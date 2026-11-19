//
//  PendingToolUses.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/19.
//

import Foundation
import Synchronization

/// The tool uses the agent waits on the user for, by id, while the app runs (in memory: an app that quits closes the
/// agent's input, and the agent then settles the request itself).
/// The `.jsonl` shows a tool use with no result both while it runs and while it waits for the user; this mark tells
/// them apart. Kept per agent, and only by the agent's provider: set when the agent asks the user, removed once the
/// provider has the answer or the tool use has a result.
/// A mark counts only while its tool use is the session's last message (`ClaudeProvider.userRequest`): if the
/// agent was killed before it settled the request, the request can still be answered (`answerUserRequest`).
nonisolated enum PendingToolUses {

    /// Tool use ids by agent: tool use ids are an agent's own, and only that agent's provider reads them.
    private static let idsByAgent = Mutex<[AgentProviderName: Set<String>]>([:])

    static func contains(_ toolUseID: String, agent: AgentProviderName) -> Bool {
        idsByAgent.withLock { $0[agent]?.contains(toolUseID) ?? false }
    }

    static func add(_ toolUseID: String, agent: AgentProviderName) {
        idsByAgent.withLock { _ = $0[agent, default: []].insert(toolUseID) }
    }

    static func remove(_ toolUseID: String, agent: AgentProviderName) {
        idsByAgent.withLock { _ = $0[agent]?.remove(toolUseID) }
    }
}
