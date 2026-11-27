//
//  TurnRequest.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/19.
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
    /// The user's answer to a request of an earlier turn that ended before it was answered: the agent is resumed
    /// with the answer and usually makes the same tool use again; that request is answered with it, without asking.
    var repeatedAnswer: RepeatedAnswer? = nil
}
