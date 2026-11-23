//
//  SendMessageTests.swift
//  XcodeAgentRemoteTests
//
//  Runs sendMessage against the real agent.
//  These send real turns to an existing chat of this project (they are recorded in Xcode's chat store).
//

#if os(macOS)
import Foundation
import Testing
@testable import XcodeAgentRemote

@Suite(.serialized)
struct SendMessageTests {

    static let project = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "XcodeAgentRemote.xcodeproj")
    /// The "Echo user message" chat of this project.
    static let conversationID = "D868CB20-1251-4ECC-9047-041C449419CB"

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
            stream = answerUserRequest(.permission(toolUseID: request.toolUseID, allow: false))
        }

        #expect(!answered.isEmpty)
        let denied = events.contains { event in
            if case .userResponse(.permission(let toolUseID, false, _)) = event { answered.contains(toolUseID) } else { false }
        }
        #expect(denied)
        #expect(events.waitingForUser.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path), "the command ran although it was denied")
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
