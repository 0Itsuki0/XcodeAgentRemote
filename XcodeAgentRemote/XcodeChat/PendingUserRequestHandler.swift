//
//  PendingUserRequestHandler.swift
//  XcodeAgentRemote
//

import Foundation

/// The requests to the user in running turns (permission, questions, a plan: `ChatEvent.UserRequest`), and their answers.
/// A tool use is answerable from when it is streamed until its result (`register` / `unregister`, by `sendMessage`); the answer
/// may arrive before the agent asks for it (it is kept until the provider waits for it) and is taken once.
actor PendingUserRequestHandler {
    /// One for the app: answers come from the server, waits from the running turns.
    static let shared = PendingUserRequestHandler()

    /// Where a tool use is: answerable, answered before the agent asked, or the agent waiting for the answer.
    private enum State {
        case registered
        case answered(ChatEvent.UserResponse)
        case waiting(CheckedContinuation<ChatEvent.UserResponse?, Never>)
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
        if case .waiting(let continuation)? = requests.removeValue(
            forKey: toolUseID
        ) {
            continuation.resume(returning: nil)
        }
    }

    /// Unregisters several tool uses (a turn's, when it ends).
    func unregister(_ toolUseIDs: Set<String>) {
        for toolUseID in toolUseIDs { unregister(toolUseID) }
    }

    /// Takes the answer to a tool use: hands it to the waiting provider, or keeps it until the provider asks.
    /// Throws `noWaitingRequest` if the tool use is not answerable or was already answered.
    func answer(_ answer: ChatEvent.UserResponse) throws(SendMessageError) {
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
    func whenWaiting(
        for toolUseID: String,
        _ handler: @escaping @Sendable () async -> Void
    ) {
        if case .waiting? = requests[toolUseID] {
            Task { await handler() }
        } else {
            waitingHandlers[toolUseID] = handler
        }
    }

    /// For providers: the user's answer to the tool use the agent waits for; nil if none arrives within
    /// `timeout` seconds, the tool use is closed, or the task is cancelled.
    func waitForAnswer(toolUseID: String, timeout: TimeInterval) async
        -> ChatEvent.UserResponse?
    {
        if case .answered(let answer)? = requests[toolUseID] {
            requests[toolUseID] = nil
            return answer
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                requests[toolUseID] = .waiting(continuation)
                if let handler = waitingHandlers.removeValue(forKey: toolUseID)
                {
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
