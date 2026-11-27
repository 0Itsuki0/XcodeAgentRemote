//
//  ChatConversation.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import Foundation

// MARK: Conversations
nonisolated extension ChatStore {
    // MARK: - Chat locations

    /// The chat's folder (`<store>/<chat UUID>`), in whichever store has it.
    static func chatFolder(conversationID: String)
        throws(XcodeChatError) -> URL
    {
        let stores =
            (try? FileManager.default.contentsOfDirectory(
                at: storeRoot,
                includingPropertiesForKeys: nil
            )) ?? []
        let folder = stores.lazy.compactMap {
            ChatStore.item(named: conversationID, in: $0)
        }
        .first {
            FileManager.default.fileExists(
                atPath: $0.appending(path: "conversation.plist").path
            )
        }

        guard let folder else {
            throw XcodeChatError.chatNotFound(id: conversationID)
        }
        return folder
    }

    /// The store containing the chat.
    /// aka: `~/Library/Developer/Xcode/UserData/CodingAssistant/<ProjectName>-<hash>`
    static func chatStore(conversationID: String) throws(XcodeChatError) -> URL
    {
        return try chatFolder(conversationID: conversationID)
            .deletingLastPathComponent()
    }

    // MARK: - Agent Provider

    static func provider(store: URL, conversationID: String)
        throws(XcodeChatError)
        -> AgentProvider.Type
    {
        // The chat's own folder holds its metadata.
        let metadata = item(named: conversationID, in: store).flatMap {
            decode(
                ManifestEntry.self,
                from: $0.appending(path: "metadata.plist")
            )
        }
        guard
            let agent = metadata?.chatModelDefinitionIdentifier?
                .providerIdentifier?.builtIn?._0.keys.first.flatMap(
                    AgentProviderName.init(rawValue:)
                )
        else {
            throw XcodeChatError.unknownAgent(conversationID: conversationID)
        }
        guard let provider = AgentProviders.provider(for: agent) else {
            throw XcodeChatError.agentNotImplemented(agent)
        }
        return provider
    }

    /// The agent's session id of a chat: `conversation.plist` → `assistantConfiguration`.
    static func providerSessionID(store: URL, conversationID: String)
        throws(XcodeChatError) -> String
    {
        guard let folder = item(named: conversationID, in: store)
        else {
            throw XcodeChatError.chatNotFound(id: conversationID)
        }
        let conversation = decode(
            ConversationPlist.self,
            from: folder.appending(path: "conversation.plist")
        )
        let sessionId = conversation?.assistantConfiguration
            .flatMap {
                try? JSONDecoder().decode(AssistantConfiguration.self, from: $0)
            }?.agent._0.sessionID

        guard let sessionId else {
            throw XcodeChatError.sessionMissing(conversationID: conversationID)
        }
        return sessionId
    }

    // MARK: - Read / Unread Conversation

    /// Marks a chat read in Xcode's navigator (`isUnread` false in its store's `CodingAssistantNavigator.plist`).
    /// Throws `XcodeChatError.chatNotFound` if no store has the chat.
    static func markRead(conversationID: String) throws {
        try markRead(
            conversationID: conversationID,
            store: chatStore(conversationID: conversationID)
        )
    }

    /// Marks a chat of `store` read (`setUnread`).
    static func markRead(conversationID: String, store: URL) throws {
        try setUnread(false, conversationID: conversationID, store: store)
    }

    /// Marks a chat of `store` unread, as Xcode does when a reply arrives while the chat isn't shown (`setUnread`).
    static func markUnread(conversationID: String, store: URL) throws {
        try setUnread(true, conversationID: conversationID, store: store)
    }

    /// Sets a chat's `isUnread` in `store`'s `CodingAssistantNavigator.plist`; the rest of the file is kept as it is
    /// (and in its format). A chat with no state there, or already in that state, is left alone.
    private static func setUnread(
        _ unread: Bool,
        conversationID: String,
        store: URL
    ) throws {
        let file = store.appending(path: "CodingAssistantNavigator.plist")
        guard let data = try? Data(contentsOf: file) else { return }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard
            var navigator = try PropertyListSerialization.propertyList(
                from: data,
                format: &format
            ) as? [String: Any],
            var states = navigator["navigatorConversations"] as? [Any]
        else { return }
        // Swift's `[UUID: State]` is written as a flat `[id, state, id, state, ...]` list.
        guard
            let index = stride(from: 0, to: states.count - 1, by: 2).first(
                where: {
                    (states[$0] as? String).map { sameID($0, conversationID) }
                        ?? false
                }),
            var state = states[index + 1] as? [String: Any],
            state["isUnread"] as? Bool != unread
        else { return }
        state["isUnread"] = unread
        states[index + 1] = state
        navigator["navigatorConversations"] = states
        try writePlist(navigator, to: file, format: format)
    }

    // MARK: - A conversation

    /// One conversation in full, given Xcode's chat UUID: its fields, its history (`history(conversationID:)`) and its
    /// project. Throws `XcodeChatError` like `history(conversationID:)`.
    static func conversation(id: String) throws -> XcodeConversationDetail {
        let history = try history(conversationID: id)
        let store = try chatStore(conversationID: id)
        let project = project(store: store)
        guard
            let conversation = project.conversations.first(where: {
                ChatStore.sameID($0.id, id)
            })
        else { throw XcodeChatError.chatNotFound(id: id) }
        return XcodeConversationDetail(
            id: conversation.id,
            name: conversation.name,
            provider: conversation.provider,
            modelIdentifier: conversation.modelIdentifier,
            providerSessionID: conversation.providerSessionID,
            group: conversation.group,
            isArchived: conversation.isArchived,
            isUnread: conversation.isUnread,
            subtitle: conversation.subtitle,
            startDate: conversation.startDate,
            lastActivityDate: conversation.lastActivityDate,
            history: history,
            project: ProjectReference(
                name: project.name,
                projectFile: project.projectFile,
                store: project.store
            )
        )
    }

    // MARK: - Chat History

    /// The history of an Xcode chat, given Xcode's chat UUID (the chat's folder name in its store),
    /// loaded from the agent's own session: the same events a live turn streams (`sendMessage`).
    static func history(conversationID: String) throws -> [ChatEvent] {
        let id = conversationID
        let store = try chatStore(conversationID: id)
        let provider = try provider(
            store: store,
            conversationID: conversationID
        )
        let sessionID = try providerSessionID(
            store: store,
            conversationID: id
        )
        do {
            return try provider.history(sessionID: sessionID)
        } catch XcodeChatError.transcriptMissing(_)
            where Chat.load(store: store, id: id)?.hasNoTurns == true
        {
            // A chat created in Xcode with nothing sent yet: its session has no file yet.
            return []
        }
    }
}

