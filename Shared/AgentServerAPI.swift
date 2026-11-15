//
//  AgentServerAPI.swift
//  XcodeAgentRemote
//
//  The macOS app's HTTP server API, shared by the server (macOS) and its client (iOS).
//

import Foundation

nonisolated enum AgentServerAPI {
    static let defaultPort = 8765

    /// `GET /health` → `HealthResponse`
    static let healthPath = "health"
    /// `POST /message` with a `MessageRequest` body → SSE stream of `ChatEvent`s (event name = `ChatEvent.type`),
    /// or an `errorEvent` if the turn fails.
    static let messagePath = "message"
    /// SSE event name sent instead of the remaining events when a turn fails; data is `ErrorResponse.Body`.
    static let errorEvent = "error"

    /// Optional header every request must carry, e.g. `AuthHeader(name: "Authorization", value: "Bearer <secret>")`.
    /// When set, the server rejects requests without it (401) and the iOS client sends it with every request.
    /// `nil`: no check.
    static let authHeader: AuthHeader? = nil
}

/// A header name and the exact value required (`AgentServerAPI.authHeader`).
nonisolated struct AuthHeader: Codable, Hashable, Sendable {
    /// Header name, e.g. "Authorization" or "X-Api-Key".
    var name: String
    /// The exact value required, e.g. "Bearer <secret>".
    var value: String
}

/// Response of `GET /health`.
nonisolated struct HealthResponse: Codable, Sendable {
    var status: String
}

/// The JSON body of an error: `{"error": {"message": …}}` for a failed request (Hummingbird's format),
/// and `{"message": …}` as the data of an SSE `error` event.
nonisolated struct ErrorResponse: Codable, Sendable {
    struct Body: Codable, Sendable {
        var message: String
    }
    var error: Body
}
