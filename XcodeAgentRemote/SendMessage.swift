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
    /// No chat waits for an answer to this tool use (unknown id, already answered, or settled without it).
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
/// `.assistantMessage`, `.toolUse`, `.toolResult` and `.userRequest` events. The turn is recorded in Xcode's chat store
/// when it ends.
///
/// The stream ends when the turn ends, or when the agent waits for the user (permission to use a tool, questions, a
/// plan): then it ends with that `.userRequest` (`waitingForUser`), and `answerUserRequest(_:)` continues the turn's
/// stream from there. With no answer within `permissionTimeout` seconds (nil: 600) the request is denied.
///
/// The turn runs on its own until it ends, whether or not its stream is read.
/// Throws `XcodeChatError`; `.agentFailed` comes after the turn's events, the turn recorded.
nonisolated func sendMessage(
    _ prompt: String,
    to target: MessageTarget,
    permissionModeOverride: PermissionMode? = nil,
    permissionTimeout: TimeInterval? = nil
) -> AsyncThrowingStream<ChatEvent, Error> {
    let turn = RunningTurn.start(XcodeChat.runTurn(
        prompt, to: target, permissionModeOverride: permissionModeOverride, permissionTimeout: permissionTimeout ?? 600))
    return turn.untilWaitingForUser()
}

// MARK: - Answer a request to the user

/// Answers a request from a chat's history (`waitingForUser`): a permission, questions or a plan. Streams the rest of
/// that turn like `sendMessage`: until the next request to the user, or the end of the turn.
/// - If the turn's agent still waits for it, the answer goes to it and the stream continues that turn.
/// - If not (its agent was stopped before it settled the request), the chat is resumed with the answer: the agent
///   usually makes the same tool use again, and that request is answered with the same answer without asking
///   (unless the answer is a deny). `permissionTimeout` applies to that resumed turn.
/// Throws `SendMessageError.noWaitingRequest` if no chat waits for the user on that tool use.
nonisolated func answerUserRequest(_ answer: UserAnswer, permissionTimeout: TimeInterval? = nil) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let events: AsyncThrowingStream<ChatEvent, Error>
                if let turn = await RunningTurns.shared.take(waitingFor: answer.toolUseID) {
                    // If the wait timed out meanwhile, the turn went on without this answer; it still continues here.
                    try? await PendingUserRequestHandler.shared.answer(answer)
                    events = turn.untilWaitingForUser()
                } else if XcodeChat.unansweredRequest(toolUseID: answer.toolUseID) != nil {
                    events = RunningTurn.start(XcodeChat.resume(
                        answering: answer, permissionTimeout: permissionTimeout ?? 600)).untilWaitingForUser()
                } else {
                    throw SendMessageError.noWaitingRequest(toolUseID: answer.toolUseID)
                }
                for try await event in events { continuation.yield(event) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// Whether a chat waits for the user's answer to this tool use (`answerUserRequest` would deliver it).
nonisolated func isWaitingForUser(toolUseID: String) async -> Bool {
    await RunningTurns.shared.isWaiting(for: toolUseID) || XcodeChat.unansweredRequest(toolUseID: toolUseID) != nil
}

// MARK: - Running turns

/// A turn running on its own, its events saved so a chain of streams reads them in order: `sendMessage`'s until the
/// turn waits for the user, `answerUserRequest`'s from there until the next request, and so on to the end.
/// Its tool uses are answerable (`PendingUserRequestHandler`) until they have a result.
private actor RunningTurn {
    /// One event, the point where the turn waits for the user (a stream ends there), or the turn's error.
    private enum Item {
        case event(ChatEvent)
        case waiting
        case failed(Error)
    }

    private var items: [Item] = []
    private var reader: CheckedContinuation<Item?, Never>?
    private var ended = false

    /// Starts the turn: reads `events` to the end in a task of its own, not tied to any stream that reads the turn.
    nonisolated static func start(_ events: AsyncThrowingStream<ChatEvent, Error>) -> RunningTurn {
        let turn = RunningTurn()
        Task {
            // Tool uses of this turn without a result yet.
            var open = Set<String>()
            do {
                for try await event in events {
                    switch event {
                    case .toolUse(let toolUse):
                        open.insert(toolUse.id)
                        await PendingUserRequestHandler.shared.register(toolUse.id)
                    case .toolResult(let result):
                        open.remove(result.toolUseID)
                        await PendingUserRequestHandler.shared.unregister(result.toolUseID)
                    default:
                        break
                    }
                    await turn.push(.event(event))
                    if case .userRequest(let request) = event {
                        // Once the agent waits on it, the turn waits for that answer (`answerUserRequest`).
                        await PendingUserRequestHandler.shared.whenWaiting(for: request.toolUseID) {
                            await RunningTurns.shared.save(turn, waitingFor: request.toolUseID)
                            await turn.push(.waiting)
                        }
                    }
                }
            } catch {
                await turn.push(.failed(error))
            }
            await PendingUserRequestHandler.shared.unregister(open)
            await RunningTurns.shared.remove(turn)
            await turn.end()
        }
        return turn
    }

    /// The turn's next events, until it waits for the user or ends.
    nonisolated func untilWaitingForUser() -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while let item = await self.next() {
                    switch item {
                    case .event(let event):
                        continuation.yield(event)
                    case .waiting:
                        continuation.finish()
                        return
                    case .failed(let error):
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func push(_ item: Item) {
        if let reader {
            self.reader = nil
            reader.resume(returning: item)
        } else {
            items.append(item)
        }
    }

    private func end() {
        ended = true
        if let reader {
            self.reader = nil
            reader.resume(returning: nil)
        }
    }

    /// The next item, waiting for the turn to produce it; nil once the turn ended and all was read.
    private func next() async -> Item? {
        if !items.isEmpty { return items.removeFirst() }
        if ended { return nil }
        return await withCheckedContinuation { reader = $0 }
    }
}

/// The running turns that wait for the user, by the tool use they wait for (what an answer names).
private actor RunningTurns {
    static let shared = RunningTurns()

    private var byToolUseID: [String: RunningTurn] = [:]

    func save(_ turn: RunningTurn, waitingFor toolUseID: String) {
        byToolUseID[toolUseID] = turn
    }

    /// The turn waiting for the answer to this tool use, removed (an answer continues it once).
    func take(waitingFor toolUseID: String) -> RunningTurn? {
        byToolUseID.removeValue(forKey: toolUseID)
    }

    func isWaiting(for toolUseID: String) -> Bool {
        byToolUseID[toolUseID] != nil
    }

    /// Forgets a turn that ended.
    func remove(_ turn: RunningTurn) {
        byToolUseID = byToolUseID.filter { $0.value !== turn }
    }
}
