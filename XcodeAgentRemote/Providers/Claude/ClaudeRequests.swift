//
//  ClaudeRequests.swift
//  XcodeAgentRemote
//
//  Claude's requests to the user (permission, questions, plans) as its session transcript (`.jsonl`) holds them.
//
//  - An answered request: the tool result's line has `permissionDecision.source` `user_temporary` (allowed /
//    answered / approved) or `user_reject` (denied / declined / rejected), or Xcode's hook rejected it because the
//    user chose Don't Allow in Xcode's prompt. That result is the user's answer (`ChatEvent.userResponse`).
//  - A request that timed out: `user_reject` with the app's "No answer to this …" text. It was asked, but not
//    answered: the request, then its result (no response), as a live turn streams it.
//  - A waiting request: the tool use is in the transcript with no result yet (Claude writes it shortly after it asks,
//    because a PreToolUse hook is registered). It is a request if it is a question or plan, or if it is still the
//    session's last message and either the app marked it waiting (`PendingToolUses`; else the mark is stale) or, in a
//    session the app isn't running, Xcode would ask about it (`PermissionRule.wouldAsk`: Xcode's own agent sets no
//    mark); otherwise it is running.
//  Both are decided in one place: `userRequest(for:decidedByUser:isLastMessage:)`, also used for a live turn.
//

import Foundation

