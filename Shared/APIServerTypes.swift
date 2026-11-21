//
//  APIServerType.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/21.
//

import Foundation

/// A header name and the exact value required (`APIServerConstants.authHeader`).
nonisolated struct AuthHeader: Codable, Hashable, Sendable {
    /// Header name, e.g. "Authorization" or "X-Api-Key".
    var name: String
    /// The exact value required, e.g. "Bearer <secret>".
    var value: String
}

nonisolated struct SuccessResponse: Codable, Sendable {
    let status: String
    
    init() {
        self.status = "ok"
    }
}

/// The JSON body of an error: `{"error": {"message": …}}` for a failed request (Hummingbird's format),
/// and `{"message": …}` as the data of an SSE `error` event.
nonisolated struct ErrorResponse: Codable, Sendable {
    struct Body: Codable, Sendable {
        var message: String
    }
    var error: Body
}

/// One agent provider (`GET /providers`): whether this app supports it, and the models the provider itself offers.
nonisolated struct AgentProviderInfo: Codable, Sendable {
    var name: AgentProviderName
    /// This app can run its chats (it has a provider for it).
    var supported: Bool
    /// The models the provider offers, as Xcode last got them from its agent; empty if Xcode has none for it.
    var models: [AgentModel]
    /// The model used when none is chosen.
    var defaultModel: AgentModel?
    /// A model id other than the listed ones can be given.
    var supportsCustomModelIdentifier: Bool
}

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
