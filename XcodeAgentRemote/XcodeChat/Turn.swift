//
//  Turn.swift
//  XcodeAgentRemote
//
//  Provider-neutral parts of one turn: what a provider is asked to run.
//

import Foundation

/// What a provider needs to run one turn.
nonisolated struct TurnRequest: Sendable {
    /// The folder the agent runs in: the folder that contains the project file.
    var workingDirectory: URL
    var sessionID: String
    /// Continue the session (an existing chat), or start it (a new chat).
    var resume: Bool
    var prompt: String
    var permissionMode: XcodeAgentConfiguration.PermissionMode
    /// Seconds a request to the user waits for its answer (`answerUserRequest`) before it is denied.
    var permissionTimeout: TimeInterval
    /// Where the provider records what the events don't carry about its tool uses, for their cards.
    var records: ToolUseRecords
}

/// What the cards need about a turn's tool uses that their events don't carry, by tool use id: the content of the file
/// a tool use changes, and whether it was denied (its result alone doesn't tell a denial from an error).
/// Recorded by the provider while the turn runs (only it knows which of its tools change files, and what it denied);
/// read when the turn's cards are built.
actor ToolUseRecords {
    /// What is recorded about one tool use.
    struct Record: Sendable {
        /// The file's content before the tool use ran; nil if it could not be read (e.g. a new file).
        var fileBefore: String?
        /// The file's content after the tool use ran.
        var fileAfter: String?
        /// The user denied it, declined its questions or rejected its plan (or did not answer in time).
        var denied = false
    }

    private(set) var byToolUseID: [String: Record] = [:]

    /// Records the file's content before the tool use ran.
    func setFileBefore(_ content: String?, toolUseID: String) {
        byToolUseID[toolUseID, default: Record()].fileBefore = content
    }

    /// Records the file's content after the tool use ran.
    func setFileAfter(_ content: String?, toolUseID: String) {
        byToolUseID[toolUseID, default: Record()].fileAfter = content
    }

    /// Records that the tool use was denied.
    func setDenied(toolUseID: String) {
        byToolUseID[toolUseID, default: Record()].denied = true
    }
}

nonisolated extension ChatEvent.ToolUse {
    /// A string value of the input.
    func stringInput(_ key: String) -> String? {
        if case .string(let value) = input[key] { value } else { nil }
    }
}
