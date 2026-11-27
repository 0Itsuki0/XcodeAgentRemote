//
//  APIServerType.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/21.
//

import Foundation

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

/// The request body of `POST /conversations/<id>/watch`: start (true) or stop (false) watching the conversation.
nonisolated struct WatchRequest: Codable, Sendable {
    var watch: Bool
}

/// Response to `GET /providers`: `[AgentProviderInfo]`
/// One agent provider: whether this app supports it, and the models the provider itself offers.
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

/// Request to `POST /conversations`: a new chat and its first prompt. Its later messages, and the answers to its
/// requests (the first turn's too), go to `POST /conversations/<id>/messages`.
nonisolated struct CreateConversationRequest: Codable, Sendable {
    /// The new chat's id, chosen by the client: a UUID, in any case.
    var id: String
    /// The project (`.xcodeproj` / `.xcworkspace`) the chat belongs to, as a file URL.
    var project: URL
    var agent: AgentProviderName
    /// nil: the start of the prompt.
    var name: String? = nil
    var prompt: String
    var permissionModeOverride: PermissionMode? = nil
    /// Seconds a request to the user (permission, questions, plan) waits for its answer before it is denied; nil: 600.
    var permissionTimeout: TimeInterval? = nil
}

/// Request to `POST /conversations/<id>/messages`
nonisolated enum MessageRequest: Codable, Sendable {
    /// `project`: the project (`.xcodeproj` / `.xcworkspace`) the chat belongs to, as a file URL.
    /// Seconds a request to the user (permission, questions, plan) waits for its answer before it is denied; nil: 600.
    case prompt(
        prompt: String,
        project: URL,
        permissionModeOverride: PermissionMode? = nil,
        permissionTimeout: TimeInterval? = nil
    )

    case answer(ChatEvent.UserResponse)
}

/// Manual / Auto, to override Xcode's setting for one message.
nonisolated enum PermissionMode: String, Identifiable, Codable, Sendable,
    Hashable, Equatable,
    CaseIterable
{
    case manual, auto

    var id: String { self.rawValue }
}
