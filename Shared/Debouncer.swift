//
//  Debouncer.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/24.
//


import Foundation

// MARK: Debouncer: fires at the end of rapid events
// 
/// Usage
/// ```
/// let debouncer = Debouncer(delay: .milliseconds(400))
/// func onTextChanged(_ text: String) {
///     debouncer.run {
///         await SearchService.query(text)
///     }
/// }
/// ```
final class Debouncer {
    private var task: Task<Void, Never>?
    private let delay: Duration
 
    init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }
 
    func run(_ action: @escaping @Sendable () async -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }
}
