//
//  SendMessageTests.swift
//  XcodeAgentRemoteTests
//
//  Runs sendMessage against the real agent.
//  These send real turns to an existing chat of the Demo10 project (they are recorded in Xcode's chat store).
//

#if os(macOS)
import Foundation
import Testing
@testable import XcodeAgentRemote

@Suite(.serialized)
struct SendMessageTests {

    /// The Demo10 project (the one `ScenarioTests` uses).
    static let project = ScenarioTests.project
    /// A chat of the Demo10 project (`DebugConstants.conversationId`).
    static let conversationID = "1170A351-FBFE-4317-8FA7-4F65AC6F3B64"

    static func events(_ prompt: String, to target: MessageTarget,
                       permissionModeOverride: PermissionMode? = nil) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in sendMessage(prompt, to: target, permissionModeOverride: permissionModeOverride) {
            events.append(event)
        }
        return events
    }

    @Test func completesTurn() async throws {
        let events = try await Self.events(
            "Reply with only the word pong.",
            to: .conversation(id: Self.conversationID, project: Self.project))

        #expect(!events.contains { if case .userMessage = $0 { true } else { false } })
        let reply = events.compactMap { if case .assistantMessage(let text) = $0 { text } else { nil } }.joined()
        #expect(reply.lowercased().contains("pong"))
        #expect(events.waitingForUser.isEmpty)
    }

    @Test func deniedPermissionRequestInManualMode() async throws {
        let file = URL(filePath: NSTemporaryDirectory()).appending(path: "permission-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        var events: [ChatEvent] = []
        var answered = Set<String>()
        // Each stream ends where the turn waits for the user; the answer's stream continues the turn.
        var stream = sendMessage(
            "Use the Bash tool to run: touch \(file.path). If it is denied, say DENIED and stop.",
            to: .conversation(id: Self.conversationID, project: Self.project),
            permissionModeOverride: .manual
        )
        while true {
            for try await event in stream { events.append(event) }
            guard let request = events.waitingForUser.last else { break }
            answered.insert(request.toolUseID)
            // The answer isn't streamed back: keep it, like the iOS app does.
            let answer = ChatEvent.UserResponse.permission(toolUseID: request.toolUseID, allow: false)
            events.append(.userResponse(answer))
            stream = answerUserRequest(answer)
        }

        #expect(!answered.isEmpty)
        // A denied tool use's result isn't streamed either (the answer is its result).
        #expect(!events.contains { event in
            if case .toolResult(let result) = event { answered.contains(result.toolUseID) } else { false }
        })
        #expect(events.waitingForUser.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path), "the command ran although it was denied")
    }

    /// A second message to a chat whose turn is still running (here: waiting on a request) is refused; once that turn
    /// ended, the chat takes messages again.
    @Test func refusesSecondMessageWhileRunning() async throws {
        let file = URL(filePath: NSTemporaryDirectory()).appending(path: "busy-test-\(UUID().uuidString)")
        let target = MessageTarget.conversation(id: Self.conversationID, project: Self.project)
        var events: [ChatEvent] = []
        for try await event in sendMessage(
            "Use the Bash tool to run: touch \(file.path). If it is denied, say DENIED and stop.",
            to: target, permissionModeOverride: .manual
        ) { events.append(event) }
        let request = try #require(events.waitingForUser.last, "the first turn didn't wait for the user")

        await #expect {
            _ = try await Self.events("Reply with only the word pong.", to: target)
        } throws: { error in
            if case XcodeChatError.conversationRunning = error { true } else { false }
        }

        // End the first turn, then the chat takes a message again.
        for try await _ in answerUserRequest(.permission(toolUseID: request.toolUseID, allow: false)) {}
        let reply = try await Self.events("Reply with only the word pong.", to: target)
        #expect(reply.contains { if case .assistantMessage = $0 { true } else { false } })
    }

    @Test func throwsForUnknownConversation() async throws {
        await #expect(throws: XcodeChatError.self) {
            _ = try await Self.events(
                "hi",
                to: .conversation(id: "00000000-0000-0000-0000-000000000000", project: Self.project))
        }
    }
}
#endif
