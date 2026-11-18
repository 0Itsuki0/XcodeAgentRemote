//
//  ChatStore.swift
//  XcodeAgentRemote
//
//  Writing to Xcode's coding-assistant chat store, shared by all providers.
//
//  Layout (one store per workspace / project file):
//
//      ~/Library/Developer/Xcode/UserData/CodingAssistant/<ProjectName>-<hash>/
//          CodingAssistantManifest.plist      list of every chat's metadata
//          <chat UUID>/conversation.plist     the chat: its turns and their cards, provider, assistantConfiguration
//          <chat UUID>/metadata.plist         name, dates, provider
//          Snapshots/<UUID>.plist             git state before / after each turn
//
//  Xcode reads this store only when the project is opened; a running Xcode does not pick up changes.
//

import CryptoKit
import Foundation

// TODO: - split up files per functionality

/// Manage **Xcode's** chat store.
/// reading, writing, finding a project's store, git snapshots, and chats.
/// Layout (one store per workspace / project file):
///
/// ```
/// ~/Library/Developer/Xcode/UserData/CodingAssistant/<ProjectName>-<hash>/
///     CodingAssistantManifest.plist      list of every chat's metadata
///     Snapshots/<UUID>.plist             git state before / after each turn
///     <chat UUID>
///         conversation.plist     the chat: its turns and their cards, provider, assistantConfiguration
///         metadata.plist         name, dates, provider
/// ```
/// Note:
/// - Xcode *only* reads this store only when the project is opened; a running Xcode does not pick up changes.

