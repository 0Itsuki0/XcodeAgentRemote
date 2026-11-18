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

import Foundation

/// Reading and writing Xcode's chat store: finding a project's store, git snapshots, and chats.
nonisolated enum ChatStore {

    /// A new id, uppercased like the UUIDs Xcode writes.
    static func newUUID() -> String { UUID().uuidString }

    // MARK: Ids

    /// Whether two ids are the same Xcode chat id or agent session id. Xcode writes its chat UUIDs uppercase, Claude
    /// its session ids lowercase, and an id given to the app may be cased either way: both sides are lowercased.
    static func sameID(_ id: String, _ other: String) -> Bool { id.lowercased() == other.lowercased() }

    /// The item in `folder` named after an id (plus `suffix`, e.g. ".jsonl"), however its name is cased on disk.
    static func item(named id: String, suffix: String = "", in folder: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.first { $0.lowercased() == (id + suffix).lowercased() }.map { folder.appending(path: $0) }
    }

    // MARK: Locating the store

    /// The store of a `.xcodeproj` / `.xcworkspace`: `<ProjectName>-<hash of the project file path>`.
    static func storeDirectory(forProject project: URL) -> URL {
        let name = project.deletingPathExtension().lastPathComponent
        return XcodeChats.storeRoot.appending(
            path: "\(name)-\(XcodeChats.xcodePathHash(project.path))", directoryHint: .isDirectory)
    }

    /// A store given by folder name (`<ProjectName>-<hash>`, looked up in the store root) or by path.
    static func storeDirectory(named store: String) -> URL {
        var store = (store as NSString).expandingTildeInPath
        while store.count > 1 && store.hasSuffix("/") { store.removeLast() }
        let url = store.contains("/")
            ? URL(filePath: store, directoryHint: .isDirectory)
            : XcodeChats.storeRoot.appending(path: store, directoryHint: .isDirectory)
        return url.absoluteURL.standardizedFileURL
    }

    // MARK: Property lists

    /// A plist file's content, untyped; nil if it is missing or not a plist.
    private static func readPlist(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    /// Writes a plist file (XML unless told otherwise), replacing it atomically.
    private static func writePlist(
        _ plist: Any, to url: URL, format: PropertyListSerialization.PropertyListFormat = .xml
    ) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// A typed value as a property list object, to add to a plist that is kept untyped.
    private static func plistObject<T: Encodable>(_ value: T) throws -> Any {
        try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(value), format: nil)
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
    static func writeGitSnapshot(store: URL, workingDirectory: URL) throws -> String? {
        guard
            let top = runCommand(["git", "rev-parse", "--show-toplevel"], in: workingDirectory)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !top.isEmpty
        else { return nil }
        let repository = URL(filePath: top, directoryHint: .isDirectory)
        let revision = runCommand(["git", "rev-parse", "HEAD"], in: repository)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = GitSnapshotFile.GitState(
            id: newUUID(),
            date: Date(),
            diffStaged: runCommand(["git", "diff", "--cached"], in: repository) ?? "",
            diffUnstaged: runCommand(["git", "diff"], in: repository) ?? "",
            revision: revision?.isEmpty == false ? revision : nil
        )
        var root = top
        while root.hasSuffix("/") { root.removeLast() }
        let id = newUUID()
        let file = GitSnapshotFile(id: id, repository: .init(relative: "file://\(root)/"), snapshot: snapshot)

        let folder = store.appending(path: "Snapshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(file).write(to: folder.appending(path: "\(id).plist"), options: .atomic)
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

        init(modelIdentifier: String, agent: Agent) {
            self.modelIdentifier = modelIdentifier
            self.providerIdentifier = .builtIn([agent.rawValue: Empty()])
        }
    }

    /// One turn: `transcriptMessages[]`.
    private struct TurnRecord: Encodable {
        /// What the user sent in this turn.
        struct Prompt: Encodable {
            var id: ChatCards.CardID
            var rawMessageText: String
            var sentDate: Date
            var showDateSeparator: Bool
        }

        var deliveredMessages: [String: String] = [:]
        var finishedDate: Date
        var historyLogDate: Date
        var id: String
        var isModification: Bool
        var responseContent: [ChatCards.Card]
        var responseContentSequence: [ChatCards.CardID]
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

        private var directory: URL { store.appending(path: id, directoryHint: .isDirectory) }

        /// An existing chat (its id as its folder is named); nil if the store has no chat with this id.
        static func load(store: URL, id: String) -> Chat? {
            guard let folder = item(named: id, in: store),
                  let plist = readPlist(at: folder.appending(path: "conversation.plist")) as? [String: Any]
            else { return nil }
            return Chat(store: store, id: folder.lastPathComponent, plist: plist)
        }

        /// A new chat (not written until `save`), for an agent session.
        static func create(
            store: URL, modelDefinition: AgentModel, sessionID: String, name: String
        ) throws -> Chat {
            let id = newUUID()
            let configuration = XcodeChats.AssistantConfiguration(agent: .init(_0: .init(sessionID: sessionID)))
            let plist: [String: Any] = [
                "assistantConfiguration": try JSONEncoder().encode(configuration),
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
        var agent: Agent? {
            let model = plist["chatModelDefinitionId"] as? [String: Any]
            let provider = model?["providerIdentifier"] as? [String: Any]
            let builtIn = (provider?["builtIn"] as? [String: Any])?["_0"] as? [String: Any]
            return builtIn?.keys.first.flatMap(Agent.init(rawValue:))
        }

        /// The agent session id stored in `assistantConfiguration`.
        var sessionID: String? {
            (plist["assistantConfiguration"] as? Data)
                .flatMap { try? JSONDecoder().decode(XcodeChats.AssistantConfiguration.self, from: $0) }?
                .agent._0.sessionID
        }

        private var hasNoTurns: Bool { (plist["transcriptMessages"] as? [Any])?.isEmpty ?? true }

        /// Adds a finished turn: the prompt, the turn's cards and its git snapshots.
        mutating func appendTurn(
            prompt: String, startDate: Date, finishedDate: Date,
            response: (content: [ChatCards.Card], sequence: [ChatCards.CardID], isModification: Bool),
            snapshotBefore: String?, snapshotAfter: String?
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
                    id: .prose(newUUID()), rawMessageText: prompt, sentDate: startDate, showDateSeparator: hasNoTurns),
                snapshotIdBefore: snapshotBefore,
                snapshotIdAfter: snapshotAfter
            )
            plist["transcriptMessages"] = (plist["transcriptMessages"] as? [Any] ?? []) + [try plistObject(message)]
            plist["entryStates"] =
                (plist["entryStates"] as? [Any] ?? []) + [try plistObject(TurnReference.assistantMessage(entryID))]
            plist["lastAppliedEntry"] = entryID
            lastActivity = finishedDate
        }

        /// Writes `conversation.plist`, `metadata.plist` and this chat's entry in the store's manifest.
        func save() throws {
            let metadata: [String: Any] = [
                "chatModelDefinitionIdentifier": plist["chatModelDefinitionId"] ?? [String: Any](),
                "conversationType": "assistant",
                "id": id,
                "lastActivityDate": lastActivity ?? Date(),
                "name": plist["name"] as? String ?? "",
                "startDate": plist["startDate"] as? Date ?? Date(),
            ]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writePlist(plist, to: directory.appending(path: "conversation.plist"))
            try writePlist(metadata, to: directory.appending(path: "metadata.plist"))

            let manifestFile = store.appending(path: "CodingAssistantManifest.plist")
            let existing = readPlist(at: manifestFile) as? [Any] ?? []
            let manifest = existing.filter { entry in
                ((entry as? [String: Any])?["id"] as? String).map { !sameID($0, id) } ?? true
            } + [metadata]
            try writePlist(manifest, to: manifestFile)
        }
    }
}
