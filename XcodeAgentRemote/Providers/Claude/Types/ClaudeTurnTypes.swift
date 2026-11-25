//
//  ClaudeTurnTypes.swift
//  XcodeAgentRemote
//
//  The stream-json messages a turn exchanges with the agent (only the fields used), and the turn's state shared with the agent process's exit.
//

import Foundation
import Synchronization

nonisolated extension ClaudeProvider {

    // MARK: stream-json messages (only the fields used)

    /// Sent to the agent: the prompt.
    struct PromptMessage: Encodable {
        var prompt: String
        var sessionID: String

        private enum CodingKeys: String, CodingKey {
            case type, message
            case parentToolUseID = "parent_tool_use_id"
            case sessionID = "session_id"
        }
        /// The user message: the prompt as its content.
        private struct Message: Encodable {
            var role = "user"
            var content: String
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("user", forKey: .type)
            try container.encode(Message(content: prompt), forKey: .message)
            try container.encodeNil(forKey: .parentToolUseID)
            try container.encode(sessionID, forKey: .sessionID)
        }
    }

    /// Sent to the agent: the answer to a control request (a permission decision, a hook's output, or an error).
    struct ControlResponse<Response: Encodable>: Encodable {
        /// The response to one control request: success with its response, or an error.
        struct Body: Encodable {
            var subtype: String
            var requestID: String
            var response: Response?
            var error: String?

            enum CodingKeys: String, CodingKey {
                case subtype, response, error
                case requestID = "request_id"
            }
        }
        var type = "control_response"
        var response: Body
    }

    /// `{"behavior": "allow", "updatedInput": {...}}` or `{"behavior": "deny", "message": "..."}`
    struct PermissionDecision: Encodable {
        var behavior: String
        var updatedInput: [String: JSONValue]?
        var message: String?
    }

    /// The tool use a turn waits on for the user's answer, if any. Set by the turn, read when the agent exits (behind a
    /// lock: only set and read, never waited on).
    final class WaitingToolUse: Sendable {
        private let id = Mutex<String?>(nil)
        var toolUseID: String? { id.withLock { $0 } }
        func set(_ toolUseID: String?) { id.withLock { $0 = toolUseID } }
    }

    /// Set by the agent process's `onExit` (on another thread), read once it exited.
    final class ExitError: Sendable {
        private let value = Mutex<(any Error)?>(nil)
        var error: (any Error)? { value.withLock { $0 } }
        func set(_ error: (any Error)?) { value.withLock { $0 = error } }
    }

    /// `{}`: a hook's output with no decision.
    struct Empty: Encodable {}

    /// A control request from the agent: `can_use_tool` (ask the user about a tool use) or `hook_callback`.
    struct ToolPermissionRequest: Decodable {
        var subtype: String?
        var toolName: String?
        var input: [String: JSONValue]?
        var toolUseID: String?

        enum CodingKeys: String, CodingKey {
            case subtype, input
            case toolName = "tool_name"
            case toolUseID = "tool_use_id"
        }
    }

    /// A line the agent writes. Fields that don't decode are left nil, so an unexpected line is skipped, not fatal.
    struct AgentOutputLine: Decodable {
        var type: String?
        /// assistant / user
        var message: APIMessage?
        /// control_request
        var requestID: String?
        var request: ToolPermissionRequest?
        /// result
        var result: String?
        var isError: Bool?

        enum CodingKeys: String, CodingKey {
            case type, message, request, result
            case requestID = "request_id"
            case isError = "is_error"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            message = try? container.decodeIfPresent(APIMessage.self, forKey: .message)
            requestID = try? container.decodeIfPresent(String.self, forKey: .requestID)
            request = try? container.decodeIfPresent(ToolPermissionRequest.self, forKey: .request)
            result = try? container.decodeIfPresent(String.self, forKey: .result)
            isError = try? container.decodeIfPresent(Bool.self, forKey: .isError)
        }
    }
}
