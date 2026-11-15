//
//  ServerRequest.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

import Foundation

nonisolated enum ServerRequestError: Error, LocalizedError {
    /// The server sent an `error` event: the turn failed.
    case turnFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .turnFailed(let message): "The turn failed: \(message)"
        }
    }
}

/// Requests to the macOS app's server (`AgentServer`, see `AgentServerAPI`).
nonisolated struct AgentServerClient: Sendable {
    /// The server, e.g. `http://192.168.0.4:8765`.
    var baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// The server at `http://<host>:<port>`.
    init(host: String, port: Int = AgentServerAPI.defaultPort) throws {
        guard let url = URL(string: "http://\(host):\(port)") else { throw NetworkError.failToCreateURL }
        self.baseURL = url
    }

    /// `GET /health`
    func health() async throws -> SuccessResponse {
        let data = try await NetworkService.sendURLRequest(
            url: baseURL.appending(path: AgentServerAPI.healthPath),
            method: "GET",
            headers: Self.headers(["Accept": "application/json"]),
            body: nil
        )
        return try NetworkService.decode(SuccessResponse.self, from: data)
    }

    /// `GET /projects`: every project with Xcode chats on the Mac, with its chats (for when iCloud syncing fails).
    func projects() async throws -> [XcodeProject] {
        let data = try await NetworkService.sendURLRequest(
            url: baseURL.appending(path: AgentServerAPI.projectsPath),
            method: "GET",
            headers: Self.headers(["Accept": "application/json"]),
            body: nil
        )
        return try NetworkService.decode([XcodeProject].self, from: data)
    }

    /// `GET /history/<Xcode chat UUID>`: a chat's history (for when iCloud syncing fails).
    /// Throws `NetworkError.badResponse` with 404 if there is no such chat, 501 if not implemented for its agent.
    func history(conversationID: String) async throws -> [ChatEvent] {
        let data = try await NetworkService.sendURLRequest(
            url: baseURL.appending(path: AgentServerAPI.historyPath).appending(path: conversationID),
            method: "GET",
            headers: Self.headers(["Accept": "application/json"]),
            body: nil
        )
        return try NetworkService.decode([ChatEvent].self, from: data)
    }

    /// `POST /message` (`.prompt`): sends one message, the same parameters as the macOS app's `sendMessage`, and
    /// streams the turn's events as they arrive (the prompt, then intermediate output, assistant messages, tool uses
    /// and tool results).
    /// The stream ends when the turn ends, or when it waits for the user's answer (a permission, questions, a plan):
    /// then its last tool use has no result (`waitingForUser`), and `answer(_:)` continues the turn's stream.
    /// Throws `ServerRequestError.turnFailed` if the server reports the turn failed, `NetworkError` for HTTP or
    /// connection errors. Cancelling (or dropping) the stream only closes this connection: the turn keeps running
    /// on the Mac until it finishes.
    func sendMessage(
        _ prompt: String,
        to target: MessageTarget,
        permissionModeOverride: PermissionMode? = nil,
        permissionTimeout: TimeInterval? = nil
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        events(for: .prompt(
            prompt: prompt,
            target: target,
            permissionModeOverride: permissionModeOverride,
            permissionTimeout: permissionTimeout
        ))
    }

    /// `POST /message` (`.answer`): answers the request the turn waits for (`waitingForUser`), and continues the
    /// turn's stream from where the previous one (`sendMessage`, or the previous `answer`) ended: until the next
    /// request to the user or the end of the turn, like `sendMessage`.
    /// Throws `NetworkError.badResponse` with code 404 if no turn is waiting for tool use `answer.toolUseID`.
    func answer(_ answer: UserAnswer) -> AsyncThrowingStream<ChatEvent, Error> {
        events(for: .answer(answer))
    }

    /// Sends a `POST /message` and streams the turn's events from its SSE response.
    private func events(for request: MessageRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let url = baseURL.appending(path: AgentServerAPI.messagePath)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await NetworkService.streamURLRequest(
                        url: url,
                        method: "POST",
                        headers: Self.headers(["Content-Type": "application/json", "Accept": "text/event-stream"]),
                        body: try NetworkService.encode(request)
                    )
                    // SSE: `event: <name>` then `data: <json>` per event. The server sends one data line per event,
                    // so an event is complete at its data line. Blank lines and `:` comments carry nothing.
                    var eventName: String?
                    for try await line in bytes.lines {
                        if let name = Self.field("event", in: line) {
                            eventName = name
                        } else if let data = Self.field("data", in: line) {
                            if eventName == AgentServerAPI.errorEvent {
                                let error = try NetworkService.decode(ErrorResponse.Body.self, from: data)
                                throw ServerRequestError.turnFailed(message: error.message)
                            }
                            continuation.yield(try NetworkService.decode(ChatEvent.self, from: data))
                            eventName = nil
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The request's headers, plus `AgentServerAPI.authHeader` if it is set.
    private static func headers(_ headers: [String: String]) -> [String: String] {
        guard let authHeader = AgentServerAPI.authHeader else { return headers }
        return headers.merging([authHeader.name: authHeader.value]) { _, auth in auth }
    }

    /// The value of an SSE field line `<name>: <value>` (one optional space after the colon), or nil.
    private static func field(_ name: String, in line: String) -> String? {
        guard line.hasPrefix(name + ":") else { return nil }
        let value = line.dropFirst(name.count + 1)
        return String(value.hasPrefix(" ") ? value.dropFirst() : value)
    }
}
