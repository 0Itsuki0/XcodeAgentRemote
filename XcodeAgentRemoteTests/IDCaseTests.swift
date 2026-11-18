//
//  IDCaseTests.swift
//  XcodeAgentRemoteTests
//
//  Ids are matched whatever their case: Xcode writes its chat UUIDs uppercase, Claude its session ids lowercase, and an
//  id given to the app may be cased either way (`ChatStore.sameID`, `ChatStore.item(named:suffix:in:)`).
//  The lookups are checked on a real Claude chat of Xcode's chat store (with an agent session that has a transcript).
//

#if os(macOS)
import Foundation
import Testing
@testable import XcodeAgentRemote

struct IDCaseTests {

    // MARK: Helpers

    @Test func sameIDIgnoresCase() {
        #expect(ChatStore.sameID("1F143C21-4AC9-4F2D", "1f143c21-4ac9-4f2d"))
        #expect(!ChatStore.sameID("1F143C21-4AC9-4F2D", "1F143C21-4AC9-4F2E"))
    }

    @Test func itemFoundWhateverItsCaseOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "IDCaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let upper = "1F143C21-4AC9-4F2D-8305-1C260FBCC776"
        let lower = "14aa9259-5c2e-4729-8388-fdcb42dad74b"
        try FileManager.default.createDirectory(at: folder.appending(path: upper), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "\(lower).jsonl"))

        // Found by its id in either case; the URL has the name as it is on disk.
        #expect(ChatStore.item(named: upper.lowercased(), in: folder)?.lastPathComponent == upper)
        #expect(ChatStore.item(named: upper, in: folder)?.lastPathComponent == upper)
        #expect(ChatStore.item(named: lower.uppercased(), suffix: ".jsonl", in: folder)?.lastPathComponent == "\(lower).jsonl")
        // The suffix is part of the name.
        #expect(ChatStore.item(named: lower, in: folder) == nil)
        #expect(ChatStore.item(named: upper, suffix: ".jsonl", in: folder) == nil)
    }

    @Test func runningSessionsWhateverTheCase() {
        let sessionID = UUID().uuidString.lowercased()
        RunningSessions.insert(sessionID.uppercased())
        #expect(RunningSessions.contains(sessionID))
        RunningSessions.remove(sessionID)
        #expect(!RunningSessions.contains(sessionID.uppercased()))
    }

    // MARK: Lookups (a real chat)

    /// A Claude chat of Xcode's chat store whose agent session has a transcript.
    static func claudeChat() -> (project: XcodeProject, chat: XcodeChatConversation, sessionID: String)? {
        for project in ChatStore.listProjects() {
            for chat in project.conversations where chat.provider == .claude {
                if let sessionID = chat.providerSessionID, ClaudeProvider.transcript(sessionID: sessionID) != nil {
                    return (project, chat, sessionID)
                }
            }
        }
        return nil
    }

    @Test(arguments: [false, true]) func conversationFoundWhateverTheCase(otherCase: Bool) throws {
        let (project, chat, _) = try #require(Self.claudeChat(), "no Claude chat with a transcript in Xcode's chat store")
        let id = otherCase ? chat.id.lowercased() : chat.id  // Xcode writes its chat ids uppercase

        let detail = try ChatStore.conversation(id: id)
        #expect(detail.id == chat.id)
        #expect(detail.project.store == project.store)
        #expect(try !ChatStore.history(conversationID: id).isEmpty)
        #expect(ChatStore.Chat.load(store: project.store, id: id)?.id == chat.id)  // the id as its folder is named
    }

    @Test(arguments: [false, true]) func transcriptFoundWhateverTheCase(otherCase: Bool) throws {
        let (_, _, sessionID) = try #require(Self.claudeChat(), "no Claude chat with a transcript in Xcode's chat store")
        let transcript = try #require(ClaudeProvider.transcript(sessionID: sessionID))
        let id = otherCase ? sessionID.uppercased() : sessionID  // Claude writes its session ids lowercase

        #expect(ClaudeProvider.transcript(sessionID: id) == transcript)
    }

    @Test func unknownConversationNotFound() {
        #expect(throws: ChatHistoryError.self) {
            try ChatStore.conversation(id: "00000000-0000-0000-0000-000000000000")
        }
    }
}
#endif
