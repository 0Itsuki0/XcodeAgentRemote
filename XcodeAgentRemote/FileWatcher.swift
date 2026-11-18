//
//  FileWatcher.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

import Foundation

nonisolated enum FileChange: Sendable {
    /// Written to or appended to in place (what Claude does to its session .jsonl).
    case modified
    /// Replaced by another file (deleted / renamed over, e.g. an atomic save): read it again from the start.
    case replaced
}

nonisolated enum FileWatcherError: Error {
    /// The file could not be opened (missing, or gone and not back after a replace).
    case cannotOpen(path: String, errno: Int32)
}

/// `FileWatcher`for watching for file changes
///
/// Runs on its own serial queue, the same queue the DispatchSource calls its handler on,
/// so the handler enters the actor directly (`assumeIsolated`), in event order.
///
/// Usage: Refer to `ChatWatcher.watchFile`
actor FileWatcher {
    private let path: String
    private let continuation:
        AsyncThrowingStream<FileChange, Error>.Continuation
    private let queue = DispatchSerialQueue(label: "FileWatcher")
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private var source: DispatchSourceFileSystemObject?
    private var reopenTask: Task<Void, Never>?
    private var stopped = false

    /// After a replace, the new file may not be there yet: retry opening this often, this many times.
    private static let reopenInterval: Duration = .milliseconds(50)
    private static let reopenAttempts = 20

    init(
        path: String,
        continuation: AsyncThrowingStream<FileChange, Error>.Continuation
    ) {
        self.path = path
        self.continuation = continuation
    }

    //    func start() {
    //        guard !stopped else { return }
    //        do {
    //            try open()
    //        } catch {
    //            continuation.finish(throwing: error)
    //        }
    //    }
    func start() throws(FileWatcherError) {
        guard !stopped else { return }
        try open()
    }

    func stop() {
        stopped = true
        reopenTask?.cancel()
        source?.cancel()
        source = nil
    }

    /// Opens the file and starts watching it.
    private func open() throws(FileWatcherError) {
        let descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw .cannotOpen(path: path, errno: errno)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [self] in
            assumeIsolated { $0.handleEvent() }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func handleEvent() {
        guard let source else { return }
        if source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
            continuation.yield(.modified)
        } else {
            // The descriptor now points at the old file: watch the new one at the path.
            source.cancel()
            self.source = nil
            reopenTask = Task { await reopen() }
        }
    }

    private func reopen() async {
        for attempt in 1...Self.reopenAttempts {
            guard !stopped else { return }
            do {
                try open()
                continuation.yield(.replaced)
                return
            } catch {
                if attempt == Self.reopenAttempts {
                    continuation.finish(throwing: error)
                    return
                }
            }
            try? await Task.sleep(for: Self.reopenInterval)
        }
    }
}
