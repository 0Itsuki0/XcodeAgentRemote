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
///  - session history (loaded from each provider instead of the xcode chat data). For not implemented providers, "NOT IMPLEMENTED"
///  - any other metadata available

import AppKit
import CryptoKit
import Foundation

/// A project that has Xcode chats: one chat store folder `<ProjectName>-<hash>`.
nonisolated struct XcodeProject: Identifiable, Sendable {
    /// `<ProjectName>` of the store folder (the project file's name without extension).
    var name: String
    /// The `.xcodeproj` / `.xcworkspace`, or nil if it could not be found (moved, deleted, ...).
    var projectFile: URL?
    /// The chat store folder: `~/Library/Developer/Xcode/UserData/CodingAssistant/<ProjectName>-<hash>`.
    var store: URL
    /// Most recent first.
    var sessions: [XcodeChatSession]

    var id: String { store.lastPathComponent }
}

/// One Xcode chat (one chat == one agent session).
nonisolated struct XcodeChatSession: Identifiable, Sendable {
    /// Xcode's chat UUID (the chat's folder name in the store).
    var id: String
    var name: String
    /// The agent, e.g. "claude" (`chatModelDefinitionIdentifier.providerIdentifier.builtIn._0`).
    var provider: String?
    /// Xcode's model identifier for the agent, e.g. "claude-code".
    var modelIdentifier: String?
    /// The model of the latest reply, e.g. "claude-opus-5-5" (from the agent's session). nil if unknown.
    var model: String?
    /// The agent's own session id (`conversation.plist` → `assistantConfiguration`).
    var providerSessionID: String?
    /// The navigator group (folder) the chat is in, if any.
    var group: String?
    var isArchived: Bool
    var isUnread: Bool
    /// The line under the chat's name in Xcode's navigator, e.g. "Editing README.md".
    var subtitle: String?
    var startDate: Date?
    var lastActivityDate: Date?
}

/// A chat's history, loaded from the agent's own session (not from Xcode's chat files).
/// See `XcodeChats.history(conversationID:)`.
nonisolated enum ChatHistory: Sendable {
    case claude([ClaudeProvider.SessionMessage])
    /// NOT IMPLEMENTED for this provider.
    case notImplemented(provider: String)
    /// The session could not be loaded, e.g. its transcript is missing.
    case unavailable(reason: String)
}

