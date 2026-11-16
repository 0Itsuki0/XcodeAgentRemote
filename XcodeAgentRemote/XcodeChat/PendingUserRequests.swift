//
//  PendingUserRequests.swift
//  XcodeAgentRemote
//

import Foundation

/// The tool uses the agent waits on the user for, by id, kept across launches (`UserDefaults`).
/// The `.jsonl` shows a tool use with no result both while it runs and while it waits for the user; this mark tells
/// them apart. Kept per agent, and only by the agent's provider: set when the agent asks the user, removed once the
/// provider has the answer or the tool use has a result.
/// A mark counts only while its tool use is the session's last message (`ClaudeProvider.userRequest`): if the
/// agent was killed before it settled the request, the request can still be answered (`answerUserRequest`); if the app quit
/// instead, the agent settles it itself (as failed) and goes on, and the mark left behind is stale.
nonisolated enum WaitingMarks {
    /// `[agent: [tool use id]]`: tool use ids are an agent's own, and only that agent's provider reads them.
    private static let key = "WaitingForUserToolUseIDsByAgent"

    private static var marks: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func contains(_ toolUseID: String, agent: Agent) -> Bool {
        marks[agent.rawValue]?.contains(toolUseID) ?? false
    }

    static func add(_ toolUseID: String, agent: Agent) {
        var ids = marks[agent.rawValue] ?? []
        if !ids.contains(toolUseID) { ids.append(toolUseID) }
        marks[agent.rawValue] = ids
    }

    static func remove(_ toolUseID: String, agent: Agent) {
        marks[agent.rawValue] = (marks[agent.rawValue] ?? []).filter { $0 != toolUseID }
    }
}

/// The requests to the user in running turns (permission, questions, a plan: `UserRequest`), and their answers.
/// A tool use is answerable from when it is streamed until its result (`register` / `unregister`, by `sendMessage`); the answer
/// may arrive before the agent asks for it (it is kept until the provider waits for it) and is taken once.
actor PendingUserRequests {
    /// One for the app: answers come from the server, waits from the running turns.
    static let shared = PendingUserRequests()

    /// Where a tool use is: answerable, answered before the agent asked, or the agent waiting for the answer.
    private enum State {
        case registered
        case answered(UserAnswer)
        case waiting(CheckedContinuation<UserAnswer?, Never>)
    }

    private var requests: [String: State] = [:]
    /// What to do when the agent starts waiting for a tool use's answer (`whenWaiting`), by tool use id.
    private var waitingHandlers: [String: @Sendable () async -> Void] = [:]

    /// Makes a tool use answerable (when it is streamed).
    func register(_ toolUseID: String) {
        if requests[toolUseID] == nil { requests[toolUseID] = .registered }
    }

    /// No longer answerable; a provider waiting for it gets no answer.
    func unregister(_ toolUseID: String) {
        waitingHandlers[toolUseID] = nil
        if case .waiting(let continuation)? = requests.removeValue(forKey: toolUseID) {
            continuation.resume(returning: nil)
        }
    }

    /// Unregisters several tool uses (a turn's, when it ends).
    func unregister(_ toolUseIDs: Set<String>) {
        for toolUseID in toolUseIDs { unregister(toolUseID) }
    }

    /// Takes the answer to a tool use: hands it to the waiting provider, or keeps it until the provider asks.
    /// Throws `noWaitingRequest` if the tool use is not answerable or was already answered.
    func answer(_ answer: UserAnswer) throws(SendMessageError) {
        let toolUseID = answer.toolUseID
        switch requests[toolUseID] {
        case .registered:
            requests[toolUseID] = .answered(answer)
        case .waiting(let continuation):
            requests[toolUseID] = nil
            continuation.resume(returning: answer)
        case .answered, nil:
            throw .noWaitingRequest(toolUseID: toolUseID)
        }
    }

    /// Runs `handler` once the agent waits for the answer to this tool use (right away if it already waits);
    /// never if the agent doesn't ask for it.
    func whenWaiting(for toolUseID: String, _ handler: @escaping @Sendable () async -> Void) {
        if case .waiting? = requests[toolUseID] {
            Task { await handler() }
        } else {
            waitingHandlers[toolUseID] = handler
        }
    }

    /// For providers: the user's answer to the tool use the agent waits for; nil if none arrives within
    /// `timeout` seconds, the tool use is closed, or the task is cancelled.
    func waitForAnswer(toolUseID: String, timeout: TimeInterval) async -> UserAnswer? {
        if case .answered(let answer)? = requests[toolUseID] {
            requests[toolUseID] = nil
            return answer
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                requests[toolUseID] = .waiting(continuation)
                if let handler = waitingHandlers.removeValue(forKey: toolUseID) {
                    Task { await handler() }
                }
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    self.unregister(toolUseID)
                }
            }
        } onCancel: {
            Task { await self.unregister(toolUseID) }
        }
    }
}
