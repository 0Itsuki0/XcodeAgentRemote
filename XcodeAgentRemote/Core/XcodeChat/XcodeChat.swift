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

    // MARK: - Check a new chat

    /// Checks a new chat before its first turn (`MessageTarget.newConversation`), and returns its id: the given one in
    /// its canonical form (any case accepted), or a new one if nil.
    /// Throws `XcodeChatError`: `.projectNotFound`, `.agentNotImplemented`, `.invalidConversationID` (not a UUID: it
    /// names the chat's folder), `.conversationExists`.
    static func checkNewConversation(
        id: String?,
        project: URL,
        agent: AgentProviderName
    ) throws(XcodeChatError) -> String {
        let file = project.absoluteURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw .projectNotFound(file)
        }
        guard AgentProviders.provider(for: agent) != nil else {
            throw .agentNotImplemented(agent)
        }
        guard let id else { return ChatStore.newUUID() }
        guard let uuid = UUID(uuidString: id) else {
            throw .invalidConversationID(id)
        }
        guard (try? ChatStore.chatStore(conversationID: id)) == nil else {
            throw .conversationExists(id: id)
        }
        return uuid.uuidString
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
        let (knownProject, store, conversationID) = try resolveTarget(target)
        guard
            let (provider, sessionID, chat) = try resolveChat(
                prompt: prompt,
                target: target,
                store: store,
                conversationID: conversationID
            )
        else { return }
        var conversation = chat
        // One turn per chat at a time: claimed until this turn is recorded.
        guard RunningSessions.insert(sessionID) else {
            throw XcodeChatError.conversationRunning(
                conversationID: conversation.id
            )
        }
        defer { RunningSessions.remove(sessionID) }

        let project = try resolveProject(
            knownProject,
            provider: provider,
            sessionID: sessionID,
            store: store
        )
        await closeProjectInXcode(project, sessionID: sessionID)
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

        // One turn, like Xcode: snapshot, run the agent, snapshot, record.
        let snapshotBefore = try ChatStore.writeGitSnapshot(
            store: store,
            workingDirectory: workingDirectory
        )
        // A chat created in Xcode with nothing sent yet has a session id but no session file: start that session.
        let isUnstartedSession =
            conversation.hasNoTurns
            && (try? provider.transcriptFile(sessionID: sessionID)) == nil
        let startDate = Date()
        let records = ToolUseRecords()
        let request = TurnRequest(
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            resume: conversationID != nil && !isUnstartedSession,
            prompt: prompt,
            permissionMode: permissionMode(for: permissionModeOverride),
            permissionTimeout: permissionTimeout,
            records: records,
            repeatedAnswer: repeatedAnswer
        )
        let (events, agentError) = try await runAgent(
            provider: provider,
            request: request,
            repeatedAnswer: repeatedAnswer,
            continuation: continuation
        )
        let finishedDate = Date()
        let snapshotAfter = try ChatStore.writeGitSnapshot(
            store: store,
            workingDirectory: workingDirectory
        )

        try recordTurn(
            in: &conversation,
            prompt: prompt,
            events: events,
            provider: provider,
            records: records,
            startDate: startDate,
            finishedDate: finishedDate,
            snapshotBefore: snapshotBefore,
            snapshotAfter: snapshotAfter
        )

        try removeRepeatedEarlierToolUse(
            repeatedAnswer: repeatedAnswer,
            records: records,
            provider: provider,
            sessionID: sessionID
        )
        /// The resume marked the answered tool use interrupted (`[Tool call interrupted …]`,
        /// then `No response requested.`):
        /// remove those, and make the answer (the prompt) its result, so the history reads like a live
        /// turn. (Not if it was repeated: the old tool use is gone, the repeat has its own result.)
        if let repeatedAnswer, !records.repeatedEarlierToolUse {
            _ = try provider.replaceResumeInterruption(
                with: repeatedAnswer.answer,
                prompt: prompt,
                sessionID: sessionID
            )
        }

        if let agentError { throw agentError }
    }

    /// The target's store and existing chat, and its project if the target names it.
    private static func resolveTarget(
        _ target: MessageTarget
    ) throws -> (project: URL?, store: URL, conversationID: String?) {
        var project: URL?
        let store: URL
        let conversationID: String?
        switch target {
        case .newConversation(let projectFile, _, _, _),
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
        return (project, store, conversationID)
    }

    /// Provider and session: the chat's own for an existing chat, the given agent for a new one (created here).
    /// nil if there is no existing chat and the target is not a new one.
    private static func resolveChat(
        prompt: String,
        target: MessageTarget,
        store: URL,
        conversationID: String?
    ) throws -> (
        provider: any AgentProvider.Type, sessionID: String,
        conversation: ChatStore.Chat
    )? {
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
            return (existingProvider, existingSession, existing)
        } else {
            guard
                case .newConversation(
                    let projectFile,
                    let agent,
                    let name,
                    let id
                ) = target
            else {
                return nil
            }
            let newID = try checkNewConversation(
                id: id,
                project: projectFile,
                agent: agent
            )
            guard let provider = AgentProviders.provider(for: agent) else {
                throw XcodeChatError.agentNotImplemented(agent)
            }
            let sessionID = provider.newSessionID()
            let conversation = try ChatStore.Chat.create(
                store: store,
                id: newID,
                modelDefinition: .init(
                    modelIdentifier: provider.modelIdentifier,
                    agent: provider.agent
                ),
                sessionID: sessionID,
                name: name ?? String(prompt.prefix(40))
            )
            return (provider, sessionID, conversation)
        }
    }

    /// The given project, or for a store only: the project found from the session's folder and the snapshots.
    private static func resolveProject(
        _ project: URL?,
        provider: any AgentProvider.Type,
        sessionID: String,
        store: URL
    ) throws -> URL {
        if let project { return project }
        let folders =
            [provider.workingDirectory(sessionID: sessionID)]
            .compactMap { $0 }
            + ChatStore.snapshotRoots(store: store)
        guard
            let found = ChatStore.projectFile(
                store: store,
                folders: folders
            )
        else {
            throw XcodeChatError.projectFileNotFound(store: store)
        }
        return found
    }

    /// Xcode keeps the project's chats in memory: it would write over what this turn records, and a request it
    /// shows could still be answered there.
    /// Close the project in Xcode before the turn (nothing if it isn't open).
    /// Best effort: only when automation is already allowed (never shows the prompt), and a failed close doesn't fail the turn.
    private static func closeProjectInXcode(
        _ project: URL,
        sessionID: String
    ) async {
        if await XcodeAutomation.automationPermission(askIfNeeded: false)
            == .granted,
            (try? await MainActor.run(body: {
                try XcodeAutomation.closeProject(at: project)
            })) == true
        {
            // Its agent for this session writes what it settles as it stops: wait for it to be gone.
            await waitForAgentToStop(sessionID: sessionID)
        }
    }

    /// The turn's permission mode: the override, or the current one.
    private static func permissionMode(
        for override: PermissionMode?
    ) -> XcodeAgentConfiguration.PermissionMode {
        switch override {
        case .manual: .manual
        case .auto: .auto
        case nil: XcodeAgentConfiguration.PermissionMode.currentMode
        }
    }

    /// Runs the agent's turn, streaming to the caller only what it doesn't have already (`ClientEvents`).
    /// Returns all the turn's events (for its cards) and the agent's error, if any: an agent error still records the
    /// turn, then is thrown; any other error (or cancelling) is thrown here and does not record it.
    private static func runAgent(
        provider: any AgentProvider.Type,
        request: TurnRequest,
        repeatedAnswer: RepeatedAnswer?,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> (events: [ChatEvent], agentError: XcodeChatError?) {
        var events: [ChatEvent] = []
        var clientEvents = ClientEvents(
            provider: provider,
            repeatedToolUse: repeatedAnswer.flatMap {
                $0.answer.isDeny ? nil : $0.toolUse
            }
        )
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
        return (events, agentError)
    }

    /// Appends the turn (its cards from the events) to the chat and saves it.
    private static func recordTurn(
        in conversation: inout ChatStore.Chat,
        prompt: String,
        events: [ChatEvent],
        provider: any AgentProvider.Type,
        records: ToolUseRecords,
        startDate: Date,
        finishedDate: Date,
        snapshotBefore: String?,
        snapshotAfter: String?
    ) throws {
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
    }

    /// The agent repeated the earlier tool use and was given its answer: the earlier one (left without a result
    /// when its agent was stopped, then marked interrupted on resume) is replaced by the repeat, so remove it.
    private static func removeRepeatedEarlierToolUse(
        repeatedAnswer: RepeatedAnswer?,
        records: ToolUseRecords,
        provider: any AgentProvider.Type,
        sessionID: String
    ) throws {
        if let repeatedAnswer, records.repeatedEarlierToolUse {
            try provider.removeToolUse(
                repeatedAnswer.toolUse.id,
                sessionID: sessionID
            )
        }
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
