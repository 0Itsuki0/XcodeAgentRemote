//
//  ChatTypes.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/21.
//

import Foundation

/// Type for `GET /projects`
/// A project that has Xcode chats: one chat store folder `<ProjectName>-<hash>`.
nonisolated struct XcodeProject: Codable, Identifiable, Sendable, Hashable,
    Equatable
{
    /// `<ProjectName>` of the store folder (the project file's name without extension).
    var name: String
    /// The `.xcodeproj` / `.xcworkspace`, or nil if it could not be found (moved, deleted, ...).
    var projectFile: URL?
    /// The chat store folder: `~/Library/Developer/Xcode/UserData/CodingAssistant/<ProjectName>-<hash>`.
    var store: URL
    /// Most recent first.
    var conversations: [XcodeConversation]

    var id: String { store.lastPathComponent }
}

extension Array where Element == XcodeProject {
    func applySearchQuery(_ query: String) -> Self {
        let base = self
        let query = query.trimmed
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.conversations.map(\.name).contains(where: {
                    $0.localizedCaseInsensitiveContains(query)
                })
        }
    }
}

/// One Xcode conversation, as a project lists it (no history: `XcodeConversationDetail` has it).
/// It runs in one agent session (`providerSessionID`).
nonisolated struct XcodeConversation: Codable, Identifiable, Sendable,
    Hashable, Equatable
{
    /// Xcode's chat UUID (the chat's folder name in the store).
    var id: String
    var name: String
    var displayName: String {
        name.trimmed.isEmpty ? "New Conversation" : name.trimmed
    }
    /// The agent (`chatModelDefinitionIdentifier.providerIdentifier.builtIn._0`);
    /// nil if it is not one of the agents Xcode can run (`AgentProviderName`).
    var provider: AgentProviderName?
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
    /// The Mac watches its session's transcript (`POST /conversations/<id>/watch`).
    var isWatching: Bool = false
}

extension Array where Element == XcodeConversation {
    func applySearchQuery(_ query: String) -> Self {
        let base = self
        let query = query.trimmed
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

/// Type for `GET /conversations/<id>`
/// One Xcode conversation in full: its fields, its history, and the project it belongs to.
nonisolated struct XcodeConversationDetail: Codable, Identifiable, Sendable,
    Hashable, Equatable
{
    /// Xcode's chat UUID (the chat's folder name in the store).
    var id: String
    var name: String
    var displayName: String {
        name.trimmed.isEmpty ? "New Conversation" : name.trimmed
    }
    /// The agent (`chatModelDefinitionIdentifier.providerIdentifier.builtIn._0`); nil if it is not one of the agents
    /// Xcode can run (`Agent`).
    var provider: AgentProviderName?
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
    /// The Mac watches its session's transcript (`POST /conversations/<id>/watch`).
    var isWatching: Bool = false
    /// Its events, loaded from the agent's own session: the same events a live turn streams (`sendMessage`).
    var history: [ChatEvent]
    /// The project it belongs to.
    var project: ProjectReference
}

/// The project a conversation belongs to: the project's own fields, without its conversations.
nonisolated struct ProjectReference: Identifiable, Codable, Sendable, Hashable,
    Equatable
{
    /// `<ProjectName>` of the store folder (the project file's name without extension).
    var name: String
    /// The `.xcodeproj` / `.xcworkspace`, or nil if it could not be found (moved, deleted, ...).
    var projectFile: URL?
    /// The chat store folder: `~/Library/Developer/Xcode/UserData/CodingAssistant/<ProjectName>-<hash>`.
    var store: URL

    var id: String { store.lastPathComponent }
}
