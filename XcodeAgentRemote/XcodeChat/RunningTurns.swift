//
//  RunningTurns.swift
//  XcodeAgentRemote
//
//  The running turns that wait for the user.
//

import Foundation
import Synchronization

/// The running turns that wait for the user, by the tool use they wait for (what an answer names). Only set and read,
/// never waited on: kept behind a lock.
nonisolated enum RunningTurns {
    private static let byToolUseID = Mutex<[String: RunningTurn]>([:])

    static func save(
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
