//
//  RunningTurn.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import Foundation
import Synchronization

// MARK: - Running turns

/// A turn running on its own, its events saved so a chain of streams reads them in order: `sendMessage`'s until the
/// turn waits for the user, `answerUserRequest`'s from there until the next request, and so on to the end.
/// Its tool uses are answerable (`PendingUserRequestHandler`) until they have a result.
actor RunningTurn {
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
    nonisolated static func start(
        _ events: AsyncThrowingStream<ChatEvent, Error>
    ) -> RunningTurn {
        let turn = RunningTurn()
        Task {
            // Tool uses of this turn without a result yet.
            var open = Set<String>()
            do {
                for try await event in events {
                    switch event {
                    case .toolUse(let toolUse):
                        open.insert(toolUse.id)
                        await PendingUserRequestHandler.shared.register(
                            toolUse.id
                        )
                    // A question or a plan has no `.toolUse`: its request opens it.
                    case .userRequest(let request):
                        open.insert(request.toolUseID)
                        await PendingUserRequestHandler.shared.register(
                            request.toolUseID
                        )
                    case .toolResult(let result):
                        open.remove(result.toolUseID)
                        await PendingUserRequestHandler.shared.unregister(
                            result.toolUseID
                        )
                    default:
                        break
                    }
                    await turn.push(.event(event))
                    if case .userRequest(let request) = event {
                        // Once the agent waits on it, the turn waits for that answer (`answerUserRequest`).
                        await PendingUserRequestHandler.shared.whenWaiting(
                            for: request.toolUseID
                        ) {
                            RunningTurns.save(
                                turn,
                                waitingFor: request.toolUseID
                            )
                            await turn.push(.waiting)
                        }
                    }
                }
            } catch {
                await turn.push(.failed(error))
            }
            await PendingUserRequestHandler.shared.unregister(open)
            RunningTurns.remove(turn)
            await turn.end()
        }
        return turn
    }

    /// The turn's next events, until it waits for the user or ends.
    nonisolated func untilWaitingForUser() -> AsyncThrowingStream<
        ChatEvent, Error
    > {
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

/// The running turns that wait for the user, by the tool use they wait for (what an answer names). Only set and read,
/// never waited on: kept behind a lock.
nonisolated enum RunningTurns {
    private static let byToolUseID = Mutex<[String: RunningTurn]>([:])

    fileprivate static func save(
        _ turn: RunningTurn,
        waitingFor toolUseID: String
    ) {
        byToolUseID.withLock { $0[toolUseID] = turn }
    }

    /// The turn waiting for the answer to this tool use, removed (an answer continues it once).
    static func take(waitingFor toolUseID: String) -> RunningTurn? {
        byToolUseID.withLock { $0.removeValue(forKey: toolUseID) }
    }

    static func isWaiting(for toolUseID: String) -> Bool {
        byToolUseID.withLock { $0[toolUseID] != nil }
    }

    /// Forgets a turn that ended.
    static func remove(_ turn: RunningTurn) {
        byToolUseID.withLock { $0 = $0.filter { $0.value !== turn } }
    }

    /// Whether a chat waits for the user's answer to this tool use (`answerUserRequest` would deliver it).
    nonisolated static func isWaitingForUser(toolUseID: String) -> Bool {
        isWaiting(for: toolUseID)
            || XcodeChat.unansweredRequest(toolUseID: toolUseID) != nil
    }

}
