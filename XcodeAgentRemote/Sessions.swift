//
//  Sessions.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

/// List project chat sessions.
///
/// session list source:  xcode chat data: `~/Library/Developer/Xcode/UserData/CodingAssistant`
/// chat history source
/// - claude: `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects`
///
/// ```
/// project_a
///  - project metadata (name, path to `.xcodeproj`, conversation store path (path to <ProjectName>-<hash>) )
///  - sessions
///     - session_1 (one session == one chat)
///     - session_2 ...
///  project_b
///  - project metadata
///  - sessions
///     - session_1 (one session == one chat)
///     - session_2 ...
///  ```
///
///  Each session contains
///  - id give by xcode (
///  - provider's session id
///  - folder / group
///  - provider (claude opus 5.5, claude haiku, codex ...)
///  - session history (loaded from each provider instead of the xcode chat data, `XcodeChat.history`). For not implemented providers, "NOT IMPLEMENTED"
///  - any other metadata available

import AppKit
import CryptoKit
import Foundation

/// One agent Xcode can run (Claude, Codex, ...): where its sessions live and how to read them.
/// Implemented per provider in `Providers/`.
nonisolated protocol AgentProvider: SendableMetatype {
    /// The agent: also the key Xcode stores for it under `chatModelDefinitionIdentifier.providerIdentifier.builtIn._0`.
    static var agent: Agent { get }
    /// A session's events, from the agent's own session storage.
    static func history(sessionID: String) throws -> [ChatEvent]
    /// The folder the agent ran a session in, if the session records it.
    static func workingDirectory(sessionID: String) -> URL?

    // MARK: Running a turn (XcodeChat/XcodeChat.swift)

    /// `chatModelDefinitionIdentifier.modelIdentifier` of the agent's chats, e.g. "claude-code".
    static var modelIdentifier: String { get }
    /// A session id for a new chat.
    static func newSessionID() -> String
    /// Runs one turn of the agent in `request.workingDirectory` and streams its events (not the prompt).
    /// If the agent asks the user (permission to use a tool, questions, a plan), waits for the answer to that tool use
    /// (`PendingUserRequests.waitForAnswer`); no answer is a deny. Records the file content around its
    /// file-changing tool uses, and the ones it denied, in `request.records`.
    /// Throws `XcodeChatError.agentFailed` (after all events) if the agent reports an error.
    /// Cancelling (stopping the iteration) stops the agent.
    static func runTurn(_ request: TurnRequest) -> AsyncThrowingStream<ChatEvent, Error>
    /// The session's tool use that waits for the user's answer: its last tool use, if it has no result and is a
    /// request (a question / plan, or marked waiting: `WaitingMarks`); nil if there is none.
    static func pendingToolUse(sessionID: String) -> ChatEvent.ToolUse?
    /// Removes a tool use and its result from the session's transcript (an earlier tool use the agent repeated).
    static func removeToolUse(_ toolUseID: String, sessionID: String) throws
    /// Removes the result the agent wrote for a tool use when it was stopped while the tool ran (Xcode's project
    /// closed), and the interrupted text after it if any, so the tool use is left without a result. A result the tool
    /// produced itself (it finished before the stop) stays. Returns whether there was one to remove.
    static func removeStoppedResult(of toolUseID: String, sessionID: String) throws -> Bool
    /// Whether two tool uses are the same call (the same tool, with the same input that matters).
    static func isSameCall(_ toolUse: ChatEvent.ToolUse, _ other: ChatEvent.ToolUse) -> Bool
    /// The card Xcode shows for one of the agent's tool uses; nil if it never finished (no result).
    static func card(
        for toolUse: ChatEvent.ToolUse, result: ChatEvent.ToolResult?, record: ToolUseRecords.Record?
    ) -> ChatCards.Card?
}

/// The providers implemented so far.
nonisolated enum AgentProviders {
    static let all: [any AgentProvider.Type] = [ClaudeProvider.self]

    static func provider(for agent: Agent) -> (any AgentProvider.Type)? {
        all.first { $0.agent == agent }
    }
}

