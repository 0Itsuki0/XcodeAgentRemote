//
//  TestScenarios.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//
//  End-to-end test scenarios, in two parts:
//  1. on the Mac: calling the Mac app's functions directly (`TestScenarios.runDirect`)
//  2. on iOS: sending through the server with the iOS app's client (`TestScenarios.runThroughServer`)
//  Each runs real agent turns: they create chats named "Test scenario …" in Xcode's chat store of the project.
//

import Foundation

/// The outcome of one test scenario.
nonisolated struct ScenarioResult: Sendable, CustomStringConvertible {
    var name: String
    var passed: Bool
    /// What was checked, or why it failed.
    var detail: String

    var description: String { "\(passed ? "✅" : "❌") \(name): \(detail)" }
}

/// End-to-end test scenarios against the real agent.
nonisolated enum TestScenarios {

    /// How a scenario answers the requests its turn waits for.
    fileprivate typealias Answering = @Sendable (UserRequest) -> UserAnswer

    /// A check that did not hold.
    fileprivate struct CheckFailed: Error, CustomStringConvertible {
        var description: String
    }

    /// Fails the scenario with `message` unless `condition` holds.
    fileprivate static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw CheckFailed(description: message()) }
    }

    /// Runs one scenario: passed with the detail it returns, or failed with what it throws.
    fileprivate static func scenario(_ name: String, _ body: () async throws -> String) async -> ScenarioResult {
        do {
            return ScenarioResult(name: name, passed: true, detail: try await body())
        } catch let failure as CheckFailed {
            return ScenarioResult(name: name, passed: false, detail: failure.description)
        } catch {
            return ScenarioResult(name: name, passed: false, detail: "\(type(of: error)): \(error.localizedDescription)")
        }
    }

    /// The results of a turn's tool uses of one tool.
    fileprivate static func toolResults(of tool: String, in events: [ChatEvent]) -> [ChatEvent.ToolResult] {
        let ids = Set(events.compactMap { event -> String? in
            if case .toolUse(let toolUse) = event, toolUse.name == tool { toolUse.id } else { nil }
        })
        return events.compactMap { event in
            if case .toolResult(let result) = event, ids.contains(result.toolUseID) { result } else { nil }
        }
    }

    /// A turn's reply: its assistant messages.
    fileprivate static func reply(_ events: [ChatEvent]) -> String {
        events.compactMap { event in
            if case .assistantMessage(let text) = event { text } else { nil }
        }.joined(separator: "\n")
    }

    /// How many prompts (user messages) the events have.
    fileprivate static func promptCount(_ events: [ChatEvent]) -> Int {
        events.filter { if case .userMessage = $0 { true } else { false } }.count
    }

    /// A unique name for the chat a run creates.
    fileprivate static func chatName(_ part: String) -> String {
        "Test scenario (\(part)): \(UUID().uuidString.prefix(8))"
    }

    /// Answers every request with a permission: allowed or denied (questions and plans are not expected).
    fileprivate static func permission(allow: Bool) -> Answering {
        { request in .permission(toolUseID: request.toolUseID, allow: allow) }
    }

    /// Answers questions with `choose(question)` (the labels to choose), and allows anything else (e.g. ToolSearch).
    fileprivate static func choosing(_ choose: @escaping @Sendable (UserRequest.Question) -> [String]) -> Answering {
        { request in
            guard case .questions(let toolUseID, let questions) = request else {
                return .permission(toolUseID: request.toolUseID, allow: true)
            }
            return .questions(toolUseID: toolUseID, answers: Dictionary(
                uniqueKeysWithValues: questions.map { ($0.question, choose($0)) }))
        }
    }

    /// Declines questions, and allows anything else.
    fileprivate static let decliningQuestions: Answering = { request in
        guard case .questions(let toolUseID, _) = request else { return .permission(toolUseID: request.toolUseID, allow: true) }
        return .declineQuestions(toolUseID: toolUseID, message: "The user declined to answer.")
    }

    /// Approves a plan, or rejects it with `feedback`; allows anything else (e.g. entering plan mode).
    fileprivate static func plan(approve: Bool, feedback: String? = nil) -> Answering {
        { request in
            guard case .planApproval(let toolUseID, _) = request else {
                return .permission(toolUseID: request.toolUseID, allow: true)
            }
            return .planApproval(toolUseID: toolUseID, approve: approve, feedback: feedback)
        }
    }

    /// The prompts and checks the questions and plan scenarios share, run with `send` (directly or via the server).
    fileprivate static func questionsAndPlans(
        _ send: (String, @escaping Answering) async throws -> [ChatEvent]
    ) async -> [ScenarioResult] {
        var results: [ScenarioResult] = []

        results.append(await scenario("Questions: one choice") {
            let events = try await send(
                "Use the AskUserQuestion tool to ask me which color I prefer, with exactly these options: Red, Green, Blue. Then reply with only the color I chose.",
                choosing { _ in ["Green"] })
            let asked = toolResults(of: "AskUserQuestion", in: events)
            try check(asked.count == 1 && !asked[0].isError, "AskUserQuestion: \(asked.map(\.output))")
            try check(reply(events).contains("Green"), "reply: \(reply(events))")
            return "answered Green; reply: \(reply(events))"
        })

        results.append(await scenario("Questions: several choices (multi-select)") {
            let events = try await send(
                "Use the AskUserQuestion tool to ask me which colors I like, multiSelect true, options exactly: Red, Green, Blue. Then reply with only the colors I chose.",
                choosing { _ in ["Red", "Blue"] })
            let asked = toolResults(of: "AskUserQuestion", in: events)
            try check(asked.count == 1 && asked[0].output.contains("Red, Blue"), "AskUserQuestion: \(asked.map(\.output))")
            try check(reply(events).contains("Red") && reply(events).contains("Blue"), "reply: \(reply(events))")
            return "answered Red, Blue; reply: \(reply(events))"
        })

        results.append(await scenario("Questions: declined") {
            let events = try await send(
                "Use the AskUserQuestion tool to ask me which size I want: Small, Large. Then reply with what happened.",
                decliningQuestions)
            let asked = toolResults(of: "AskUserQuestion", in: events)
            try check(asked.count == 1 && asked[0].isError, "AskUserQuestion was not declined: \(asked.map(\.output))")
            return "declined; reply: \(reply(events))"
        })

        results.append(await scenario("Plan: approved") {
            let events = try await send(
                "Enter plan mode with the EnterPlanMode tool, then present a one-step plan to run `echo planned` with the ExitPlanMode tool. After it is approved, run it with Bash and reply with the output.",
                plan(approve: true))
            let plans = toolResults(of: "ExitPlanMode", in: events)
            try check(plans.count == 1 && !plans[0].isError, "ExitPlanMode: \(plans.map(\.output))")
            try check(toolResults(of: "Bash", in: events).contains { $0.output.contains("planned") }, "the plan did not run")
            return "approved, then ran; reply: \(reply(events))"
        })

        results.append(await scenario("Plan: rejected with feedback") {
            let events = try await send(
                "Enter plan mode with the EnterPlanMode tool, then present a one-step plan to run `echo first` with the ExitPlanMode tool. If the plan is rejected, do not run anything; reply with the feedback you got.",
                plan(approve: false, feedback: "Run `echo second` instead."))
            let plans = toolResults(of: "ExitPlanMode", in: events)
            try check(plans.count == 1 && plans[0].isError && plans[0].output.contains("echo second"),
                      "ExitPlanMode was not rejected with the feedback: \(plans.map(\.output))")
            try check(toolResults(of: "Bash", in: events).isEmpty, "something ran after the rejection")
            return "rejected; reply: \(reply(events))"
        })

        return results
    }
}

