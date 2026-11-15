//
//  PermissionRequests.swift
//  XcodeAgentRemote
//

import Foundation

/// Tool uses without a result in running turns, and the answers to them.
/// A tool use is answerable from when it is streamed until its result (`register` / `unregister`, by `sendMessage`); the answer
/// may arrive before the agent asks for it (it is kept until the provider waits for it) and is taken once.
actor PermissionRequests {
    /// One for the app: answers come from the server, waits from the running turns.
    static let shared = PermissionRequests()

    /// Where a tool use is: answerable, answered before the agent asked, or the agent waiting for the answer.
    private enum State {
        case registered
        case answered(PermissionAnswer)
        case waiting(CheckedContinuation<PermissionAnswer?, Never>)
    }

    private var requests: [String: State] = [:]

    /// Makes a tool use answerable (when it is streamed).
    func register(_ toolUseID: String) {
        if requests[toolUseID] == nil { requests[toolUseID] = .registered }
    }

    /// No longer answerable; a provider waiting for it gets no answer.
    func unregister(_ toolUseID: String) {
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
    func answer(_ answer: PermissionAnswer) throws(SendMessageError) {
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

    /// For providers: the answer to the tool use the agent asks permission for; nil if none arrives within
    /// `timeout` seconds, the tool use is closed, or the task is cancelled.
    func waitForAnswer(toolUseID: String, timeout: TimeInterval) async -> PermissionAnswer? {
        if case .answered(let answer)? = requests[toolUseID] {
            requests[toolUseID] = nil
            return answer
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                requests[toolUseID] = .waiting(continuation)
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
