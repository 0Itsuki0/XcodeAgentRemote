//
//  APIServerConstant.swift
//  XcodeAgentRemote
//
//  The macOS app's HTTP server API, shared by the server (macOS) and its client (iOS).
//

import Foundation

nonisolated enum APIServerConstant {
    static let defaultPort = 8765

    /// `GET /health` → `SuccessResponse`
    static let healthPath = "health"
    /// `POST /message` with a `MessageRequest` body: `.prompt` → SSE stream of `ChatEvent`s (event name =
    /// `ChatEvent.type`), or an `errorEvent` if the turn fails; `.answer` → the same turn's events, continued, or 404.
    static let messagePath = "message"
    /// `GET /projects` → `[XcodeProject]`: every project with Xcode chats, with its conversations, no histories
    /// (`XcodeChat.listProjects`).
    static let projectsPath = "projects"
    /// `GET /conversation/<Xcode chat UUID>` → `XcodeConversationDetail`: one conversation in full, with its history
    /// and its project (`XcodeChat.conversation(id:)`). 404 if there is no such chat (or its session is missing), 501
    /// if history is not implemented for its agent.
    static let conversationPath = "conversation"
    /// SSE event name sent instead of the remaining events when a turn fails; data is `ErrorResponse.Body`.
    static let errorEvent = "error"

}

/// A header name and the exact value required (`APIServerConstant.authHeader`).
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