// MARK: - private type used by the conversation history
nonisolated extension ChatStore {

    /// One chat: `<store>/<chat UUID>/conversation.plist`, its `metadata.plist` and its manifest entry.
    /// `conversation.plist` is kept untyped, so the keys Xcode wrote that are not used here are written back as they were.
    struct Chat {
        private let store: URL
        let id: String
        private var plist: [String: Any]
        private var lastActivity: Date?

        private var directory: URL {
            store.appending(path: id, directoryHint: .isDirectory)
        }

        /// An existing chat (its id as its folder is named); nil if the store has no chat with this id.
        static func load(store: URL, id: String) -> Chat? {
            guard let folder = item(named: id, in: store),
                let plist = readPlist(
                    at: folder.appending(path: "conversation.plist")
                ) as? [String: Any]
            else { return nil }
            return Chat(
                store: store,
                id: folder.lastPathComponent,
                plist: plist
            )
        }

        /// A new chat (not written until `save`), for an agent session.
        static func create(
            store: URL,
            id: String,
            modelDefinition: ChatStore.AgentModel,
            sessionID: String,
            name: String
        ) throws -> Chat {
            let configuration = ChatStore.AssistantConfiguration(
                agent: .init(_0: .init(sessionID: sessionID))
            )
            let plist: [String: Any] = [
                "assistantConfiguration": try JSONEncoder().encode(
                    configuration
                ),
                "assistantKind": "agent",
                "chatModelDefinitionId": try plistObject(modelDefinition),
                "entryStates": [Any](),
                "id": id,
                "name": name,
                "startDate": Date(),
                "transcriptMessages": [Any](),
            ]
            return Chat(store: store, id: id, plist: plist)
        }

        /// The agent this chat uses: the key under `chatModelDefinitionId.providerIdentifier.builtIn._0`; nil if it is
        /// missing or not one of the agents Xcode can run.
        var agent: AgentProviderName? {
            let model = plist["chatModelDefinitionId"] as? [String: Any]
            let provider = model?["providerIdentifier"] as? [String: Any]
            let builtIn =
                (provider?["builtIn"] as? [String: Any])?["_0"]
                as? [String: Any]
            return builtIn?.keys.first.flatMap(
                AgentProviderName.init(rawValue:)
            )
        }

        /// The agent session id stored in `assistantConfiguration`.
        var sessionID: String? {
            (plist["assistantConfiguration"] as? Data)
                .flatMap {
                    try? JSONDecoder().decode(
                        ChatStore.AssistantConfiguration.self,
                        from: $0
                    )
                }?
                .agent._0.sessionID
        }

        var hasNoTurns: Bool {
            (plist["transcriptMessages"] as? [Any])?.isEmpty ?? true
        }

        /// Adds a finished turn: the prompt, the turn's cards and its git snapshots.
        mutating func appendTurn(
            prompt: String,
            startDate: Date,
            finishedDate: Date,
            response: (
                content: [ChatCard.Card], sequence: [ChatCard.CardID],
                isModification: Bool
            ),
            snapshotBefore: String?,
            snapshotAfter: String?
        ) throws {
            let entryID = newUUID()
            let message = TurnRecord(
                finishedDate: finishedDate,
                historyLogDate: startDate,
                id: entryID,
                isModification: response.isModification,
                responseContent: response.content,
                responseContentSequence: response.sequence,
                startDate: startDate,
                userMessage: .init(
                    id: .prose(newUUID()),
                    rawMessageText: prompt,
                    sentDate: startDate,
                    showDateSeparator: hasNoTurns
                ),
                snapshotIdBefore: snapshotBefore,
                snapshotIdAfter: snapshotAfter
            )
            plist["transcriptMessages"] =
                (plist["transcriptMessages"] as? [Any] ?? []) + [
                    try plistObject(message)
                ]
            plist["entryStates"] =
                (plist["entryStates"] as? [Any] ?? []) + [
                    try plistObject(TurnReference.assistantMessage(entryID))
                ]
            plist["lastAppliedEntry"] = entryID
            lastActivity = finishedDate
        }

        /// Writes `conversation.plist`, `metadata.plist` and this chat's entry in the store's manifest.
        func save() throws {
            let metadata: [String: Any] = [
                "chatModelDefinitionIdentifier": plist["chatModelDefinitionId"]
                    ?? [String: Any](),
                "conversationType": "assistant",
                "id": id,
                "lastActivityDate": lastActivity ?? Date(),
                "name": plist["name"] as? String ?? "",
                "startDate": plist["startDate"] as? Date ?? Date(),
            ]
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try writePlist(
                plist,
                to: directory.appending(path: "conversation.plist")
            )
            try writePlist(
                metadata,
                to: directory.appending(path: "metadata.plist")
            )

            let manifestFile = store.appending(
                path: "CodingAssistantManifest.plist"
            )
            let existing = readPlist(at: manifestFile) as? [Any] ?? []
            let manifest =
                existing.filter { entry in
                    ((entry as? [String: Any])?["id"] as? String).map {
                        !sameID($0, id)
                    } ?? true
                } + [metadata]
            try writePlist(manifest, to: manifestFile)
        }
    }

    /// `chatModelDefinitionId` / `chatModelDefinitionIdentifier`.
    struct AgentModel: Encodable {
        /// Encodes as `{}`.
        private struct Empty: Encodable {}
        /// Which agent: one of Xcode's built-in ones, by name.
        private enum Provider: Encodable {
            /// `{"builtIn": {"_0": {"<provider name>": {}}}}`
            case builtIn([String: Empty])
        }

        /// e.g. "claude-code"
        private var modelIdentifier: String
        private var providerIdentifier: Provider

        init(modelIdentifier: String, agent: AgentProviderName) {
            self.modelIdentifier = modelIdentifier
            self.providerIdentifier = .builtIn([agent.rawValue: Empty()])
        }
    }

    /// One turn: `transcriptMessages[]`.
    private struct TurnRecord: Encodable {
        /// What the user sent in this turn.
        struct Prompt: Encodable {
            var id: ChatCard.CardID
            var rawMessageText: String
            var sentDate: Date
            var showDateSeparator: Bool
        }

        var deliveredMessages: [String: String] = [:]
        var finishedDate: Date
        var historyLogDate: Date
        var id: String
        var isModification: Bool
        var responseContent: [ChatCard.Card]
        var responseContentSequence: [ChatCard.CardID]
        var startDate: Date
        var userMessage: Prompt
        var snapshotIdBefore: String?
        var snapshotIdAfter: String?
    }

    /// `entryStates[]`
    private enum TurnReference: Encodable {
        /// The transcript message id.
        case assistantMessage(String)
    }

}
