//
//  MessageTarget.swift
//  XcodeAgentRemote
//
//  Which chat a message goes to (`XcodeChat.sendMessage`).
//

import Foundation

/// Which chat a message goes to (`sendMessage`).
nonisolated enum MessageTarget: Sendable {
    /// Start a new chat in the project (`.xcodeproj` / `.xcworkspace`) with this agent. `id`: the chat's UUID (any
    /// case; `XcodeChat.checkNewConversation`), or nil for a new one.
    case newConversation(
        project: URL,
        agent: AgentProviderName,
        name: String? = nil,
        id: String? = nil
    )
    /// Continue a chat of the project.
    case conversation(id: String, project: URL)
    /// Continue a chat, given its Xcode chat store folder (`<ProjectName>-<hash>`, name or path).
    case conversationInStore(id: String, store: String)
}