nonisolated enum ChatHistoryError: LocalizedError {
    /// No chat store has a chat with this id.
    case chatNotFound(conversationID: String)
    /// The chat's agent could not be read from its metadata.
    case unknownProvider(conversationID: String)
    /// Loading history is not implemented for this agent (e.g. Codex).
    case notImplemented(agent: Agent)
    /// The chat has no agent session id.
    case sessionMissing(conversationID: String)
    /// The agent's session file is gone.
    case transcriptMissing(sessionID: String)

    var errorDescription: String? {
        switch self {
        case .chatNotFound(let id): "No Xcode chat \(id)"
        case .unknownProvider(let id): "Unknown agent for Xcode chat \(id)"
        case .notImplemented(let agent): "History is not implemented for agent \(agent.rawValue)"
        case .sessionMissing(let id): "Xcode chat \(id) has no agent session"
        case .transcriptMissing(let sessionID): "No session file for agent session \(sessionID)"
        }
    }
}

nonisolated extension XcodeChat {

    static let storeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Developer/Xcode/UserData/CodingAssistant")

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
                .providerIdentifier?.builtIn?._0.keys.first.flatMap(Agent.init(rawValue:))
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
                guard let provider = conversation.provider.flatMap(AgentProviders.provider(for:)),
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
        guard let folder = chatFolder(conversationID: id) else { throw ChatHistoryError.chatNotFound(conversationID: id) }
        let project = project(store: folder.deletingLastPathComponent())
        guard let conversation = project.conversations.first(where: { ChatStore.sameID($0.id, id) })
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
            project: ProjectReference(name: project.name, projectFile: project.projectFile, store: project.store))
    }

    /// The chat's folder (`<store>/<chat UUID>`), in whichever store has it.
    private static func chatFolder(conversationID: String) -> URL? {
        let stores = (try? FileManager.default.contentsOfDirectory(at: storeRoot, includingPropertiesForKeys: nil)) ?? []
        return stores.lazy.compactMap { ChatStore.item(named: conversationID, in: $0) }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "conversation.plist").path) }
    }

    // MARK: History

    /// The history of an Xcode chat, given Xcode's chat UUID (the chat's folder name in its store),
    /// loaded from the agent's own session: the same events a live turn streams (`sendMessage`).
    static func history(conversationID: String) throws -> [ChatEvent] {
        let id = conversationID
        guard let folder = chatFolder(conversationID: id) else { throw ChatHistoryError.chatNotFound(conversationID: id) }

        let metadata = decode(
            ManifestEntry.self,
            from: folder.appending(path: "metadata.plist")
        )
        guard
            let agent = metadata?.chatModelDefinitionIdentifier?
                .providerIdentifier?.builtIn?._0.keys.first.flatMap(Agent.init(rawValue:))
        else { throw ChatHistoryError.unknownProvider(conversationID: id) }
        guard let provider = AgentProviders.provider(for: agent) else {
            throw ChatHistoryError.notImplemented(agent: agent)
        }
        guard let sessionID = providerSessionID(store: folder.deletingLastPathComponent(), conversationID: id) else {
            throw ChatHistoryError.sessionMissing(conversationID: id)
        }
        return try provider.history(sessionID: sessionID)
    }

    /// The agent's session id of a chat: `conversation.plist` → `assistantConfiguration`.
    static func providerSessionID(store: URL, conversationID: String) -> String?
    {
        guard let folder = ChatStore.item(named: conversationID, in: store) else { return nil }
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
            groups = try container.decodeIfPresent([Group].self, forKey: .groups) ?? []
            rootNodeOrder = try container.decodeIfPresent([String].self, forKey: .rootNodeOrder) ?? []
            // Swift's `[UUID: State]` is written as a flat `[id, state, id, state, ...]` list.
            conversations = [:]
            if container.contains(.navigatorConversations) {
                var flat = try container.nestedUnkeyedContainer(forKey: .navigatorConversations)
                while !flat.isAtEnd {
                    let id = try flat.decode(String.self)
                    conversations[id.lowercased()] = try flat.decode(ConversationState.self)
                }
            }
        }

        /// A chat's state, if the navigator has one.
        func state(of conversationID: String) -> ConversationState? {
            conversations[conversationID.lowercased()]
        }

        /// The group a chat is in, if any.
        func group(of conversationID: String) -> Group? {
            groups.first { $0.memberConversationIDs.contains { ChatStore.sameID($0, conversationID) } }
        }
    }
}

/// Xcode Agent Configuration
/// - current mode (auto vs manual)

