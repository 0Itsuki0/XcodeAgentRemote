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
/// `POST /message` runs an agent that can use tools on this Mac, so it is not exposed to the network.
///
/// - `GET /health` → `{"status": "ok"}`
/// - `GET /projects` → `[XcodeProject]` (`XcodeChat.listProjects`)
/// - `GET /conversation/<Xcode chat UUID>` → `XcodeConversationDetail` (`XcodeChat.conversation`): the conversation, its
///   history and its project; 404 no such chat, 501 not implemented
/// - `POST /message` with `MessageRequest` (Swift's Codable JSON; `project` is a file URL):
///   - `.prompt` → SSE stream of the turn's events (`sendMessage`), until the turn waits for the user's answer
///     (the stream ends with that tool use, which has no result yet) or the turn ends:
///     ```
///     {"prompt": {"prompt": "…", "target": {"conversation": {"id": "<Xcode chat UUID>", "project": "file:///…"}},
///                 "permissionModeOverride": "manual", "permissionTimeout": 600}}
///     ```
///     Each `ChatEvent` is sent as `event: <its type>` + `data: <its JSON>`. If the turn fails, an `event: error`
///     with `{"message": …}` is sent.
///   - `.answer` → the user's answer (`UserAnswer`: permission, questions, plan) goes to the turn waiting for it,
///     and the response continues that turn's stream from where the previous response ended, again until the next
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
            router: Self.router(authHeader: authHeader),
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

    private static func router(authHeader: AuthHeader?) -> Router<
        BasicRequestContext
    > {
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

        // For when iCloud syncing fails: the chats and their histories, read directly from this Mac.
        router.get(RouterPath(APIServerConstants.projectsPath)) { _, _ in
            logger.info(
                category: category,
                message: "GET /\(APIServerConstants.projectsPath)"
            )
            return ChatStore.listProjects()
        }

        router.get(
            RouterPath("\(APIServerConstants.conversationPath)/:conversation")
        ) { _, context -> XcodeConversationDetail in
            logger.info(
                category: category,
                message:
                    "GET /\(APIServerConstants.conversationPath)/:conversation"
            )
            let conversationID = try context.parameters.require("conversation")
            do {
                return try ChatStore.conversation(id: conversationID)
            } catch let error as ChatStoreError {
                switch error {
                case .notImplemented:
                    throw HTTPError(
                        .notImplemented,
                        message: error.localizedDescription
                    )
                case .chatNotFound, .unknownProvider, .sessionMissing,
                    .transcriptMissing:
                    throw HTTPError(
                        .notFound,
                        message: error.localizedDescription
                    )
                }
            }
        }

        // TODO: - addd a POST /conversation/:conversation/watch

        router.post(RouterPath(APIServerConstants.messagePath)) {
            request,
            context -> Response in
            logger.info(
                category: category,
                message: "POST /\(APIServerConstants.messagePath)"
            )

            let body = try await request.decode(
                as: MessageRequest.self,
                context: context
            )

            switch body {
            case .answer(let answer):
                guard isWaitingForUser(toolUseID: answer.toolUseID) else {
                    throw HTTPError(
                        .notFound,
                        message: SendMessageError.noWaitingRequest(
                            toolUseID: answer.toolUseID
                        ).localizedDescription
                    )
                }
                return streamResponse(answerUserRequest(answer))
            case .prompt(
                let prompt,
                let target,
                let permissionModeOverride,
                let permissionTimeout
            ):
                return streamResponse(
                    sendMessage(
                        prompt,
                        to: target,
                        permissionModeOverride: permissionModeOverride,
                        permissionTimeout: permissionTimeout
                    )
                )
            }
        }

        return router
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

extension SuccessResponse: ResponseEncodable {}
extension XcodeProject: ResponseEncodable {}
extension XcodeConversationDetail: ResponseEncodable {}
extension ChatEvent: ResponseEncodable {}

/// Rejects (401) every request that does not carry `APIServerConstants.authHeader` with its exact value.
/// An invalid header name rejects every request.
nonisolated struct AuthHeaderMiddleware<Context: RequestContext>:
    RouterMiddleware
{
    let name: HTTPField.Name?
    let value: String

    init(_ authHeader: AuthHeader) {
        self.name = HTTPField.Name(authHeader.name)
        self.value = authHeader.value
    }

    @concurrent func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let name, let received = request.headers[name],
            Self.constantTimeEqual(received, value)
        else {
            throw HTTPError(.unauthorized)
        }
        return try await next(request, context)
    }

    /// Compares without stopping at the first difference, so response timing doesn't reveal how much of a guess matched.
    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool
    {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |=
                (index < a.count ? a[index] : 0)
                ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}
