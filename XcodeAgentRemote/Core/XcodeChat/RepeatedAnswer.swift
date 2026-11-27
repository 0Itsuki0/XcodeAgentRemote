//
//  RepeatedAnswer.swift
//  XcodeAgentRemote
//
//  An earlier answer given again (`TurnRequest.repeatedAnswer`).
//

import Foundation

/// An answer to give again when the agent repeats the tool use it was given for.
nonisolated struct RepeatedAnswer: Sendable {
    /// The tool use the user answered (it ended without a result).
    var toolUse: ChatEvent.ToolUse
    var answer: ChatEvent.UserResponse
}
