//
//  SendMessage.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

/// Invoke XcodeChat (`XcodeChat/`) to send a message.
/// Input: new conversation / conversationId / project (whatever is required by the script)

import Foundation

/// Why the user's answer to a request could not be delivered.
nonisolated enum SendMessageError: LocalizedError {
    /// No running turn is waiting for an answer to this tool use (unknown id, already answered, or timed out).
    case noWaitingRequest(toolUseID: String)

    var errorDescription: String? {
        switch self {
        case .noWaitingRequest(let toolUseID):
            "No turn is waiting for an answer to tool use \(toolUseID)"
        }
    }
}

// MARK: - Send

/// Runs one turn and streams its events as they happen: the prompt (`.userMessage`), then `.intermediate`,
/// `.assistantMessage`, `.toolUse` and `.toolResult` events. The turn is recorded in Xcode's chat store when it ends.
///
/// When the agent asks the user (permission to use a tool, questions, a plan: `UserRequest`), that tool use has no
/// result yet (`waitingForUser`) and the turn waits for `answerUserRequest(_:)`; with no answer within
/// `permissionTimeout` seconds (nil: 600) it is
/// denied. Then its tool result follows and the turn continues.
///
/// Cancelling (the caller stops iterating) stops the agent; the turn is then not recorded.
/// Throws `XcodeChatError`; `.agentFailed` comes after the turn's events, the turn recorded.
nonisolated func sendMessage(
    _ prompt: String,
    to target: MessageTarget,
    permissionModeOverride: PermissionMode? = nil,
    permissionTimeout: TimeInterval? = nil
) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            // Tool uses of this turn without a result yet: answerable by their id.
            var waiting = Set<String>()
            do {
                for try await event in XcodeChat.runTurn(
                    prompt, to: target, permissionModeOverride: permissionModeOverride,
                    permissionTimeout: permissionTimeout ?? 600)
                {
                    switch event {
                    case .toolUse(let toolUse):
                        waiting.insert(toolUse.id)
                        await PendingUserRequests.shared.register(toolUse.id)
                    case .toolResult(let result):
                        waiting.remove(result.toolUseID)
                        await PendingUserRequests.shared.unregister(result.toolUseID)
                    default:
                        break
                    }
                    continuation.yield(event)
                }
                await PendingUserRequests.shared.unregister(waiting)
                continuation.finish()
            } catch {
                await PendingUserRequests.shared.unregister(waiting)
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Answer a request to the user

/// Runs `handler` once a running turn waits for the user's answer to this tool use (a permission, questions, a plan;
/// right away if it already waits); never if the agent doesn't ask the user (e.g. a tool that runs without asking).
nonisolated func whenWaitingForUser(toolUseID: String, _ handler: @escaping @Sendable () async -> Void) async {
    await PendingUserRequests.shared.whenWaiting(for: toolUseID, handler)
}

/// Answers a request a running turn waits for (`waitingForUser`): a permission, questions or a plan. The turn then
/// continues. Throws `SendMessageError.noWaitingRequest` if no running turn has that tool use without a result.
nonisolated func answerUserRequest(_ answer: UserAnswer) async throws {
    try await PendingUserRequests.shared.answer(answer)
}
