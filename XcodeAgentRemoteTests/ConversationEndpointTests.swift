//
//  ConversationEndpointTests.swift
//  XcodeAgentRemoteTests
//
//  `POST /conversations` (a new chat with the client's id, and its first prompt) and
//  `POST /conversations/:conversationID/messages`, through the server.
//  The new chat is created in the Demo10 project (`ScenarioTests.project`).
//

#if os(macOS)
import Foundation
import Testing
@testable import XcodeAgentRemote

@Suite(.serialized)
struct ConversationEndpointTests {
    private static func withServer(_ body: (URL) async throws -> Void) async throws {
        let server = APIServer(
            watchingConversations: { [] },
            watchConversation: { _ in },
            stopWatchingConversation: { _ in }
        )
        let port = try await server.start(port: 0)
        do {
            try await body(URL(string: "http://127.0.0.1:\(port)")!)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private static func post<Body: Encodable>(_ url: URL, _ body: Body) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func conversationsURL(_ base: URL) -> URL {
        base.appending(path: APIServerConstants.conversationsPath)
    }

    private static func messagesURL(_ base: URL, conversationID: String) -> URL {
        base.appending(path: APIServerConstants.path(APIServerConstants.messagePath, conversationID: conversationID))
    }

    private static func create(id: String, project: URL = ScenarioTests.project, prompt: String = "hi")
        -> CreateConversationRequest
    {
        CreateConversationRequest(
            id: id, project: project, agent: .claude, prompt: prompt, permissionModeOverride: .auto)
    }

    private static func status(_ request: URLRequest) async throws -> Int? {
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// The turn's events from an SSE response; fails on an `error` event.
    private static func events(_ request: URLRequest) async throws -> [ChatEvent] {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var events: [ChatEvent] = []
        var eventName: String?
        for try await line in bytes.lines {
            if line.hasPrefix("event: ") {
                eventName = String(line.dropFirst("event: ".count))
            } else if line.hasPrefix("data: ") {
                let json = Data(line.dropFirst("data: ".count).utf8)
                try #require(eventName != APIServerConstants.errorEvent, "\(String(decoding: json, as: UTF8.self))")
                events.append(try JSONDecoder().decode(ChatEvent.self, from: json))
            }
        }
        return events
    }

    private static func reply(_ events: [ChatEvent]) -> String {
        events.compactMap { if case .assistantMessage(let text) = $0 { text } else { nil } }.joined()
    }

    @Test func createInUnknownProjectIs404() async throws {
        try await Self.withServer { base in
            let request = try Self.post(
                Self.conversationsURL(base),
                Self.create(id: UUID().uuidString, project: URL(filePath: "/nonexistent/App.xcodeproj")))
            #expect(try await Self.status(request) == 404)
        }
    }

    @Test func createWithInvalidIDIs400() async throws {
        try await Self.withServer { base in
            let request = try Self.post(Self.conversationsURL(base), Self.create(id: "not-a-uuid"))
            #expect(try await Self.status(request) == 400)
        }
    }

    /// An existing chat's id, in another case than Xcode's.
    @Test func createWithExistingIDIs409() async throws {
        try await Self.withServer { base in
            let request = try Self.post(
                Self.conversationsURL(base), Self.create(id: SendMessageTests.conversationID.lowercased()))
            #expect(try await Self.status(request) == 409)
        }
    }

    @Test func messageToUnknownChatIs404() async throws {
        try await Self.withServer { base in
            let request = try Self.post(
                Self.messagesURL(base, conversationID: "00000000-0000-0000-0000-000000000000"),
                MessageRequest.prompt(prompt: "hi"))
            #expect(try await Self.status(request) == 404)
        }
    }

    /// A new chat with a lowercase id the client chose: its first turn runs, it is found by that id (named after the
    /// prompt), and its next message goes to `/conversations/<id>/messages`.
    @Test func startThenContinue() async throws {
        try await Self.withServer { base in
            let id = UUID().uuidString.lowercased()
            let first = "Reply with only the word pong."
            let events = try await Self.events(
                try Self.post(Self.conversationsURL(base), Self.create(id: id, prompt: first)))
            #expect(Self.reply(events).lowercased().contains("pong"))

            let conversation = try ChatStore.conversation(id: id)
            #expect(ChatStore.sameID(conversation.id, id))
            #expect(conversation.name == first)
            #expect(conversation.provider == .claude)

            let second = "Reply with only the word ping."
            let next = try await Self.events(
                try Self.post(
                    Self.messagesURL(base, conversationID: id),
                    MessageRequest.prompt(prompt: second, permissionModeOverride: .auto)))
            #expect(Self.reply(next).lowercased().contains("ping"))
            #expect(try ChatStore.conversation(id: id).history.contains(.userMessage(second)))
        }
    }
}
#endif
