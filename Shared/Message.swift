//
//  Message.swift
//  XcodeAgentRemote
//
//  Types shared by the macOS app (xcode-chat / server) and the iOS app (server client).
//

import Foundation

// MARK: - Input

/// Which chat a message goes to (the targets `xcode-chat` accepts).
nonisolated enum MessageTarget: Codable, Sendable {
    /// Start a new chat in the project (`.xcodeproj` / `.xcworkspace`).
    case newConversation(project: URL, name: String? = nil)
    /// Continue a chat of the project.
    case conversation(id: String, project: URL)
    /// Continue a chat, given its Xcode chat store folder (`<ProjectName>-<hash>`, name or path).
    case conversationInStore(id: String, store: String)
}

/// Manual / Auto, to override Xcode's setting for one message.
nonisolated enum PermissionMode: String, Codable, Sendable {
    case manual, auto
}

// MARK: - Output (Swift counterpart of xcode-chat's events.py)

/// One event `xcode-chat` streams while a turn runs (one JSON line on its stdout, discriminated by "type").
/// The last event is always `.result`.
nonisolated enum ChatEvent: Codable, Sendable {
    case start(Start)
    case text(Text)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    /// The agent asked for permission to use a tool; the turn stops after this.
    case permissionRequest(PermissionRequest)
    case result(TurnResult)

    /// Xcode's permission setting the turn ran with (`IDEChatAgentPermissionMode`).
    enum PermissionMode: String, Codable, Sendable {
        case manual = "standard"
        case auto
        case dontAsk
        case bypassPermissions
    }

    struct Start: Codable, Sendable {
        var conversation: String
        var session: String
        var provider: String
        var permissionMode: PermissionMode
        var newConversation: Bool

        enum CodingKeys: String, CodingKey {
            case conversation, session, provider
            case permissionMode = "permission_mode"
            case newConversation = "new_conversation"
        }
    }

    struct Text: Codable, Sendable {
        enum Category: String, Codable, Sendable {
            case thinking, prose
        }
        var category: Category
        var text: String
    }

    struct ToolUse: Codable, Sendable {
        var id: String
        var name: String
        var input: [String: JSONValue]
    }

    struct ToolResult: Codable, Sendable {
        var id: String
        var isError: Bool
        var output: String

        enum CodingKeys: String, CodingKey {
            case id, output
            case isError = "is_error"
        }
    }

    struct PermissionRequest: Codable, Sendable {
        var toolUseID: String?
        var tool: String
        var input: [String: JSONValue]

        enum CodingKeys: String, CodingKey {
            case tool, input
            case toolUseID = "tool_use_id"
        }
    }

    struct TurnResult: Codable, Sendable {
        enum Status: String, Codable, Sendable {
            case completed, error
            case permissionRequired = "permission_required"
        }
        var status: Status
        var conversation: String
        var session: String
        /// The agent's final reply.
        var result: String?
        /// The request the turn stopped at (status `.permissionRequired`).
        var pending: PermissionRequest?
        /// The chat's folder in Xcode's chat store.
        var savedTo: String
        /// Tool calls that never finished (not shown in Xcode's transcript).
        var unfinishedTools: [String]

        enum CodingKeys: String, CodingKey {
            case status, conversation, session, result, pending
            case savedTo = "saved_to"
            case unfinishedTools = "unfinished_tools"
        }
    }

    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(
            String.self,
            forKey: .type
        )
        switch type {
        case "start": self = .start(try Start(from: decoder))
        case "text": self = .text(try Text(from: decoder))
        case "tool_use": self = .toolUse(try ToolUse(from: decoder))
        case "tool_result": self = .toolResult(try ToolResult(from: decoder))
        case "permission_request":
            self = .permissionRequest(try PermissionRequest(from: decoder))
        case "result": self = .result(try TurnResult(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: [TypeKey.type],
                    debugDescription: "unknown event type \(type)"
                )
            )
        }
    }

    /// The event's "type" in xcode-chat's output.
    var type: String {
        switch self {
        case .start: "start"
        case .text: "text"
        case .toolUse: "tool_use"
        case .toolResult: "tool_result"
        case .permissionRequest: "permission_request"
        case .result: "result"
        }
    }

    /// Encodes back to xcode-chat's JSON: "type" plus the event's fields.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .start(let event): try event.encode(to: encoder)
        case .text(let event): try event.encode(to: encoder)
        case .toolUse(let event): try event.encode(to: encoder)
        case .toolResult(let event): try event.encode(to: encoder)
        case .permissionRequest(let event): try event.encode(to: encoder)
        case .result(let event): try event.encode(to: encoder)
        }
    }
}

// MARK: - Request body

/// The JSON body of `POST /message`: the parameters of `sendMessage`.
nonisolated struct MessageRequest: Codable, Sendable {
    var prompt: String
    var target: MessageTarget
    var permissionModeOverride: PermissionMode?
}
