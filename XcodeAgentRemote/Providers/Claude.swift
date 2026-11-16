//
//  Claude.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

import Foundation

// MARK: - Types
nonisolated enum ClaudeProvider {

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

    // MARK: - Tool inputs (Swift counterparts of the Agent SDK's `sdk-tools.d.ts`)

    /// A tool call's input, typed by tool name. Tools without a typed counterpart here keep their raw JSON.
    nonisolated enum ToolInput: Hashable, Sendable {
        case agent(AgentInput)
        case bash(BashInput)
        case exitPlanMode(ExitPlanModeInput)
        case edit(FileEditInput)
        case read(FileReadInput)
        case write(FileWriteInput)
        case glob(GlobInput)
        case grep(GrepInput)
        case notebookEdit(NotebookEditInput)
        case todoWrite(TodoWriteInput)
        case webFetch(WebFetchInput)
        case webSearch(WebSearchInput)
        case askUserQuestion(AskUserQuestionInput)
        case taskCreate(TaskCreateInput)
        case taskGet(TaskGetInput)
        case taskUpdate(TaskUpdateInput)
        case taskStop(TaskStopInput)
        case listMcpResources(ListMcpResourcesInput)
        case readMcpResource(ReadMcpResourceInput)
        /// An MCP tool, named `mcp__<server>__<tool>` (for example `mcp__xcode-tools__BuildProject`).
        case mcp(server: String, tool: String, arguments: JSONValue)
        /// Any other tool, or an input that does not match its tool's type.
        case other(name: String, input: JSONValue)

        init(toolName: String, input: JSONValue) {
            func decode<T: Decodable>(_ type: T.Type) -> T? {
                guard let data = try? JSONEncoder().encode(input) else {
                    return nil
                }
                return try? JSONDecoder().decode(type, from: data)
            }
            let typed: ToolInput?
            switch toolName {
            case "Agent", "Task":
                typed = decode(AgentInput.self).map(ToolInput.agent)
            case "Bash": typed = decode(BashInput.self).map(ToolInput.bash)
            case "ExitPlanMode":
                typed = decode(ExitPlanModeInput.self).map(
                    ToolInput.exitPlanMode
                )
            case "Edit": typed = decode(FileEditInput.self).map(ToolInput.edit)
            case "Read": typed = decode(FileReadInput.self).map(ToolInput.read)
            case "Write":
                typed = decode(FileWriteInput.self).map(ToolInput.write)
            case "Glob": typed = decode(GlobInput.self).map(ToolInput.glob)
            case "Grep": typed = decode(GrepInput.self).map(ToolInput.grep)
            case "NotebookEdit":
                typed = decode(NotebookEditInput.self).map(
                    ToolInput.notebookEdit
                )
            case "TodoWrite":
                typed = decode(TodoWriteInput.self).map(ToolInput.todoWrite)
            case "WebFetch":
                typed = decode(WebFetchInput.self).map(ToolInput.webFetch)
            case "WebSearch":
                typed = decode(WebSearchInput.self).map(ToolInput.webSearch)
            case "AskUserQuestion":
                typed = decode(AskUserQuestionInput.self).map(
                    ToolInput.askUserQuestion
                )
            case "TaskCreate":
                typed = decode(TaskCreateInput.self).map(ToolInput.taskCreate)
            case "TaskGet":
                typed = decode(TaskGetInput.self).map(ToolInput.taskGet)
            case "TaskUpdate":
                typed = decode(TaskUpdateInput.self).map(ToolInput.taskUpdate)
            case "TaskStop":
                typed = decode(TaskStopInput.self).map(ToolInput.taskStop)
            case "ListMcpResourcesTool":
                typed = decode(ListMcpResourcesInput.self).map(
                    ToolInput.listMcpResources
                )
            case "ReadMcpResourceTool":
                typed = decode(ReadMcpResourceInput.self).map(
                    ToolInput.readMcpResource
                )
            default:
                if toolName.hasPrefix("mcp__"),
                    let separator = toolName.dropFirst(5).range(of: "__")
                {
                    let rest = toolName.dropFirst(5)
                    typed = .mcp(
                        server: String(rest[..<separator.lowerBound]),
                        tool: String(rest[separator.upperBound...]),
                        arguments: input
                    )
                } else {
                    typed = nil
                }
            }
            self = typed ?? .other(name: toolName, input: input)
        }
    }

    nonisolated struct AgentInput: Codable, Hashable, Sendable {
        var description: String
        var prompt: String
        var subagentType: String?
        /// "sonnet" | "opus" | "haiku" | "fable"
        var model: String?
        /// "low" | "medium" | "high" | "xhigh" | "max"
        var effort: String?
        var runInBackground: Bool?
        var name: String?
        var teamName: String?
        /// "acceptEdits" | "auto" | "bypassPermissions" | "default" | "dontAsk" | "plan"
        var mode: String?
        /// "worktree" | "remote"
        var isolation: String?

        enum CodingKeys: String, CodingKey {
            case description, prompt, model, effort, name, mode, isolation
            case subagentType = "subagent_type"
            case runInBackground = "run_in_background"
            case teamName = "team_name"
        }
    }

    nonisolated struct BashInput: Codable, Hashable, Sendable {
        var command: String
        var timeout: Double?
        var description: String?
        var runInBackground: Bool?
        var dangerouslyDisableSandbox: Bool?

        enum CodingKeys: String, CodingKey {
            case command, timeout, description, dangerouslyDisableSandbox
            case runInBackground = "run_in_background"
        }
    }

    nonisolated struct ExitPlanModeInput: Codable, Hashable, Sendable {
        struct AllowedPrompt: Codable, Hashable, Sendable {
            /// Always "Bash".
            var tool: String
            var prompt: String
        }
        var allowedPrompts: [AllowedPrompt]?
    }

    nonisolated struct FileEditInput: Codable, Hashable, Sendable {
        var filePath: String
        var oldString: String
        var newString: String
        var replaceAll: Bool?

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case oldString = "old_string"
            case newString = "new_string"
            case replaceAll = "replace_all"
        }
    }

    nonisolated struct FileReadInput: Codable, Hashable, Sendable {
        var filePath: String
        var offset: Int?
        var limit: Int?
        var pages: String?
        var allowLarge: Bool?

        enum CodingKeys: String, CodingKey {
            case offset, limit, pages
            case filePath = "file_path"
            case allowLarge = "allow_large"
        }
    }

    nonisolated struct FileWriteInput: Codable, Hashable, Sendable {
        var filePath: String
        var content: String

        enum CodingKeys: String, CodingKey {
            case content
            case filePath = "file_path"
        }
    }

    nonisolated struct GlobInput: Codable, Hashable, Sendable {
        var pattern: String
        var path: String?
    }

    nonisolated struct GrepInput: Codable, Hashable, Sendable {
        var pattern: String
        var path: String?
        var glob: String?
        /// "content" | "files_with_matches" | "count"
        var outputMode: String?
        var linesBefore: Int?
        var linesAfter: Int?
        var linesAround: Int?
        var context: Int?
        var showLineNumbers: Bool?
        var caseInsensitive: Bool?
        var onlyMatching: Bool?
        var type: String?
        var headLimit: Int?
        var offset: Int?
        var multiline: Bool?

        enum CodingKeys: String, CodingKey {
            case pattern, path, glob, context, type, offset, multiline
            case outputMode = "output_mode"
            case linesBefore = "-B"
            case linesAfter = "-A"
            case linesAround = "-C"
            case showLineNumbers = "-n"
            case caseInsensitive = "-i"
            case onlyMatching = "-o"
            case headLimit = "head_limit"
        }
    }

    nonisolated struct NotebookEditInput: Codable, Hashable, Sendable {
        var notebookPath: String
        var cellID: String?
        var newSource: String
        /// "code" | "markdown"
        var cellType: String?
        /// "replace" | "insert" | "delete"
        var editMode: String?

        enum CodingKeys: String, CodingKey {
            case notebookPath = "notebook_path"
            case cellID = "cell_id"
            case newSource = "new_source"
            case cellType = "cell_type"
            case editMode = "edit_mode"
        }
    }

    nonisolated struct TodoWriteInput: Codable, Hashable, Sendable {
        struct Todo: Codable, Hashable, Sendable {
            var content: String
            /// "pending" | "in_progress" | "completed"
            var status: String
            var activeForm: String
        }
        var todos: [Todo]
    }

    nonisolated struct WebFetchInput: Codable, Hashable, Sendable {
        var url: String
        var prompt: String
        var offset: Int?
    }

    nonisolated struct WebSearchInput: Codable, Hashable, Sendable {
        var query: String
        var allowedDomains: [String]?
        var blockedDomains: [String]?

        enum CodingKeys: String, CodingKey {
            case query
            case allowedDomains = "allowed_domains"
            case blockedDomains = "blocked_domains"
        }
    }

    nonisolated struct AskUserQuestionInput: Codable, Hashable, Sendable {
        struct Question: Codable, Hashable, Sendable {
            struct Option: Codable, Hashable, Sendable {
                var label: String
                var description: String
                var preview: String?
            }
            var question: String
            var header: String
            var options: [Option]
            var multiSelect: Bool
        }
        struct Annotation: Codable, Hashable, Sendable {
            var notes: String?
        }
        struct Metadata: Codable, Hashable, Sendable {
            var source: String?
        }
        var questions: [Question]
        /// Question text → chosen answer, filled in by whoever answers the form.
        var answers: [String: String]?
        var annotations: [String: Annotation]?
        var metadata: Metadata?
    }

    nonisolated struct TaskCreateInput: Codable, Hashable, Sendable {
        var subject: String
        var description: String
        var activeForm: String?
        var metadata: [String: JSONValue]?
    }

    nonisolated struct TaskGetInput: Codable, Hashable, Sendable {
        var taskId: String
    }

    nonisolated struct TaskUpdateInput: Codable, Hashable, Sendable {
        var taskId: String
        var subject: String?
        var description: String?
        var activeForm: String?
        /// "pending" | "in_progress" | "completed" | "deleted"
        var status: String?
        var addBlocks: [String]?
        var addBlockedBy: [String]?
        var owner: String?
        var metadata: [String: JSONValue]?
    }

    nonisolated struct TaskStopInput: Codable, Hashable, Sendable {
        var taskID: String?
        var shellID: String?

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case shellID = "shell_id"
        }
    }

    nonisolated struct ListMcpResourcesInput: Codable, Hashable, Sendable {
        var server: String?
    }

    nonisolated struct ReadMcpResourceInput: Codable, Hashable, Sendable {
        var server: String
        var uri: String
    }

    // MARK: - Transcript (.jsonl) entries

    /// One line of a session `.jsonl` transcript. Only the fields needed to rebuild the conversation are decoded.
    nonisolated struct TranscriptEntry: Decodable, Sendable {
        var type: String
        var uuid: String?
        var parentUUID: String?
        var sessionID: String?
        var isSidechain: Bool
        var isMeta: Bool
        var teamName: String?
        /// `attachment.type` for `attachment` entries.
        var attachmentType: String?
        /// `nil` for entries without an API message, or whose message could not be decoded.
        var message: APIMessage?

        private enum CodingKeys: String, CodingKey {
            case type, uuid, isSidechain, isMeta, teamName, attachment, message
            case parentUUID = "parentUuid"
            case sessionID = "sessionId"
        }

        private enum AttachmentKeys: String, CodingKey { case type }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            uuid = try? container.decodeIfPresent(String.self, forKey: .uuid)
            parentUUID = try? container.decodeIfPresent(
                String.self,
                forKey: .parentUUID
            )
            sessionID = try? container.decodeIfPresent(
                String.self,
                forKey: .sessionID
            )
            isSidechain =
                (try? container.decodeIfPresent(Bool.self, forKey: .isSidechain))
                ?? false
            isMeta =
                (try? container.decodeIfPresent(Bool.self, forKey: .isMeta))
                ?? false
            teamName = try? container.decodeIfPresent(
                String.self,
                forKey: .teamName
            )
            attachmentType = try? container.nestedContainer(
                keyedBy: AttachmentKeys.self,
                forKey: .attachment
            )
            .decodeIfPresent(String.self, forKey: .type)
            message = try? container.decodeIfPresent(
                APIMessage.self,
                forKey: .message
            )
        }

        var toolUseIDs: [String] {
            message?.content.compactMap {
                if case .toolUse(let block) = $0 { block.id } else { nil }
            } ?? []
        }

        var toolResultIDs: [String] {
            message?.content.compactMap {
                if case .toolResult(let block) = $0 {
                    block.toolUseID
                } else {
                    nil
                }
            } ?? []
        }
    }

}