nonisolated enum XcodeChats {

    static let storeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Developer/Xcode/UserData/CodingAssistant")
    static let claudeConfig = FileManager.default.homeDirectoryForCurrentUser
        .appending(
            path: "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig"
        )

    /// Every project with Xcode chats, with its chats.
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
        let navigator = Navigator(store: store)

        let sessions = manifest.map { entry -> XcodeChatSession in
            let provider = entry.chatModelDefinitionIdentifier?
                .providerIdentifier?.builtIn?._0.keys.first
            let sessionID = providerSessionID(
                store: store,
                conversationID: entry.id
            )
            let state = navigator.conversations[entry.id]
            return XcodeChatSession(
                id: entry.id,
                name: entry.name ?? "",
                provider: provider,
                modelIdentifier: entry.chatModelDefinitionIdentifier?
                    .modelIdentifier,
                model: provider == "claude"
                    ? sessionID.flatMap(latestClaudeModel) : nil,
                providerSessionID: sessionID,
                group: navigator.groupName(of: entry.id),
                isArchived: state?["isArchived"] as? Bool ?? false,
                isUnread: state?["isUnread"] as? Bool ?? false,
                subtitle: state?["subtitle"] as? String,
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
            sessions.compactMap {
                $0.providerSessionID.flatMap(claudeSessionCWD)
            } + snapshotRoots(store: store)
        return XcodeProject(
            name: name,
            projectFile: projectFile(store: store, folders: folders),
            store: store,
            sessions: sessions
        )
    }

    // MARK: History

    /// The history of an Xcode chat, given Xcode's chat UUID (the chat's folder name in its store).
    /// Loaded from the agent's own session; `nil` if no store has a chat with that id.
    static func history(conversationID: String) -> ChatHistory? {
        let id = conversationID.uppercased()
        let stores =
            (try? FileManager.default.contentsOfDirectory(
                at: storeRoot,
                includingPropertiesForKeys: nil
            )) ?? []
        guard
            let store = stores.first(where: {
                FileManager.default.fileExists(
                    atPath: $0.appending(path: "\(id)/conversation.plist").path
                )
            })
        else { return nil }

        let metadata = decode(
            ManifestEntry.self,
            from: store.appending(path: "\(id)/metadata.plist")
        )
        guard
            let provider = metadata?.chatModelDefinitionIdentifier?
                .providerIdentifier?.builtIn?._0.keys.first
        else {
            return .unavailable(reason: "unknown provider")
        }
        guard provider == "claude" else {
            return .notImplemented(provider: provider)
        }
        guard
            let sessionID = providerSessionID(store: store, conversationID: id),
            let transcript = claudeTranscript(sessionID: sessionID)
        else {
            return .unavailable(reason: "no session transcript for chat \(id)")
        }
        do {
            return .claude(
                try ClaudeProvider.SessionHistory.load(contentsOf: transcript)
            )
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    /// The agent's session id of a chat: `conversation.plist` → `assistantConfiguration`.
    static func providerSessionID(store: URL, conversationID: String) -> String?
    {
        let conversation = decode(
            ConversationFile.self,
            from: store.appending(path: "\(conversationID)/conversation.plist")
        )
        return conversation?.assistantConfiguration
            .flatMap {
                try? JSONDecoder().decode(AssistantConfiguration.self, from: $0)
            }?.agent._0.sessionID
    }

    /// `<ClaudeAgentConfig>/projects/<project-dir>/<sessionID>.jsonl`
    static func claudeTranscript(sessionID: String) -> URL? {
        let projects = claudeConfig.appending(path: "projects")
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: projects,
                includingPropertiesForKeys: nil
            )) ?? []
        return
            folders
            .map { $0.appending(path: "\(sessionID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The model of the latest assistant entry in a Claude session's transcript, read without loading the history.
    static func latestClaudeModel(sessionID: String) -> String? {
        guard let transcript = claudeTranscript(sessionID: sessionID),
            let data = try? Data(contentsOf: transcript)
        else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            if let entry = try? JSONDecoder().decode(
                TranscriptModel.self,
                from: Data(line)
            ),
                entry.type == "assistant", let model = entry.message?.model
            {
                return model
            }
        }
        return nil
    }

    // MARK: Finding the project file

    /// The `cwd` recorded in a Claude session's transcript: the folder the agent ran in.
    static func claudeSessionCWD(sessionID: String) -> URL? {
        guard let transcript = claudeTranscript(sessionID: sessionID),
            let data = try? Data(contentsOf: transcript)
        else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let cwd =
                (try? JSONDecoder().decode(TranscriptCWD.self, from: Data(line)))?
                .cwd
            {
                return URL(filePath: cwd, directoryHint: .isDirectory)
            }
        }
        return nil
    }

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
        struct ModelDefinition: Decodable {
            struct ProviderIdentifier: Decodable {
                struct BuiltIn: Decodable {
                    struct Empty: Decodable {}
                    var _0: [String: Empty]  // {"<provider name>": {}}
                }
                var builtIn: BuiltIn?
            }
            var modelIdentifier: String?
            var providerIdentifier: ProviderIdentifier?
        }
        var id: String
        var name: String?
        var startDate: Date?
        var lastActivityDate: Date?
        var chatModelDefinitionIdentifier: ModelDefinition?
    }

    /// The part of `conversation.plist` read here.
    struct ConversationFile: Decodable {
        var assistantConfiguration: Data?
    }

    /// `assistantConfiguration` (JSON): Swift `.agent(AgentConfiguration(sessionID:))`.
    struct AssistantConfiguration: Decodable {
        struct Box: Decodable {
            struct Configuration: Decodable { var sessionID: String }
            var _0: Configuration
        }
        var agent: Box
    }

    struct TranscriptCWD: Decodable {
        var cwd: String?
    }

    /// `type` and `message.model` of a transcript line.
    struct TranscriptModel: Decodable {
        struct Message: Decodable { var model: String? }
        var type: String?
        var message: Message?
    }

    /// `CodingAssistantNavigator.plist`: the navigator's per-chat state and groups.
    /// `navigatorConversations` is Swift's `[UUID: State]`, written as a flat `[key, value, ...]` list.
    /// Group entries are read loosely: their exact shape was not observed (no groups in the files seen so far).
    struct Navigator {
        var conversations: [String: [String: Any]] = [:]
        var groups: [[String: Any]] = []

        init(store: URL) {
            guard
                let data = try? Data(
                    contentsOf: store.appending(
                        path: "CodingAssistantNavigator.plist"
                    )
                ),
                let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    format: nil
                ) as? [String: Any]
            else { return }
            let flat = plist["navigatorConversations"] as? [Any] ?? []
            for index in stride(from: 0, to: flat.count - 1, by: 2) {
                if let id = flat[index] as? String,
                    let state = flat[index + 1] as? [String: Any]
                {
                    conversations[id] = state
                }
            }
            groups = (plist["groups"] as? [Any] ?? []).compactMap {
                $0 as? [String: Any]
            }
        }

        func groupName(of conversationID: String) -> String? {
            let group = groups.first {
                ($0["memberConversationIDs"] as? [String])?.contains(
                    conversationID
                ) == true
            }
            return group?["name"] as? String ?? group?["title"] as? String
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
