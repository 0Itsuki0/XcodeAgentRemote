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
nonisolated enum AgentProviderName: String, Codable, CaseIterable, Sendable {
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
    case newConversation(
        project: URL,
        agent: AgentProviderName,
        name: String? = nil
    )
    /// Continue a chat of the project.
    case conversation(id: String, project: URL)
    /// Continue a chat, given its Xcode chat store folder (`<ProjectName>-<hash>`, name or path).
    case conversationInStore(id: String, store: String)
}

/// Manual / Auto, to override Xcode's setting for one message.
nonisolated enum PermissionMode: String, Identifiable, Codable, Sendable,
    Hashable, Equatable,
    CaseIterable
{
    case manual, auto

    var id: String { self.rawValue }
}

// MARK: - Events

/// One event of a conversation. The same type for a turn streaming live (`sendMessage`) and for a chat's history.
/// JSON (the server's SSE events), discriminated by "type".
///
/// `.userRequest` and `.toolUse`
/// - In the `history`: `.userRequest` replaces its `.toolUse` for every tool use that maps to a request, not just the last message.
/// - Live turn still emit both because user request tool could be emitted after the actual tool use.
///   The user request may never come and if we wait for anything after tool use, the user may not see the use event until it is finished.
///
/// `.userResponse(UserResponse) `and `.toolResult`
/// -  in both the `history` and the live turn:`.userResponse(UserResponse) `replaces its `.toolResult` for a deny, answered questions, a declined question, or a plan because the result is the user's response.
/// -  in both the `history` and the live turn, for an allowed permission, the tool result isn't the user's response, it's the tool's output after the user
///     1. `.userRequest(.permission)` in place of the `.toolUse`
///     2. `.userResponse(.permission(allow: true))`
///     3. `.toolResult with the tool's output`
nonisolated enum ChatEvent: Codable, Hashable, Sendable, Equatable {

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
    /// The agent asks the user about a tool use it made (permission, questions, a plan); it waits for the answer
    /// (`UserResponse`) until the tool use has a response (`userResponse`). In the history it replaces the tool use;
    /// a live turn streams it after the tool use. `"type": "user_request"`, `"request": {...}`
    case userRequest(UserRequest)
    /// The user's answer to a request (`userRequest`). It replaces the tool use's result, which is only the agent's
    /// record of that answer (denied, declined, the answers, the plan approved or rejected); an allowed permission is
    /// followed by the tool's result, its output. `"type": "user_response"`, `"response": {...}`
    case userResponse(UserResponse)

    struct ToolUse: Codable, Hashable, Sendable, Equatable {
        var id: String
        var name: String
        var input: [String: JSONValue]
    }

    struct ToolResult: Codable, Hashable, Sendable, Equatable {
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
        case .userRequest: "user_request"
        case .userResponse: "user_response"
        }
    }

    private enum Keys: String, CodingKey { case type, text, request, response }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "user_message":
            self = .userMessage(
                try container.decode(String.self, forKey: .text)
            )
        case "assistant_message":
            self = .assistantMessage(
                try container.decode(String.self, forKey: .text)
            )
        case "intermediate":
            self = .intermediate(
                try container.decode(String.self, forKey: .text)
            )
        case "tool_use": self = .toolUse(try ToolUse(from: decoder))
        case "tool_result": self = .toolResult(try ToolResult(from: decoder))
        case "user_request":
            self = .userRequest(
                try container.decode(UserRequest.self, forKey: .request)
            )
        case "user_response":
            self = .userResponse(
                try container.decode(UserResponse.self, forKey: .response)
            )
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown event type \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .userMessage(let text), .assistantMessage(let text),
            .intermediate(let text):
            try container.encode(text, forKey: .text)
        case .toolUse(let toolUse):
            try toolUse.encode(to: encoder)
        case .toolResult(let toolResult):
            try toolResult.encode(to: encoder)
        case .userRequest(let request):
            try container.encode(request, forKey: .request)
        case .userResponse(let answer):
            try container.encode(answer, forKey: .response)
        }
    }
}