// MARK: - load session history
nonisolated extension ClaudeProvider {

    nonisolated enum SessionHistory {

        /// Loads the full conversation of a session from its `.jsonl` transcript file
        /// (`<CLAUDE_CONFIG_DIR>/projects/<project-dir>/<sessionID>.jsonl`; for Xcode,
        /// `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects/…`).
        static func load(
            contentsOf url: URL,
            includeSystemMessages: Bool = false
        ) throws -> [SessionMessage] {
            try parse(
                Data(contentsOf: url),
                includeSystemMessages: includeSystemMessages
            )
        }

        /// Rebuilds the conversation from `.jsonl` transcript data, like the Agent SDK's `getSessionMessages`:
        /// follows `parentUuid` links from the newest main-thread message back to the start, restores parallel tool
        /// calls that branch off that chain, and returns user/assistant (and optionally system) messages in order.
        ///
        /// Not ported from the SDK: relinking of messages preserved across compaction (`compact_boundary`) and
        /// conversion of queued-command attachments into user messages.
        static func parse(_ data: Data, includeSystemMessages: Bool = false)
            -> [SessionMessage]
        {
            let decoder = JSONDecoder()
            let keptTypes: Set<String> = [
                "user", "assistant", "progress", "system", "attachment",
            ]
            var entries: [TranscriptEntry] = []
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard
                    let entry = try? decoder.decode(
                        TranscriptEntry.self,
                        from: Data(line)
                    ),
                    keptTypes.contains(entry.type), entry.uuid != nil
                else { continue }
                entries.append(entry)
            }

            // Index by uuid (a later line with the same uuid replaces an earlier one) and remember file order.
            var byUUID: [String: TranscriptEntry] = [:]
            var order: [String: Int] = [:]
            for (index, entry) in entries.enumerated() {
                byUUID[entry.uuid!] = entry
                order[entry.uuid!] = index
            }
            func parent(of entry: TranscriptEntry) -> TranscriptEntry? {
                entry.parentUUID.flatMap { byUUID[$0] }
            }
            func isConversational(_ entry: TranscriptEntry) -> Bool {
                entry.type == "user" || entry.type == "assistant"
            }

            // 1. Leaf: the newest main-thread entry nothing else on the main thread points to,
            //    walked up to its nearest user/assistant entry.
            func isMainThread(_ entry: TranscriptEntry) -> Bool {
                !entry.isSidechain && entry.teamName == nil
                    && entry.type != "progress"
                    && !(entry.type == "attachment"
                        && entry.attachmentType == "fork_briefing")
            }
            let mainThreadParents = Set(
                byUUID.values.filter(isMainThread).compactMap(\.parentUUID)
            )
            let tips = byUUID.values
                .filter {
                    isMainThread($0) && !mainThreadParents.contains($0.uuid!)
                }
                .sorted { order[$0.uuid!]! > order[$1.uuid!]! }

            var leaf: TranscriptEntry?
            var visited = Set<String>()
            findLeaf: for tip in tips {
                var walked: [String] = []
                var current: TranscriptEntry? = tip
                while let entry = current, !visited.contains(entry.uuid!),
                    !walked.contains(entry.uuid!)
                {
                    if isConversational(entry) {
                        leaf = entry
                        break findLeaf
                    }
                    walked.append(entry.uuid!)
                    current = parent(of: entry)
                }
                visited.formUnion(walked)
            }
            if leaf == nil {
                // Fallback: the newest user/assistant entry, preferring main-thread, non-meta ones.
                let conversational = entries.filter(isConversational)
                leaf =
                    conversational.last {
                        !$0.isSidechain && $0.teamName == nil && !$0.isMeta
                    } ?? conversational.last
            }
            guard let leaf else { return [] }

            // 2. Chain: follow parentUuid from the leaf back to the root.
            var chain: [TranscriptEntry] = []
            var inChain = Set<String>()
            var current: TranscriptEntry? = leaf
            while let entry = current, !inChain.contains(entry.uuid!) {
                inChain.insert(entry.uuid!)
                chain.append(entry)
                current = parent(of: entry)
            }
            chain.reverse()

            // 3. Parallel tool calls: each tool_use block of one API message is written as its own entry (same message
            //    id), and their tool_result entries branch off them, so the chain only covers one branch.
            let chainMessageIDs = Set(
                chain.filter { $0.type == "assistant" }.compactMap {
                    $0.message?.id
                }
            )
            let answeredInChain = Set(chain.flatMap(\.toolResultIDs))
            var toolUseIDs = Set<String>()
            var recovered: [TranscriptEntry] = []
            for entry in byUUID.values where entry.type == "assistant" {
                guard let id = entry.message?.id, chainMessageIDs.contains(id)
                else { continue }
                toolUseIDs.formUnion(entry.toolUseIDs)
                if !inChain.contains(entry.uuid!) { recovered.append(entry) }
            }
            for entry in byUUID.values
            where entry.type == "user" && !inChain.contains(entry.uuid!)
                && !entry.isSidechain
            {
                let results = entry.toolResultIDs
                if !results.isEmpty,
                    results.allSatisfy({
                        toolUseIDs.contains($0) && !answeredInChain.contains($0)
                    })
                {
                    recovered.append(entry)
                }
            }
            let conversation =
                recovered.isEmpty
                ? chain
                : (chain + recovered).sorted {
                    order[$0.uuid!]! < order[$1.uuid!]!
                }

            // 4. Keep user/assistant (and optionally system) messages of the main thread, without meta entries.
            return conversation.compactMap { entry -> SessionMessage? in
                guard
                    let type = SessionMessage.MessageType(rawValue: entry.type),
                    type != .system || includeSystemMessages,
                    !entry.isMeta, !entry.isSidechain, entry.teamName == nil
                else { return nil }
                return SessionMessage(
                    type: type,
                    uuid: entry.uuid!,
                    sessionID: entry.sessionID ?? "",
                    message: entry.message,
                    parentToolUseID: nil,
                    parentAgentID: nil
                )
            }
        }
    }

}