// MARK: - Part 1: on the Mac, calling the Mac app's functions directly

#if os(macOS)
extension TestScenarios {

    /// Runs the scenarios on the Mac with the app's own functions (`XcodeChats`, `sendMessage`, `answerUserRequest`),
    /// against the chats of `project` (its `.xcodeproj` / `.xcworkspace`).
    static func runDirect(project: URL) async -> [ScenarioResult] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "test-scenarios-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = chatName("Mac")
        var chatID: String?
        var results: [ScenarioResult] = []

        results.append(await scenario("List projects") {
            let projects = XcodeChats.listProjects()
            return "\(projects.count) projects, \(projects.map(\.sessions.count).reduce(0, +)) chats"
        })

        let allowedFile = folder.appending(path: "allowed")
        results.append(await scenario("New chat: a Bash command, allowed") {
            let events = try await sendDirect(
                "Use the Bash tool to run: touch \(allowedFile.path). Then reply DONE.",
                to: .newConversation(project: project, agent: .claude, name: name), answering: permission(allow: true))
            let bash = toolResults(of: "Bash", in: events)
            try check(!bash.isEmpty, "no Bash tool use")
            try check(bash.allSatisfy { !$0.isError }, "Bash failed: \(bash.map(\.output))")
            try check(FileManager.default.fileExists(atPath: allowedFile.path), "the command did not create the file")
            chatID = XcodeChats.listProjects().flatMap(\.sessions).first { $0.name == name }?.id
            try check(chatID != nil, "the new chat is not in Xcode's chat store")
            return "file created; chat \(chatID ?? "")"
        })

