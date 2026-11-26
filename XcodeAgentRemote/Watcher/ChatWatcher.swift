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

nonisolated struct ChatHistoryDidChange: NotificationCenter.AsyncMessage {
    typealias Subject = Never
    let conversation: XcodeConversationDetail
    /// Will only fire for userRequest / assistantMessage
    let chatEvent: ChatEvent
}

nonisolated extension NotificationCenter.MessageIdentifier
where
    Self == NotificationCenter.BaseMessageIdentifier<
        ChatHistoryDidChange
    >
{
    static var chatHistoryDidChange: Self { .init() }
}

nonisolated
    extension Array where Element == ChatWatcher.WatchingConversation
{
    subscript(_ id: String) -> ChatWatcher.WatchingConversation? {
        get {
            return self.first(where: { $0.id.lowercased() == id.lowercased() })
        }
        set {
            guard
                let index = self.firstIndex(where: {
                    $0.id.lowercased() == id.lowercased()
                }), let newValue
            else {
                return
            }
            self[index] = newValue
        }
    }
}

/// `ChatWatcher` managing a list of `FileWatcher`, one per chat.
///
/// Notes:
/// - Not preserving the watching URL between app launches to avoid watching unnecessary amount of chats simultaneously
@Observable nonisolated final class ChatWatcher: Sendable {
    /// Note:
    /// 1. not putting  throttler/debouncer on the send side (iCloudManager) because this is suppose to be per-conversation
    fileprivate struct WatchingConversation: Sendable, Identifiable {
        #if DEBUG
            static let throttlerInterval: TimeInterval = 1
            static let debouncerDelay: Duration = .seconds(1)
        #else
            /// 5 minutes
            static let throttlerInterval: TimeInterval = 5 * 60
            /// 5 seconds
            static let debouncerDelay: Duration = .seconds(5)
        #endif

        var id: String { conversationId }
        var conversationId: String
        var fileURL: URL
        var watcher: FileWatcher
        var error: Error?
        var task: Task<Void, Never>

        var isWatching: Bool {
            !task.isCancelled && error == nil
        }

        /// Throttler to make sure the push notification is only sent every 10 minutes
        let throttler = Throttler(interval: Self.throttlerInterval)
        /// Debouncer to handle rapid change events
        let debouncer = Debouncer(delay: Self.debouncerDelay)
    }

    private let _watchingConversations: Mutex<[WatchingConversation]> =
        Mutex([])
    private var watchingConversations: [WatchingConversation] {
        return _watchingConversations.withLock { $0 }.filter { $0.isWatching }
    }
    var watchingConversationIds: [String] {
        return watchingConversations.map(\.conversationId)
    }
    var watchingFileURLs: [URL] {
        return watchingConversations.map(\.fileURL)
    }

    private func isWatching(_ conversationId: String) -> Bool {
        guard let conversation = self.watchingConversations[conversationId]
        else {
            return false
        }
        return conversation.isWatching
    }

    /// Start watching a conversation.
    ///
    /// Notes:
    /// 1. watching the provider's session file instead of Xcode's `conversation.plist`
    ///     - matches what is returned with `ChatStore.history`
    ///     - contains full history instead of just what Xcode displays (what `conversation.plist` is)
    func watchConversation(_ conversationId: String) async throws {
        guard !self.isWatching(conversationId) else {
            return
        }
        let store = try ChatStore.chatStore(conversationID: conversationId)
        let sessionId = try ChatStore.providerSessionID(
            store: store,
            conversationID: conversationId
        )
        let provider = try ChatStore.provider(
            store: store,
            conversationID: conversationId
        )
        let fileURL = try provider.transcriptFile(sessionID: sessionId)
        guard !self.watchingFileURLs.contains(fileURL) else {
            return
        }
        try await self.watchFile(at: fileURL, for: conversationId)
    }

    func stopWatchingConversation(_ conversationId: String) async {
        let conversation: WatchingConversation? = self._watchingConversations
            .withLock { $0[conversationId] }
        conversation?.task.cancel()
        await conversation?.watcher.stop()
        self._watchingConversations.withLock {
            $0.removeAll { $0.conversationId == conversationId }
        }
        logger.info(
            category: category,
            message: "Stop watching conversation: \(conversationId)"
        )
    }

    private func stopWatcherTask(_ conversationId: String) {
        self._watchingConversations.withLock {
            $0[conversationId]?.task.cancel()
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
                    self.stopWatcherTask(conversationId)
                }
            }
        }
        try await watcher.start()
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            do {
                for try await _ in event {
                    self.handleChange(conversationId: conversationId)
                }
            } catch {
                guard !error.isCancellationError else { return }
                self.setError(conversationId, error: error)
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
        logger.info(
            category: category,
            message: "Start watching conversation: \(conversationId)"
        )
    }

    private func handleChange(conversationId: String) {
        logger.info(
            category: category,
            message: "Watched conversation changed for id: \(conversationId)"
        )

        guard let watching = self.watchingConversations[conversationId] else {
            return
        }

        /// Fetch the conversation history within the debouncer to make sure it is the latest
        watching.debouncer.run {
            guard
                let conversation = try? ChatStore.conversation(
                    id: conversationId
                )
            else { return }

            let history = conversation.history

            /// Only fire notification for assistant response / user request
            let chatEvent: ChatEvent
            switch history.last {
            case .assistantMessage(let message):
                chatEvent = .assistantMessage(message)
            case .userRequest(let request):
                chatEvent = .userRequest(request)
            default:
                return
            }

            watching.throttler.run {
                NotificationCenter.default.post(
                    ChatHistoryDidChange(
                        conversation: conversation,
                        chatEvent: chatEvent
                    )
                )
            }
        }
    }

    private func setError(_ conversationId: String, error: Error) {
        self._watchingConversations.withLock {
            $0[conversationId]?.error = error
        }
    }
}

nonisolated extension Error {
    var isCancellationError: Bool {
        return self is CancellationError
    }
}
