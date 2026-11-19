//
//  XcodeAgentConfiguration.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/19.
//

import Foundation

nonisolated enum XcodeAgentConfiguration {
    // MARK: Would Xcode ask?

    /// Whether Xcode would ask the user before this tool use runs.
    /// - Parameters:
    ///   - agentAllowedTools: the tools Xcode lets the agent run without asking (`--allowedTools`); an MCP server's
    ///     name (`mcp__<server>`) covers all its tools.
    ///   - workingDirectory: the chat's project folder (open to the agent).
    static func wouldAsk(
        _ toolUse: ChatEvent.ToolUse,
        agentAllowedTools: [String],
        workingDirectory: URL?
    ) -> Bool {
        switch PermissionMode.currentMode {
        case .manual: break
        case .auto: return true
        case .dontAsk, .bypassPermissions: return false
        }
        guard let settings = PermissionRule.settings() else { return true }
        if !PermissionRule.toolIsAllowed(
            toolUse,
            settings: settings,
            agentAllowedTools: agentAllowedTools
        ) {
            return true
        }
        return PermissionRule.controlsFileAccess
            && PermissionRule.fileAccessWouldAsk(
                toolUse,
                settings: settings,
                workingDirectory: workingDirectory
            )
    }

}
