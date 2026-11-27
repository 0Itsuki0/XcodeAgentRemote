//
//  NewChatHistoryTests.swift
//  XcodeAgentRemoteTests
//
//  A chat whose agent session has no file: a new chat from Xcode's UI with nothing sent yet (empty history, and its
//  first message starts the session), or one whose session file is gone (an error).
//  The chats are created in the Demo10 project's store (`ScenarioTests.project`) and removed after each test.
//

#if os(macOS)
import Foundation
import Testing
@testable import XcodeAgentRemote

@Suite(.serialized)
struct NewChatHistoryTests {
    private static let store = ChatStore.storeDirectory(forProject: ScenarioTests.project)

    /// A chat like the one Xcode creates for a new chat: a session id, no turns, and no session file.
    /// With `turn`, it has one recorded turn (its session file is then missing, as if deleted).
    static func makeChat(withTurn turn: Bool = false) throws -> (id: String, sessionID: String) {
        let id = ChatStore.newUUID()
        let sessionID = ClaudeProvider.newSessionID()
        var chat = try ChatStore.Chat.create(
            store: store,
            id: id,
            modelDefinition: .init(modelIdentifier: ClaudeProvider.modelIdentifier, agent: .claude),
            sessionID: sessionID,
            name: ""
        )
        if turn {
            try chat.appendTurn(
                prompt: "hi",
                startDate: Date(),
                finishedDate: Date(),
                response: (content: [], sequence: [], isModification: false),
                snapshotBefore: nil,
                snapshotAfter: nil
            )
        }
        try chat.save()
        return (id, sessionID)
    }

    /// Removes the chat's folder, its manifest entry and its session file (if a turn created one).
    static func remove(_ chat: (id: String, sessionID: String)) {
        if let transcript = try? ClaudeProvider.transcriptFile(sessionID: chat.sessionID) {
            try? FileManager.default.removeItem(at: transcript)
        }
        try? FileManager.default.removeItem(at: store.appending(path: chat.id, directoryHint: .isDirectory))
        let manifestFile = store.appending(path: "CodingAssistantManifest.plist")
        if let manifest = ChatStore.readPlist(at: manifestFile) as? [Any] {
            let kept = manifest.filter {
                (($0 as? [String: Any])?["id"] as? String).map { !ChatStore.sameID($0, chat.id) } ?? true
            }
            try? ChatStore.writePlist(kept, to: manifestFile)
        }
    }

    @Test func newChatWithoutSessionFileHasEmptyHistory() throws {
        let chat = try Self.makeChat()
        defer { Self.remove(chat) }
        #expect((try? ClaudeProvider.transcriptFile(sessionID: chat.sessionID)) == nil)

        #expect(try ChatStore.history(conversationID: chat.id).isEmpty)
        let conversation = try ChatStore.conversation(id: chat.id)
        #expect(ChatStore.sameID(conversation.id, chat.id))
        #expect(conversation.history.isEmpty)
    }

    @Test func chatWithTurnsWithoutSessionFileIsTranscriptMissing() throws {
        let chat = try Self.makeChat(withTurn: true)
        defer { Self.remove(chat) }

        #expect {
            try ChatStore.history(conversationID: chat.id)
        } throws: { error in
            guard case XcodeChatError.transcriptMissing(let sessionID) = error else { return false }
            return sessionID == chat.sessionID
        }
        #expect(throws: XcodeChatError.self) { try ChatStore.conversation(id: chat.id) }
    }

    /// The first message to a new chat from Xcode starts its session (with the chat's session id) instead of resuming one.
    @Test func firstMessageToNewChatStartsSession() async throws {
        let chat = try Self.makeChat()
        defer { Self.remove(chat) }

        let prompt = "Reply with only the word pong."
        let events = try await SendMessageTests.events(
            prompt,
            to: .conversation(id: chat.id, project: ScenarioTests.project),
            permissionModeOverride: .auto
        )
        let reply = events.compactMap { if case .assistantMessage(let text) = $0 { text } else { nil } }.joined()
        #expect(reply.lowercased().contains("pong"))

        #expect((try? ClaudeProvider.transcriptFile(sessionID: chat.sessionID)) != nil)
        #expect(try ChatStore.history(conversationID: chat.id).contains(.userMessage(prompt)))
    }
}
#endif