nonisolated enum ChatStore {

    static let storeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Developer/Xcode/UserData/CodingAssistant")

    /// A new id, uppercased like the UUIDs Xcode writes.
    static func newUUID() -> String { UUID().uuidString }

    // MARK: Ids

    /// Whether two ids are the same Xcode chat id or agent session id. Xcode writes its chat UUIDs uppercase, Claude
    /// its session ids lowercase, and an id given to the app may be cased either way: both sides are lowercased.
    static func sameID(_ id: String, _ other: String) -> Bool {
        id.lowercased() == other.lowercased()
    }

    /// The item in `folder` named after an id (plus `suffix`, e.g. ".jsonl"), however its name is cased on disk.
    static func item(named id: String, suffix: String = "", in folder: URL)
        -> URL?
    {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path))
            ?? []
        return names.first { $0.lowercased() == (id + suffix).lowercased() }.map
        { folder.appending(path: $0) }
    }

    // MARK: Locating the store

    /// The store of a `.xcodeproj` / `.xcworkspace`: `<ProjectName>-<hash of the project file path>`.
    static func storeDirectory(forProject project: URL) -> URL {
        let name = project.deletingPathExtension().lastPathComponent
        return storeRoot.appending(
            path: "\(name)-\(ChatStore.xcodePathHash(project.path))",
            directoryHint: .isDirectory
        )
    }

    /// A store given by folder name (`<ProjectName>-<hash>`, looked up in the store root) or by path.
    static func storeDirectory(named store: String) -> URL {
        var store = (store as NSString).expandingTildeInPath
        while store.count > 1 && store.hasSuffix("/") { store.removeLast() }
        let url =
            store.contains("/")
            ? URL(filePath: store, directoryHint: .isDirectory)
            : storeRoot.appending(path: store, directoryHint: .isDirectory)
        return url.absoluteURL.standardizedFileURL
    }

    // MARK: Property lists

    /// A plist file's content, untyped; nil if it is missing or not a plist.
    private static func readPlist(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        )
    }

    /// Writes a plist file (XML unless told otherwise), replacing it atomically.
    private static func writePlist(
        _ plist: Any,
        to url: URL,
        format: PropertyListSerialization.PropertyListFormat = .xml
    ) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    /// A typed value as a property list object, to add to a plist that is kept untyped.
    private static func plistObject<T: Encodable>(_ value: T) throws -> Any {
        try PropertyListSerialization.propertyList(
            from: PropertyListEncoder().encode(value),
            format: nil
        )
    }

    // MARK: Snapshots

    /// `Snapshots/<UUID>.plist` (binary).
    private struct GitSnapshotFile: Encodable {
        /// The project's git state at one moment.
        struct GitState: Encodable {
            var id: String
            var date: Date
            var diffStaged: String
            var diffUnstaged: String
            /// HEAD
            var revision: String?
        }

        /// The git repository the state is of.
        struct RepositoryURL: Encodable {
            /// `file:///path/to/repo/`
            var relative: String
        }

        var id: String
        var repository: RepositoryURL
        var snapshot: GitState

        private enum CodingKeys: String, CodingKey { case id, snapshots }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            // Swift's `[URL: GitState]` is written as a flat `[key, value, ...]` list.
            var snapshots = container.nestedUnkeyedContainer(forKey: .snapshots)
            try snapshots.encode(repository)
            try snapshots.encode(snapshot)
        }
    }

    /// Records the git state of the project (like Xcode does before and after each turn) and returns its id;
    /// nil if the project is not in a git repository.
    static func writeGitSnapshot(store: URL, workingDirectory: URL) throws
        -> String?
    {
        guard
            let top = runCommand(
                ["git", "rev-parse", "--show-toplevel"],
                in: workingDirectory
            )?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !top.isEmpty
        else { return nil }
        let repository = URL(filePath: top, directoryHint: .isDirectory)
        let revision = runCommand(
            ["git", "rev-parse", "HEAD"],
            in: repository
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = GitSnapshotFile.GitState(
            id: newUUID(),
            date: Date(),
            diffStaged: runCommand(["git", "diff", "--cached"], in: repository)
                ?? "",
            diffUnstaged: runCommand(["git", "diff"], in: repository) ?? "",
            revision: revision?.isEmpty == false ? revision : nil
        )
        var root = top
        while root.hasSuffix("/") { root.removeLast() }
        let id = newUUID()
        let file = GitSnapshotFile(
            id: id,
            repository: .init(relative: "file://\(root)/"),
            snapshot: snapshot
        )

        let folder = store.appending(
            path: "Snapshots",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(file).write(
            to: folder.appending(path: "\(id).plist"),
            options: .atomic
        )
        return id
    }

    // MARK: conversation.plist types

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

    // MARK: Conversations

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
            modelDefinition: AgentModel,
            sessionID: String,
            name: String
        ) throws -> Chat {
            let id = newUUID()
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

        private var hasNoTurns: Bool {
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
}

nonisolated extension ChatStore {

    /// List all projects that has one more more Xcode chat sessions
    static func listProjects() -> [XcodeProject] {
        let stores =
            (try? FileManager.default.contentsOfDirectory(
                at: storeRoot,
                includingPropertiesForKeys: nil
            )) ?? []
        return
            stores
            .filter {
                FileManager.default.fileExists(
                    atPath: $0.appending(path: "CodingAssistantManifest.plist")
                        .path
                )
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(project(store:))
    }

    static func project(store: URL) -> XcodeProject {
        let manifest =
            decode(
                [ManifestEntry].self,
                from: store.appending(path: "CodingAssistantManifest.plist")
            ) ?? []
        let navigator = decode(
            Navigator.self,
            from: store.appending(path: "CodingAssistantNavigator.plist")
        )

        let conversations = manifest.map { entry -> XcodeChatConversation in
            let provider = entry.chatModelDefinitionIdentifier?
                .providerIdentifier?.builtIn?._0.keys.first.flatMap(
                    AgentProviderName.init(rawValue:)
                )
            let sessionID = providerSessionID(
                store: store,
                conversationID: entry.id
            )
            let state = navigator?.state(of: entry.id)
            return XcodeChatConversation(
                id: entry.id,
                name: entry.name ?? "",
                provider: provider,
                modelIdentifier: entry.chatModelDefinitionIdentifier?
                    .modelIdentifier,
                providerSessionID: sessionID,
                group: navigator?.group(of: entry.id)?.name,
                isArchived: state?.isArchived ?? false,
                isUnread: state?.isUnread ?? false,
                subtitle: state?.subtitle,
                startDate: entry.startDate,
                lastActivityDate: entry.lastActivityDate
            )
        }
        .sorted {
            ($0.lastActivityDate ?? .distantPast)
                > ($1.lastActivityDate ?? .distantPast)
        }

        let name = String(
            store.lastPathComponent.split(
                separator: "-",
                omittingEmptySubsequences: false
            ).dropLast().joined(separator: "-")
        )
        let folders =
            conversations.compactMap { conversation -> URL? in
                guard
                    let provider = conversation.provider.flatMap(
                        AgentProviders.provider(for:)
                    ),
                    let sessionID = conversation.providerSessionID
                else { return nil }
                return provider.workingDirectory(sessionID: sessionID)
            } + snapshotRoots(store: store)
        return XcodeProject(
            name: name,
            projectFile: projectFile(store: store, folders: folders),
            store: store,
            conversations: conversations
        )
    }

    // MARK: A conversation

    /// One conversation in full, given Xcode's chat UUID: its fields, its history (`history(conversationID:)`) and its
    /// project. Throws `ChatHistoryError` like `history(conversationID:)`.
    static func conversation(id: String) throws -> XcodeConversationDetail {
        let history = try history(conversationID: id)
        guard let folder = chatFolder(conversationID: id) else {
            throw ChatHistoryError.chatNotFound(conversationID: id)
        }
        let project = project(store: folder.deletingLastPathComponent())
        guard
            let conversation = project.conversations.first(where: {
                ChatStore.sameID($0.id, id)
            })
        else { throw ChatHistoryError.chatNotFound(conversationID: id) }
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

    /// The chat's folder (`<store>/<chat UUID>`), in whichever store has it.
    private static func chatFolder(conversationID: String) -> URL? {
        let stores =
            (try? FileManager.default.contentsOfDirectory(
                at: storeRoot,
                includingPropertiesForKeys: nil
            )) ?? []
        return stores.lazy.compactMap {
            ChatStore.item(named: conversationID, in: $0)
        }
        .first {
            FileManager.default.fileExists(
                atPath: $0.appending(path: "conversation.plist").path
            )
        }
    }

    // MARK: History
    /// The history of an Xcode chat, given Xcode's chat UUID (the chat's folder name in its store),
    /// loaded from the agent's own session: the same events a live turn streams (`sendMessage`).
    static func history(conversationID: String) throws -> [ChatEvent] {
        let id = conversationID
        guard let folder = chatFolder(conversationID: id) else {
            throw ChatHistoryError.chatNotFound(conversationID: id)
        }

        let metadata = decode(
            ManifestEntry.self,
            from: folder.appending(path: "metadata.plist")
        )
        guard
            let agent = metadata?.chatModelDefinitionIdentifier?
                .providerIdentifier?.builtIn?._0.keys.first.flatMap(
                    AgentProviderName.init(rawValue:)
                )
        else { throw ChatHistoryError.unknownProvider(conversationID: id) }
        guard let provider = AgentProviders.provider(for: agent) else {
            throw ChatHistoryError.notImplemented(agent: agent)
        }
        guard
            let sessionID = providerSessionID(
                store: folder.deletingLastPathComponent(),
                conversationID: id
            )
        else {
            throw ChatHistoryError.sessionMissing(conversationID: id)
        }
        return try provider.history(sessionID: sessionID)
    }

    /// The agent's session id of a chat: `conversation.plist` → `assistantConfiguration`.
    static func providerSessionID(store: URL, conversationID: String) -> String?
    {
        guard let folder = ChatStore.item(named: conversationID, in: store)
        else { return nil }
        let conversation = decode(
            ConversationFile.self,
            from: folder.appending(path: "conversation.plist")
        )
        return conversation?.assistantConfiguration
            .flatMap {
                try? JSONDecoder().decode(AssistantConfiguration.self, from: $0)
            }?.agent._0.sessionID
    }

    // MARK: Finding the project file

    /// The git repository roots recorded in the store's snapshots (`"relative": "file:///…/"`).
    static func snapshotRoots(store: URL) -> [URL] {
        let snapshots = store.appending(path: "Snapshots")
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: snapshots,
                includingPropertiesForKeys: nil
            )) ?? []
        return files.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    format: nil
                ) as? [String: Any],
                let first = (plist["snapshots"] as? [Any])?.first
                    as? [String: Any],
                let relative = first["relative"] as? String
            else { return nil }
            return URL(string: relative)
        }
    }

    /// The store name is `<ProjectName>-<hash of the project file path>` and the hash is one-way,
    /// so look for project files in candidate folders and match name + hash.
    static func projectFile(store: URL, folders: [URL]) -> URL? {
        let storeName = store.lastPathComponent
        guard let dash = storeName.lastIndex(of: "-") else { return nil }
        let name = String(storeName[..<dash])
        let hash = String(storeName[storeName.index(after: dash)...])
        let skipped: Set<String> = [
            "build", "DerivedData", "Pods", "node_modules",
        ]

        var seen = Set<String>()
        for folder in folders
        where seen.insert(folder.standardizedFileURL.path).inserted {
            guard
                let walker = FileManager.default.enumerator(
                    at: folder,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for case let url as URL in walker {
                let ext = url.pathExtension
                if ext == "xcodeproj" || ext == "xcworkspace" {
                    walker.skipDescendants()
                    let path = url.standardizedFileURL.path
                    if url.deletingPathExtension().lastPathComponent == name
                        && xcodePathHash(path) == hash
                    {
                        return URL(filePath: path)
                    }
                } else if skipped.contains(url.lastPathComponent) {
                    walker.skipDescendants()
                }
            }
        }
        return nil
    }

    /// Same hash Xcode uses for DerivedData / UserData folder names:
    /// MD5 of the path, each 8-byte half written as 14 base-26 letters.
    static func xcodePathHash(_ path: String) -> String {
        let digest = Array(Insecure.MD5.hash(data: Data(path.utf8)))
        return [digest[0..<8], digest[8..<16]].map { half -> String in
            var value = half.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var letters = [Character](repeating: "a", count: 14)
            for index in stride(from: 13, through: 0, by: -1) {
                letters[index] = Character(
                    UnicodeScalar(UInt8(97 + value % 26))
                )
                value /= 26
            }
            return String(letters)
        }.joined()
    }

    // MARK: Files

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(type, from: data)
    }

    /// An entry of `CodingAssistantManifest.plist` (same as each chat's `metadata.plist`).
    struct ManifestEntry: Decodable {
        struct AgentModel: Decodable {
            struct Provider: Decodable {
                struct BuiltIn: Decodable {
                    struct Empty: Decodable {}
                    var _0: [String: Empty]  // {"<provider name>": {}}
                }
                var builtIn: BuiltIn?
            }
            var modelIdentifier: String?
            var providerIdentifier: Provider?
        }
        var id: String
        var name: String?
        var startDate: Date?
        var lastActivityDate: Date?
        var chatModelDefinitionIdentifier: AgentModel?
    }

    /// The part of `conversation.plist` read here.
    struct ConversationFile: Decodable {
        var assistantConfiguration: Data?
    }

    /// `assistantConfiguration` (JSON): Swift `.agent(AgentConfiguration(sessionID:))`.
    struct AssistantConfiguration: Codable {
        struct Box: Codable {
            struct Configuration: Codable { var sessionID: String }
            var _0: Configuration
        }
        var agent: Box
    }

    /// `CodingAssistantNavigator.plist`: the navigator's groups (folders), per-chat state and order.
    struct Navigator: Decodable {
        struct Group: Decodable {
            var id: String
            var name: String
            var createdDate: Date?
            var isExpanded: Bool?
            var memberConversationIDs: [String]
        }

        struct ConversationState: Decodable {
            var isArchived: Bool?
            var isUnread: Bool?
            /// The line under the chat's name, e.g. "Editing README.md".
            var subtitle: String?
        }

        var groups: [Group]
        /// Chat UUID (lowercased: `state(of:)`) → its state.
        private var conversations: [String: ConversationState]
        /// Top-level order: group ids and ids of chats not in a group.
        var rootNodeOrder: [String]

        private enum CodingKeys: String, CodingKey {
            case groups, navigatorConversations, rootNodeOrder
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            groups =
                try container.decodeIfPresent([Group].self, forKey: .groups)
                ?? []
            rootNodeOrder =
                try container.decodeIfPresent(
                    [String].self,
                    forKey: .rootNodeOrder
                ) ?? []
            // Swift's `[UUID: State]` is written as a flat `[id, state, id, state, ...]` list.
            conversations = [:]
            if container.contains(.navigatorConversations) {
                var flat = try container.nestedUnkeyedContainer(
                    forKey: .navigatorConversations
                )
                while !flat.isAtEnd {
                    let id = try flat.decode(String.self)
                    conversations[id.lowercased()] = try flat.decode(
                        ConversationState.self
                    )
                }
            }
        }

        /// A chat's state, if the navigator has one.
        func state(of conversationID: String) -> ConversationState? {
            conversations[conversationID.lowercased()]
        }

        /// The group a chat is in, if any.
        func group(of conversationID: String) -> Group? {
            groups.first {
                $0.memberConversationIDs.contains {
                    ChatStore.sameID($0, conversationID)
                }
            }
        }
    }
}
