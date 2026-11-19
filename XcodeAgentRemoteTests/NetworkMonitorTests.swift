//
//  NetworkMonitorTests.swift
//  XcodeAgentRemoteTests
//
//  NetworkMonitor's monitoring task must not keep it alive: once its last reference is gone, it is freed (its
//  `deinit` stops the monitoring).
//

import Foundation
import Testing
@testable import XcodeAgentRemote

struct NetworkMonitorTests {

    @Test func freedOnceNotReferenced() async throws {
        weak var released: NetworkMonitor?
        do {
            let monitor = NetworkMonitor()
            released = monitor
            // Let the monitoring task start and get the current path.
            try await Task.sleep(for: .milliseconds(500))
            #expect(released != nil)
        }
        #expect(released == nil)
    }
}
