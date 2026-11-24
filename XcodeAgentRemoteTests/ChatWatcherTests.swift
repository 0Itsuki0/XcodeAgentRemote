//
//  ChatWatcherTests.swift
//  XcodeAgentRemoteTests
//
//  ChatWatcher, and the server's `POST /conversations/:conversationID/watch` and `isWatching`, against a real chat of
//  the Demo10 project (nothing is written to it).
//

#if os(macOS)
    import Foundation
    import Testing
    @testable import XcodeAgentRemote

    /// A chat of the Demo10 project (`DebugConstants.conversationId`).
    private let conversationID = "1170A351-FBFE-4317-8FA7-4F65AC6F3B64"
    private let unknownID = "00000000-0000-0000-0000-000000000000"

    @Suite(.serialized)
    struct ChatWatcherTests {

        @Test func watchesAndStops() async throws {
            let watcher = ChatWatcher()
            try await watcher.watchConversation(conversationID)
            #expect(watcher.watchingConversationIds == [conversationID])

            // Watching it again adds nothing.
            try await watcher.watchConversation(conversationID)
            #expect(watcher.watchingConversationIds == [conversationID])

            await watcher.stopWatchingConversation(conversationID)
            #expect(watcher.watchingConversationIds.isEmpty)
        }

        @Test func unknownConversationThrows() async {
            let watcher = ChatWatcher()
            await #expect(throws: ChatStoreError.self) {
                try await watcher.watchConversation(unknownID)
            }
            #expect(watcher.watchingConversationIds.isEmpty)
        }

        @Test func stoppingUnwatchedDoesNothing() async {
            let watcher = ChatWatcher()
            await watcher.stopWatchingConversation(conversationID)
            #expect(watcher.watchingConversationIds.isEmpty)
        }
    }

    @Suite(.serialized)
    struct WatchEndpointTests {

        @Test func watchAndUnwatch() async throws {
            let watcher = ChatWatcher()
            let server = APIServer(
                watchingConversations: { watcher.watchingConversationIds },
                watchConversation: watcher.watchConversation,
                stopWatchingConversation: watcher.stopWatchingConversation
            )
            let port = try await server.start(port: 0)
            let base = URL(string: "http://127.0.0.1:\(port)")!

            let conversationURL = base.appending(
                path: APIServerConstants.path(
                    APIServerConstants.conversationPath,
                    conversationID: conversationID
                )
            )
            func watchURL(_ id: String) -> URL {
                base.appending(
                    path: APIServerConstants.path(
                        APIServerConstants.watchPath,
                        conversationID: id
                    )
                )
            }

            #expect(try await isWatching(conversationURL) == false)

            #expect(try await post(watchURL(conversationID), watch: true) == 200)
            #expect(watcher.watchingConversationIds == [conversationID])
            #expect(try await isWatching(conversationURL) == true)
            #expect(try await isWatchingInProjects(base) == true)

            #expect(try await post(watchURL(conversationID), watch: false) == 200)
            #expect(watcher.watchingConversationIds.isEmpty)
            #expect(try await isWatching(conversationURL) == false)
            #expect(try await isWatchingInProjects(base) == false)

            #expect(try await post(watchURL(unknownID), watch: true) == 404)
            #expect(watcher.watchingConversationIds.isEmpty)

            await server.stop()
        }

        /// POSTs a `WatchRequest`; returns the status code.
        private func post(_ url: URL, watch: Bool) async throws -> Int {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(WatchRequest(watch: watch))
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }

        /// `isWatching` of `GET /conversations/:conversationID`.
        private func isWatching(_ url: URL) async throws -> Bool? {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["isWatching"] as? Bool
        }

        /// `isWatching` of the conversation in `GET /projects`.
        private func isWatchingInProjects(_ base: URL) async throws -> Bool? {
            let (data, _) = try await URLSession.shared.data(
                from: base.appending(path: APIServerConstants.projectsPath)
            )
            let projects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            let conversation = projects
                .flatMap { $0["conversations"] as? [[String: Any]] ?? [] }
                .first { ($0["id"] as? String).map { ChatStore.sameID($0, conversationID) } ?? false }
            return conversation?["isWatching"] as? Bool
        }
    }
#endif
