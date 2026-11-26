//
//  APIServerConstants.swift
//  XcodeAgentRemote
//
//  The macOS app's HTTP server API, shared by the server (macOS) and its client (iOS).
//

import Foundation

nonisolated enum APIServerConstants {
    static let defaultPort = 8000

    // MARK: - Paths

    /// `GET /health` → `SuccessResponse`
    static let healthPath = "health"
    /// `POST /conversations` with a `CreateConversationRequest` body: a new chat with the client's id, and its first
    /// prompt → SSE stream of the first turn's events, like `messagePath`'s `.prompt` (its answers go to `messagePath`).
    /// Before the stream: 400 if the id is not a UUID, 409 if it is already a chat's, 404 if the project doesn't exist,
    /// 501 if its agent is not implemented.
    static let conversationsPath = "conversations"
    /// `POST /conversations/<Xcode chat UUID>/messages` with a `MessageRequest` body: `.prompt` → SSE stream of
    /// `ChatEvent`s (event name = `ChatEvent.type`), or an `errorEvent` if the turn fails, 404 if there is no such chat;
    /// `.answer` → the same turn's events, continued, or 404.
    static let messagePath = "conversations/:\(conversationIDParameter)/messages"
    /// `GET /projects` → `[XcodeProject]`: every project with Xcode chats, with its conversations, no histories
    /// (`ChatStore.listProjects`).
    static let projectsPath = "projects"
    /// `GET /conversations/<Xcode chat UUID>` → `XcodeConversationDetail`: one conversation in full, with its history
    /// and its project (`ChatStore.conversation(id:)`). 404 if there is no such chat (or its session is missing), 501
    /// if history is not implemented for its agent.
    static let conversationPath = "conversations/:\(conversationIDParameter)"
    /// `POST /conversations/<Xcode chat UUID>/watch` with a `WatchRequest` body → `SuccessResponse` once the Mac started
    /// (or stopped) watching the conversation's session. 404 if there is no such chat (or its transcript is missing),
    /// 501 if not implemented for its agent.
    static let watchPath = "conversations/:\(conversationIDParameter)/watch"
    /// `POST /conversations/<Xcode chat UUID>/read` → `SuccessResponse` once the chat is marked read in Xcode's
    /// navigator (`isUnread` false). 404 if there is no such chat.
    static let readPath = "conversations/:\(conversationIDParameter)/read"
    /// `GET /providers` → `[AgentProviderInfo]`: every agent provider, whether this app supports it, and the models
    /// the provider offers (`AgentProviders.infos`).
    static let providersPath = "providers"

    // MARK: - Path parameters
    /// The path parameter for Xcode's chat UUID in `conversationPath`, `messagePath`, `watchPath` and `readPath`.
    static let conversationIDParameter = "conversationID"

    /// The path with its `:conversationID` replaced by `conversationID` (what the client requests).
    static func path(_ path: String, conversationID: String) -> String {
        path.replacingOccurrences(
            of: ":\(conversationIDParameter)",
            with: conversationID
        )
    }

    // MARK: - Stream event
    /// SSE event name sent instead of the remaining events when a turn fails; data is `ErrorResponse.Body`.
    static let errorEvent = "error"

}
