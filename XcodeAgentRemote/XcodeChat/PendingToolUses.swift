//
//  PendingToolUses.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/19.
//

import Foundation

// TODO: - should clear on app launch? if yes, maybe switch to using Mutex like RunningSessions

/// The tool uses the agent waits on the user for, by id, kept across launches (`UserDefaults`).
/// The `.jsonl` shows a tool use with no result both while it runs and while it waits for the user; this mark tells
/// them apart. Kept per agent, and only by the agent's provider: set when the agent asks the user, removed once the
/// provider has the answer or the tool use has a result.
/// A mark counts only while its tool use is the session's last message (`ClaudeProvider.userRequest`): if the
/// agent was killed before it settled the request, the request can still be answered (`answerUserRequest`); if the app quit
/// instead, the agent settles it itself (as failed) and goes on, and the mark left behind is stale.
nonisolated enum PendingToolUses {

    private static var pendingUsesMap: [String: [String]] {
        get {
            UserDefaultsKey.pendingToolUseIdMap.getValue()
                as? [String: [String]] ?? [:]
        }
        set {
            UserDefaultsKey.pendingToolUseIdMap.setValue(value: newValue)
        }
    }

    static func contains(_ toolUseID: String, agent: AgentProviderName) -> Bool
    {
        pendingUsesMap[agent.rawValue]?.contains(toolUseID) ?? false
    }

    static func add(_ toolUseID: String, agent: AgentProviderName) {
        var ids = pendingUsesMap[agent.rawValue] ?? []
        if !ids.contains(toolUseID) { ids.append(toolUseID) }
        pendingUsesMap[agent.rawValue] = ids
    }

    static func remove(_ toolUseID: String, agent: AgentProviderName) {
        pendingUsesMap[agent.rawValue] = (pendingUsesMap[agent.rawValue] ?? [])
            .filter {
                $0 != toolUseID
            }
    }
}
