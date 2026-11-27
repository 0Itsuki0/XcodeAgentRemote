//
//  ChatEvent+Extensions.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import Foundation

nonisolated extension ChatEvent.UserResponse {
    /// The same answer, for another tool use.
    func answering(_ toolUseID: String) -> ChatEvent.UserResponse {
        switch self {
        case .permission(_, let allow, let message):
            .permission(toolUseID: toolUseID, allow: allow, message: message)
        case .questions(_, let answers):
            .questions(toolUseID: toolUseID, answers: answers)
        case .declineQuestions(_, let message):
            .declineQuestions(toolUseID: toolUseID, message: message)
        case .planApproval(_, let approve, let feedback):
            .planApproval(
                toolUseID: toolUseID,
                approve: approve,
                feedback: feedback
            )
        }
    }

    /// An allowed permission: the tool runs, and its result is its output.
    var isAllowedPermission: Bool {
        if case .permission(_, true, _) = self { true } else { false }
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

nonisolated extension ChatEvent.ToolUse {
    /// A string value of the input.
    func stringInput(_ key: String) -> String? {
        if case .string(let value) = input[key] { value } else { nil }
    }
}