// MARK: - Provider

nonisolated extension ClaudeProvider: AgentProvider {
    static let agent = Agent.claude

    /// Xcode's config folder for its Claude agent (`CLAUDE_CONFIG_DIR`).
    static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig")

    /// `<config>/projects/<project-dir>/<sessionID>.jsonl`
    static func transcript(sessionID: String) -> URL? {
        let projects = configDirectory.appending(path: "projects")
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders
            .map { $0.appending(path: "\(sessionID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A session's events, with the requests to the user (`ChatEvent.userRequest`) the transcript shows.
    static func history(sessionID: String) throws -> [ChatEvent] {
        guard let transcript = transcript(sessionID: sessionID) else {
            throw ChatHistoryError.transcriptMissing(sessionID: sessionID)
        }
        let events = try SessionHistory.load(contentsOf: transcript).flatMap(\.chatEvents)
        return addingUserRequests(to: events, transcript: try Data(contentsOf: transcript), sessionID: sessionID)
    }

    /// The `cwd` recorded in the session's transcript.
    static func workingDirectory(sessionID: String) -> URL? {
        guard let transcript = transcript(sessionID: sessionID),
              let data = try? Data(contentsOf: transcript)
        else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let cwd = (try? JSONDecoder().decode(TranscriptCWD.self, from: Data(line)))?.cwd {
                return URL(filePath: cwd, directoryHint: .isDirectory)
            }
        }
        return nil
    }

    private struct TranscriptCWD: Decodable {
        var cwd: String?
    }
}

// MARK: - Conversion to the shared events

nonisolated extension ClaudeProvider.SessionMessage {
    /// This transcript message as `ChatEvent`s: user text → `.userMessage`, assistant text → `.assistantMessage`,
    /// thinking → `.intermediate`, tool use / tool result → `.toolUse` / `.toolResult`
    /// (images and redacted thinking are left out).
    var chatEvents: [ChatEvent] {
        guard let message else { return [] }
        return message.content.compactMap { block -> ChatEvent? in
            switch (message.role, block) {
            case (.user, .text(let text)):
                return .userMessage(text.text)
            case (.assistant, .text(let text)):
                return .assistantMessage(text.text)
            case (_, .thinking(let thinking)):
                return .intermediate(thinking.thinking)
            case (_, .toolUse(let toolUse)):
                guard case .object(let input) = toolUse.input else {
                    return .toolUse(ChatEvent.ToolUse(id: toolUse.id, name: toolUse.name, input: [:]))
                }
                return .toolUse(ChatEvent.ToolUse(id: toolUse.id, name: toolUse.name, input: input))
            case (_, .toolResult(let result)):
                return .toolResult(ChatEvent.ToolResult(
                    toolUseID: result.toolUseID,
                    output: Self.text(of: result.content ?? []),
                    isError: result.isError ?? false
                ))
            default:
                return nil
            }
        }
    }

    /// The text of a tool result's content blocks (as a live turn reports it).
    static func text(of blocks: [ClaudeProvider.ContentBlock]) -> String {
        blocks.compactMap { block -> String? in
            if case .text(let text) = block { text.text } else { nil }
        }.joined()
    }
}
