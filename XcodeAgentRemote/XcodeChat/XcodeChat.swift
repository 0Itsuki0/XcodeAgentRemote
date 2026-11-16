//
//  XcodeChat.swift
//  XcodeAgentRemote
//
//  Runs one Xcode coding-assistant turn the way Xcode does and records it in Xcode's chat store:
//  snapshot the project's git state, run the agent (provider-specific, `AgentProvider.runTurn`), snapshot again,
//  and append the turn to the chat (conversation.plist, metadata.plist, the manifest).
//

import Foundation

/// Why a turn could not run, or that the agent failed.
nonisolated enum XcodeChatError: LocalizedError {
    case projectNotFound(URL)
    case storeNotFound(URL)
    case conversationNotFound(id: String, store: URL)
    /// Running turns is not implemented for this agent (only Claude is).
    case agentNotImplemented(Agent)
    /// The chat's agent is not one of the agents Xcode can run (`Agent`), or the chat doesn't say.
    case unknownAgent(conversationID: String)
    /// The chat has no agent session id.
    case sessionMissing(conversationID: String)
    /// `.conversationInStore`: the project file of the store could not be found.
    case projectFileNotFound(store: URL)
    /// The turn ran (and was recorded) but the agent reported an error.
    case agentFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound(let project):
            "No such project: \(project.path)"
        case .storeNotFound(let store):
            "No such chat store: \(store.path)"
        case .conversationNotFound(let id, let store):
            "No conversation at \(ChatStore.Chat.plistFile(store: store, id: id).path)"
        case .agentNotImplemented(let agent):
            "Agent \(agent.rawValue) is not implemented; implemented: \(AgentProviders.all.map { $0.agent.rawValue }.joined(separator: ", "))"
        case .unknownAgent(let id):
            "Unknown agent for Xcode chat \(id)"
        case .sessionMissing(let id):
            "Chat \(id) has no agent session"
        case .projectFileNotFound(let store):
            "Could not find the project file for \(store.path)"
        case .agentFailed(let message):
            "The agent failed: \(message)"
        }
    }
}