        let deniedFile = folder.appending(path: "denied")
        results.append(await scenario("Continue the chat: a Bash command, denied") {
            guard let chatID else { throw CheckFailed(description: "needs the chat of the previous scenario") }
            let events = try await sendDirect(
                "Use the Bash tool to run: touch \(deniedFile.path). If it is denied, reply DENIED.",
                to: .conversation(id: chatID, project: project), answering: permission(allow: false))
            let bash = toolResults(of: "Bash", in: events)
            try check(!bash.isEmpty, "no Bash tool use")
            try check(bash.allSatisfy(\.isError), "Bash was not denied: \(bash.map(\.output))")
            try check(!FileManager.default.fileExists(atPath: deniedFile.path), "the denied command ran")
            return "denied: \(bash.first?.output ?? "")"
        })

        results.append(await scenario("Continue the chat by its store name") {
            guard let chatID else { throw CheckFailed(description: "needs the chat of the previous scenarios") }
            let store = ChatStore.storeDirectory(forProject: project).lastPathComponent
            let events = try await sendDirect(
                "Reply with only the word pong.", to: .conversationInStore(id: chatID, store: store), mode: .auto,
                answering: permission(allow: false))
            try check(reply(events).lowercased().contains("pong"), "reply: \(reply(events))")
            return "reply: \(reply(events))"
        })

        results.append(await scenario("History of the new chat") {
            guard let chatID else { throw CheckFailed(description: "needs the chat of the previous scenarios") }
            let history = try XcodeChats.history(conversationID: chatID)
            try check(promptCount(history) == 3, "\(promptCount(history)) prompts in the history, expected 3")
            try check(toolResults(of: "Bash", in: history).count == 2, "expected 2 Bash results in the history")
            let requests = history.filter { if case .userRequest(.permission) = $0 { true } else { false } }.count
            try check(requests == 2, "\(requests) permission requests in the history, expected 2 (allowed, denied)")
            return "\(history.count) events, 3 prompts, 2 permission requests"
        })

        if let chatID {
            results += await questionsAndPlans { prompt, answering in
                try await sendDirect(prompt, to: .conversation(id: chatID, project: project), answering: answering)
            }
            results += await requestsLeftWaiting(project: project, chatID: chatID, folder: folder)
        }

        results.append(await scenario("Errors") {
            do {
                _ = try await sendDirect(
                    "hi", to: .conversation(id: "00000000-0000-0000-0000-000000000000", project: project),
                    answering: permission(allow: false))
                throw CheckFailed(description: "an unknown chat did not fail")
            } catch XcodeChatError.conversationNotFound {}
            do {
                _ = try await sendDirect(
                    "hi", to: .newConversation(project: project, agent: .codex), answering: permission(allow: false))
                throw CheckFailed(description: "codex did not fail")
            } catch XcodeChatError.agentNotImplemented {}
            do {
                _ = try await collect(answerUserRequest(.permission(toolUseID: "toolu_unknown", allow: true)))
                throw CheckFailed(description: "an answer to an unknown tool use was accepted")
            } catch SendMessageError.noWaitingRequest {}
            return "unknown chat, agent not implemented, answer to an unknown tool use"
        })

