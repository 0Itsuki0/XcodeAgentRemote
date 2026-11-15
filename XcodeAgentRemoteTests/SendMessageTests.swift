//
//  SendMessageTests.swift
//  XcodeAgentRemoteTests
//
//  Runs sendMessage against the real agent, with the xcode-chat executable embedded in the host app.
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
                       permissionMode: PermissionModeOverride? = nil) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in sendMessage(prompt, to: target, permissionMode: permissionMode) {
            events.append(event)
        }
        return events
    }

    @Test func completesTurn() async throws {
        let events = try await Self.events(
            "Reply with only the word pong.",
            to: .conversation(id: Self.conversationID, project: Self.project))

        guard case .start(let start) = events.first else {
            Issue.record("first event is not start: \(String(describing: events.first))")
            return
        }
        #expect(start.conversation == Self.conversationID)
        #expect(!start.newConversation)

        guard case .result(let result) = events.last else {
            Issue.record("last event is not result: \(String(describing: events.last))")
            return
        }
        #expect(result.status == .completed)
        #expect(result.result?.lowercased().contains("pong") == true)
        #expect(events.contains { if case .text = $0 { true } else { false } })
    }

    @Test func stopsAtPermissionRequestInManualMode() async throws {
        let file = URL(filePath: NSTemporaryDirectory()).appending(path: "xcode-chat-permission-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        let events = try await Self.events(
            "Use the Bash tool to run: touch \(file.path)",
            to: .conversation(id: Self.conversationID, project: Self.project),
            permissionMode: .manual)

        let request = events.lazy.compactMap { event -> ChatEvent.PermissionRequest? in
            if case .permissionRequest(let request) = event { request } else { nil }
        }.first
        #expect(request?.tool == "Bash")

        guard case .result(let result) = events.last else {
            Issue.record("last event is not result: \(String(describing: events.last))")
            return
        }
        #expect(result.status == .permissionRequired)
        #expect(result.pending?.tool == "Bash")
        #expect(!FileManager.default.fileExists(atPath: file.path), "the command ran without permission")
    }

    @Test func throwsForUnknownConversation() async throws {
        await #expect(throws: SendMessageError.self) {
            _ = try await Self.events(
                "hi",
                to: .conversation(id: "00000000-0000-0000-0000-000000000000", project: Self.project))
        }
    }
}
#endif
