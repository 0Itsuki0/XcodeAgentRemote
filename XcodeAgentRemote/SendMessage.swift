//
//  SendMessage.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

/// Invoke XcodeChat (`XcodeChat/`) to send a message.
/// Input: new conversation / conversationId / project (whatever is required by the script)

import Foundation

/// Why a permission answer could not be delivered.
nonisolated enum SendMessageError: LocalizedError {
    /// No running turn is waiting for an answer to this tool use (unknown id, already answered, or timed out).
    case noWaitingRequest(toolUseID: String)

    var errorDescription: String? {
        switch self {
        case .noWaitingRequest(let toolUseID):
            "No turn is waiting for a permission answer to tool use \(toolUseID)"
        }
    }
}

// MARK: - Send

/// Runs one turn and streams its events as they happen: the prompt (`.userMessage`), then `.intermediate`,
/// `.assistantMessage`, `.toolUse` and `.toolResult` events. The turn is recorded in Xcode's chat store when it ends.
///
/// When the agent asks for permission to use a tool, that tool use has no result yet (`waitingForPermission`) and the
/// turn waits for `answerPermissionRequest(_:)`; with no answer within `permissionTimeout` seconds (nil: 600) it is
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
                        await PermissionRequests.shared.register(toolUse.id)
                    case .toolResult(let result):
                        waiting.remove(result.toolUseID)
                        await PermissionRequests.shared.unregister(result.toolUseID)
                    default:
                        break
                    }
                    continuation.yield(event)
                }
                await PermissionRequests.shared.unregister(waiting)
                continuation.finish()
            } catch {
                await PermissionRequests.shared.unregister(waiting)
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Answer a permission request

/// Answers a running turn's tool use that waits for permission (`waitingForPermission`); the turn then continues.
/// Throws `SendMessageError.noWaitingRequest` if no running turn has that tool use without a result.
nonisolated func answerPermissionRequest(_ answer: PermissionAnswer) async throws {
    try await PermissionRequests.shared.answer(answer)
}
