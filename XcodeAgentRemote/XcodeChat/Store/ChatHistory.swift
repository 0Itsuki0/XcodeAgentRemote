//
//  ChatHistory.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/19.
//

import Foundation

nonisolated enum ChatHistoryError: LocalizedError {
    /// No chat store has a chat with this id.
    case chatNotFound(conversationID: String)
    /// The chat's agent could not be read from its metadata.
    case unknownProvider(conversationID: String)
    /// Loading history is not implemented for this agent (e.g. Codex).
    case notImplemented(agent: AgentProviderName)
    /// The chat has no agent session id.
    case sessionMissing(conversationID: String)
    /// The agent's session file is gone.
    case transcriptMissing(sessionID: String)

    var errorDescription: String? {
        switch self {
        case .chatNotFound(let id): "No Xcode chat \(id)"
        case .unknownProvider(let id): "Unknown agent for Xcode chat \(id)"
        case .notImplemented(let agent):
            "History is not implemented for agent \(agent.rawValue)"
        case .sessionMissing(let id): "Xcode chat \(id) has no agent session"
        case .transcriptMissing(let sessionID):
            "No session file for agent session \(sessionID)"
        }
    }
}
