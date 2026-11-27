//
//  ClaudeSessionMessage.swift
//  XcodeAgentRemote
//
//  A session transcript's messages: the Agent SDK's `SessionMessage` and the Anthropic API message.
//

import Foundation

nonisolated extension ClaudeProvider {

    // MARK: - SessionMessage (Swift counterpart of the Agent SDK's `SessionMessage`)

    /// A message from a session transcript, as returned by the TypeScript Agent SDK's `getSessionMessages`:
    /// ```ts
    /// type SessionMessage = {
    ///     type: 'user' | 'assistant' | 'system';
    ///     uuid: string;
    ///     session_id: string;
    ///     message: unknown;
    ///     parent_tool_use_id: string | null;
    ///     parent_agent_id: string | null;
    /// };
    /// ```
    /// `message` is `unknown` in the SDK; it is the raw Anthropic API message, typed here as `APIMessage`.
    nonisolated struct SessionMessage: Codable, Hashable, Sendable, Identifiable
    {
        enum MessageType: String, Codable, Hashable, Sendable {
            case user, assistant, system
        }

        var type: MessageType
        var uuid: String
        var sessionID: String
        /// `nil` for system messages, which have no API message.
        var message: APIMessage?
        var parentToolUseID: String?
        var parentAgentID: String?

        var id: String { uuid }

        enum CodingKeys: String, CodingKey {
            case type, uuid, message
            case sessionID = "session_id"
            case parentToolUseID = "parent_tool_use_id"
            case parentAgentID = "parent_agent_id"
        }
    }

    // MARK: - Anthropic API message

    /// An Anthropic Messages API message (`MessageParam` for user entries, `Message` for assistant entries).
    nonisolated struct APIMessage: Codable, Hashable, Sendable {
        enum Role: String, Codable, Hashable, Sendable {
            case user, assistant
        }

        /// API message id (`msg_…`); assistant messages only.
        var id: String?
        var role: Role
        var model: String?
        var content: [ContentBlock]
        var stopReason: String?
        var usage: JSONValue?

        enum CodingKeys: String, CodingKey {
            case id, role, model, content, usage
            case stopReason = "stop_reason"
        }

        init(
            id: String? = nil,
            role: Role,
            model: String? = nil,
            content: [ContentBlock],
            stopReason: String? = nil,
            usage: JSONValue? = nil
        ) {
            self.id = id
            self.role = role
            self.model = model
            self.content = content
            self.stopReason = stopReason
            self.usage = usage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            role = try container.decode(Role.self, forKey: .role)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            stopReason = try container.decodeIfPresent(
                String.self,
                forKey: .stopReason
            )
            usage = try container.decodeIfPresent(
                JSONValue.self,
                forKey: .usage
            )
            // `content` is either a plain string or an array of content blocks.
            if let text = try? container.decode(String.self, forKey: .content) {
                content = [.text(TextBlock(text: text))]
            } else {
                content = try container.decode(
                    [ContentBlock].self,
                    forKey: .content
                )
            }
        }
    }

    /// A content block of an API message. Unrecognized block types are kept as `.unknown` with their raw JSON.
    nonisolated enum ContentBlock: Codable, Hashable, Sendable {
        case text(TextBlock)
        case thinking(ThinkingBlock)
        case redactedThinking(RedactedThinkingBlock)
        case toolUse(ToolUseBlock)
        case toolResult(ToolResultBlock)
        case image(ImageBlock)
        case unknown(JSONValue)

        private enum TypeKey: String, CodingKey { case type }

        init(from decoder: Decoder) throws {
            let type = try decoder.container(keyedBy: TypeKey.self)
                .decodeIfPresent(String.self, forKey: .type)
            switch type {
            case "text": self = .text(try TextBlock(from: decoder))
            case "thinking": self = .thinking(try ThinkingBlock(from: decoder))
            case "redacted_thinking":
                self = .redactedThinking(
                    try RedactedThinkingBlock(from: decoder)
                )
            case "tool_use": self = .toolUse(try ToolUseBlock(from: decoder))
            case "tool_result":
                self = .toolResult(try ToolResultBlock(from: decoder))
            case "image": self = .image(try ImageBlock(from: decoder))
            default: self = .unknown(try JSONValue(from: decoder))
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let block): try block.encode(to: encoder)
            case .thinking(let block): try block.encode(to: encoder)
            case .redactedThinking(let block): try block.encode(to: encoder)
            case .toolUse(let block): try block.encode(to: encoder)
            case .toolResult(let block): try block.encode(to: encoder)
            case .image(let block): try block.encode(to: encoder)
            case .unknown(let value): try value.encode(to: encoder)
            }
        }
    }

    nonisolated struct TextBlock: Codable, Hashable, Sendable {
        var type = "text"
        var text: String
    }

    nonisolated struct ThinkingBlock: Codable, Hashable, Sendable {
        var type = "thinking"
        var thinking: String
        var signature: String?
    }

    nonisolated struct RedactedThinkingBlock: Codable, Hashable, Sendable {
        var type = "redacted_thinking"
        var data: String
    }

    nonisolated struct ToolUseBlock: Codable, Hashable, Sendable {
        var type = "tool_use"
        var id: String
        var name: String
        var input: JSONValue

        /// `input` decoded into the tool's typed input, by tool name.
        var toolInput: ToolInput { ToolInput(toolName: name, input: input) }
    }

    nonisolated struct ToolResultBlock: Codable, Hashable, Sendable {
        var type = "tool_result"
        var toolUseID: String
        /// Either a plain string or content blocks in the API; a string is decoded as a single text block.
        var content: [ContentBlock]?
        var isError: Bool?

        enum CodingKeys: String, CodingKey {
            case type, content
            case toolUseID = "tool_use_id"
            case isError = "is_error"
        }

        init(
            toolUseID: String,
            content: [ContentBlock]? = nil,
            isError: Bool? = nil
        ) {
            self.toolUseID = toolUseID
            self.content = content
            self.isError = isError
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            toolUseID = try container.decode(String.self, forKey: .toolUseID)
            isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
            if let text = try? container.decode(String.self, forKey: .content) {
                content = [.text(TextBlock(text: text))]
            } else {
                content = try container.decodeIfPresent(
                    [ContentBlock].self,
                    forKey: .content
                )
            }
        }
    }

    nonisolated struct ImageBlock: Codable, Hashable, Sendable {
        var type = "image"
        var source: JSONValue
    }
}
