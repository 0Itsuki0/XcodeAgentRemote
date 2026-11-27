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
        if let prompt = XcodeChat.xcodeSystemPrompt() {
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
        // Why the agent exited, if it failed (a non-zero code): thrown to the client once it exited.
        let exitError = ExitError()
        let sessionID = request.sessionID
        // The session is in `RunningSessions` for the whole turn (`XcodeChat.runTurn`).
        let agentProcess = try CommandExecutor.runCommandStream(
            ["xcrun"] + launchArguments(sessionID: sessionID, resume: request.resume, permissionMode: request.permissionMode),
            in: request.workingDirectory
        ) { error in
            exitError.set(error)
            if let toolUseID = waitingOn.toolUseID {
                Task { await PendingUserRequestHandler.shared.unregister(toolUseID) }
            }
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
            // The agent's repeat of the earlier tool use, and the earlier answer it gets without asking the user.
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
                        let toolUse = askedToolUse(
                            toolUses[toolUseID] ?? ChatEvent.ToolUse(
                                id: toolUseID, name: permissionRequest.toolName ?? "?", input: permissionRequest.input ?? [:]),
                            requestInput: permissionRequest.input)
                        // The agent asked the user: mark it waiting, and stream the request it is (`userRequest`).
                        PendingToolUses.add(toolUseID, agent: agent)
                        if let userRequest = userRequest(for: toolUse, decidedByUser: nil, isLastMessage: true) {
                            continuation.yield(.userRequest(userRequest))
                        }
                        let answer: ChatEvent.UserResponse?
                        if let repeatCall, repeatCall.toolUseID == toolUseID {
                            // The repeat: answered with the earlier answer, without waiting for the user.
                            answer = repeatCall.answer
                        } else {
                            waitingOn.set(toolUseID)
                            answer = await PendingUserRequestHandler.shared.waitForAnswer(
                                toolUseID: toolUseID, timeout: request.permissionTimeout)
                            waitingOn.set(nil)
                        }
                        if let answer {
                            PendingToolUses.remove(toolUseID, agent: agent)
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
            if let error = exitError.error { throw XcodeChatError.agentFailed(message: error.localizedDescription) }
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
}