// MARK: - Requests to the user

nonisolated extension ChatEvent {
    /// What the agent asks the user about one of its tool uses: permission for it, answers to questions, or approval of
    /// a plan (`ChatEvent.userRequest`). The tool use has no result until the user answers (`UserResponse`).
    /// Which tool uses are requests is decided on the Mac, by the agent's provider (Claude: `ClaudeProvider.userRequest`);
    /// clients only read the `userRequest` events.
    enum UserRequest: Codable, Hashable, Sendable, Equatable {
        /// Allow or deny this tool use.
        case permission(ChatEvent.ToolUse)
        /// Choose among each question's options.
        case questions(toolUseID: String, [Question])
        /// Approve the plan, or reject it with feedback.
        case planApproval(toolUseID: String, plan: String)

        /// One question with its options (`AskUserQuestion`'s input).
        struct Question: Codable, Hashable, Sendable, Equatable {
            /// One option of a question.
            struct Option: Codable, Hashable, Sendable, Equatable {
                var label: String
                var description: String?
            }

            /// The question's text; its answers are keyed by it (`UserResponse.questions`).
            var question: String
            /// A short title for the question.
            var header: String?
            var options: [Option]
            /// Several options can be chosen.
            var multiSelect: Bool?
        }

        /// The tool use the request is (`UserResponse`'s `toolUseID`).
        var toolUseID: String {
            switch self {
            case .permission(let toolUse): toolUse.id
            case .questions(let toolUseID, _), .planApproval(let toolUseID, _):
                toolUseID
            }
        }
    }
}

nonisolated extension Array where Element == ChatEvent {
    /// The requests the events end waiting for: `userRequest`s whose tool use has no result or response yet.
    /// This function is to be used after mapping tool use / tool result to user request / user response
    var waitingForUser: [ChatEvent.UserRequest] {
        let events = self
        let answered = Set(
            events.compactMap { event -> String? in
                switch event {
                case .toolResult(let result): result.toolUseID
                case .userResponse(let answer): answer.toolUseID
                default: nil
                }
            }
        )
        return events.compactMap { event -> ChatEvent.UserRequest? in
            if case .userRequest(let request) = event,
                !answered.contains(request.toolUseID)
            {
                request
            } else {
                nil
            }
        }
    }
}

nonisolated extension ChatEvent {
    /// The user's answer to a request a turn waits for (`UserRequest`), by its tool use id.
    enum UserResponse: Codable, Hashable, Sendable, Equatable {
        /// Allow or deny a tool use; `message`: deny only, why (shown to the agent).
        case permission(toolUseID: String, allow: Bool, message: String? = nil)
        /// The chosen option labels of each question, by the question's text: several for a multi-select question,
        /// or any text of the user's own.
        case questions(toolUseID: String, answers: [String: [String]])
        /// Decline to answer the questions; `message`: why (shown to the agent).
        case declineQuestions(toolUseID: String, message: String? = nil)
        /// Approve the plan, or reject it; `feedback`: reject only, what to change (shown to the agent).
        case planApproval(
            toolUseID: String,
            approve: Bool,
            feedback: String? = nil
        )

        /// The tool use the answer is for.
        var toolUseID: String {
            switch self {
            case .permission(let toolUseID, _, _), .questions(let toolUseID, _),
                .declineQuestions(let toolUseID, _),
                .planApproval(let toolUseID, _, _):
                toolUseID
            }
        }
    }
}

// MARK: - Request body

/// The JSON body of `POST /messages`: a new message (the parameters of `sendMessage`),
/// or the user's answer to a request the running turn waits for (`answerUserRequest`).
nonisolated enum MessageRequest: Codable, Sendable {
    /// Seconds a request to the user (permission, questions, plan) waits for its answer before it is denied; nil: 600.
    case prompt(
        prompt: String,
        target: MessageTarget,
        permissionModeOverride: PermissionMode? = nil,
        permissionTimeout: TimeInterval? = nil
    )
    case answer(ChatEvent.UserResponse)
}
