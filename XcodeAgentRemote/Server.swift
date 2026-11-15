//
//  Server.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

/// A Server
/// - `POST /message`: send a single message. same parameters as `sendMessage`. SSE event for Async stream.
/// - `GET /health`

import Foundation
import HTTPTypes
import Hummingbird
import Logging
import ServiceLifecycle

/// HTTP server (Hummingbird), listening on localhost only:
/// `POST /message` runs an agent that can use tools on this Mac, so it is not exposed to the network.
///
/// - `GET /health` → `{"status": "ok"}`
/// - `GET /projects` → `[XcodeProject]` (`XcodeChats.listProjects`)
/// - `GET /history/<Xcode chat UUID>` → `[ChatEvent]` (`XcodeChats.history`); 404 no such chat, 501 not implemented
/// - `POST /message` with `MessageRequest` (Swift's Codable JSON; `project` is a file URL):
///   - `.prompt` → SSE stream of the turn's events (`sendMessage`), closed when the turn ends:
///     ```
///     {"prompt": {"prompt": "…", "target": {"conversation": {"id": "<Xcode chat UUID>", "project": "file:///…"}},
///                 "permissionModeOverride": "manual", "permissionTimeout": 600}}
///     ```
///     Each `ChatEvent` is sent as `event: <its type>` + `data: <its JSON>`. If the turn fails, an `event: error`
///     with `{"message": …}` is sent. A tool use waiting for permission waits for its answer.
///   - `.permissionAnswer` → the answer goes to the turn waiting for it, whose stream then continues;
///     responds `{"status": "ok"}`, or 404 if no turn is waiting for that request:
///     ```
///     {"permissionAnswer": {"answer": {"tool_use_id": "…", "behavior": "allow" | "deny"}}}
///     ```
///   The turn does not depend on the client: if the connection closes, the turn still runs to completion and is saved.
///
/// If `AgentServerAPI.authHeader` is set, every request must carry that header with that exact value, or it is
/// rejected with 401.
actor AgentServer {
    static let shared = AgentServer()

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
    @discardableResult
    func start(port: Int = AgentServerAPI.defaultPort) async throws -> Int {
        if let runningPort {
            return try await runningPort.value
        }

        let (running, runningContinuation) = AsyncStream<Int>.makeStream()
        let app = Application(
            router: Self.router(),
            configuration: .init(address: .hostname("127.0.0.1", port: port)),
            onServerRunning: { channel in
                runningContinuation.yield(channel.localAddress?.port ?? port)
                runningContinuation.finish()
            }
        )
        var configuration = ServiceGroupConfiguration(
            services: [app],
            logger: Logger(label: "AgentServer")
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

    private static func router() -> Router<BasicRequestContext> {
        let router = Router()

        if let authHeader = AgentServerAPI.authHeader {
            router.add(middleware: AuthHeaderMiddleware(authHeader))
        }

        router.get(RouterPath(AgentServerAPI.healthPath)) { _, _ in
            HealthResponse(status: "ok")
        }

        // For when iCloud syncing fails: the chats and their histories, read directly from this Mac.
        router.get(RouterPath(AgentServerAPI.projectsPath)) { _, _ in
            XcodeChats.listProjects()
        }

        router.get(RouterPath("\(AgentServerAPI.historyPath)/:conversation")) { _, context -> [ChatEvent] in
            let conversationID = try context.parameters.require("conversation")
            do {
                return try XcodeChats.history(conversationID: conversationID)
            } catch let error as ChatHistoryError {
                switch error {
                case .notImplemented:
                    throw HTTPError(.notImplemented, message: error.localizedDescription)
                case .chatNotFound, .unknownProvider, .sessionMissing, .transcriptMissing:
                    throw HTTPError(.notFound, message: error.localizedDescription)
                }
            }
        }

        router.post(RouterPath(AgentServerAPI.messagePath)) { request, context -> Response in
            let body = try await request.decode(
                as: MessageRequest.self,
                context: context
            )
            let events: AsyncThrowingStream<ChatEvent, Error>
            switch body {
            case .permissionAnswer(let answer):
                // The answer goes to the turn waiting for it; that turn's own stream continues.
                do {
                    try await answerPermissionRequest(answer)
                } catch let error as SendMessageError {
                    throw HTTPError(.notFound, message: error.localizedDescription)
                }
                return try HealthResponse(status: "ok").response(from: request, context: context)
            case .prompt(let prompt, let target, let permissionModeOverride, let permissionTimeout):
                events = sendMessage(
                    prompt,
                    to: target,
                    permissionModeOverride: permissionModeOverride,
                    permissionTimeout: permissionTimeout
                )
            }

            let stream = ResponseBody { writer in
                let (output, outputContinuation) = AsyncStream<ByteBuffer>
                    .makeStream()
                // The turn runs to completion (and is saved) on its own, whether or not the client stays connected:
                // an unstructured task, not tied to this response.
                Task {
                    do {
                        for try await event in events {
                            outputContinuation.yield(
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
                        outputContinuation.yield(
                            serverSentEvent(AgentServerAPI.errorEvent, message)
                        )
                    }
                    outputContinuation.finish()
                }
                // If the client disconnects, writing throws and only this response ends.
                for await chunk in output {
                    try await writer.write(chunk)
                }
                try await writer.finish(nil)
            }
            return Response(
                status: .ok,
                headers: [
                    .contentType: "text/event-stream",
                    .cacheControl: "no-cache",
                ],
                body: stream
            )
        }

        return router
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

extension HealthResponse: ResponseEncodable {}
extension XcodeProject: ResponseEncodable {}
extension ChatEvent: ResponseEncodable {}


/// Rejects (401) every request that does not carry `AgentServerAPI.authHeader` with its exact value.
/// An invalid header name rejects every request.
nonisolated struct AuthHeaderMiddleware<Context: RequestContext>: RouterMiddleware {
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
        guard let name, let received = request.headers[name], Self.constantTimeEqual(received, value) else {
            throw HTTPError(.unauthorized)
        }
        return try await next(request, context)
    }

    /// Compares without stopping at the first difference, so response timing doesn't reveal how much of a guess matched.
    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}
