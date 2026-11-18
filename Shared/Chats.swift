//
//  Chats.swift
//  XcodeAgentRemote
//
//  The Xcode projects and conversations listed by the macOS app (`XcodeChats.listProjects`, `GET /projects`), and one
//  conversation in full (`XcodeChats.conversation(id:)`, `GET /conversation/<id>`), shared with the iOS app.
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
    var conversations: [XcodeChatConversation]

    var id: String { store.lastPathComponent }
}

/// One Xcode conversation, as a project lists it (no history: `XcodeConversationDetail` has it). It runs in one agent
/// session (`providerSessionID`).
nonisolated struct XcodeChatConversation: Codable, Identifiable, Sendable {
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

/// One Xcode conversation in full (`GET /conversation/<id>`): its fields, its history, and the project it belongs to.
nonisolated struct XcodeConversationDetail: Codable, Identifiable, Sendable {
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
    /// Its events, loaded from the agent's own session: the same events a live turn streams (`sendMessage`).
    var history: [ChatEvent]
    /// The project it belongs to.
    var project: ProjectReference
}

/// The project a conversation belongs to: the project's own fields, without its conversations.
nonisolated struct ProjectReference: Codable, Sendable {
    /// `<ProjectName>` of the store folder (the project file's name without extension).
    var name: String
    /// The `.xcodeproj` / `.xcworkspace`, or nil if it could not be found (moved, deleted, ...).
    var projectFile: URL?
    /// The chat store folder: `~/Library/Developer/Xcode/UserData/CodingAssistant/<ProjectName>-<hash>`.
    var store: URL
}
