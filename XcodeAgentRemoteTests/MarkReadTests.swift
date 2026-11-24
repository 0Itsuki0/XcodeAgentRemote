//
//  MarkReadTests.swift
//  XcodeAgentRemoteTests
//
//  `ChatStore.markRead` on a navigator file in a temporary store (no real chat store is changed), and
//  `POST /conversations/:conversationID/read` for an unknown chat.
//

#if os(macOS)
    import Foundation
    import Testing
    @testable import XcodeAgentRemote

    struct MarkReadTests {
        private let unread = "29EB8160-662B-464F-8DBA-153BB4964C11"
        private let other = "381527EB-4F59-4DD0-9866-959E7AA375B8"

        /// A store with a navigator file like Xcode's (binary; chat states as a flat `[id, state, ...]` list).
        private func makeStore() throws -> URL {
            let store = FileManager.default.temporaryDirectory.appending(path: "mark-read-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            let navigator: [String: Any] = [
                "groups": [Any](),
                "navigatorConversations": [
                    other, ["isArchived": false, "isUnread": true],
                    unread, ["isArchived": false, "isUnread": true, "subtitle": "Q&A"],
                ],
                "rootNodeOrder": [unread, other],
                "version": 1,
            ]
            try PropertyListSerialization.data(fromPropertyList: navigator, format: .binary, options: 0)
                .write(to: store.appending(path: "CodingAssistantNavigator.plist"))
            return store
        }

        private func navigator(_ store: URL) throws -> (plist: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
            var format = PropertyListSerialization.PropertyListFormat.xml
            let data = try Data(contentsOf: store.appending(path: "CodingAssistantNavigator.plist"))
            let plist = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any] ?? [:]
            return (plist, format)
        }

        @Test func marksOnlyThatChatRead() throws {
            let store = try makeStore()
            defer { try? FileManager.default.removeItem(at: store) }

            // Found whatever the case of its id.
            try ChatStore.markRead(conversationID: unread.lowercased(), store: store)

            let (plist, format) = try navigator(store)
            #expect(format == .binary)
            let states = plist["navigatorConversations"] as? [Any] ?? []
            #expect(states.count == 4)
            let otherState = states[1] as? [String: Any]
            let readState = states[3] as? [String: Any]
            #expect(otherState?["isUnread"] as? Bool == true)
            #expect(readState?["isUnread"] as? Bool == false)
            #expect(readState?["isArchived"] as? Bool == false)
            #expect(readState?["subtitle"] as? String == "Q&A")
            #expect(plist["rootNodeOrder"] as? [String] == [unread, other])
            #expect(plist["version"] as? Int == 1)
        }

        @Test func marksOnlyThatChatUnread() throws {
            let store = try makeStore()
            defer { try? FileManager.default.removeItem(at: store) }
            try ChatStore.markRead(conversationID: unread, store: store)
            try ChatStore.markRead(conversationID: other, store: store)

            try ChatStore.markUnread(conversationID: unread, store: store)

            let (plist, format) = try navigator(store)
            #expect(format == .binary)
            let states = plist["navigatorConversations"] as? [Any] ?? []
            #expect((states[1] as? [String: Any])?["isUnread"] as? Bool == false)
            let state = states[3] as? [String: Any]
            #expect(state?["isUnread"] as? Bool == true)
            #expect(state?["subtitle"] as? String == "Q&A")
        }

        /// A store without a navigator file (best effort: nothing to mark, no error).
        @Test func noNavigatorFileIsNoError() throws {
            let store = FileManager.default.temporaryDirectory.appending(path: "mark-read-\(UUID().uuidString)")
            try ChatStore.markUnread(conversationID: unread, store: store)
            #expect(!FileManager.default.fileExists(atPath: store.path))
        }

        @Test func unknownChatChangesNothing() throws {
            let store = try makeStore()
            defer { try? FileManager.default.removeItem(at: store) }
            let before = try Data(contentsOf: store.appending(path: "CodingAssistantNavigator.plist"))
            try ChatStore.markRead(conversationID: "00000000-0000-0000-0000-000000000000", store: store)
            let after = try Data(contentsOf: store.appending(path: "CodingAssistantNavigator.plist"))
            #expect(before == after)
        }

        @Test func endpointUnknownChatIs404() async throws {
            let server = APIServer(
                watchingConversations: { [] },
                watchConversation: { _ in },
                stopWatchingConversation: { _ in }
            )
            let port = try await server.start(port: 0)
            defer { Task { await server.stop() } }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)")!.appending(
                path: APIServerConstants.path(
                    APIServerConstants.readPath,
                    conversationID: "00000000-0000-0000-0000-000000000000"
                )))
            request.httpMethod = "POST"
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
        }
    }
#endif
