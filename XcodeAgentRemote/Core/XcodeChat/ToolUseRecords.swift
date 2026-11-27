//
//  ToolUseRecords.swift
//  XcodeAgentRemote
//
//  What the cards need about a turn's tool uses that their events don't carry.
//

import Foundation
import Synchronization

/// What the cards need about a turn's tool uses that their events don't carry, by tool use id: the content of the file
/// a tool use changes, and whether it was denied (its result alone doesn't tell a denial from an error).
/// Recorded by the provider while the turn runs (only it knows which of its tools change files, and what it denied);
/// read when the turn's cards are built. Set and read only, never waited on: kept behind a lock.
nonisolated final class ToolUseRecords: Sendable {
    /// What is recorded about one tool use.
    struct Record: Sendable {
        /// The file's content before the tool use ran; nil if it could not be read (e.g. a new file).
        var fileBefore: String?
        /// The file's content after the tool use ran.
        var fileAfter: String?
        /// The user denied it, declined its questions or rejected its plan (or did not answer in time).
        var denied = false
    }

    private struct State {
        var byToolUseID: [String: Record] = [:]
        var repeatedEarlierToolUse = false
    }

    private let state = Mutex(State())

    var byToolUseID: [String: Record] { state.withLock { $0.byToolUseID } }

    /// Records the file's content before the tool use ran.
    func setFileBefore(_ content: String?, toolUseID: String) {
        state.withLock { $0.byToolUseID[toolUseID, default: Record()].fileBefore = content }
    }

    /// Records the file's content after the tool use ran.
    func setFileAfter(_ content: String?, toolUseID: String) {
        state.withLock { $0.byToolUseID[toolUseID, default: Record()].fileAfter = content }
    }

    /// Records that the tool use was denied.
    func setDenied(toolUseID: String) {
        state.withLock { $0.byToolUseID[toolUseID, default: Record()].denied = true }
    }

    /// The earlier answer (`TurnRequest.repeatedAnswer`) was given to a repeat of its tool use in this turn.
    var repeatedEarlierToolUse: Bool { state.withLock { $0.repeatedEarlierToolUse } }

    /// Records that the agent repeated the earlier tool use, and was given the earlier answer.
    func setRepeatedEarlierToolUse() {
        state.withLock { $0.repeatedEarlierToolUse = true }
    }
}
