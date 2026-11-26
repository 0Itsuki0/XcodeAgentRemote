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
    fileprivate struct WatchingConversation: Sendable, Identifiable {
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

    /// Throttler to make sure the push notification is only sent every 10 minutes
    ///
    /// Note:
    /// 1. not putting on the send side (iCloudManager) because this is suppose to be per-conversation
    private let throttler = Throttler(interval: 10 * 60)

    /// Start watching a conversation.
    ///
    /// Notes:
    /// 1. watching the provider's session file instead of Xcode's `conversation.plist`
    ///     - matches what is returned with `ChatStore.history`
    ///     - contains full history instead of just what Xcode displays (what `conversation.plist` is)
    func watchConversation(_ conversationId: String) async throws {
        guard !self.watchingConversationIds.contains(conversationId) else {
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
    }

    private func handleChange(conversationId: String) {
        logger.info(
            category: category,
            message: "Watched conversation changed for id: \(conversationId)"
        )

        /// Only fire notification for assistant response / user request
        guard
            let conversation = try? ChatStore.conversation(id: conversationId)
        else { return }
        let history = conversation.history
        guard let last = history.last else { return }
        let chatEvent: ChatEvent
        switch history.last {
        case .assistantMessage(let message):
            chatEvent = .assistantMessage(message)
        case .userRequest(let request):
            chatEvent = .userRequest(request)
        default:
            return
        }

        throttler.run {
            NotificationCenter.default.post(
                ChatHistoryDidChange(
                    conversation: conversation,
                    chatEvent: chatEvent
                )
            )
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
