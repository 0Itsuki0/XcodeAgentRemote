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
    /// Running turns is not implemented for this agent (only "claude" is).
    case agentNotImplemented(String)
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
            "Agent \(agent) is not implemented; implemented: \(AgentProviders.all.map { $0.name }.joined(separator: ", "))"
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
        permissionTimeout: TimeInterval
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runAndRecord(
                        prompt, to: target, permissionModeOverride: permissionModeOverride,
                        permissionTimeout: permissionTimeout, continuation: continuation)
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
            let name = existing.providerName ?? "unknown"
            guard let existingProvider = AgentProviders.named(name) else { throw XcodeChatError.agentNotImplemented(name) }
            guard let existingSession = existing.sessionID else {
                throw XcodeChatError.sessionMissing(conversationID: existing.id)
            }
            provider = existingProvider
            sessionID = existingSession
            conversation = existing
        } else {
            guard case .newConversation(_, let agent, let name) = target else { return }
            guard let newProvider = AgentProviders.named(agent.rawValue) else {
                throw XcodeChatError.agentNotImplemented(agent.rawValue)
            }
            provider = newProvider
            sessionID = provider.newSessionID()
            conversation = try ChatStore.Chat.create(
                store: store,
                modelDefinition: .init(modelIdentifier: provider.modelIdentifier, provider: provider.name),
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
            records: records)
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
}
