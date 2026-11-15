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

// MARK: - Requests to the user

/// What a turn waits for from the user: permission for a tool use, answers to questions, or approval of a plan.
/// The agent asks each of them with a tool use that has no result until the user answers (`UserAnswer`).
/// For Claude: `AskUserQuestion` asks questions, `ExitPlanMode` presents a plan, any other tool asks for permission.
nonisolated enum UserRequest: Sendable {
    /// Allow or deny this tool use.
    case permission(ChatEvent.ToolUse)
    /// Choose among each question's options.
    case questions(toolUseID: String, [Question])
    /// Approve the plan, or reject it with feedback.
    case planApproval(toolUseID: String, plan: String)

    /// One question with its options (`AskUserQuestion`'s input).
    struct Question: Codable, Hashable, Sendable {
        /// One option of a question.
        struct Option: Codable, Hashable, Sendable {
            var label: String
            var description: String?
        }

        /// The question's text; its answers are keyed by it (`UserAnswer.questions`).
        var question: String
        /// A short title for the question.
        var header: String?
        var options: [Option]
        /// Several options can be chosen.
        var multiSelect: Bool?
    }

    /// The request a tool use makes: questions for `AskUserQuestion`, a plan for `ExitPlanMode`, else a permission.
    init(_ toolUse: ChatEvent.ToolUse) {
        switch toolUse.name {
        case "AskUserQuestion":
            let questions = (try? JSONEncoder().encode(toolUse.input["questions"]))
                .flatMap { try? JSONDecoder().decode([Question].self, from: $0) }
            self = questions.map { .questions(toolUseID: toolUse.id, $0) } ?? .permission(toolUse)
        case "ExitPlanMode":
            if case .string(let plan)? = toolUse.input["plan"] {
                self = .planApproval(toolUseID: toolUse.id, plan: plan)
            } else {
                self = .permission(toolUse)
            }
        default:
            self = .permission(toolUse)
        }
    }

    /// The tool use the request is (`UserAnswer`'s `toolUseID`).
    var toolUseID: String {
        switch self {
        case .permission(let toolUse): toolUse.id
        case .questions(let toolUseID, _), .planApproval(let toolUseID, _): toolUseID
        }
    }
}

/// The requests a turn's events end waiting for: its tool uses that have no result yet.
/// (A tool use that is still running has no result yet either; a stream from the server ends only at a request.)
nonisolated func waitingForUser(_ events: [ChatEvent]) -> [UserRequest] {
    let answered = Set(events.compactMap { event -> String? in
        if case .toolResult(let result) = event { result.toolUseID } else { nil }
    })
    return events.compactMap { event -> UserRequest? in
        if case .toolUse(let toolUse) = event, !answered.contains(toolUse.id) { UserRequest(toolUse) } else { nil }
    }
}

/// The user's answer to a request a turn waits for (`UserRequest`), by its tool use id.
nonisolated enum UserAnswer: Codable, Sendable {
    /// Allow or deny a tool use; `message`: deny only, why (shown to the agent).
    case permission(toolUseID: String, allow: Bool, message: String? = nil)
    /// The chosen option labels of each question, by the question's text: several for a multi-select question,
    /// or any text of the user's own.
    case questions(toolUseID: String, answers: [String: [String]])
    /// Decline to answer the questions; `message`: why (shown to the agent).
    case declineQuestions(toolUseID: String, message: String? = nil)
    /// Approve the plan, or reject it; `feedback`: reject only, what to change (shown to the agent).
    case planApproval(toolUseID: String, approve: Bool, feedback: String? = nil)

    /// The tool use the answer is for.
    var toolUseID: String {
        switch self {
        case .permission(let toolUseID, _, _), .questions(let toolUseID, _), .declineQuestions(let toolUseID, _),
            .planApproval(let toolUseID, _, _):
            toolUseID
        }
    }
}

// MARK: - Request body

/// The JSON body of `POST /message`: a new message (the parameters of `sendMessage`),
/// or the user's answer to a request the running turn waits for (`answerUserRequest`).
nonisolated enum MessageRequest: Codable, Sendable {
    /// Seconds a request to the user (permission, questions, plan) waits for its answer before it is denied; nil: 600.
    case prompt(
        prompt: String,
        target: MessageTarget,
        permissionModeOverride: PermissionMode? = nil,
        permissionTimeout: TimeInterval? = nil
    )
    case answer(UserAnswer)
}
