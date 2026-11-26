//
//  Debouncer.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/24.
//

import Foundation
import Synchronization

// MARK: Debouncer: fires at the end of rapid events

/// Usage:
///
/// ```
/// let debouncer = Debouncer(delay: .milliseconds(400))
/// func onTextChanged(_ text: String) {
///     debouncer.run {
///         await SearchService.query(text)
///     }
/// }
/// ```
nonisolated final class Debouncer: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    private let delay: Duration

    init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    func run(_ action: @escaping @Sendable () async -> Void) {
        self.task.withLock { task in
            task?.cancel()
            task = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await action()
            }
        }
    }
}
