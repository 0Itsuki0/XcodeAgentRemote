//
//  AgentModels.swift
//  XcodeAgentRemote
//
//  The models each provider's agent offers, as Xcode caches them.
//

import Foundation

nonisolated extension XcodeAgentConfiguration {

    /// Xcode's cache of the models an agent reported: `com.apple.dt.Xcode` → `IDEChatGatewayModels.<Xcode's id for
    /// the agent>`, JSON data (`{"models": [...], "defaultModel": {...}, "supportsCustomModelIdentifier": true}`).
    struct GatewayModels: Decodable, Sendable {
        var models: [AgentModel]
        var defaultModel: AgentModel?
        var supportsCustomModelIdentifier: Bool?
    }

    /// The models Xcode has cached for a provider; nil if it has none (or its id in Xcode is unknown).
    static func gatewayModels(of provider: AgentProviderName) -> GatewayModels? {
        guard let agentID = xcodeAgentID(of: provider) else { return nil }
        let domain = "com.apple.dt.Xcode" as CFString
        CFPreferencesAppSynchronize(domain)  // re-read: Xcode may have refreshed it since
        guard let data = CFPreferencesCopyAppValue("IDEChatGatewayModels.\(agentID)" as CFString, domain) as? Data
        else { return nil }
        return try? JSONDecoder().decode(GatewayModels.self, from: data)
    }

    /// Xcode's id for a provider's agent, the suffix of its `IDEChatGatewayModels` key. Only Claude's is known
    /// (`claude-code`, also its `modelIdentifier` in `IDEChatUserSelectedDefaultChatModelDefinitionIdentifier`).
    private static func xcodeAgentID(of provider: AgentProviderName) -> String? {
        switch provider {
        case .claude: "claude-code"
        default: nil
        }
    }
}
