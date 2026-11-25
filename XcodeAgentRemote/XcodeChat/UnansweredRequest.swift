//
//  UnansweredRequest.swift
//  XcodeAgentRemote
//
//  A request no running turn waits for (`XcodeChat.unansweredRequest`).
//

import Foundation

nonisolated extension XcodeChat {
    /// A request in a chat's session that waits for the user, while no running turn waits for it (the turn ended
    /// before it was answered: its agent was stopped before it settled the request).
    struct UnansweredRequest: Sendable {
        var store: URL
        var conversationID: String
        var provider: any AgentProvider.Type
        var sessionID: String
        /// The tool use the request is about.
        var toolUse: ChatEvent.ToolUse
    }
}
