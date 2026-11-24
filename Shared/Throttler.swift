//
//  Throttler.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/24.
//

import Foundation

// MARK: - Throttler: fires at most once per interval
//
/// Usage — analytics event that shouldn't spam
/// ```
/// let scrollThrottler = Throttler(interval: 1.0)
/// func scrollViewDidScroll() {
///     scrollThrottler.run {
///         Analytics.track("scrolled_feed")
///     }
/// }
/// ```
final class Throttler {
    private var lastFire: Date = .distantPast
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.5) {
        self.interval = interval
    }

    func run(_ action: () -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastFire) >= interval else { return }
        lastFire = now
        action()
    }
}
