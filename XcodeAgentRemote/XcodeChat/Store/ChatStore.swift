//
//  ChatStore.swift
//  XcodeAgentRemote
//

import CryptoKit
import Foundation

/// Manage **Xcode's** chat store.
/// reading, writing, finding a project's store, git snapshots, and chats.
/// Layout (one store per workspace / project file):
///
/// ```
/// ~/Library/Developer/Xcode/UserData/CodingAssistant/<ProjectName>-<hash>/ (`store`)
///     CodingAssistantManifest.plist      list of every chat's metadata
///     Snapshots/<UUID>.plist             git state before / after each turn
///     <chat UUID>/ (`chatFolder`)
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
    static func readPlist(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        )
    }

    /// Writes a plist file (XML unless told otherwise), replacing it atomically.
    static func writePlist(
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
    static func plistObject<T: Encodable>(_ value: T) throws -> Any {
        try PropertyListSerialization.propertyList(
            from: PropertyListEncoder().encode(value),
            format: nil
        )
    }


    static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(type, from: data)
    }
}
