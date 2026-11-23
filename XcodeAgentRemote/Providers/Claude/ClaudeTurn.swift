//
//  ClaudeTurn.swift
//  XcodeAgentRemote
//
//  Running a turn of Claude (Xcode provider "claude", model "claude-code").
//
//  Launches the agent the way Xcode does: `xcrun mcpbridge run-agent claude` (Xcode's bundled binary,
//  CLAUDE_CONFIG_DIR, xcode-tools MCP config, settings) plus the flags Xcode adds, and talks to it over stream-json.
//

import Foundation
import Synchronization

nonisolated extension ClaudeProvider {
    /// Xcode's model identifier for its Claude agent's chats.
    static let modelIdentifier = "claude-code"

    /// A new Claude session id (lowercase UUID, as Claude writes them).
    static func newSessionID() -> String { UUID().uuidString.lowercased() }

    /// Claude Code's tools that run without asking, as Xcode passes them to `--allowedTools`.
    static let xcodeAllowedTools = [
        "mcp__xcode-tools", "ReadMcpResourceTool", "ListMcpResourcesTool", "Agent", "Task",
        "EnterPlanMode", "AgentEnterMode", "ToolSearch", "TodoWrite",
        "TaskCreate", "TaskGet", "TaskList", "TaskUpdate", "TaskOutput",
    ]

    /// Tools whose file content is captured before and after they run.
    private static let fileChangingTools: Set<String> = ["Edit", "Write"]

    /// Xcode's permission mode → Claude's `--permission-mode`.
    private static func claudePermissionMode(_ mode: XcodeAgentConfiguration.PermissionMode) -> String {
        switch mode {
        case .manual: "default"
        case .auto: "auto"
        case .dontAsk: "dontAsk"
        case .bypassPermissions: "bypassPermissions"
        }
    }

    /// Xcode's system prompt addition, rendered from its template inside Xcode.
    private static func xcodeSystemPrompt() -> String? {
        guard let developer = CommandExecutor.runCommand(["xcode-select", "-p"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let path = (developer as NSString).appendingPathComponent(
            "../PlugIns/IDEIntelligenceChat.framework/Resources/AgentSystemPromptAddition.idechatprompttemplate")
        guard let template = try? String(contentsOfFile: (path as NSString).standardizingPath, encoding: .utf8)
        else { return nil }
        // Keep every `{% if MCPTool_X %}` section (all Xcode tools are available) and drop the tags.
        return template.replacing(#/\{%[^%]*%\}/#, with: "")
    }

    /// The command line, after `xcrun`.
    private static func launchArguments(sessionID: String, resume: Bool, permissionMode: XcodeAgentConfiguration.PermissionMode)
        -> [String]
    {
        var arguments = [
            "mcpbridge", "run-agent", agent.rawValue,
            "-p",
            "--input-format=stream-json",
            "--output-format=stream-json",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", claudePermissionMode(permissionMode),
            "--allow-dangerously-skip-permissions",
            "--thinking-display", "summarized",
            "--allowedTools", xcodeAllowedTools.joined(separator: ","),
        ]
        if let prompt = xcodeSystemPrompt() {
            arguments += ["--append-system-prompt", prompt]
        }
        if let pluginDirectory = CommandExecutor.runCommand(["xcrun", "mcpbridge", "run-agent", "plugin", "path", "--plugin-format", agent.rawValue])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !pluginDirectory.isEmpty
        {
            arguments += ["--plugin-dir", pluginDirectory]
        }
        return arguments + (resume ? ["--resume", sessionID] : ["--session-id", sessionID])
    }

    // MARK: Running a turn

    /// Runs one turn of Claude and streams its events (`AgentProvider.runTurn`).
    static func runTurn(_ request: TurnRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runAgent(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Launches the agent, sends the prompt, and turns its output into events until its result; answers its
    /// permission requests. Cancelling stops the agent.
    private static func runAgent(
        _ request: TurnRequest, continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        // The request the turn waits on: if the agent exits meanwhile (e.g. it is killed), nothing will come of it,
        // so the wait ends right away (the request is left waiting in the transcript, still answerable).
        let waitingOn = WaitingToolUse()
        let sessionID = request.sessionID
        RunningSessions.insert(sessionID)
        let agentProcess: CommandExecutor.RunningCommand
        do {
            agentProcess = try CommandExecutor.runCommandStream(
                ["xcrun"] + launchArguments(sessionID: sessionID, resume: request.resume, permissionMode: request.permissionMode),
                in: request.workingDirectory
            ) {
                RunningSessions.remove(sessionID)
                if let toolUseID = waitingOn.toolUseID {
                    Task { await PendingUserRequestHandler.shared.unregister(toolUseID) }
                }
            }
        } catch {
            RunningSessions.remove(sessionID)
            throw error
        }
        /// Writes one JSON line to the agent's input.
        func sendToAgent<Message: Encodable>(_ message: Message) {
            guard let line = try? JSONEncoder().encode(message) else { return }
            agentProcess.writeLine(line)
        }

        try await withTaskCancellationHandler {
            // A pass-through PreToolUse hook, like the one Xcode registers: with any PreToolUse hook, Claude writes a
            // tool use to the session's transcript before it asks the user about it, so a waiting request is in the
            // `.jsonl`. It answers no decision: Claude's own permission check still decides (`can_use_tool`).
            sendToAgent(initializeRequest)
            sendToAgent(PromptMessage(prompt: request.prompt, sessionID: request.sessionID))
            // The earlier answer to give again, once, when the agent repeats the tool use it was given for.
            var repeatedAnswer = request.repeatedAnswer
            // That earlier request is answered by this turn: it no longer waits.
            if let earlier = request.repeatedAnswer { PendingToolUses.remove(earlier.toolUse.id, agent: agent) }

            var toolUses: [String: ChatEvent.ToolUse] = [:]
            // The user's answers to this turn's requests, by tool use id: streamed when given, in place of their results.
            var answers: [String: ChatEvent.UserResponse] = [:]
            // The agent's repeat of the earlier tool use, and the earlier answer it gets: its tool use isn't streamed.
            var repeatCall: (toolUseID: String, answer: ChatEvent.UserResponse)?
            var agentError: String?
            let decoder = JSONDecoder()
            reading: for try await line in agentProcess.outputLines {
                guard let message = try? decoder.decode(AgentOutputLine.self, from: line) else { continue }

                switch message.type {
                case "assistant":
                    for block in message.message?.content ?? [] {
                        switch block {
                        case .thinking(let thinking) where !thinking.thinking.isEmpty:
                            continuation.yield(.intermediate(thinking.thinking))
                        case .text(let text) where !text.text.isEmpty:
                            continuation.yield(.assistantMessage(text.text))
                        case .toolUse(let block):
                            var toolUse = ChatEvent.ToolUse(id: block.id, name: block.name, input: [:])
                            if case .object(let input) = block.input { toolUse.input = input }
                            if fileChangingTools.contains(toolUse.name), let path = toolUse.stringInput("file_path") {
                                request.records.setFileBefore(
                                    try? String(contentsOfFile: path, encoding: .utf8), toolUseID: toolUse.id)
                            }
                            toolUses[toolUse.id] = toolUse
                            if let repeated = repeatedAnswer, !repeated.answer.isDeny,
                                isSameCall(repeated.toolUse, toolUse)
                            {
                                repeatedAnswer = nil
                                repeatCall = (toolUse.id, repeated.answer.answering(toolUse.id))
                                request.records.setRepeatedEarlierToolUse()
                                continue
                            }
                            continuation.yield(.toolUse(toolUse))
                        default:
                            break
                        }
                    }

                case "user":
                    for case .toolResult(let result) in message.message?.content ?? [] {
                        guard let toolUse = toolUses[result.toolUseID] else { continue }
                        PendingToolUses.remove(toolUse.id, agent: agent)
                        if fileChangingTools.contains(toolUse.name), let path = toolUse.stringInput("file_path") {
                            request.records.setFileAfter(
                                try? String(contentsOfFile: path, encoding: .utf8), toolUseID: toolUse.id)
                        }
                        let toolResult = ChatEvent.ToolResult(
                            toolUseID: toolUse.id,
                            output: SessionMessage.text(of: result.content ?? []),
                            isError: result.isError ?? false)
                        // A request's result is the user's answer, streamed when it was given; only an allowed
                        // permission's result (the tool's output) is streamed. The card still needs the result: recorded.
                        if let answer = answers[toolUse.id], !answer.isAllowedPermission {
                            request.records.setResult(toolResult, toolUseID: toolUse.id)
                            continue
                        }
                        continuation.yield(.toolResult(toolResult))
                    }

                case "control_request":
                    let requestID = message.requestID ?? ""
                    switch message.request?.subtype {
                    case "can_use_tool":
                        // The agent asks the user about a tool use: stream the request, then wait for the answer.
                        guard let permissionRequest = message.request, let toolUseID = permissionRequest.toolUseID else {
                            sendToAgent(ControlResponse<Empty>(response: .init(
                                subtype: "error", requestID: requestID, error: "no tool use id")))
                            break
                        }
                        let toolUse = toolUses[toolUseID] ?? ChatEvent.ToolUse(
                            id: toolUseID, name: permissionRequest.toolName ?? "?", input: permissionRequest.input ?? [:])
                        // The agent asked the user: mark it waiting, and stream the request it is (`userRequest`).
                        PendingToolUses.add(toolUseID, agent: agent)
                        let answer: ChatEvent.UserResponse?
                        if let repeatCall, repeatCall.toolUseID == toolUseID {
                            // The repeat: answered with the earlier answer, not requested again.
                            answer = repeatCall.answer
                        } else {
                            if let userRequest = userRequest(for: toolUse, decidedByUser: nil, isLastMessage: true) {
                                continuation.yield(.userRequest(userRequest))
                            }
                            waitingOn.set(toolUseID)
                            answer = await PendingUserRequestHandler.shared.waitForAnswer(
                                toolUseID: toolUseID, timeout: request.permissionTimeout)
                            waitingOn.set(nil)
                        }
                        if let answer {
                            PendingToolUses.remove(toolUseID, agent: agent)
                            answers[toolUseID] = answer
                            continuation.yield(.userResponse(answer))
                        }
                        let decision = permissionDecision(for: permissionRequest, answer: answer, timeout: request.permissionTimeout)
                        if decision.behavior == "deny" {
                            request.records.setDenied(toolUseID: toolUseID)
                        }
                        sendToAgent(ControlResponse(response: .init(subtype: "success", requestID: requestID, response: decision)))
                    case "hook_callback":
                        // The pass-through PreToolUse hook: no decision.
                        sendToAgent(ControlResponse(response: .init(subtype: "success", requestID: requestID, response: Empty())))
                    default:
                        sendToAgent(ControlResponse<Empty>(response: .init(
                            subtype: "error", requestID: requestID, error: "unsupported request")))
                    }

                case "result":
                    if message.isError == true { agentError = message.result ?? "unknown error" }
                    agentProcess.closeInput()
                    break reading

                default:
                    break
                }
            }

            await agentProcess.waitUntilExit()
            try Task.checkCancellation()
            if let agentError { throw XcodeChatError.agentFailed(message: agentError) }
        } onCancel: {
            agentProcess.terminate()
        }
    }

    /// Claude's decision from the user's answer to the tool use the agent asks about.
    /// Claude asks for permission, questions (AskUserQuestion) and plan approval (ExitPlanMode) the same way:
    /// - permission: "allow" with the tool's input, or "deny" with why;
    /// - questions: "allow" with the input plus `answers` (`{"<question>": "<label>, <label>"}`), or "deny" to decline;
    /// - plan: "allow" to approve, or "deny" with the feedback.
    /// No answer within `timeout` seconds: deny.
    private static func permissionDecision(
        for request: ToolPermissionRequest, answer: ChatEvent.UserResponse?, timeout: TimeInterval
    ) -> PermissionDecision {
        let input = request.input ?? [:]
        switch answer {
        case .permission(_, true, _), .planApproval(_, true, _):
            return PermissionDecision(behavior: "allow", updatedInput: input)
        case .permission(_, false, let message):
            return PermissionDecision(behavior: "deny", message: message ?? deniedMessage)
        case .questions(_, let answers):
            var answered = input
            answered["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
            return PermissionDecision(behavior: "allow", updatedInput: answered)
        case .declineQuestions(_, let message):
            return PermissionDecision(behavior: "deny", message: message ?? declinedMessage)
        case .planApproval(_, false, let feedback):
            return PermissionDecision(behavior: "deny", message: feedback ?? rejectedPlanMessage)
        case nil:
            return PermissionDecision(behavior: "deny", message: "\(noAnswerMessagePrefix)request within \(Int(timeout)) seconds.")
        }
    }

    // MARK: stream-json messages (only the fields used)

    /// Sent to the agent: the prompt.
    private struct PromptMessage: Encodable {
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
    private struct ControlResponse<Response: Encodable>: Encodable {
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
    private struct PermissionDecision: Encodable {
        var behavior: String
        var updatedInput: [String: JSONValue]?
        var message: String?
    }

    /// The tool use a turn waits on for the user's answer, if any. Set by the turn, read when the agent exits (behind a
    /// lock: only set and read, never waited on).
    private final class WaitingToolUse: Sendable {
        private let id = Mutex<String?>(nil)
        var toolUseID: String? { id.withLock { $0 } }
        func set(_ toolUseID: String?) { id.withLock { $0 = toolUseID } }
    }

    /// `{}`: a hook's output with no decision.
    private struct Empty: Encodable {}

    /// The `initialize` control request: registers the pass-through PreToolUse hook (every tool, one callback).
    private static let initializeRequest: JSONValue = .object([
        "type": .string("control_request"),
        "request_id": .string("initialize"),
        "request": .object([
            "subtype": .string("initialize"),
            "hooks": .object([
                "PreToolUse": .array([.object(["matcher": .null, "hookCallbackIds": .array([.string("pre_tool_use")])])])
            ]),
        ]),
    ])

    /// A control request from the agent: `can_use_tool` (ask the user about a tool use) or `hook_callback`.
    private struct ToolPermissionRequest: Decodable {
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
    private struct AgentOutputLine: Decodable {
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

    // MARK: Tool calls → Xcode cards

    /// A line of the Read tool's output: `<line number><tab><text>`.
    private static let readOutputLinePattern = try! NSRegularExpression(pattern: #"^\s*\d+\t"#, options: .anchorsMatchLines)

    /// Xcode's title and SF Symbol of the Tool Search card.
    private static let toolSearchCard = (name: "Tool Search", icon: "point.3.filled.connected.trianglepath.dotted")
    /// Xcode's SF Symbol of an agent task's card (titled with the task's description).
    private static let agentIcon = "square.on.square.intersection.dashed"
    /// Tools Xcode shows no card for.
    private static let toolsWithoutCard: Set<String> = ["TaskCreate"]

    /// The card for one of Claude's tool uses (`AgentProvider.card`), as Xcode shows it: file cards for Read, Edit
    /// and Write, the terminal card for Bash, fetch and search cards for WebFetch and WebSearch, title-only cards for
    /// ToolSearch and Agent, no card for the tools Xcode hides, the generic tool card for anything else.
    /// A denied tool use keeps its card as `cancelled`, a failed one as `failed`. Nil if it has no result.
    static func card(
        for call: ChatEvent.ToolUse, result toolResult: ChatEvent.ToolResult?, record: ToolUseRecords.Record?
    ) -> ChatCard.Card? {
        guard let toolResult, !toolsWithoutCard.contains(call.name) else { return nil }
        let result = toolResult.output
        let status: ChatCard.CardStatus =
            !toolResult.isError ? .completed : record?.denied == true ? .cancelled : .failed
        // Claude Code wraps a tool's error as `<tool_use_error>…</tool_use_error>`; the card shows the message.
        let errorDescription = status == .failed
            ? result.replacing("<tool_use_error>", with: "").replacing("</tool_use_error>", with: "") : nil

        switch call.name {
        case "Read":
            guard let path = call.stringInput("file_path") else { break }
            let lines = status == .completed
                ? readOutputLinePattern.numberOfMatches(in: result, range: NSRange(result.startIndex..., in: result)) : 0
            return ChatCard.fileCard(
                toolID: call.id, path: path, kind: .read, added: lines, removed: 0, source: "",
                status: status, errorDescription: errorDescription)
        case "Edit":
            guard let path = call.stringInput("file_path") else { break }
            let new = call.stringInput("new_string") ?? ""
            let changes = ChatCard.lineChanges(old: call.stringInput("old_string") ?? "", new: new)
            return ChatCard.fileCard(
                toolID: call.id, path: path, kind: .modified, added: changes.added, removed: changes.removed,
                source: changes.addedText.isEmpty ? new : changes.addedText,
                before: record?.fileBefore, after: record?.fileAfter, status: status, errorDescription: errorDescription)
        case "Write":
            guard let path = call.stringInput("file_path") else { break }
            let changes = ChatCard.lineChanges(old: record?.fileBefore ?? "", new: call.stringInput("content") ?? "")
            return ChatCard.fileCard(
                toolID: call.id, path: path, kind: record?.fileBefore == nil ? .added : .modified,
                added: changes.added, removed: changes.removed, source: changes.addedText,
                before: record?.fileBefore, after: record?.fileAfter, status: status, errorDescription: errorDescription)
        case "Bash":
            guard let command = call.stringInput("command"), !command.isEmpty else { break }
            return ChatCard.terminalCard(toolID: call.id, command: command, output: result, status: status)
        case "WebFetch":
            guard let url = call.stringInput("url") else { break }
            return ChatCard.webFetchCard(toolID: call.id, url: url, status: status)
        case "WebSearch":
            guard let query = call.stringInput("query") else { break }
            return ChatCard.webSearchCard(
                toolID: call.id, tool: call.name, query: query, titles: searchResultTitles(result), status: status)
        case "ToolSearch":
            return ChatCard.namedToolCard(
                toolID: call.id, name: toolSearchCard.name, icon: toolSearchCard.icon, status: status)
        case "Agent", "Task":
            return ChatCard.namedToolCard(
                toolID: call.id, name: call.stringInput("description") ?? call.name, icon: agentIcon, status: status)
        default:
            break
        }
        // Any other tool: the generic tool card, titled with the tool's name (for MCP tools `mcp__<server>__<tool>`,
        // just the tool).
        let parts = call.name.components(separatedBy: "__")
        let title = call.name.hasPrefix("mcp__") && parts.count >= 3 ? parts.dropFirst(2).joined(separator: "__") : call.name
        return ChatCard.genericCard(
            toolID: call.id, title: title, summary: inputSummary(call), output: result, status: status)
    }

    /// The titles of the pages a WebSearch found. Its output lists them on a line `Links: [{"title": …, "url": …}, …]`.
    private static func searchResultTitles(_ output: String) -> [String] {
        struct Link: Decodable { var title: String }
        return output.split(separator: "\n").flatMap { line -> [String] in
            guard line.hasPrefix("Links: "),
                  let links = try? JSONDecoder().decode([Link].self, from: Data(line.dropFirst("Links: ".count).utf8))
            else { return [] }
            return links.map(\.title)
        }
    }

    /// One line describing a tool call's input.
    private static func inputSummary(_ call: ChatEvent.ToolUse) -> String {
        for key in ["command", "file_path", "notebook_path", "pattern", "url", "query", "description", "prompt"] {
            if let value = call.stringInput(key), !value.isEmpty { return value }
        }
        guard !call.input.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(call.input)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return String(json.prefix(300))
    }
}
