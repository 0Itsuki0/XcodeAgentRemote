//
//  APIServerClient.swift
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

/// Requests to the macOS app's server (`APIServer`, see `APIServerConstants`).
nonisolated struct APIServerClient: Sendable {
    /// The server, e.g. `http://192.168.0.4:8765`.
    let baseURL: URL
    let useAuth: Bool
    let authHeaderName: String
    let authHeaderValue: String

    private var authHeader: AuthHeader? {
        useAuth
            ? AuthHeader(
                name: authHeaderName,
                value: authHeaderValue
            ) : nil
    }

    static var saved: APIServerClient? {
        #if DEBGU
            UserDefaultsKey.apiServerURL.setValue(
                value: DebugConstants.ngrokURL
            )
        #endif

        let url = UserDefaultsKey.apiServerURL.getValue() as? String ?? ""

        let useAuth =
            UserDefaultsKey.apiServerUseAuth.getValue() as? Bool ?? false

        let authHeaderName =
            UserDefaultsKey.apiServerAuthHeaderName.getValue() as? String ?? ""
        let authHeaderValue =
            UserDefaultsKey.apiServerAuthHeaderValue.getValue() as? String ?? ""

        return APIServerClient(
            baseURLString: url,
            useAuth: useAuth,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue
        )
    }

    init?(
        baseURLString: String,
        useAuth: Bool,
        authHeaderName: String,
        authHeaderValue: String
    ) {
        guard let baseURL = URL(string: baseURLString) else {
            return nil
        }
        self.init(
            baseURL: baseURL,
            useAuth: useAuth,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue
        )
    }

    init(
        baseURL: URL,
        useAuth: Bool = false,
        authHeaderName: String = "",
        authHeaderValue: String = ""
    ) {
        self.baseURL = baseURL
        self.useAuth = useAuth
        self.authHeaderName = authHeaderName
        self.authHeaderValue = authHeaderValue
    }

    /// The server at `http://<host>:<port>`.
    init?(
        host: String,
        port: Int = APIServerConstants.defaultPort,
        useAuth: Bool = false,
        authHeaderName: String = "",
        authHeaderValue: String = ""
    ) {
        guard let url = URL(string: "http://\(host):\(port)") else {
            return nil
        }
        self.init(
            baseURL: url,
            useAuth: useAuth,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue
        )
    }

    /// `GET /health`
    func health() async throws(NetworkError) -> SuccessResponse {
        let data = try await NetworkService.sendURLRequest(
            url: baseURL.appending(path: APIServerConstants.healthPath),
            method: .get,
            headers: Self.headers(
                Self.jsonResponse,
                authHeader: authHeader
            ),
            body: nil
        )
        return try NetworkService.decode(SuccessResponse.self, from: data)
    }

    /// `GET /projects`: every project with Xcode chats on the Mac, with its chats (for when iCloud syncing fails).
    func projects() async throws(NetworkError) -> [XcodeProject] {
        let data = try await NetworkService.sendURLRequest(
            url: baseURL.appending(path: APIServerConstants.projectsPath),
            method: .get,
            headers: Self.headers(
                Self.jsonResponse,
                authHeader: authHeader
            ),
            body: nil
        )
        return try NetworkService.decode([XcodeProject].self, from: data)
    }

    /// `GET /providers`
    func providers() async throws(NetworkError) -> [AgentProviderInfo] {
        let data = try await NetworkService.sendURLRequest(
            url: baseURL.appending(path: APIServerConstants.providersPath),
            method: .get,
            headers: Self.headers(
                Self.jsonResponse,
                authHeader: authHeader
            ),
            body: nil
        )
        return try NetworkService.decode([AgentProviderInfo].self, from: data)
    }

    /// `GET /conversations/<Xcode chat UUID>`: one conversation in full, with its history and its project (for when
    /// iCloud syncing fails).
    /// Throws `NetworkError.badResponse` with 404 if there is no such chat, 501 if not implemented for its agent.
    func conversation(id: String) async throws(NetworkError)
        -> XcodeConversationDetail
    {
        let data = try await NetworkService.sendURLRequest(
            url: baseURL.appending(
                path: APIServerConstants.path(
                    APIServerConstants.conversationPath,
                    conversationID: id
                )
            ),
            method: .get,
            headers: Self.headers(
                Self.jsonResponse,
                authHeader: authHeader
            ),
            body: nil
        )
        return try NetworkService.decode(
            XcodeConversationDetail.self,
            from: data
        )
    }

    /// `POST /conversations/<Xcode chat UUID>/read`: marks the conversation read in Xcode's navigator; returns once it
    /// did. Throws `NetworkError.badResponse` with 404 if there is no such chat.
    func markRead(conversationID: String) async throws(NetworkError) -> SuccessResponse {
        let data = try await NetworkService.sendURLRequest(
            url: baseURL.appending(
                path: APIServerConstants.path(
                    APIServerConstants.readPath,
                    conversationID: conversationID
                )
            ),
            method: .post,
            headers: Self.headers(Self.jsonResponse, authHeader: authHeader),
            body: nil
        )
        return try NetworkService.decode(SuccessResponse.self, from: data)
    }

    /// `POST /conversations/<Xcode chat UUID>/watch`: starts (`watch` true) or stops watching the conversation on the
    /// Mac; returns once it did. Throws `NetworkError.badResponse` with 404 if there is no such chat (or its transcript
    /// is missing), 501 if not implemented for its agent.
    func watch(conversationID: String, _ watch: Bool) async throws(NetworkError)
        -> SuccessResponse
    {
        let body: Data
        do {
            body = try NetworkService.encode(WatchRequest(watch: watch))
        } catch {
            throw .other(error)
        }
        let data = try await NetworkService.sendURLRequest(
            url: baseURL.appending(
                path: APIServerConstants.path(
                    APIServerConstants.watchPath,
                    conversationID: conversationID
                )
            ),
            method: .post,
            headers: Self.headers(
                Self.jsonRequest,
                authHeader: authHeader
            ),
            body: body
        )
        return try NetworkService.decode(SuccessResponse.self, from: data)
    }

    /// `POST /messages` (`.prompt`): sends one message, the same parameters as the macOS app's `sendMessage`, and
    /// streams the turn's events as they arrive (intermediate output, assistant messages, tool uses, tool results,
    /// requests to the user and their responses; not the prompt: the caller has it).
    /// The stream ends when the turn ends, or when it waits for the user's answer (a permission, questions, a plan):
    /// then its last event is a `.userRequest` (`waitingForUser`), and `answer(_:)` continues the turn's stream.
    /// Throws `ServerRequestError.turnFailed` if the server reports the turn failed, `NetworkError` for HTTP or
    /// connection errors. Cancelling (or dropping) the stream only closes this connection: the turn keeps running
    /// on the Mac until it finishes.
    func sendMessage(
        _ prompt: String,
        to target: MessageTarget,
        permissionModeOverride: PermissionMode? = nil,
        permissionTimeout: TimeInterval? = nil
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        events(
            for: .prompt(
                prompt: prompt,
                target: target,
                permissionModeOverride: permissionModeOverride,
                permissionTimeout: permissionTimeout
            )
        )
    }

    /// `POST /messages` (`.answer`): answers the request the turn waits for (`waitingForUser`), and continues the
    /// turn's stream from where the previous one (`sendMessage`, or the previous `answer`) ended: until the next
    /// request to the user or the end of the turn, like `sendMessage`. The answer is not echoed (keep it as
    /// `.userResponse`); an allowed permission's `.toolResult` comes next, other answers have none.
    /// Throws `NetworkError.badResponse` with code 404 if no turn is waiting for tool use `answer.toolUseID`.
    func answer(_ answer: ChatEvent.UserResponse) -> AsyncThrowingStream<
        ChatEvent, Error
    > {
        events(for: .answer(answer))
    }

    /// Sends a `POST /messages` and streams the turn's events from its SSE response.
    private func events(for request: MessageRequest) -> AsyncThrowingStream<
        ChatEvent, Error
    > {
        let url = baseURL.appending(path: APIServerConstants.messagePath)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await NetworkService.streamURLRequest(
                        url: url,
                        method: .post,
                        headers: Self.headers(
                            Self.eventStreamRequest,
                            authHeader: authHeader
                        ),
                        body: try NetworkService.encode(request)
                    )
                    // SSE: `event: <name>` then `data: <json>` per event. The server sends one data line per event,
                    // so an event is complete at its data line. Blank lines and `:` comments carry nothing.
                    var eventName: String?
                    for try await line in bytes.lines {
                        if let name = Self.field("event", in: line) {
                            eventName = name
                        } else if let data = Self.field("data", in: line) {
                            if eventName == APIServerConstants.errorEvent {
                                let error = try NetworkService.decode(
                                    ErrorResponse.Body.self,
                                    from: data
                                )
                                throw ServerRequestError.turnFailed(
                                    message: error.message
                                )
                            }
                            continuation.yield(
                                try NetworkService.decode(
                                    ChatEvent.self,
                                    from: data
                                )
                            )
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

    /// A request whose response is JSON.
    private static let jsonResponse = ["Accept": "application/json"]
    /// A request with a JSON body, whose response is JSON.
    private static let jsonRequest = ["Content-Type": "application/json", "Accept": "application/json"]
    /// A request with a JSON body, whose response is a stream of server-sent events.
    private static let eventStreamRequest = ["Content-Type": "application/json", "Accept": "text/event-stream"]

    /// The request's headers, plus `APIServerConstants.authHeader` if it is set.
    private static func headers(
        _ headers: [String: String],
        authHeader: AuthHeader?
    ) -> [String: String] {
        guard let authHeader else {
            return headers
        }
        return headers.merging([authHeader.name: authHeader.value]) { _, auth in
            auth
        }
    }

    /// The value of an SSE field line `<name>: <value>` (one optional space after the colon), or nil.
    private static func field(_ name: String, in line: String) -> String? {
        guard line.hasPrefix(name + ":") else { return nil }
        let value = line.dropFirst(name.count + 1)
        return String(value.hasPrefix(" ") ? value.dropFirst() : value)
    }
}
