//
//  XcodeChatError.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import Foundation

/// Why a turn could not run, or that the agent failed.
nonisolated enum XcodeChatError: LocalizedError {
    case projectNotFound(URL)
    case storeNotFound(URL)
    case chatNotFound(id: String)
    /// Running turns is not implemented for this agent (only Claude is).
    case agentNotImplemented(AgentProviderName)
    /// The chat's agent is not one of the agents Xcode can run (`Agent`), or the chat doesn't say.
    case unknownAgent(conversationID: String)
    /// The chat has no agent session id.
    case sessionMissing(conversationID: String)
    /// The agent's session file is gone.
    case transcriptMissing(sessionID: String)

    /// `.conversationInStore`: the project file of the store could not be found.
    case projectFileNotFound(store: URL)
    /// The turn ran (and was recorded) but the agent reported an error.
    case agentFailed(message: String)
    /// The chat is already running a turn (another message to it, or an answer that resumes it).
    case conversationRunning(conversationID: String)
    case noWaitingRequest(toolUseID: String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound(let project):
            "No such project: \(project.path)"
        case .storeNotFound(let store):
            "No such chat store: \(store.path)"
        case .chatNotFound(let id):
            "No such conversation: \(id)"
        case .agentNotImplemented(let agent):
            "Agent \(agent.rawValue) is not implemented; implemented: \(AgentProviders.all.map { $0.agent.rawValue }.joined(separator: ", "))"
        case .unknownAgent(let id):
            "Unknown agent for Xcode chat \(id)"
        case .sessionMissing(let id):
            "Chat \(id) has no agent session"
        case .projectFileNotFound(let store):
            "Could not find the project file for \(store.path)"
        case .agentFailed(let message):
            "The agent failed: \(message)"
        case .conversationRunning(let id):
            "Chat \(id) is already running a turn: wait for it to end (or answer its request)"
        case .transcriptMissing(let sessionID):
            "No session file for agent session \(sessionID)"
        case .noWaitingRequest(let toolUseID):
            "No turn is waiting for an answer to tool use \(toolUseID)"
        }
    }
}
