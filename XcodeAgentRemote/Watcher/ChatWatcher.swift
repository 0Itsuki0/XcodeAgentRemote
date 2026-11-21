//
//  ChatWatcher.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/18.
//

import SwiftUI
import Synchronization

nonisolated private let logger = Logger.shared
nonisolated private let category = Logger.category(#fileID)

/// `ChatWatcher` managing a list of `FileWatcher`, one per chat.
///
/// Notes:
/// - Not preserving the watching URL between app launches to avoid watching unnecessary amount of chats simultaneously
@Observable nonisolated final class ChatWatcher: Sendable {
    private struct WatchingConversation: Sendable, Identifiable {
        var id: String { conversationId }
        var conversationId: String
        var fileURL: URL
        var watcher: FileWatcher
        var error: Error?
        var task: Task<Void, Never>
    }

    private let _watchingConversations: Mutex<[WatchingConversation]> =
        Mutex([])
    private var watchingConversations: [WatchingConversation] {
        return _watchingConversations.withLock { $0 }
    }
    var watchingConversationIds: [String] {
        return watchingConversations.map(\.conversationId)
    }
    var watchingFileURLs: [URL] {
        return watchingConversations.map(\.fileURL)
    }

    func watchConversation(_ id: String) async throws {
        guard !self.watchingConversationIds.contains(id) else {
            return
        }
        let store = try ChatStore.chatStore(conversationID: id)
        let sessionId = try ChatStore.providerSessionID(
            store: store,
            conversationID: id
        )
        let provider = try ChatStore.provider(store: store, conversationID: id)
        let fileURL = try provider.transcriptFile(sessionID: sessionId)
        guard !self.watchingFileURLs.contains(fileURL) else {
            return
        }
        try await self.watchFile(at: fileURL, for: id)
    }

    func stopWatchingConversation(_ id: String) async {
        let conversation: WatchingConversation? = self._watchingConversations
            .withLock {
                guard
                    let index =
                        $0.firstIndex(where: { $0.conversationId == id })
                else { return nil }
                return $0[index]
            }
        conversation?.task.cancel()
        await conversation?.watcher.stop()
        self._watchingConversations.withLock {
            $0.removeAll { $0.conversationId == id }
        }
    }

    /// Watches one file for changes (DispatchSource on the file's descriptor; no folder watching).
    /// Throws `FileWatcherError.cannotOpen` if the file doesn't exist
    private func watchFile(at url: URL, for conversationId: String)
        async throws(FileWatcherError)
    {
        /// Yield Error: `FileWatcherError.cannotOpen`
        /// Occurs if the file is deleted and doesn't come back.
        let (event, continuation) = AsyncThrowingStream<FileChange, Error>
            .makeStream()
        let watcher = FileWatcher(
            path: url.path,
            continuation: continuation
        )
        continuation.onTermination = { _ in
            Task {
                await watcher.stop()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    /// stop the task, but not removing the value from the array (in case there is an error)
                    self.stopWatcherTask(for: url)
                }
            }
        }
        try await watcher.start()
        let task: Task<Void, Never> = Task {
            do {
                for try await change in event {
                    logger.info(
                        category: category,
                        message: "\(url.lastPathComponent) - \(change)"
                    )
                }
            } catch {
                guard !error.isCancellationError else { return }
                self.setError(for: url, error: error)
            }
        }
        self._watchingConversations.withLock {
            $0.append(
                WatchingConversation(
                    conversationId: conversationId,
                    fileURL: url,
                    watcher: watcher,
                    task: task
                )
            )
        }
    }

    private func setError(for url: URL, error: Error) {
        self._watchingConversations.withLock {
            guard let index = $0.firstIndex(where: { $0.fileURL == url }) else {
                return
            }
            $0[index].error = error
        }
    }

    private func stopWatcherTask(for url: URL) {
        self._watchingConversations.withLock {
            guard let index = $0.firstIndex(where: { $0.fileURL == url }) else {
                return
            }
            $0[index].task.cancel()
        }
    }
}

nonisolated extension Error {
    var isCancellationError: Bool {
        return self is CancellationError
    }
}
