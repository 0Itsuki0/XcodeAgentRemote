//
//  Chats.swift
//  XcodeAgentRemote
//
//  The Xcode projects and chats listed by the macOS app (`XcodeChats.listProjects`), shared with the iOS app
//  (`GET /projects`).
//

import Foundation

/// A project that has Xcode chats: one chat store folder `<ProjectName>-<hash>`.
nonisolated struct XcodeProject: Codable, Identifiable, Sendable {
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
nonisolated struct XcodeChatSession: Codable, Identifiable, Sendable {
    /// Xcode's chat UUID (the chat's folder name in the store).
    var id: String
    var name: String
    /// The agent (`chatModelDefinitionIdentifier.providerIdentifier.builtIn._0`); nil if it is not one of the agents
    /// Xcode can run (`Agent`).
    var provider: Agent?
    /// Xcode's model identifier for the agent, e.g. "claude-code" (the chat's metadata).
    var modelIdentifier: String?
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
