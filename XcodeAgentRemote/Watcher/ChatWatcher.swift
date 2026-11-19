//
//  ChatWatcher.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/18.
//

import SwiftUI

private let logger = Logger.shared
private let category = Logger.category(#fileID)

/// `ChatWatcher` managing a list of `FileWatcher`, one per chat.
///
/// Notes:
/// - Not preserving the watching URL between app launches to avoid watching unnecessary amount of chats simultaneously
@Observable class ChatWatcher {
    private(set) var watcherMap: [URL: FileWatcher] = [:]
    private(set) var taskMap: [URL: Task<Void, Never>] = [:]
    private(set) var errorMap: [URL: Error] = [:]

    /// Watches one file for changes (DispatchSource on the file's descriptor; no folder watching).
    /// Throws `FileWatcherError.cannotOpen` if the file doesn't exist
    func watchFile(at url: URL) async throws(FileWatcherError) {
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
                    self.watcherMap.removeValue(forKey: url)
                    self.taskMap[url]?.cancel()
                    self.taskMap.removeValue(forKey: url)
                }
            }
        }
        try await watcher.start()
        self.watcherMap[url] = watcher
        self.taskMap[url] = Task {
            do {
                for try await change in event {
                    logger.info(
                        category: category,
                        message: "\(url.lastPathComponent) - \(change)"
                    )
                }
            } catch {
                guard !error.isCancellationError else { return }
                errorMap[url] = error
            }
        }
    }
}

extension Error {
    var isCancellationError: Bool {
        return self is CancellationError
    }
}
