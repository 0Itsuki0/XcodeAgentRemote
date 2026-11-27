//
//  ChatEvent+Extensions.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/27.
//

import Foundation

extension ChatEvent.UserRequest {
    var name: String {
        switch self {
        case .permission(_):
            "Permission"
        case .questions(_, _):
            "Questions"
        case .planApproval(_, plan: _):
            "Plan Approval"
        }
    }
}

extension ChatEvent.UserResponse {
    var permissionAllowed: Bool {
        if case .permission(_, allow: let allowed, message: _) = self {
            return allowed
        }
        return false
    }

    var planResponse: (Bool, String?)? {
        if case .planApproval(
            _,
            approve: let approved,
            feedback: let feedback
        ) = self {
            return (approved, feedback)
        }
        return nil
    }

    var answers: [String: [String]] {
        if case .questions(_, answers: let answers) = self {
            return answers
        }
        return [:]
    }

    var declineQuestion: String? {
        if case .declineQuestions(_, message: let message) = self {
            /// return empty string instead of nil to show the exclamation mark
            return message ?? ""
        }
        return nil
    }
}

extension Array where Element == ChatEvent {
    func response(for request: ChatEvent.UserRequest) -> ChatEvent.UserResponse?
    {
        let responses: [ChatEvent.UserResponse] = self.compactMap {
            $0.userResponse
        }

        return responses.first {
            $0.toolUseID == request.toolUseID
        }

    }

    func result(for toolUse: ChatEvent.ToolUse) -> ChatEvent.ToolResult? {
        let results: [ChatEvent.ToolResult] = self.compactMap {
            $0.toolResult
        }
        return results.first { $0.toolUseID == toolUse.id }
    }
}

extension ChatEvent {
    var userResponse: UserResponse? {
        if case .userResponse(let response) = self {
            return response
        }
        return nil
    }

    var toolResult: ToolResult? {
        if case .toolResult(let toolResult) = self {
            return toolResult
        }
        return nil
    }
}

extension PermissionMode {
    var displayString: String {
        self.rawValue.capitalized
    }
}

extension Array where Element == XcodeConversation {
    var sortedByLastActivity: Self {
        return self.sorted(by: {
            ($0.lastActivityDate?.timeIntervalSince1970 ?? 0)
                > ($1.lastActivityDate?.timeIntervalSince1970 ?? 0)
        })
    }
}
