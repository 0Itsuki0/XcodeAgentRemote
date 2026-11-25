//
//  XcodeChat.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import Foundation

// MARK: - Xcode Chat
/// Running one turn of a chat the way Xcode does, and recording it in Xcode's chat store.
/// snapshot the project's git state, run the agent (provider-specific, `AgentProvider.runTurn`), snapshot again,
/// and append the turn to the chat (conversation.plist, metadata.plist, the manifest).
nonisolated enum XcodeChat {
    // MARK: - Send

    /// Runs one turn and streams its events as they happen: `.intermediate`, `.assistantMessage`, `.toolUse`,
    /// `.toolResult` and `.userRequest` events (not the prompt, nor the answers to its requests: the caller has them). The
    /// turn is recorded in Xcode's chat store when it ends.
    ///
    /// The stream ends when the turn ends, or when the agent waits for the user (permission to use a tool, questions, a
    /// plan): then it ends with that `.userRequest` (`waitingForUser`), and `answerUserRequest(_:)` continues the turn's
    /// stream from there. With no answer within `permissionTimeout` seconds (nil: 600) the request is denied.
    ///
    /// The turn runs on its own until it ends, whether or not its stream is read.
    /// Throws `XcodeChatError`; `.agentFailed` comes after the turn's events, the turn recorded.
    static func sendMessage(
        _ prompt: String,
        to target: MessageTarget,
        permissionModeOverride: PermissionMode? = nil,
        permissionTimeout: TimeInterval? = nil
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        let turn = RunningTurn.start(
            runTurn(
                prompt,
                to: target,
                permissionModeOverride: permissionModeOverride,
                permissionTimeout: permissionTimeout ?? 600
            )
        )
        return turn.untilWaitingForUser()
    }

    // MARK: - Answer a request to the user

    /// Answers a request from a chat's history (`waitingForUser`): a permission, questions or a plan. Streams the rest of
    /// that turn like `sendMessage`: until the next request to the user, or the end of the turn.
    /// - If the turn's agent still waits for it, the answer goes to it and the stream continues that turn.
    /// - If not (its agent was stopped before it settled the request), the chat is resumed with the answer: the agent
    ///   usually makes the same tool use again, and that request is answered with the same answer without asking
    ///   (unless the answer is a deny). `permissionTimeout` applies to that resumed turn.
    /// Throws `XcodeChatError.noWaitingRequest` if no chat waits for the user on that tool use.
    static func answerUserRequest(
        _ answer: ChatEvent.UserResponse,
        permissionTimeout: TimeInterval? = nil
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let events: AsyncThrowingStream<ChatEvent, Error>
                    if let turn = RunningTurns.take(
                        waitingFor: answer.toolUseID
                    ) {
                        // If the wait timed out meanwhile, the turn went on without this answer; it still continues here.
                        try? await PendingUserRequestHandler.shared.answer(
                            answer
                        )
                        events = turn.untilWaitingForUser()
                    } else if XcodeChat.unansweredRequest(
                        toolUseID: answer.toolUseID
                    ) != nil {
                        events = RunningTurn.start(
                            XcodeChat.resume(
                                answering: answer,
                                permissionTimeout: permissionTimeout ?? 600
                            )
                        ).untilWaitingForUser()
                    } else {
                        throw XcodeChatError.noWaitingRequest(
                            toolUseID: answer.toolUseID
                        )
                    }
                    for try await event in events { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs one turn and records it, streaming its events: the prompt, then the agent's events.
    /// Throws `XcodeChatError`; `.agentFailed` after the turn's events, the turn recorded.
    /// Cancelling (stopping the iteration) stops the agent; the turn is then not recorded.
    private static func runTurn(
        _ prompt: String,
        to target: MessageTarget,
        permissionModeOverride: PermissionMode?,
        permissionTimeout: TimeInterval,
        repeatedAnswer: RepeatedAnswer? = nil
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runAndRecord(
                        prompt,
                        to: target,
                        permissionModeOverride: permissionModeOverride,
                        permissionTimeout: permissionTimeout,
                        repeatedAnswer: repeatedAnswer,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Finds the chat and its agent, snapshots git, runs the agent's turn (streaming its events), snapshots again,
    /// and records the turn.
    private static func runAndRecord(
        _ prompt: String,
        to target: MessageTarget,
        permissionModeOverride: PermissionMode?,
        permissionTimeout: TimeInterval,
        repeatedAnswer: RepeatedAnswer?,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        // Store and existing chat.
        var project: URL?
        let store: URL
        let conversationID: String?
        switch target {
        case .newConversation(let projectFile, _, _),
            .conversation(_, let projectFile):
            let file = projectFile.absoluteURL.standardizedFileURL
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw XcodeChatError.projectNotFound(file)
            }
            project = file
            store = ChatStore.storeDirectory(forProject: file)
        case .conversationInStore(_, let name):
            store = ChatStore.storeDirectory(named: name)
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: store.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue
            else { throw XcodeChatError.storeNotFound(store) }
        }
        switch target {
        case .newConversation: conversationID = nil
        case .conversation(let id, _), .conversationInStore(let id, _):
            conversationID = id
        }

        // Provider and session: the chat's own for an existing chat, the given agent for a new one.
        let provider: any AgentProvider.Type
        let sessionID: String
        var conversation: ChatStore.Chat
        if let conversationID {
            guard
                let existing = ChatStore.Chat.load(
                    store: store,
                    id: conversationID
                )
            else {
                throw XcodeChatError.chatNotFound(
                    id: conversationID,
                )
            }
            guard let agent = existing.agent else {
                throw XcodeChatError.unknownAgent(conversationID: existing.id)
            }
            guard let existingProvider = AgentProviders.provider(for: agent)
            else { throw XcodeChatError.agentNotImplemented(agent) }
            guard let existingSession = existing.sessionID else {
                throw XcodeChatError.sessionMissing(conversationID: existing.id)
            }
            provider = existingProvider
            sessionID = existingSession
            conversation = existing
        } else {
            guard case .newConversation(_, let agent, let name) = target else {
                return
            }
            guard let newProvider = AgentProviders.provider(for: agent) else {
                throw XcodeChatError.agentNotImplemented(agent)
            }
            provider = newProvider
            sessionID = provider.newSessionID()
            conversation = try ChatStore.Chat.create(
                store: store,
                modelDefinition: .init(
                    modelIdentifier: provider.modelIdentifier,
                    agent: provider.agent
                ),
                sessionID: sessionID,
                name: name ?? String(prompt.prefix(40))
            )
        }
        // One turn per chat at a time: claimed until this turn is recorded.
        guard RunningSessions.insert(sessionID) else {
            throw XcodeChatError.conversationRunning(
                conversationID: conversation.id
            )
        }
        defer { RunningSessions.remove(sessionID) }

        if project == nil {  // a store only: find the project from the session's folder and the snapshots
            let folders =
                [provider.workingDirectory(sessionID: sessionID)].compactMap {
                    $0
                }
                + ChatStore.snapshotRoots(store: store)
            guard
                let found = ChatStore.projectFile(
                    store: store,
                    folders: folders
                )
            else {
                throw XcodeChatError.projectFileNotFound(store: store)
            }
            project = found
        }
        guard let project else { return }
        // Xcode keeps the project's chats in memory: it would write over what this turn records, and a request it
        // shows could still be answered there. Close the project in Xcode before the turn (nothing if it isn't open).
        if try await MainActor.run(body: {
            try XcodeAutomation.closeProject(at: project)
        }) {
            // Its agent for this session writes what it settles as it stops: wait for it to be gone.
            await waitForAgentToStop(sessionID: sessionID)
        }
        // Answering a request of Xcode's chat whose tool was running after all: closing the project killed it, and its
        // agent wrote that as its result (`Exit code 137`). Remove that result: the tool use is left without one like a
        // waiting one, and the agent's repeat runs with the user's answer. (A tool that finished before the close keeps
        // its result.)
        if let repeatedAnswer {
            _ = try provider.removeStoppedResult(
                of: repeatedAnswer.toolUse.id,
                sessionID: sessionID
            )
        }
        let workingDirectory = project.deletingLastPathComponent()
        let permissionMode: XcodeAgentConfiguration.PermissionMode =
            switch permissionModeOverride {
            case .manual: .manual
            case .auto: .auto
            case nil: XcodeAgentConfiguration.PermissionMode.currentMode
            }

        // One turn, like Xcode: snapshot, run the agent, snapshot, record.
        let snapshotBefore = try ChatStore.writeGitSnapshot(
            store: store,
            workingDirectory: workingDirectory
        )
        let startDate = Date()
        let records = ToolUseRecords()
        let request = TurnRequest(
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            resume: conversationID != nil,
            prompt: prompt,
            permissionMode: permissionMode,
            permissionTimeout: permissionTimeout,
            records: records,
            repeatedAnswer: repeatedAnswer
        )
        // All the turn's events, for its cards; the caller gets only what it doesn't have already (`ClientEvents`).
        var events: [ChatEvent] = []
        var clientEvents = ClientEvents(
            provider: provider,
            repeatedToolUse: repeatedAnswer.flatMap {
                $0.answer.isDeny ? nil : $0.toolUse
            }
        )
        // An agent error still records the turn, then is thrown; any other error (or cancelling) does not record it.
        var agentError: XcodeChatError?
        do {
            for try await event in provider.runTurn(request) {
                events.append(event)
                if clientEvents.passes(event) { continuation.yield(event) }
            }
        } catch let error as XcodeChatError {
            guard case .agentFailed = error else { throw error }
            agentError = error
        }
        let finishedDate = Date()
        let snapshotAfter = try ChatStore.writeGitSnapshot(
            store: store,
            workingDirectory: workingDirectory
        )

        let toolUseRecords = records.byToolUseID
        let response = ChatCard.turnCards(for: events) { toolUse, result in
            provider.card(
                for: toolUse,
                result: result,
                record: toolUseRecords[toolUse.id]
            )
        }
        try conversation.appendTurn(
            prompt: prompt,
            startDate: startDate,
            finishedDate: finishedDate,
            response: response,
            snapshotBefore: snapshotBefore,
            snapshotAfter: snapshotAfter
        )
        try conversation.save()

        // The agent repeated the earlier tool use and was given its answer: the earlier one (left without a result
        // when its agent was stopped, then marked interrupted on resume) is replaced by the repeat, so remove it.
        if let repeatedAnswer, records.repeatedEarlierToolUse {
            try provider.removeToolUse(
                repeatedAnswer.toolUse.id,
                sessionID: sessionID
            )
        }

        if let agentError { throw agentError }
    }

    /// Waits (up to 10 seconds) until no process runs with the session id in its arguments: the agent Xcode ran it in.
    private static func waitForAgentToStop(sessionID: String) async {
        for _ in 0..<50 {
            if CommandExecutor.runCommand(["pgrep", "-if", sessionID]) == nil {
                return
            }  // -i: the id may be cased differently
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: Answering a request no running turn waits for

    /// A request in a chat's session that waits for the user, while no running turn waits for it (the turn ended
    /// before it was answered: its agent was stopped before it settled the request).
    struct UnansweredRequest: Sendable {
        var store: URL
        var conversationID: String
        var provider: any AgentProvider.Type
        var sessionID: String
        /// The tool use the request is about.
        var toolUse: ChatEvent.ToolUse
    }

    /// The chat whose session waits for the user on this tool use (its last tool use: `AgentProvider.pendingToolUse`).
    static func unansweredRequest(toolUseID: String) -> UnansweredRequest? {
        for project in ChatStore.listProjects() {
            for chat in project.conversations {
                guard let agent = chat.provider,
                    let provider = AgentProviders.provider(for: agent),
                    let sessionID = chat.providerSessionID,
                    let toolUse = provider.pendingToolUse(sessionID: sessionID),
                    toolUse.id == toolUseID
                else { continue }
                return UnansweredRequest(
                    store: project.store,
                    conversationID: chat.id,
                    provider: provider,
                    sessionID: sessionID,
                    toolUse: toolUse
                )
            }
        }
        return nil
    }

    /// Answers a request no running turn waits for (`unansweredRequest`), streaming the turn like `runTurn`: resumes
    /// the chat with the answer as the prompt (the agent marks the waiting tool use interrupted), and gives the same
    /// answer to the agent's repeat of that tool use without asking. Once the turn ended, if the agent did repeat it,
    /// the earlier tool use and its interrupted result are removed from the session: only the repeat remains.
    /// Throws `XcodeChatError.noWaitingRequest` if no chat waits on that tool use.
    static func resume(
        answering answer: ChatEvent.UserResponse,
        permissionTimeout: TimeInterval
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard
                        let request = unansweredRequest(
                            toolUseID: answer.toolUseID
                        )
                    else {
                        throw XcodeChatError.noWaitingRequest(
                            toolUseID: answer.toolUseID
                        )
                    }
                    let events = runTurn(
                        prompt(answering: answer, about: request.toolUse),
                        to: .conversationInStore(
                            id: request.conversationID,
                            store: request.store.path
                        ),
                        permissionModeOverride: nil,
                        permissionTimeout: permissionTimeout,
                        repeatedAnswer: RepeatedAnswer(
                            toolUse: request.toolUse,
                            answer: answer
                        )
                    )
                    for try await event in events { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The answer as the prompt the chat is resumed with: what the agent reads as the user's message.
    private static func prompt(
        answering answer: ChatEvent.UserResponse,
        about toolUse: ChatEvent.ToolUse
    ) -> String {
        switch answer {
        case .permission(_, true, _):
            "Allowed: you may run the \(toolUse.name) call you asked permission for."
        case .permission(_, false, let message):
            "Denied: don't run the \(toolUse.name) call you asked permission for."
                + (message.map { " \($0)" } ?? "")
        case .questions(_, let answers):
            "My answers to your questions: "
                + answers.sorted { $0.key < $1.key }
                .map {
                    "\"\($0.key)\" = \"\($0.value.joined(separator: ", "))\""
                }.joined(separator: "; ") + "."
        case .declineQuestions(_, let message):
            "I decline to answer your questions."
                + (message.map { " \($0)" } ?? "")
        case .planApproval(_, true, _):
            "Your plan is approved: go ahead."
        case .planApproval(_, false, let feedback):
            "Your plan is rejected." + (feedback.map { " \($0)" } ?? "")
        }
    }

    /// Xcode's system prompt addition, rendered from its template inside Xcode.
    static func xcodeSystemPrompt() -> String? {
        guard
            let developer = CommandExecutor.runCommand(["xcode-select", "-p"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let path = (developer as NSString).appendingPathComponent(
            "../PlugIns/IDEIntelligenceChat.framework/Resources/AgentSystemPromptAddition.idechatprompttemplate"
        )
        guard
            let template = try? String(
                contentsOfFile: (path as NSString).standardizingPath,
                encoding: .utf8
            )
        else { return nil }
        // Keep every `{% if MCPTool_X %}` section (all Xcode tools are available) and drop the tags.
        return template.replacing(#/\{%[^%]*%\}/#, with: "")
    }
}

/// Which of a turn's events go to the caller. The provider streams them all (the turn's cards are built from all of
/// them); the caller doesn't get what it has already or what stands for something it has:
/// - a tool use that always waits for the user (a question, a plan): its `.userRequest` stands for it;
/// - the agent's repeat of the earlier tool use being answered (resuming a chat): its tool use and request (the caller
///   has the earlier one, and answered it);
/// - `.userResponse`: the caller sent the answer;
/// - the result of a tool use the user answered, unless it allowed a permission: the answer is its result. An allowed
///   permission's result is the tool's output.
nonisolated private struct ClientEvents {
    let provider: any AgentProvider.Type
    /// The earlier tool use being answered, until the agent repeats it.
    var repeatedToolUse: ChatEvent.ToolUse?
    private var repeatID: String?
    private var answers: [String: ChatEvent.UserResponse] = [:]

    init(provider: any AgentProvider.Type, repeatedToolUse: ChatEvent.ToolUse?)
    {
        self.provider = provider
        self.repeatedToolUse = repeatedToolUse
    }

    /// Whether the caller gets this event (call it for every event, in order).
    mutating func passes(_ event: ChatEvent) -> Bool {
        switch event {
        case .toolUse(let toolUse):
            if let earlier = repeatedToolUse,
                provider.isSameCall(earlier, toolUse)
            {
                repeatedToolUse = nil
                repeatID = toolUse.id
                return false
            }
            return !provider.alwaysWaitsForUser(toolUse)
        case .userRequest(let request):
            return request.toolUseID != repeatID
        case .userResponse(let answer):
            answers[answer.toolUseID] = answer
            return false
        case .toolResult(let result):
            return answers[result.toolUseID]?.isAllowedPermission ?? true
        default:
            return true
        }
    }
}
