//
//  ChatSnapshot.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import Foundation

// MARK: Snapshots of a project
/// ```
/// ~/Library/Developer/Xcode/UserData/CodingAssistant/<ProjectName>-<hash>/ (`store`)
///     CodingAssistantManifest.plist      list of every chat's metadata
///     Snapshots/<UUID>.plist             git state before / after each turn
///     <chat UUID>/ (`chatFolder`)
/// ```
nonisolated extension ChatStore {

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
            let top = CommandExecutor.runCommand(
                ["git", "rev-parse", "--show-toplevel"],
                in: workingDirectory
            )?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !top.isEmpty
        else { return nil }
        let repository = URL(filePath: top, directoryHint: .isDirectory)
        let revision = CommandExecutor.runCommand(
            ["git", "rev-parse", "HEAD"],
            in: repository
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = GitSnapshotFile.GitState(
            id: newUUID(),
            date: Date(),
            diffStaged: CommandExecutor.runCommand(
                ["git", "diff", "--cached"],
                in: repository
            )
                ?? "",
            diffUnstaged: CommandExecutor.runCommand(
                ["git", "diff"],
                in: repository
            ) ?? "",
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
}
