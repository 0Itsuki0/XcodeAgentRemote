//
//  Throttler.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/24.
//

import Foundation
import Synchronization

// MARK: - Throttler: fires at most once per interval (seconds)

/// Usage — analytics event that shouldn't spam
/// ```
/// let scrollThrottler = Throttler(interval: 1.0)
/// func scrollViewDidScroll() {
///     scrollThrottler.run {
///         Analytics.track("scrolled_feed")
///     }
/// }
/// ```
nonisolated final class Throttler: Sendable {
    private let lastFire: Mutex<Date> = Mutex(.distantPast)
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.5) {
        self.interval = interval
    }

    func run(_ action: () -> Void) {
        let lastFire = lastFire.withLock { $0 }
        let now = Date()
        guard now.timeIntervalSince(lastFire) >= interval else { return }
        self.lastFire.withLock { $0 = now }
        action()
    }
}