        try? FileManager.default.removeItem(at: folder)
        return results
    }

    /// Scenarios for a request whose agent was killed while it waited (so it couldn't settle the request): the request
    /// is in the chat's history, and `answerUserRequest` answers it by resuming the chat.
    private static func requestsLeftWaiting(project: URL, chatID: String, folder: URL) async -> [ScenarioResult] {
        let target = MessageTarget.conversation(id: chatID, project: project)
        var results: [ScenarioResult] = []

        let allowedFile = folder.appending(path: "left-waiting-allowed")
        results.append(await scenario("Request left waiting: in the history, then allowed") {
            let toolUse = try await leftWaitingPermission(
                "Use the Bash tool to run: touch \(allowedFile.path). Then reply DONE.", to: target, chatID: chatID)
            let events = try await collect(answerUserRequest(.permission(toolUseID: toolUse.id, allow: true), permissionTimeout: 120))
            let bash = toolResults(of: "Bash", in: events)
            try check(bash.count == 1 && !bash[0].isError, "Bash: \(bash.map(\.output))")
            try check(FileManager.default.fileExists(atPath: allowedFile.path), "the command did not run")
            try checkAnswered(toolUse, chatID: chatID)
            return "the agent repeated it, answered without asking, and it ran; reply: \(reply(events))"
        })

        let deniedFile = folder.appending(path: "left-waiting-denied")
        results.append(await scenario("Request left waiting: denied") {
            let toolUse = try await leftWaitingPermission(
                "Use the Bash tool to run: touch \(deniedFile.path). If it is denied, reply DENIED.", to: target, chatID: chatID)
            let events = try await collect(answerUserRequest(.permission(toolUseID: toolUse.id, allow: false), permissionTimeout: 120))
            try check(!FileManager.default.fileExists(atPath: deniedFile.path), "the denied command ran")
            try checkLeftInterrupted(toolUse, chatID: chatID)
            return "nothing ran; the old tool use stays, interrupted; reply: \(reply(events))"
        })

        results.append(await scenario("Question left waiting: in the history, then answered") {
            let request = try await leaveWaiting(
                "Use the AskUserQuestion tool to ask me which color I prefer, with exactly these options: Red, Green, Blue. Then reply with only the color I chose.",
                to: target)
            let history = try XcodeChats.history(conversationID: chatID)
            guard case .questions(let toolUseID, let questions)? = waitingForUser(history).last, toolUseID == request.toolUseID
            else { throw CheckFailed(description: "the history doesn't end waiting on the question: \(waitingForUser(history))") }
            let events = try await collect(answerUserRequest(
                .questions(toolUseID: toolUseID, answers: Dictionary(uniqueKeysWithValues: questions.map { ($0.question, ["Green"]) })),
                permissionTimeout: 120))
            try check(reply(events).contains("Green"), "reply: \(reply(events))")
            let after = try XcodeChats.history(conversationID: chatID)
            try check(waitingForUser(after).isEmpty, "the history still waits: \(waitingForUser(after))")
            return "answered Green; reply: \(reply(events))"
        })

        return results
    }

    /// Checks an answered request the agent didn't repeat (a deny): the old tool use stays, with Claude's interrupted
    /// result; not marked waiting, and the history not waiting for the user.
    private static func checkLeftInterrupted(_ toolUse: ChatEvent.ToolUse, chatID: String) throws {
        let history = try XcodeChats.history(conversationID: chatID)
        let result = history.lazy.compactMap { event -> ChatEvent.ToolResult? in
            if case .toolResult(let result) = event, result.toolUseID == toolUse.id { result } else { nil }
        }.first
        try check(result?.output.contains("Tool call interrupted") == true, "the old tool use's result: \(result?.output ?? "none")")
        try check(!WaitingMarks.contains(toolUse.id, agent: .claude), "the old tool use is still marked waiting")
        try check(waitingForUser(history).isEmpty, "the history still waits: \(waitingForUser(history))")
    }

    /// Leaves a permission request waiting and checks the chat's history ends waiting on it; returns its tool use.
    private static func leftWaitingPermission(
        _ prompt: String, to target: MessageTarget, chatID: String
    ) async throws -> ChatEvent.ToolUse {
        let request = try await leaveWaiting(prompt, to: target)
        let history = try XcodeChats.history(conversationID: chatID)
        guard case .permission(let toolUse)? = waitingForUser(history).last, toolUse.id == request.toolUseID else {
            throw CheckFailed(description: "the history doesn't end waiting on it: \(waitingForUser(history))")
        }
        return toolUse
    }

    /// Checks an answered request the agent repeated is gone: the old tool use and its interrupted result out of the
    /// history, not marked waiting, and the history not waiting for the user.
    private static func checkAnswered(_ toolUse: ChatEvent.ToolUse, chatID: String) throws {
        let history = try XcodeChats.history(conversationID: chatID)
        try check(!history.contains { if case .toolUse(let old) = $0 { old.id == toolUse.id } else { false } },
                  "the old tool use is still in the history")
        try check(!history.contains { if case .toolResult(let result) = $0 { result.output.contains("Tool call interrupted") } else { false } },
                  "the history has an interrupted marker")
        try check(!WaitingMarks.contains(toolUse.id, agent: .claude), "the old tool use is still marked waiting")
        try check(waitingForUser(history).isEmpty, "the history still waits: \(waitingForUser(history))")
    }

    /// Sends a message, and once the turn waits for the user (its stream ends at the request), kills the agent hard
    /// (`kill -9`), so it can't settle the request: it stays waiting in the chat's `.jsonl`. Returns that request.
    private static func leaveWaiting(_ prompt: String, to target: MessageTarget) async throws -> UserRequest {
        guard case .conversation(let chatID, _) = target,
              let sessionID = XcodeChats.listProjects().flatMap(\.sessions).first(where: { $0.id == chatID })?.providerSessionID
        else { throw CheckFailed(description: "no session for the chat") }
        let events = try await collect(sendMessage(prompt, to: target, permissionModeOverride: .manual, permissionTimeout: 120))
        guard let request = waitingForUser(events).last else { throw CheckFailed(description: "the agent made no request") }
        try check(WaitingMarks.contains(request.toolUseID, agent: .claude), "the request is not marked waiting")
        // Claude writes the tool use to the `.jsonl` shortly after it asks: kill only once it's there.
        var inFile = false
        for _ in 0..<50 where !inFile {
            let history = (try? XcodeChats.history(conversationID: chatID)) ?? []
            inFile = waitingForUser(history).contains { $0.toolUseID == request.toolUseID }
            if !inFile { try await Task.sleep(for: .milliseconds(200)) }
        }
        try check(inFile, "the waiting tool use never reached the chat's .jsonl")
        let kill = Process()
        kill.executableURL = URL(filePath: "/usr/bin/pkill")
        kill.arguments = ["-9", "-f", "--", "resume \(sessionID)"]
        try kill.run()
        kill.waitUntilExit()
        try await Task.sleep(for: .seconds(2))  // the killed turn ends
        return request
    }

    /// All the events of a turn.
    private static func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    /// Sends one message and collects the turn's events; answers each request the turn waits for (permission,
    /// questions, plan) with `answering`.
    private static func sendDirect(
        _ prompt: String, to target: MessageTarget, mode: PermissionMode = .manual, answering: @escaping Answering
    ) async throws -> [ChatEvent] {
        // Each stream ends where the turn waits for the user; the answer's stream continues the turn.
        var events: [ChatEvent] = []
        var stream = sendMessage(prompt, to: target, permissionModeOverride: mode, permissionTimeout: 120)
        while true {
            for try await event in stream { events.append(event) }
            guard let request = waitingForUser(events).last else { return events }
            stream = answerUserRequest(answering(request), permissionTimeout: 120)
        }
    }
}
#endif

