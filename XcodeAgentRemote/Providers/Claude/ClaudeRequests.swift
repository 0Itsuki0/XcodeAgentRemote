//
//  ClaudeRequests.swift
//  XcodeAgentRemote
//
//  Claude's requests to the user (permission, questions, plans) as its session transcript (`.jsonl`) holds them.
//
//  - An answered request: the tool result's line has `permissionDecision.source` `user_temporary` (allowed /
//    answered / approved) or `user_reject` (denied / declined / rejected).
//  - A waiting request: the tool use is in the transcript with no result yet (Claude writes it shortly after it asks,
//    because a PreToolUse hook is registered). It is a request if it is a question or plan, or if it is still the
//    session's last message and either the app marked it waiting (`PendingToolUses`; else the mark is stale) or, in a
//    session the app isn't running, Xcode would ask about it (`PermissionRule.wouldAsk`: Xcode's own agent sets no
//    mark); otherwise it is running.
//  Both are decided in one place: `userRequest(for:decidedByUser:isLastMessage:)`, also used for a live turn.
//

import Foundation

nonisolated extension ClaudeProvider {

    /// The `permissionDecision.source`s of a request the user answered.
    private static let userDecisionSources: Set<String> = ["user_temporary", "user_reject"]

    /// Whether a tool use is a request to the user, and which: the one place that decides it.
    /// It is one when the agent asked the user about it:
    /// - it has a result (`decidedByUser` not nil): if the user decided it (`permissionDecision.source`);
    /// - it has none yet (`decidedByUser` nil): if it is a question or a plan, which always waits for the user, or if it
    ///   is still the session's last message (else the agent went on without the answer) and either the app marked it
    ///   waiting (`PendingToolUses`, set when the app's agent asks) or `xcodeWouldAsk` (a session Xcode runs: its agent
    ///   sets no mark, so Xcode's own permission decision tells a waiting tool use from a running one).
    /// The kind follows the tool: questions for AskUserQuestion, a plan for ExitPlanMode, else permission.
    static func userRequest(
        for toolUse: ChatEvent.ToolUse, decidedByUser: Bool?, isLastMessage: Bool,
        xcodeWouldAsk: @autoclosure () -> Bool = false
    ) -> UserRequest? {
        let request = requestKind(of: toolUse)
        switch decidedByUser {
        case true?:
            return request
        case false?:
            return nil
        case nil:
            if case .permission = request {
                return isLastMessage && (PendingToolUses.contains(toolUse.id, agent: agent) || xcodeWouldAsk()) ? request : nil
            }
            return request
        }
    }

    /// What a request about this tool use asks: questions (AskUserQuestion's input), a plan (ExitPlanMode's input),
    /// else permission for it.
    private static func requestKind(of toolUse: ChatEvent.ToolUse) -> UserRequest {
        switch toolUse.name {
        case "AskUserQuestion":
            let questions = (try? JSONEncoder().encode(toolUse.input["questions"]))
                .flatMap { try? JSONDecoder().decode([UserRequest.Question].self, from: $0) }
            if let questions { return .questions(toolUseID: toolUse.id, questions) }
        case "ExitPlanMode":
            if case .string(let plan)? = toolUse.input["plan"] { return .planApproval(toolUseID: toolUse.id, plan: plan) }
        default:
            break
        }
        return .permission(toolUse)
    }

    /// History events with the requests added (`ChatEvent.userRequest`, where a live turn streams them): before the
    /// result of each tool use that was a request, and at the end for a tool use that still waits for the user.
    static func addingUserRequests(to events: [ChatEvent], transcript: Data, sessionID: String) -> [ChatEvent] {
        let answeredByUser = userAnsweredToolUseIDs(transcript)
        var toolUses: [String: ChatEvent.ToolUse] = [:]
        var resulted = Set<String>()
        var withRequests: [ChatEvent] = []
        for event in events {
            switch event {
            case .toolUse(let toolUse):
                toolUses[toolUse.id] = toolUse
            case .toolResult(let result):
                resulted.insert(result.toolUseID)
                if let toolUse = toolUses[result.toolUseID],
                   let request = userRequest(
                       for: toolUse, decidedByUser: answeredByUser.contains(result.toolUseID), isLastMessage: false)
                {
                    withRequests.append(.userRequest(request))
                }
            default:
                break
            }
            withRequests.append(event)
        }
        let lastMessage = events.last
        for case .toolUse(let toolUse) in events where !resulted.contains(toolUse.id) {
            let request = userRequest(
                for: toolUse, decidedByUser: nil, isLastMessage: lastMessage == .toolUse(toolUse),
                xcodeWouldAsk: !RunningSessions.contains(sessionID)
                && XcodeAgentConfiguration.wouldAsk(
                        toolUse, agentAllowedTools: xcodeAllowedTools, workingDirectory: workingDirectory(sessionID: sessionID)))
            if let request {
                withRequests.append(.userRequest(request))
            }
        }
        return withRequests
    }

    /// The tool uses whose result line says the user decided them (`permissionDecision.source`).
    private static func userAnsweredToolUseIDs(_ transcript: Data) -> Set<String> {
        var ids = Set<String>()
        for line in transcript.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONDecoder().decode(DecidedResultLine.self, from: Data(line)),
                  let source = entry.permissionDecision?.source, userDecisionSources.contains(source)
            else { continue }
            for block in entry.message?.content ?? [] {
                if let toolUseID = block.toolUseID { ids.insert(toolUseID) }
            }
        }
        return ids
    }

    /// A transcript line's tool results and its `permissionDecision` (only the fields read here).
    private struct DecidedResultLine: Decodable {
        struct Decision: Decodable { var source: String? }
        struct Message: Decodable {
            struct Block: Decodable {
                var toolUseID: String?
                enum CodingKeys: String, CodingKey { case toolUseID = "tool_use_id" }
            }
            var content: [Block]?

            init(from decoder: Decoder) throws {
                // `content` is a string for a prompt: no tool results.
                content = try? decoder.container(keyedBy: CodingKeys.self).decode([Block].self, forKey: .content)
            }
            enum CodingKeys: String, CodingKey { case content }
        }
        var permissionDecision: Decision?
        var message: Message?
    }

    // MARK: The waiting tool use

    static func pendingToolUse(sessionID: String) -> ChatEvent.ToolUse? {
        guard let events = try? history(sessionID: sessionID), let request = waitingForUser(events).last else {
            return nil
        }
        return events.lazy.compactMap { event -> ChatEvent.ToolUse? in
            if case .toolUse(let toolUse) = event, toolUse.id == request.toolUseID { toolUse } else { nil }
        }.first
    }

    /// Removes a tool use and its result from the transcript: their lines (or only their blocks, if a message has
    /// other blocks).
    static func removeToolUse(_ toolUseID: String, sessionID: String) throws {
        _ = try removeBlocks(sessionID: sessionID) { _, block in isBlock(block, of: toolUseID) }
        PendingToolUses.remove(toolUseID, agent: agent)
    }

    /// The text Claude adds after a tool use's "rejected" result when the user stops it in Xcode (the close button).
    private static let interruptedText = "[Request interrupted by user for tool use]"

    /// The result Claude writes for a tool killed while it ran (the project closed by the app with AppleScript: Xcode
    /// doesn't notice, its agent's tool is killed).
    private static let killedResult = "Exit code 137"

    /// Removes the result the agent wrote when it was stopped while the tool ran, and only that, so a tool that finished
    /// on its own keeps its result (it is not run again):
    /// - the project closed by the app (AppleScript): `"content": "Exit code 137"`, `"is_error": true`,
    ///   `"toolUseResult": "Error: Exit code 137"`;
    /// - the user stopping it in Xcode (the close button): `"toolDenialKind": "user-rejected"`, then the interrupted
    ///   text.
    static func removeStoppedResult(of toolUseID: String, sessionID: String) throws -> Bool {
        let transcript = try transcriptFile(sessionID: sessionID)
        // The result's line, if it is one of those two.
        var resultLine: String?
        for line in try String(contentsOf: transcript, encoding: .utf8).split(separator: "\n") where line.contains(toolUseID) {
            guard let entry = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8)),
                  case .object(let message)? = entry["message"], case .array(let blocks)? = message["content"],
                  let result = blocks.first(where: { isResultBlock($0, of: toolUseID) }), case .object(let fields) = result,
                  case .string(let uuid)? = entry["uuid"]
            else { continue }
            let rejected = entry["toolDenialKind"] == .string("user-rejected")
            let killed = fields["content"] == .string(killedResult) && fields["is_error"] == .bool(true)
                && entry["toolUseResult"] == .string("Error: \(killedResult)")
            if rejected || killed { resultLine = uuid }
        }
        guard let resultLine else { return false }
        return try removeBlocks(sessionID: sessionID) { entry, block in
            if isResultBlock(block, of: toolUseID) { return entry["uuid"] == .string(resultLine) }
            // The interrupted text right after it (only when the user stopped it in Xcode).
            guard entry["parentUuid"] == .string(resultLine), case .object(let fields) = block else { return false }
            return fields["type"] == .string("text") && fields["text"] == .string(interruptedText)
        }
    }

    /// Removes the content blocks `isRemoved` picks (given the block's line), and the lines left without blocks. Lines
    /// that point at a removed line (`parentUuid`, `leafUuid`) are pointed past it, to the nearest line that stays, so
    /// the chain stays. Returns whether anything was removed.
    private static func removeBlocks(
        sessionID: String, where isRemoved: ([String: JSONValue], JSONValue) -> Bool
    ) throws -> Bool {
        let transcript = try transcriptFile(sessionID: sessionID)
        let lines = try String(contentsOf: transcript, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var removedAny = false
        // Removed line uuid → its parent uuid.
        var removedParents: [String: JSONValue] = [:]
        var kept: [String] = []
        for line in lines {
            guard var entry = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8)),
                  case .object(var message)? = entry["message"], case .array(let blocks)? = message["content"]
            else { kept.append(line); continue }
            let others = blocks.filter { !isRemoved(entry, $0) }
            if others.count == blocks.count { kept.append(line); continue }
            removedAny = true
            if others.isEmpty {
                if case .string(let uuid)? = entry["uuid"] { removedParents[uuid] = entry["parentUuid"] ?? .null }
            } else {
                message["content"] = .array(others)
                entry["message"] = .object(message)
                kept.append(try encodedLine(entry))
            }
        }
        /// The nearest line that stays, going up from a removed one.
        func survivingParent(of uuid: String) -> JSONValue {
            var parent = removedParents[uuid] ?? .null
            while case .string(let next) = parent, let up = removedParents[next] { parent = up }
            return parent
        }
        let relinked = try kept.map { line in
            guard !removedParents.isEmpty,
                  var entry = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8))
            else { return line }
            var changed = false
            for key in ["parentUuid", "leafUuid"] {
                if case .string(let uuid)? = entry[key], removedParents[uuid] != nil {
                    entry[key] = survivingParent(of: uuid)
                    changed = true
                }
            }
            return changed ? try encodedLine(entry) : line
        }
        if removedAny { try relinked.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8) }
        return removedAny
    }

    private static func isResultBlock(_ block: JSONValue, of toolUseID: String) -> Bool {
        guard case .object(let fields) = block else { return false }
        return fields["type"] == .string("tool_result") && fields["tool_use_id"] == .string(toolUseID)
    }

    /// Whether a content block is the tool use with this id, or its result.
    private static func isBlock(_ block: JSONValue, of toolUseID: String) -> Bool {
        guard case .object(let fields) = block else { return false }
        switch fields["type"] {
        case .string("tool_use")?: return fields["id"] == .string(toolUseID)
        case .string("tool_result")?: return fields["tool_use_id"] == .string(toolUseID)
        default: return false
        }
    }

    /// One transcript line: compact JSON, slashes unescaped (as Claude writes them).
    private static func encodedLine(_ entry: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    // MARK: Repeated calls

    static func isSameCall(_ toolUse: ChatEvent.ToolUse, _ other: ChatEvent.ToolUse) -> Bool {
        guard toolUse.name == other.name else { return false }
        let fields: [String]? =
            switch toolUse.name {
            case "Bash": ["command"]
            case "Write": ["file_path", "content"]
            case "Edit": ["file_path", "old_string", "new_string", "replace_all"]
            case "WebFetch": ["url"]
            case "AskUserQuestion": ["questions"]
            case "ExitPlanMode": []  // the agent may reword its plan: any plan it presents again is the same request
            default: nil
            }
        if toolUse.name == "AskUserQuestion" {
            return questionTexts(requestKind(of: toolUse)) == questionTexts(requestKind(of: other))
        }
        guard let fields else {
            // Anything else: the whole input, except the agent's own description of the call.
            return toolUse.input.filter { $0.key != "description" } == other.input.filter { $0.key != "description" }
        }
        return fields.allSatisfy { toolUse.input[$0] == other.input[$0] }
    }

    /// The texts of a request's questions (what identifies them; the agent may reword their options).
    private static func questionTexts(_ request: UserRequest) -> [String] {
        if case .questions(_, let questions) = request { questions.map(\.question) } else { [] }
    }
}