/// Running one turn of a chat the way Xcode does, and recording it in Xcode's chat store.
nonisolated enum XcodeChat {
    /// Runs one turn and records it, streaming its events: the prompt, then the agent's events.
    /// Throws `XcodeChatError`; `.agentFailed` after the turn's events, the turn recorded.
    /// Cancelling (stopping the iteration) stops the agent; the turn is then not recorded.
    static func runTurn(
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
                        prompt, to: target, permissionModeOverride: permissionModeOverride,
                        permissionTimeout: permissionTimeout, repeatedAnswer: repeatedAnswer, continuation: continuation)
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
        case .newConversation(let projectFile, _, _), .conversation(_, let projectFile):
            let file = projectFile.absoluteURL.standardizedFileURL
            guard FileManager.default.fileExists(atPath: file.path) else { throw XcodeChatError.projectNotFound(file) }
            project = file
            store = ChatStore.storeDirectory(forProject: file)
        case .conversationInStore(_, let name):
            store = ChatStore.storeDirectory(named: name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: store.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { throw XcodeChatError.storeNotFound(store) }
        }
        switch target {
        case .newConversation: conversationID = nil
        case .conversation(let id, _), .conversationInStore(let id, _): conversationID = id
        }

        // Provider and session: the chat's own for an existing chat, the given agent for a new one.
        let provider: any AgentProvider.Type
        let sessionID: String
        var conversation: ChatStore.Chat
        if let conversationID {
            guard let existing = ChatStore.Chat.load(store: store, id: conversationID) else {
                throw XcodeChatError.conversationNotFound(id: conversationID, store: store)
            }
            guard let agent = existing.agent else { throw XcodeChatError.unknownAgent(conversationID: existing.id) }
            guard let existingProvider = AgentProviders.provider(for: agent) else { throw XcodeChatError.agentNotImplemented(agent) }
            guard let existingSession = existing.sessionID else {
                throw XcodeChatError.sessionMissing(conversationID: existing.id)
            }
            provider = existingProvider
            sessionID = existingSession
            conversation = existing
        } else {
            guard case .newConversation(_, let agent, let name) = target else { return }
            guard let newProvider = AgentProviders.provider(for: agent) else {
                throw XcodeChatError.agentNotImplemented(agent)
            }
            provider = newProvider
            sessionID = provider.newSessionID()
            conversation = try ChatStore.Chat.create(
                store: store,
                modelDefinition: .init(modelIdentifier: provider.modelIdentifier, agent: provider.agent),
                sessionID: sessionID,
                name: name ?? String(prompt.prefix(40)))
        }

        if project == nil {  // a store only: find the project from the session's folder and the snapshots
            let folders = [provider.workingDirectory(sessionID: sessionID)].compactMap { $0 }
                + XcodeChats.snapshotRoots(store: store)
            guard let found = XcodeChats.projectFile(store: store, folders: folders) else {
                throw XcodeChatError.projectFileNotFound(store: store)
            }
            project = found
        }
        guard let project else { return }
        let workingDirectory = project.deletingLastPathComponent()
        let permissionMode: XcodeAgentConfiguration.PermissionMode =
            switch permissionModeOverride {
            case .manual: .manual
            case .auto: .auto
            case nil: XcodeAgentConfiguration.permissionMode
            }

        // One turn, like Xcode: snapshot, run the agent, snapshot, record.
        let snapshotBefore = try ChatStore.writeGitSnapshot(store: store, workingDirectory: workingDirectory)
        let startDate = Date()
        continuation.yield(.userMessage(prompt))
        let records = ToolUseRecords()
        let request = TurnRequest(
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            resume: conversationID != nil,
            prompt: prompt,
            permissionMode: permissionMode,
            permissionTimeout: permissionTimeout,
            records: records,
            repeatedAnswer: repeatedAnswer)
        var events: [ChatEvent] = []
        // An agent error still records the turn, then is thrown; any other error (or cancelling) does not record it.
        var agentError: XcodeChatError?
        do {
            for try await event in provider.runTurn(request) {
                events.append(event)
                continuation.yield(event)
            }
        } catch let error as XcodeChatError {
            guard case .agentFailed = error else { throw error }
            agentError = error
        }
        let finishedDate = Date()
        let snapshotAfter = try ChatStore.writeGitSnapshot(store: store, workingDirectory: workingDirectory)

        let toolUseRecords = await records.byToolUseID
        let response = ChatCards.turnCards(for: events) { toolUse, result in
            provider.card(for: toolUse, result: result, record: toolUseRecords[toolUse.id])
        }
        try conversation.appendTurn(
            prompt: prompt, startDate: startDate, finishedDate: finishedDate, response: response,
            snapshotBefore: snapshotBefore, snapshotAfter: snapshotAfter)
        try conversation.save()

        if let agentError { throw agentError }
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
        for project in XcodeChats.listProjects() {
            for chat in project.sessions {
                guard let agent = chat.provider, let provider = AgentProviders.provider(for: agent),
                      let sessionID = chat.providerSessionID,
                      let toolUse = provider.pendingToolUse(sessionID: sessionID), toolUse.id == toolUseID
                else { continue }
                return UnansweredRequest(
                    store: project.store, conversationID: chat.id, provider: provider, sessionID: sessionID,
                    toolUse: toolUse)
            }
        }
        return nil
    }

    /// Answers a request no running turn waits for (`unansweredRequest`), streaming the turn like `runTurn`:
    /// removes the waiting tool use from the session (so the agent doesn't mark it interrupted), resumes the chat with
    /// the answer as the prompt, and gives the same answer to the agent's repeat of that tool use without asking.
    /// Throws `SendMessageError.noWaitingRequest` if no chat waits on that tool use.
    static func resume(answering answer: UserAnswer, permissionTimeout: TimeInterval) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let request = unansweredRequest(toolUseID: answer.toolUseID) else {
                        throw SendMessageError.noWaitingRequest(toolUseID: answer.toolUseID)
                    }
                    try request.provider.removePendingToolUse(answer.toolUseID, sessionID: request.sessionID)
                    let events = runTurn(
                        prompt(answering: answer, about: request.toolUse),
                        to: .conversationInStore(id: request.conversationID, store: request.store.path),
                        permissionModeOverride: nil, permissionTimeout: permissionTimeout,
                        repeatedAnswer: RepeatedAnswer(toolUse: request.toolUse, answer: answer))
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
    static func prompt(answering answer: UserAnswer, about toolUse: ChatEvent.ToolUse) -> String {
        switch answer {
        case .permission(_, true, _):
            "Allowed: you may run the \(toolUse.name) call you asked permission for."
        case .permission(_, false, let message):
            "Denied: don't run the \(toolUse.name) call you asked permission for." + (message.map { " \($0)" } ?? "")
        case .questions(_, let answers):
            "My answers to your questions: "
                + answers.sorted { $0.key < $1.key }
                    .map { "\"\($0.key)\" = \"\($0.value.joined(separator: ", "))\"" }.joined(separator: "; ") + "."
        case .declineQuestions(_, let message):
            "I decline to answer your questions." + (message.map { " \($0)" } ?? "")
        case .planApproval(_, true, _):
            "Your plan is approved: go ahead."
        case .planApproval(_, false, let feedback):
            "Your plan is rejected." + (feedback.map { " \($0)" } ?? "")
        }
    }
}
