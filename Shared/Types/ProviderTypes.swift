//
//  ProviderTypes.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import Foundation

/// One model of a provider, as its agent reports it.
nonisolated struct AgentModel: Codable, Hashable, Sendable {
    /// The id the agent is given, e.g. "opus", "default".
    var id: String
    /// Its display name, e.g. "Opus 5.5".
    var name: String
    /// The model the id stands for, e.g. "claude-opus-5-5".
    var resolvedModel: String
    var isAvailable: Bool
    /// It can run in Auto permission mode.
    var supportsAutoMode: Bool
}

/// The agents Xcode can run: `xcrun mcpbridge run-agent <agent>`
/// ("Supported agents: antigravity, claude, claude-ext, codex, copilot, mock-agent").
nonisolated enum AgentProviderName: String, Codable, CaseIterable, Sendable,
    Hashable, Equatable
{
    case antigravity
    case claude
    case claudeExt = "claude-ext"
    case codex
    case copilot
    case mockAgent = "mock-agent"
}