nonisolated extension ClaudeProvider {

    /// The `permissionDecision.source`s of a request the user settled: the app's agent's (`user_temporary`,
    /// `user_reject`), and Xcode's PreToolUse hook (`hook`) for Xcode's own prompt.
    private static let userDecisionSources: Set<String> = [
        "user_temporary", "user_reject", "hook",
    ]

    /// The start of the app's deny when the user doesn't answer in time (`permissionDecision` for `nil`).
    static let noAnswerMessagePrefix = "No answer to this "

    /// In Xcode's hook's deny when the user chose Don't Allow in Xcode's prompt:
    /// `PreToolUse:<tool> hook error: User selected: Don’t Allow`.
    private static let xcodeUserDeniedMarker = "hook error: User selected: "

    /// Whether a tool use is a request to the user, and which: the one place that decides it.
    /// It is one when the agent asked the user about it:
    /// - it has a result (`decidedByUser` not nil): if the user decided it (`permissionDecision.source`);
    /// - it has none yet (`decidedByUser` nil): if it is a question or a plan, which always waits for the user, or if it
    ///   is still the session's last message (else the agent went on without the answer) and either the app marked it
    ///   waiting (`PendingToolUses`, set when the app's agent asks) or `xcodeWouldAsk` (a session Xcode runs: its agent
    ///   sets no mark, so Xcode's own permission decision tells a waiting tool use from a running one).
    /// The kind follows the tool: questions for AskUserQuestion, a plan for ExitPlanMode, else permission.
    static func userRequest(
        for toolUse: ChatEvent.ToolUse,
        decidedByUser: Bool?,
        isLastMessage: Bool,
        xcodeWouldAsk: @autoclosure () -> Bool = false
    ) -> ChatEvent.UserRequest? {
        let request = requestKind(of: toolUse)
        switch decidedByUser {
        case true?:
            return request
        case false?:
            return nil
        case nil:
            if case .permission = request {
                return isLastMessage
                    && (PendingToolUses.contains(toolUse.id, agent: agent)
                        || xcodeWouldAsk())
                    ? request : nil
            }
            return request
        }
    }

    /// A question (AskUserQuestion) or a plan (ExitPlanMode): always a request.
    static func alwaysWaitsForUser(_ toolUse: ChatEvent.ToolUse) -> Bool {
        if case .permission = requestKind(of: toolUse) { false } else { true }
    }

    /// What a request about this tool use asks: questions (AskUserQuestion's input), a plan (ExitPlanMode's input),
    /// else permission for it.
    private static func requestKind(of toolUse: ChatEvent.ToolUse)
        -> ChatEvent.UserRequest
    {
        switch toolUse.name {
        case "AskUserQuestion":
            let questions =
                (try? JSONEncoder().encode(toolUse.input["questions"]))
                .flatMap {
                    try? JSONDecoder().decode(
                        [ChatEvent.UserRequest.Question].self,
                        from: $0
                    )
                }
            if let questions {
                return .questions(toolUseID: toolUse.id, questions)
            }
        case "ExitPlanMode":
            if case .string(let plan)? = toolUse.input["plan"] {
                return .planApproval(toolUseID: toolUse.id, plan: plan)
            }
        default:
            break
        }
        return .permission(toolUse)
    }

    /// Map tool use / tool result to user request / user response
    ///
    /// Returning history events with the requests and responses in them (`ChatEvent.userRequest` / `.userResponse`, as a live turn streams them):
    /// a request in place of its tool use, and the user's answer in place of its result (an allowed permission's result, the tool's output, stays after it).
    ///
    /// Note
    /// - Answers to questions are split on ", " in the `history`, because the answers are stored joined that way.
    ///   An answer the user typed with ", " in it comes back as several answers.
    static func addingUserRequests(
        to events: [ChatEvent],
        transcript: Data,
        sessionID: String
    ) -> [ChatEvent] {
        let decisions = userDecisions(transcript)
        var results: [String: ChatEvent.ToolResult] = [:]
        for case .toolResult(let result) in events {
            results[result.toolUseID] = result
        }
        /// How the user settled a tool use with a result; nil if they weren't asked about it.
        func settledByUser(_ toolUseID: String) -> Settled? {
            results[toolUseID].flatMap { settled(decisions[toolUseID], result: $0) }
        }
        var toolUses: [String: ChatEvent.ToolUse] = [:]
        var withRequests: [ChatEvent] = []
        for event in events {
            switch event {
            case .toolUse(let toolUse):
                toolUses[toolUse.id] = toolUse
                let request =
                    results[toolUse.id] != nil
                    ? userRequest(
                        for: toolUse,
                        decidedByUser: settledByUser(toolUse.id) != nil,
                        isLastMessage: false
                    )
                    : userRequest(
                        for: toolUse,
                        decidedByUser: nil,
                        isLastMessage: events.last == event,
                        xcodeWouldAsk: !RunningSessions.contains(sessionID)
                            && XcodeAgentConfiguration.wouldAsk(
                                toolUse,
                                agentAllowedTools: xcodeAllowedTools,
                                workingDirectory: workingDirectory(
                                    sessionID: sessionID
                                )
                            )
                    )
                withRequests.append(request.map { .userRequest($0) } ?? event)
            case .toolResult(let result):
                guard let toolUse = toolUses[result.toolUseID],
                    let decision = decisions[result.toolUseID],
                    case .answered(let allowed) = settledByUser(result.toolUseID)
                else {
                    // Not a request, or one that timed out: its result.
                    withRequests.append(event)
                    continue
                }
                let answer = userAnswer(
                    to: toolUse,
                    result: result,
                    allowed: allowed,
                    // Xcode's deny text is Xcode's, not the user's.
                    userMessage: decision.source != "hook",
                    answers: decision.answers
                )
                withRequests.append(.userResponse(answer))
                if case .permission(_, true, _) = answer {
                    withRequests.append(event)
                }
            default:
                withRequests.append(event)
            }
        }
        return withRequests
    }

    /// The messages Claude is given for a deny without the user's own (`ChatEvent.UserResponse`'s `message` / `feedback` nil).
    static let deniedMessage = "The user denied this tool use."
    static let declinedMessage = "The user declined to answer."
    static let rejectedPlanMessage = "The user rejected the plan."

    /// How the user settled a request.
    private enum Settled {
        /// Allowed (answered, approved) or not.
        case answered(allowed: Bool)
        /// Not answered in time: the app denied it.
        case timedOut
    }

    /// How the user settled a tool use, from its result line's decision; nil if they weren't asked about it:
    /// - `user_temporary`: allowed; `user_reject`: denied, unless it is the app's timeout deny;
    /// - `hook` rejecting with Xcode's "User selected: Don’t Allow": denied in Xcode's prompt (other hook decisions
    ///   are Xcode's own, e.g. its rules, or its prompt failing).
    private static func settled(_ decision: UserDecision?, result: ChatEvent.ToolResult) -> Settled? {
        guard let decision else { return nil }
        switch decision.source {
        case "user_temporary":
            return .answered(allowed: true)
        case "user_reject":
            return result.output.hasPrefix(noAnswerMessagePrefix) ? .timedOut : .answered(allowed: false)
        case "hook" where decision.decision == "reject" && result.output.contains(xcodeUserDeniedMarker):
            return .answered(allowed: false)
        default:
            return nil
        }
    }

    /// The user's answer to a request, from its result: a deny's message is the result if `userMessage` (nil if it is
    /// Claude's default one), the answers are the result line's `toolUseResult`.
    private static func userAnswer(
        to toolUse: ChatEvent.ToolUse,
        result: ChatEvent.ToolResult,
        allowed: Bool,
        userMessage: Bool,
        answers: [String: [String]]
    ) -> ChatEvent.UserResponse {
        func message(unless defaultMessage: String) -> String? {
            allowed || !userMessage || result.output == defaultMessage ? nil : result.output
        }
        switch toolUse.name {
        case "AskUserQuestion":
            return allowed
                ? .questions(toolUseID: toolUse.id, answers: answers)
                : .declineQuestions(
                    toolUseID: toolUse.id,
                    message: message(unless: declinedMessage)
                )
        case "ExitPlanMode":
            return .planApproval(
                toolUseID: toolUse.id,
                approve: allowed,
                feedback: message(unless: rejectedPlanMessage)
            )
        default:
            return .permission(
                toolUseID: toolUse.id,
                allow: allowed,
                message: message(unless: deniedMessage)
            )
        }
    }

    /// What a result line says about the decision.
    private struct UserDecision {
        /// `permissionDecision.source`.
        var source: String
        /// `permissionDecision.decision`: "accept" or "reject".
        var decision: String?
        /// The answers to questions (`toolUseResult.answers`, `{"<question>": "<label>, <label>"}`), by question.
        var answers: [String: [String]]
    }

    /// The tool uses whose result line has a decision from one of `userDecisionSources`, with that decision.
    private static func userDecisions(_ transcript: Data) -> [String:
        UserDecision]
    {
        var decisions: [String: UserDecision] = [:]
        for line in transcript.split(separator: UInt8(ascii: "\n")) {
            guard
                let entry = try? JSONDecoder().decode(
                    DecidedResultLine.self,
                    from: Data(line)
                ),
                let source = entry.permissionDecision?.source,
                userDecisionSources.contains(source)
            else { continue }
            var answers: [String: [String]] = [:]
            if case .object(let result)? = entry.toolUseResult,
                case .object(let answered)? = result["answers"]
            {
                for case (let question, .string(let labels)) in answered {
                    answers[question] = labels.components(separatedBy: ", ")
                }
            }
            for block in entry.message?.content ?? [] {
                if let toolUseID = block.toolUseID {
                    decisions[toolUseID] = UserDecision(
                        source: source,
                        decision: entry.permissionDecision?.decision,
                        answers: answers
                    )
                }
            }
        }
        return decisions
    }

    /// A transcript line's tool results, its `permissionDecision` and `toolUseResult` (only the fields read here).
    private struct DecidedResultLine: Decodable {
        struct Decision: Decodable {
            var source: String?
            var decision: String?
        }
        struct Message: Decodable {
            struct Block: Decodable {
                var toolUseID: String?
                enum CodingKeys: String, CodingKey {
                    case toolUseID = "tool_use_id"
                }
            }
            var content: [Block]?

            init(from decoder: Decoder) throws {
                // `content` is a string for a prompt: no tool results.
                content = try? decoder.container(keyedBy: CodingKeys.self)
                    .decode([Block].self, forKey: .content)
            }
            enum CodingKeys: String, CodingKey { case content }
        }
        var permissionDecision: Decision?
        var message: Message?
        var toolUseResult: JSONValue?
    }

    // MARK: The waiting tool use

    static func pendingToolUse(sessionID: String) -> ChatEvent.ToolUse? {
        // The history has the request in place of its tool use: the tool use is found in the transcript's own events.
        guard let transcript = try? transcriptFile(sessionID: sessionID),
            let events = try? SessionHistory.load(contentsOf: transcript)
                .flatMap(\.chatEvents),
            let data = try? Data(contentsOf: transcript),
            let request = addingUserRequests(
                to: events,
                transcript: data,
                sessionID: sessionID
            ).waitingForUser.last
        else { return nil }
        return events.lazy.compactMap { event -> ChatEvent.ToolUse? in
            if case .toolUse(let toolUse) = event,
                toolUse.id == request.toolUseID
            {
                toolUse
            } else {
                nil
            }
        }.first
    }

    /// Removes a tool use and its result from the transcript: their lines (or only their blocks, if a message has
    /// other blocks).
    static func removeToolUse(_ toolUseID: String, sessionID: String) throws {
        _ = try removeBlocks(sessionID: sessionID) { _, block in
            isBlock(block, of: toolUseID)
        }
        PendingToolUses.remove(toolUseID, agent: agent)
    }

    /// The text Claude adds after a tool use's "rejected" result when the user stops it in Xcode (the close button).
    private static let interruptedText =
        "[Request interrupted by user for tool use]"

    /// The result Claude writes for a tool killed while it ran (the project closed by the app with AppleScript: Xcode
    /// doesn't notice, its agent's tool is killed).
    private static let killedResult = "Exit code 137"

    /// Removes the result the agent wrote when it was stopped while the tool ran, and only that, so a tool that finished
    /// on its own keeps its result (it is not run again):
    /// - the project closed by the app (AppleScript): `"content": "Exit code 137"`, `"is_error": true`,
    ///   `"toolUseResult": "Error: Exit code 137"`;
    /// - the user stopping it in Xcode (the close button): `"toolDenialKind": "user-rejected"`, then the interrupted
    ///   text;
    /// - the project closed by the app while Xcode's prompt was still open: `"toolDenialKind": "cancelled"` ("The user
    ///   doesn't want to take this action right now…").
    static func removeStoppedResult(of toolUseID: String, sessionID: String)
        throws -> Bool
    {
        let transcript = try transcriptFile(sessionID: sessionID)
        // The result's line, if it is one of those.
        var resultLine: String?
        for line in try String(contentsOf: transcript, encoding: .utf8).split(
            separator: "\n"
        ) where line.contains(toolUseID) {
            guard
                let entry = try? JSONDecoder().decode(
                    [String: JSONValue].self,
                    from: Data(line.utf8)
                ),
                case .object(let message)? = entry["message"],
                case .array(let blocks)? = message["content"],
                let result = blocks.first(where: {
                    isResultBlock($0, of: toolUseID)
                }), case .object(let fields) = result,
                case .string(let uuid)? = entry["uuid"]
            else { continue }
            let rejected = entry["toolDenialKind"] == .string("user-rejected")
                || entry["toolDenialKind"] == .string("cancelled")
            let killed =
                fields["content"] == .string(killedResult)
                && fields["is_error"] == .bool(true)
                && entry["toolUseResult"] == .string("Error: \(killedResult)")
            if rejected || killed { resultLine = uuid }
        }
        guard let resultLine else { return false }
        return try removeBlocks(sessionID: sessionID) { entry, block in
            if isResultBlock(block, of: toolUseID) {
                return entry["uuid"] == .string(resultLine)
            }
            // The interrupted text right after it (only when the user stopped it in Xcode).
            guard entry["parentUuid"] == .string(resultLine),
                case .object(let fields) = block
            else { return false }
            return fields["type"] == .string("text")
                && fields["text"] == .string(interruptedText)
        }
    }

    /// Removes the content blocks `isRemoved` picks (given the block's line), and the lines left without blocks. Lines
    /// that point at a removed line (`parentUuid`, `leafUuid`) are pointed past it, to the nearest line that stays, so
    /// the chain stays. Returns whether anything was removed.
    private static func removeBlocks(
        sessionID: String,
        where isRemoved: ([String: JSONValue], JSONValue) -> Bool
    ) throws -> Bool {
        let transcript = try transcriptFile(sessionID: sessionID)
        let lines = try String(contentsOf: transcript, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(
                String.init
            )
        var removedAny = false
        // Removed line uuid → its parent uuid.
        var removedParents: [String: JSONValue] = [:]
        var kept: [String] = []
        for line in lines {
            guard
                var entry = try? JSONDecoder().decode(
                    [String: JSONValue].self,
                    from: Data(line.utf8)
                ),
                case .object(var message)? = entry["message"],
                case .array(let blocks)? = message["content"]
            else {
                kept.append(line)
                continue
            }
            let others = blocks.filter { !isRemoved(entry, $0) }
            if others.count == blocks.count {
                kept.append(line)
                continue
            }
            removedAny = true
            if others.isEmpty {
                if case .string(let uuid)? = entry["uuid"] {
                    removedParents[uuid] = entry["parentUuid"] ?? .null
                }
            } else {
                message["content"] = .array(others)
                entry["message"] = .object(message)
                kept.append(try encodedLine(entry))
            }
        }
        /// The nearest line that stays, going up from a removed one.
        func survivingParent(of uuid: String) -> JSONValue {
            var parent = removedParents[uuid] ?? .null
            while case .string(let next) = parent, let up = removedParents[next]
            { parent = up }
            return parent
        }
        let relinked = try kept.map { line in
            guard !removedParents.isEmpty,
                var entry = try? JSONDecoder().decode(
                    [String: JSONValue].self,
                    from: Data(line.utf8)
                )
            else { return line }
            var changed = false
            for key in ["parentUuid", "leafUuid"] {
                if case .string(let uuid)? = entry[key],
                    removedParents[uuid] != nil
                {
                    entry[key] = survivingParent(of: uuid)
                    changed = true
                }
            }
            return changed ? try encodedLine(entry) : line
        }
        if removedAny {
            try relinked.joined(separator: "\n").write(
                to: transcript,
                atomically: true,
                encoding: .utf8
            )
        }
        return removedAny
    }

    private static func isResultBlock(_ block: JSONValue, of toolUseID: String)
        -> Bool
    {
        guard case .object(let fields) = block else { return false }
        return fields["type"] == .string("tool_result")
            && fields["tool_use_id"] == .string(toolUseID)
    }

    /// Whether a content block is the tool use with this id, or its result.
    private static func isBlock(_ block: JSONValue, of toolUseID: String)
        -> Bool
    {
        guard case .object(let fields) = block else { return false }
        switch fields["type"] {
        case .string("tool_use")?: return fields["id"] == .string(toolUseID)
        case .string("tool_result")?:
            return fields["tool_use_id"] == .string(toolUseID)
        default: return false
        }
    }

    /// One transcript line: compact JSON, slashes unescaped (as Claude writes them).
    private static func encodedLine(_ entry: [String: JSONValue]) throws
        -> String
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    // MARK: Repeated calls

    static func isSameCall(
        _ toolUse: ChatEvent.ToolUse,
        _ other: ChatEvent.ToolUse
    ) -> Bool {
        guard toolUse.name == other.name else { return false }
        let fields: [String]? =
            switch toolUse.name {
            case "Bash": ["command"]
            case "Write": ["file_path", "content"]
            case "Edit":
                ["file_path", "old_string", "new_string", "replace_all"]
            case "WebFetch": ["url"]
            case "AskUserQuestion": ["questions"]
            case "ExitPlanMode": []  // the agent may reword its plan: any plan it presents again is the same request
            default: nil
            }
        if toolUse.name == "AskUserQuestion" {
            return questionTexts(requestKind(of: toolUse))
                == questionTexts(requestKind(of: other))
        }
        guard let fields else {
            // Anything else: the whole input, except the agent's own description of the call.
            return toolUse.input.filter { $0.key != "description" }
                == other.input.filter { $0.key != "description" }
        }
        return fields.allSatisfy { toolUse.input[$0] == other.input[$0] }
    }

    /// The texts of a request's questions (what identifies them; the agent may reword their options).
    private static func questionTexts(_ request: ChatEvent.UserRequest)
        -> [String]
    {
        if case .questions(_, let questions) = request {
            questions.map(\.question)
        } else {
            []
        }
    }
}
