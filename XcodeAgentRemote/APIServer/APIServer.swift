//
//  APIServer.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

import Foundation
import HTTPTypes
import Hummingbird
import Logging
import ServiceLifecycle

nonisolated private let logger = Logger.shared
nonisolated private let category = Logger.category(#fileID)

/// HTTP server (Hummingbird), listening on localhost only:
/// - `GET /health` → `{"status": "ok"}`
/// - `GET /projects` → `[XcodeProject]` (`ChatStore.listProjects`)
/// - `GET /conversations/<Xcode chat UUID>` → `XcodeConversationDetail` (`ChatStore.conversation`): the conversation, its
///   history and its project; 404 no such chat, 501 not implemented
/// - `POST /conversations/<Xcode chat UUID>/watch` with `WatchRequest` (`{"watch": true}` / `{"watch": false}`) →
///   `{"status": "ok"}` once the Mac started (or stopped) watching the conversation's session (`watchConversation`); 404 no
///   such chat or its transcript is missing, 501 not implemented. Listed conversations carry `isWatching`.
/// - `POST /conversations/<Xcode chat UUID>/read` → `{"status": "ok"}` once the chat is marked read in Xcode's navigator
///   (`ChatStore.markRead`); 404 no such chat.
/// - `POST /conversations` with `CreateConversationRequest` (`project` is a file URL): a new chat with the client's id
///   (a UUID, any case) and its first prompt → SSE stream of the first turn, like a `.prompt` below; the answers to its
///   requests go to `/conversations/<id>/messages`. Before the stream: 400 the id is not a UUID, 409 it is already a
///   chat's, 404 the project doesn't exist, 501 not implemented:
///     ```
///     {"id": "<UUID>", "project": "file:///…/App.xcodeproj", "agent": "claude", "name": "…", "prompt": "…",
///      "permissionModeOverride": "manual", "permissionTimeout": 600}
///     ```
/// - `POST /conversations/<Xcode chat UUID>/messages` with `MessageRequest` (Swift's Codable JSON):
///   - `.prompt` → SSE stream of the turn's events (`sendMessage`), until the turn waits for the user's answer
///     (the stream ends with that `user_request`) or the turn ends. The prompt is not echoed. 404 no such chat:
///     ```
///     {"prompt": {"prompt": "…", "permissionModeOverride": "manual", "permissionTimeout": 600}}
///     ```
///     Each `ChatEvent` is sent as `event: <its type>` + `data: <its JSON>`. If the turn fails, an `event: error`
///     with `{"message": …}` is sent.
///   - `.answer` → the user's answer (`ChatEvent.UserResponse`: permission, questions, plan) goes to the turn waiting for it,
///     and the response continues that turn's stream from where the previous response ended (the answer is not
///     echoed; an allowed permission's `tool_result` comes next, other answers have none), again until the next
///     request to the user or the end. If no running turn waits for it but a chat's history does (the turn ended
///     before it was answered), that chat is resumed with the answer and the response streams it (`answerUserRequest`);
///     404 if no turn is waiting for that tool use:
///     ```
///     {"answer": {"_0": {"permission": {"toolUseID": "…", "allow": true}}}}
///     ```
///   The turn does not depend on the client: if the connection closes, the turn still runs to completion and is saved.
///
/// If `APIServerConstants.authHeader` is set, every request must carry that header with that exact value, or it is
/// rejected with 401.
actor APIServer {

    private var group: ServiceGroup?
    private var task: Task<Void, Error>?
    /// The port the server runs on, once it is running.
    private var runningPort: Task<Int, Error>?

    /// On stop, how long open requests (e.g. a turn's stream) may take before they are closed.
    private static let maximumShutdownDuration: Duration = .seconds(2)

    /// The ids of the watched conversations (`isWatching`).
    private let watchingConversations: @Sendable () -> [String]
    /// Starts watching a conversation (`POST /conversations/<id>/watch`); throws if it can't.
    private let watchConversation: @Sendable (String) async throws -> Void
    /// Stops watching a conversation.
    private let stopWatchingConversation: @Sendable (String) async -> Void

    init(
        watchingConversations: @Sendable @escaping () -> [String],
        watchConversation: @Sendable @escaping (String) async throws -> Void,
        stopWatchingConversation: @Sendable @escaping (String) async -> Void
    ) {
        self.watchingConversations = watchingConversations
        self.watchConversation = watchConversation
        self.stopWatchingConversation = stopWatchingConversation
    }

    // MARK: - Start server

    /// Starts listening on `127.0.0.1:<port>` and returns the port once the server is running
    /// (port 0 picks a free one). If the server is already running (or starting), returns its port.
    /// Throws only if the server cannot run, e.g. the port is in use.
    ///
    /// `authHeader`:
    /// Optional header every request must carry, e.g. `AuthHeader(name: "Authorization", value: "Bearer <secret>")`.
    /// When set, the server rejects requests without it (401) and the iOS client sends it with every request.
    /// `nil`: no check.
    @discardableResult
    func start(
        port: Int = APIServerConstants.defaultPort,
        authHeader: AuthHeader? = nil
    ) async throws -> Int {
        if let runningPort {
            return try await runningPort.value
        }

        let (running, runningContinuation) = AsyncStream<Int>.makeStream()
        let app = Application(
            router: Self.router(
                authHeader: authHeader,
                watchingConversations: watchingConversations,
                watchConversation: watchConversation,
                stopWatchingConversation: stopWatchingConversation
            ),
            configuration: .init(address: .hostname("127.0.0.1", port: port)),
            onServerRunning: { channel in
                runningContinuation.yield(channel.localAddress?.port ?? port)
                runningContinuation.finish()
            }
        )
        var configuration = ServiceGroupConfiguration(
            services: [app],
            logger: Logging.Logger(label: Logger.subsystem)
        )
        configuration.gracefulShutdownSignals = []
        configuration.cancellationSignals = []
        configuration.maximumGracefulShutdownDuration =
            Self.maximumShutdownDuration
        let group = ServiceGroup(configuration: configuration)
        let task = Task {
            defer { runningContinuation.finish() }
            try await group.run()
        }
        let runningPort = Task {
            for await boundPort in running {
                return boundPort
            }
            // Stopped before it was running: report why.
            try await task.value
            throw CancellationError()
        }
        self.group = group
        self.task = task
        self.runningPort = runningPort

        do {
            return try await runningPort.value
        } catch {
            if self.runningPort == runningPort {
                self.group = nil
                self.task = nil
                self.runningPort = nil
            }
            throw error
        }
    }

    // MARK: - Stop server

    /// Stops the server and waits until it has stopped: no new connections, open requests get
    /// `maximumShutdownDuration` to finish, then they are closed. Turns still running continue until they finish.
    func stop() async {
        guard let group, let task else { return }
        self.group = nil
        self.task = nil
        self.runningPort = nil
        await group.triggerGracefulShutdown()
        _ = try? await task.value
    }

    var isRunning: Bool { task != nil }

    // MARK: - Routes

    private static func router(
        authHeader: AuthHeader?,
        watchingConversations: @Sendable @escaping () -> [String],
        watchConversation: @Sendable @escaping (String) async throws -> Void,
        stopWatchingConversation: @Sendable @escaping (String) async -> Void
    ) -> Router<BasicRequestContext> {
        let router = Router()

        if let authHeader {
            router.add(middleware: AuthHeaderMiddleware(authHeader))
        }

        router.get(RouterPath(APIServerConstants.healthPath)) { _, _ in
            logger.info(
                category: category,
                message: "GET /\(APIServerConstants.healthPath)"
            )
            return SuccessResponse()
        }

        router.get(RouterPath(APIServerConstants.projectsPath)) { _, _ in
            logger.info(
                category: category,
                message: "GET /\(APIServerConstants.projectsPath)"
            )
            let watching = watchingConversations()
            return ChatStore.listProjects().map { project in
                var project = project
                project.conversations = project.conversations.map {
                    conversation in
                    var conversation = conversation
                    conversation.isWatching = isWatching(
                        conversation.id,
                        in: watching
                    )
                    return conversation
                }
                return project
            }
        }

        router.get(RouterPath(APIServerConstants.conversationPath)) {
            _,
            context -> XcodeConversationDetail in
            logger.info(
                category: category,
                message: "GET /\(APIServerConstants.conversationPath)"
            )
            let conversationID = try context.parameters.require(
                APIServerConstants.conversationIDParameter
            )
            do {
                var conversation = try ChatStore.conversation(
                    id: conversationID
                )
                conversation.isWatching = isWatching(
                    conversation.id,
                    in: watchingConversations()
                )
                return conversation
            } catch let error as XcodeChatError {
                throw httpError(error)
            }
        }

        router.get(RouterPath(APIServerConstants.providersPath)) { _, _ in
            logger.info(
                category: category,
                message: "GET /\(APIServerConstants.providersPath)"
            )
            return AgentProviders.infos()
        }

        router.post(RouterPath(APIServerConstants.readPath)) {
            _,
            context -> SuccessResponse in
            logger.info(
                category: category,
                message: "POST /\(APIServerConstants.readPath)"
            )
            let conversationID = try context.parameters.require(
                APIServerConstants.conversationIDParameter
            )
            do {
                try ChatStore.markRead(conversationID: conversationID)
            } catch let error as XcodeChatError {
                throw httpError(error)
            }
            return SuccessResponse()
        }

        router.post(RouterPath(APIServerConstants.watchPath)) {
            request,
            context -> SuccessResponse in
            logger.info(
                category: category,
                message: "POST /\(APIServerConstants.watchPath)"
            )
            let conversationID = try context.parameters.require(
                APIServerConstants.conversationIDParameter
            )
            let body = try await request.decode(
                as: WatchRequest.self,
                context: context
            )
            guard body.watch else {
                await stopWatchingConversation(conversationID)
                return SuccessResponse()
            }
            do {
                try await watchConversation(conversationID)
            } catch let error as XcodeChatError {
                throw httpError(error)
            } catch let error as FileWatcherError {
                // The session's transcript could not be opened.
                throw HTTPError(.notFound, message: "\(error)")
            }
            return SuccessResponse()
        }

        router.post(RouterPath(APIServerConstants.conversationsPath)) {
            request,
            context -> Response in
            logger.info(
                category: category,
                message: "POST /\(APIServerConstants.conversationsPath)"
            )
            let body = try await request.decode(
                as: CreateConversationRequest.self,
                context: context
            )
            // Checked before the stream starts, so these come back as the response's status.
            do throws(XcodeChatError) {
                _ = try XcodeChat.checkNewConversation(
                    id: body.id,
                    project: body.project,
                    agent: body.agent
                )
            } catch {
                throw httpError(error)
            }
            return streamResponse(
                XcodeChat.sendMessage(
                    body.prompt,
                    to: .newConversation(
                        project: body.project,
                        agent: body.agent,
                        name: body.name,
                        id: body.id
                    ),
                    permissionModeOverride: body.permissionModeOverride,
                    permissionTimeout: body.permissionTimeout
                )
            )
        }

        router.post(RouterPath(APIServerConstants.messagePath)) {
            request,
            context -> Response in
            logger.info(
                category: category,
                message: "POST /\(APIServerConstants.messagePath)"
            )
            let conversationID = try context.parameters.require(
                APIServerConstants.conversationIDParameter
            )
            let body = try await request.decode(
                as: MessageRequest.self,
                context: context
            )

            switch body {
            case .answer(let answer):
                guard RunningTurns.isWaitingForUser(toolUseID: answer.toolUseID)
                else {
                    throw HTTPError(
                        .notFound,
                        message: XcodeChatError.noWaitingRequest(
                            toolUseID: answer.toolUseID
                        ).localizedDescription
                    )
                }
                return streamResponse(XcodeChat.answerUserRequest(answer))
            case .prompt(
                let prompt,
                let permissionModeOverride,
                let permissionTimeout
            ):
                let store: URL
                do throws(XcodeChatError) {
                    store = try ChatStore.chatStore(conversationID: conversationID)
                } catch {
                    throw httpError(error)
                }
                return streamResponse(
                    XcodeChat.sendMessage(
                        prompt,
                        to: .conversationInStore(id: conversationID, store: store.path),
                        permissionModeOverride: permissionModeOverride,
                        permissionTimeout: permissionTimeout
                    )
                )
            }
        }

        return router
    }

    /// The response to a `XcodeChatError`: 501 not implemented for the chat's agent, 404 anything else.
    private static func httpError(_ error: XcodeChatError) -> HTTPError {
        switch error {
        case .agentNotImplemented(_):
            HTTPError(.notImplemented, message: error.localizedDescription)
        case .chatNotFound, .unknownAgent(conversationID: _), .sessionMissing,
            .transcriptMissing, .projectNotFound(_), .storeNotFound(_),
            .projectFileNotFound(store: _):
            HTTPError(.notFound, message: error.localizedDescription)
        case .agentFailed(_):
            HTTPError(.internalServerError, message: error.localizedDescription)
        case .conversationRunning(conversationID: _):
            HTTPError(.conflict, message: error.localizedDescription)
        case .noWaitingRequest(toolUseID: _), .invalidConversationID(_):
            HTTPError(.badRequest, message: error.localizedDescription)
        case .conversationExists(id: _):
            HTTPError(.conflict, message: error.localizedDescription)
        }
    }

    /// The conversation is among the watched ones (the same chat UUID, in any case).
    private static func isWatching(_ id: String, in watching: [String])
        -> Bool
    {
        watching.contains { ChatStore.sameID($0, id) }
    }

    /// An SSE response streaming a turn's events (`sendMessage` / `answerUserRequest`): each `ChatEvent` as
    /// `event: <type>` + `data: <json>`, and an `event: error` if the turn fails. The turn doesn't depend on it: if the
    /// client disconnects, only this response ends.
    private static func streamResponse(
        _ events: AsyncThrowingStream<ChatEvent, Error>
    ) -> Response {
        let body = ResponseBody { writer in
            do {
                for try await event in events {
                    try await writer.write(
                        serverSentEvent(
                            event.type,
                            try JSONEncoder().encode(event)
                        )
                    )
                }
            } catch {
                let message =
                    (try? JSONEncoder().encode(
                        ErrorResponse.Body(message: error.localizedDescription)
                    )) ?? Data("{}".utf8)
                try await writer.write(
                    serverSentEvent(APIServerConstants.errorEvent, message)
                )
            }
            try await writer.finish(nil)
        }
        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream", .cacheControl: "no-cache",
            ],
            body: body
        )
    }

    /// One SSE message: `event: <type>` + `data: <json>` + blank line.
    private static func serverSentEvent(_ type: String, _ json: Data)
        -> ByteBuffer
    {
        var buffer = ByteBuffer(string: "event: \(type)\ndata: ")
        buffer.writeBytes(json)
        buffer.writeString("\n\n")
        return buffer
    }

}