// MARK: - Part 2: on iOS, through the server

#if os(iOS)
extension TestScenarios {

    /// Runs the scenarios from iOS through the Mac's server (`AgentServerClient`), against the chats of `project`
    /// (the `.xcodeproj` / `.xcworkspace` on the Mac). The tools create their files in `macFolder`, on the Mac.
    static func runThroughServer(
        client: AgentServerClient, project: URL, macFolder: String = "/tmp"
    ) async -> [ScenarioResult] {
        let run = UUID().uuidString.prefix(8)
        let name = chatName("iOS")
        var chatID: String?
        var store: String?
        var results: [ScenarioResult] = []

        results.append(await scenario("Health") {
            let status = try await client.health().status
            try check(status == "ok", "status \(status)")
            return status
        })

        results.append(await scenario("List projects") {
            let projects = try await client.projects()
            return "\(projects.count) projects, \(projects.map(\.sessions.count).reduce(0, +)) chats"
        })

        results.append(await scenario("New chat: a Bash command, allowed") {
            let (events, responses) = try await sendThroughServer(
                client, "Use the Bash tool to run: touch \(macFolder)/test-scenarios-\(run)-allowed. Then reply DONE.",
                to: .newConversation(project: project, agent: .claude, name: name), answering: permission(allow: true))
            let bash = toolResults(of: "Bash", in: events)
            try check(!bash.isEmpty, "no Bash tool use")
            try check(bash.allSatisfy { !$0.isError }, "Bash failed: \(bash.map(\.output))")
            try check(responses >= 2, "the first response did not stop at the permission request")
            let projectOfChat = try await client.projects().first { $0.sessions.contains { $0.name == name } }
            chatID = projectOfChat?.sessions.first { $0.name == name }?.id
            store = projectOfChat?.store.lastPathComponent
            try check(chatID != nil, "the new chat is not in /projects")
            return "allowed; \(responses) responses (message, then answer); chat \(chatID ?? "")"
        })

        results.append(await scenario("Continue the chat: a Bash command, denied") {
            guard let chatID else { throw CheckFailed(description: "needs the chat of the previous scenario") }
            let (events, responses) = try await sendThroughServer(
                client,
                "Use the Bash tool to run: touch \(macFolder)/test-scenarios-\(run)-denied. If it is denied, reply DENIED.",
                to: .conversation(id: chatID, project: project), answering: permission(allow: false))
            let bash = toolResults(of: "Bash", in: events)
            try check(!bash.isEmpty, "no Bash tool use")
            try check(bash.allSatisfy(\.isError), "Bash was not denied: \(bash.map(\.output))")
            return "denied: \(bash.first?.output ?? ""); \(responses) responses"
        })

        results.append(await scenario("Continue the chat by its store name") {
            guard let chatID, let store else {
                throw CheckFailed(description: "needs the chat and store of the previous scenarios")
            }
            let (events, _) = try await sendThroughServer(
                client, "Reply with only the word pong.", to: .conversationInStore(id: chatID, store: store),
                mode: .auto, answering: permission(allow: false))
            try check(reply(events).lowercased().contains("pong"), "reply: \(reply(events))")
            return "reply: \(reply(events))"
        })

        results.append(await scenario("History of the new chat") {
            guard let chatID else { throw CheckFailed(description: "needs the chat of the previous scenarios") }
            let history = try await client.history(conversationID: chatID)
            try check(promptCount(history) == 3, "\(promptCount(history)) prompts in the history, expected 3")
            try check(toolResults(of: "Bash", in: history).count == 2, "expected 2 Bash results in the history")
            let requests = history.filter { if case .userRequest(.permission) = $0 { true } else { false } }.count
            try check(requests == 2, "\(requests) permission requests in the history, expected 2 (allowed, denied)")
            return "\(history.count) events, 3 prompts, 2 permission requests"
        })

        if let chatID {
            results += await questionsAndPlans { prompt, answering in
                try await sendThroughServer(
                    client, prompt, to: .conversation(id: chatID, project: project), answering: answering).events
            }
        }

        results.append(await scenario("Answer to an unknown tool use") {
            do {
                for try await _ in client.answer(.permission(toolUseID: "toolu_unknown", allow: true)) {}
                throw CheckFailed(description: "it was accepted")
            } catch NetworkError.badResponse(let code, _) where code == 404 {}
            return "404"
        })

        return results
    }

    /// Sends one message and follows the turn through the server: each response streams until the turn waits for the
    /// user, which is answered with `answering`, and the answer's response continues the turn.
    /// Returns the turn's events and how many responses it took.
    private static func sendThroughServer(
        _ client: AgentServerClient, _ prompt: String, to target: MessageTarget, mode: PermissionMode = .manual,
        answering: Answering
    ) async throws -> (events: [ChatEvent], responses: Int) {
        var events: [ChatEvent] = []
        var stream = client.sendMessage(prompt, to: target, permissionModeOverride: mode, permissionTimeout: 120)
        var responses = 0
        while true {
            responses += 1
            for try await event in stream { events.append(event) }
            guard let waiting = waitingForUser(events).last else { return (events, responses) }
            stream = client.answer(answering(waiting))
        }
    }
}
#endif
