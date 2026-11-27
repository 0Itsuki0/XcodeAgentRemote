//
//  ClaudeToolInput.swift
//  XcodeAgentRemote
//
//  Claude's tool inputs (Swift counterparts of the Agent SDK's `sdk-tools.d.ts`).
//

import Foundation

nonisolated extension ClaudeProvider {

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
}
