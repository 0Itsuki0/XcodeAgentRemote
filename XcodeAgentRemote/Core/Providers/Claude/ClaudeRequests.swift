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
        if isPlanWithoutPlan(toolUse) { return true }
        if case .permission = requestKind(of: toolUse) { return false } else { return true }
    }

    /// An ExitPlanMode whose input has no `plan`. Claude fills `plan` in from the plan file when it writes the tool use;
    /// when the agent writes that file (`Write` to `<config>/plans/`) in the same message, the file may not be written
    /// yet, and the tool use has no `plan`. Only then is the plan taken from elsewhere: live, the permission request
    /// (`can_use_tool`, which has it); in history, the result line's `toolUseResult.plan`, or, while it waits, the
    /// plan file's `Write`. An ExitPlanMode with `plan` is left as it is.
    static func isPlanWithoutPlan(_ toolUse: ChatEvent.ToolUse) -> Bool {
        toolUse.name == "ExitPlanMode" && toolUse.input["plan"] == nil
    }

    /// The tool use the agent asks about (`can_use_tool`), as its request shows it: an ExitPlanMode written without its
    /// plan (`isPlanWithoutPlan`) gets the plan from the request's input. Any other tool use is left as it is.
    static func askedToolUse(_ toolUse: ChatEvent.ToolUse, requestInput: [String: JSONValue]?) -> ChatEvent.ToolUse {
        guard isPlanWithoutPlan(toolUse), let plan = requestInput?["plan"] else { return toolUse }
        var toolUse = toolUse
        toolUse.input["plan"] = plan
        return toolUse
    }

    /// Where the agent writes its plans.
    private static let plansDirectory = configDirectory.appending(path: "plans")

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
        // The content of the latest `Write` to the plan file (`isPlanWithoutPlan`).
        var writtenPlan: JSONValue?
        for event in events {
            switch event {
            case .toolUse(var toolUse):
                if toolUse.name == "Write",
                    toolUse.stringInput("file_path")?.hasPrefix(plansDirectory.path + "/") == true
                {
                    writtenPlan = toolUse.input["content"]
                }
                if isPlanWithoutPlan(toolUse),
                    let plan = decisions[toolUse.id]?.plan.map(JSONValue.string) ?? writtenPlan
                {
                    toolUse.input["plan"] = plan
                }
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
            var plan: String?
            if case .object(let result)? = entry.toolUseResult, case .string(let text)? = result["plan"] {
                plan = text
            }
            for block in entry.message?.content ?? [] {
                if let toolUseID = block.toolUseID {
                    decisions[toolUseID] = UserDecision(
                        source: source,
                        decision: entry.permissionDecision?.decision,
                        answers: answers,
                        plan: plan
                    )
                }
            }
        }
        return decisions
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
