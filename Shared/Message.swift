//
//  Message.swift
//  XcodeAgentRemote
//
//  Types shared by the macOS app (sendMessage / server) and the iOS app (server client).
//

import Foundation

// MARK: - Input

/// The agents Xcode can run: `xcrun mcpbridge run-agent <agent>`
/// ("Supported agents: antigravity, claude, claude-ext, codex, copilot, mock-agent").
nonisolated enum Agent: String, Codable, CaseIterable, Sendable {
    case antigravity
    case claude
    case claudeExt = "claude-ext"
    case codex
    case copilot
    case mockAgent = "mock-agent"
}

/// Which chat a message goes to (`sendMessage`).
nonisolated enum MessageTarget: Codable, Sendable {
    /// Start a new chat in the project (`.xcodeproj` / `.xcworkspace`) with this agent.
    case newConversation(project: URL, agent: Agent, name: String? = nil)
    /// Continue a chat of the project.
    case conversation(id: String, project: URL)
    /// Continue a chat, given its Xcode chat store folder (`<ProjectName>-<hash>`, name or path).
    case conversationInStore(id: String, store: String)
}

/// Manual / Auto, to override Xcode's setting for one message.
nonisolated enum PermissionMode: String, Codable, Sendable {
    case manual, auto
}

// MARK: - Events

/// One event of a conversation. The same type for a turn streaming live (`sendMessage`) and for a chat's history.
/// JSON (the server's SSE events), discriminated by "type".
nonisolated enum ChatEvent: Codable, Hashable, Sendable {
    /// What the user sent (the prompt). `"type": "user_message"`
    case userMessage(String)
    /// The assistant's text. `"type": "assistant_message"`
    case assistantMessage(String)
    /// The assistant's in-between output (thinking). `"type": "intermediate"`
    case intermediate(String)
    /// `"type": "tool_use"`
    case toolUse(ToolUse)
    /// `"type": "tool_result"`
    case toolResult(ToolResult)

    struct ToolUse: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var input: [String: JSONValue]
    }

    struct ToolResult: Codable, Hashable, Sendable {
        var toolUseID: String
        /// The tool's output, or why it failed / was denied.
        var output: String
        var isError: Bool

        enum CodingKeys: String, CodingKey {
            case output
            case toolUseID = "tool_use_id"
            case isError = "is_error"
        }
    }

    /// The event's "type" in JSON.
    var type: String {
        switch self {
        case .userMessage: "user_message"
        case .assistantMessage: "assistant_message"
        case .intermediate: "intermediate"
        case .toolUse: "tool_use"
        case .toolResult: "tool_result"
        }
    }

    private enum Keys: String, CodingKey { case type, text }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "user_message": self = .userMessage(try container.decode(String.self, forKey: .text))
        case "assistant_message": self = .assistantMessage(try container.decode(String.self, forKey: .text))
        case "intermediate": self = .intermediate(try container.decode(String.self, forKey: .text))
        case "tool_use": self = .toolUse(try ToolUse(from: decoder))
        case "tool_result": self = .toolResult(try ToolResult(from: decoder))
        case let type:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown event type \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .userMessage(let text), .assistantMessage(let text), .intermediate(let text):
            try container.encode(text, forKey: .text)
        case .toolUse(let toolUse):
            try toolUse.encode(to: encoder)
        case .toolResult(let toolResult):
            try toolResult.encode(to: encoder)
        }
    }
}

/// The tool uses that have no tool result yet: the turn is waiting for the permission answer to each
/// (`PermissionAnswer.toolUseID`).
nonisolated func waitingForPermission(_ events: [ChatEvent]) -> [ChatEvent.ToolUse] {
    let answered = Set(events.compactMap { event -> String? in
        if case .toolResult(let result) = event { result.toolUseID } else { nil }
    })
    return events.compactMap { event -> ChatEvent.ToolUse? in
        if case .toolUse(let toolUse) = event, !answered.contains(toolUse.id) { toolUse } else { nil }
    }
}

// MARK: - Permission answers

nonisolated enum PermissionBehavior: String, Codable, Sendable {
    case allow, deny
}

/// The answer to a tool use waiting for permission (`waitingForPermission`).
nonisolated struct PermissionAnswer: Codable, Sendable {
    /// The waiting tool use's id (`ChatEvent.ToolUse.id`).
    var toolUseID: String
    var behavior: PermissionBehavior
    /// Allow only, optional: the tool input to use instead, e.g. `AskUserQuestion`'s input with its "answers" filled in.
    var updatedInput: [String: JSONValue]?
    /// Deny only, optional: why, shown to the agent.
    var message: String?

    enum CodingKeys: String, CodingKey {
        case behavior, message
        case toolUseID = "tool_use_id"
        case updatedInput = "updated_input"
    }
}

// MARK: - Request body

/// The JSON body of `POST /message`: a new message (the parameters of `sendMessage`),
/// or the answer to a running turn's permission request (`answerPermissionRequest`).
nonisolated enum MessageRequest: Codable, Sendable {
    /// Seconds a permission request waits for its answer before it is denied; nil: 600.
    case prompt(
        prompt: String,
        target: MessageTarget,
        permissionModeOverride: PermissionMode? = nil,
        permissionTimeout: TimeInterval? = nil
    )
    case permissionAnswer(answer: PermissionAnswer)
}
