//
//  Turn.swift
//  XcodeAgentRemote
//
//  Provider-neutral parts of one turn: what a provider is asked to run.
//

import Foundation
import Synchronization

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
    /// The user's answer to a request of an earlier turn that ended before it was answered: the agent is resumed
    /// with the answer and usually makes the same tool use again; that request is answered with it, without asking.
    var repeatedAnswer: RepeatedAnswer? = nil
}

/// An answer to give again when the agent repeats the tool use it was given for.
nonisolated struct RepeatedAnswer: Sendable {
    /// The tool use the user answered (it ended without a result).
    var toolUse: ChatEvent.ToolUse
    var answer: UserAnswer
}

nonisolated extension UserAnswer {
    /// The same answer, for another tool use.
    func answering(_ toolUseID: String) -> UserAnswer {
        switch self {
        case .permission(_, let allow, let message): .permission(toolUseID: toolUseID, allow: allow, message: message)
        case .questions(_, let answers): .questions(toolUseID: toolUseID, answers: answers)
        case .declineQuestions(_, let message): .declineQuestions(toolUseID: toolUseID, message: message)
        case .planApproval(_, let approve, let feedback):
            .planApproval(toolUseID: toolUseID, approve: approve, feedback: feedback)
        }
    }

    /// A deny: the tool use doesn't run (denied permission, declined questions, rejected plan).
    var isDeny: Bool {
        switch self {
        case .permission(_, let allow, _): !allow
        case .declineQuestions: true
        case .planApproval(_, let approve, _): !approve
        case .questions: false
        }
    }
}

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

nonisolated extension ChatEvent.ToolUse {
    /// A string value of the input.
    func stringInput(_ key: String) -> String? {
        if case .string(let value) = input[key] { value } else { nil }
    }
}