nonisolated enum XcodeAgentConfiguration {

    /// Xcode's permission menu (Manual / Auto), for all chats.
    /// Stored in Xcode's preferences: `com.apple.dt.Xcode` → `IDEChatAgentPermissionMode`.
    enum PermissionMode: String, Sendable {
        case manual = "standard"
        case auto
        /// Options Xcode hides by default.
        case dontAsk
        case bypassPermissions
    }

    /// Xcode's current permission mode; Manual if it is not set.
    static var permissionMode: PermissionMode {
        let domain = "com.apple.dt.Xcode" as CFString
        CFPreferencesAppSynchronize(domain)  // re-read: Xcode may have changed it since
        let value =
            CFPreferencesCopyAppValue(
                "IDEChatAgentPermissionMode" as CFString,
                domain
            ) as? String
        return value.flatMap(PermissionMode.init(rawValue:)) ?? .manual
    }
}

/// Controlling Xcode with Apple Events (AppleScript).
///
/// Needs, in the app:
/// - Info.plist `NSAppleEventsUsageDescription` (the text shown in the permission prompt)
/// - the Apple Events entitlement (`com.apple.security.automation.apple-events`), required with the hardened runtime
nonisolated enum XcodeAutomation {
    /// Xcode and Xcode-beta use the same bundle id.
    static let bundleIdentifier = "com.apple.dt.Xcode"

    static var isXcodeRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
    }
}

/// Close Xcode for a project with Apple script.

nonisolated enum CloseProjectError: LocalizedError {
    /// The user has not allowed this app to control Xcode (System Settings → Privacy & Security → Automation).
    case notPermitted
    case scriptFailed(number: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notPermitted:
            "Not allowed to control Xcode. Allow it in System Settings → Privacy & Security → Automation."
        case .scriptFailed(let number, let message):
            "AppleScript error \(number): \(message)"
        }
    }
}

extension XcodeAutomation {
    /// Closes the project's window in Xcode (its workspace document), saving any unsaved edits.
    /// - Parameter project: the `.xcodeproj` / `.xcworkspace` Xcode has open.
    /// - Returns: whether Xcode had the project open (and closed it). `false` if Xcode is not running:
    ///   it is not launched just to close something.
    @MainActor
    static func closeProject(at project: URL) throws -> Bool {
        guard isXcodeRunning else { return false }

        // Xcode reports a document's path without a trailing slash.
        var path = project.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let escaped =
            path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
            tell application id "\(bundleIdentifier)"
                set openCount to count of (every workspace document whose path is "\(escaped)")
                if openCount > 0 then close (every workspace document whose path is "\(escaped)") saving yes
                return openCount
            end tell
            """
        var errorInfo: NSDictionary?
        guard
            let result = NSAppleScript(source: source)?.executeAndReturnError(
                &errorInfo
            )
        else {
            let number = errorInfo?[NSAppleScript.errorNumber] as? Int ?? 0
            if number == Int(errAEEventNotPermitted) {
                throw CloseProjectError.notPermitted
            }
            let message =
                errorInfo?[NSAppleScript.errorMessage] as? String
                ?? "unknown error"
            throw CloseProjectError.scriptFailed(
                number: number,
                message: message
            )
        }
        return result.int32Value > 0
    }
}

/// Ask for permissions
/// - Apple event script

extension XcodeAutomation {
    enum PermissionStatus: Equatable, Sendable {
        case granted
        case denied
        /// Not asked yet (only returned when not asking).
        case notDetermined
        /// The prompt can only be shown, and the answer only checked, while Xcode is running.
        case xcodeNotRunning
        case unknown(OSStatus)
    }

    /// Whether this app may control Xcode with Apple Events. With `askIfNeeded`, shows the system prompt the first
    /// time ("… wants to control Xcode"); after the user answered, it only returns the answer. A denied permission
    /// can only be changed in System Settings → Privacy & Security → Automation.
    /// Runs off the main thread: the call waits while the prompt is shown.
    static func automationPermission(askIfNeeded: Bool = true) async
        -> PermissionStatus
    {
        await Task.detached {
            let target = NSAppleEventDescriptor(
                bundleIdentifier: bundleIdentifier
            )
            let status = AEDeterminePermissionToAutomateTarget(
                target.aeDesc,
                typeWildCard,
                typeWildCard,
                askIfNeeded
            )
            switch status {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            case OSStatus(errAEEventWouldRequireUserConsent):
                return .notDetermined
            case OSStatus(procNotFound): return .xcodeNotRunning
            default: return .unknown(status)
            }
        }.value
    }

    /// Opens System Settings → Privacy & Security → Automation (to change a denied permission).
    @MainActor
    static func openAutomationSettings() {
        if let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}
