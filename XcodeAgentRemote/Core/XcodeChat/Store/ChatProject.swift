//
//  ChatProject.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/19.
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

import CryptoKit
import Foundation

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

        let conversations = manifest.map { entry -> XcodeConversation in
            let provider = entry.chatModelDefinitionIdentifier?
                .providerIdentifier?.builtIn?._0.keys.first.flatMap(
                    AgentProviderName.init(rawValue:)
                )
            let sessionID = try? providerSessionID(
                store: store,
                conversationID: entry.id
            )
            let state = navigator?.state(of: entry.id)
            return XcodeConversation(
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

    // MARK: - Finding the project file

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
}
