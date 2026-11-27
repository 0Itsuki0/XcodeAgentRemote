//
//  NetworkMonitor.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/05/28.
//

import Foundation
import Network
import Synchronization

nonisolated
    struct NetworkConnectivityDidChange: NotificationCenter.AsyncMessage
{
    typealias Subject = Never
    let isConnected: Bool

}
nonisolated
    extension NotificationCenter.MessageIdentifier
where
    Self == NotificationCenter.BaseMessageIdentifier<
        NetworkConnectivityDidChange
    >
{
    static var connectivityDidChange: Self { .init() }
}

// MARK: - NetworkMonitor for monitoring network change.
/// Not tied to an actor: its state is read on request from any thread, and changes are posted as notifications
/// (`NetworkConnectivityDidChange`). The state is kept behind a lock.
nonisolated final class NetworkMonitor: Sendable {

    private struct State {
        var isConnected = true
        var connectionType: ConnectionType = .unknown
    }

    private let state = Mutex(State())
    var isConnected: Bool { state.withLock { $0.isConnected } }
    var connectionType: ConnectionType { state.withLock { $0.connectionType } }

    private let monitor = NWPathMonitor()
    private let monitorTask = Mutex<Task<Void, Never>?>(nil)

    enum ConnectionType: String, Sendable {
        case wifi, cellular, ethernet, unknown
    }

    init() { startMonitoring() }

    deinit { self.stopMonitoring() }

    private func startMonitoring() {
        // `self` weakly: the task runs until it is cancelled, which `deinit` does, so holding `self` would keep both
        // alive forever.
        let task = Task { [weak self, monitor] in
            for await path in monitor {
                guard let self else { return }
                let nowConnected = path.status == .satisfied
                let connectionType = self.resolve(path)
                let previous = self.state.withLock { state in
                    let previous = state.isConnected
                    state.isConnected = nowConnected
                    state.connectionType = connectionType
                    return previous
                }
                if previous != nowConnected {
                    NotificationCenter.default.post(
                        NetworkConnectivityDidChange(isConnected: nowConnected)
                    )
                }
            }
        }
        self.monitorTask.withLock { $0 = task }
    }

    private func resolve(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        return .unknown
    }

    func stopMonitoring() {
        self.monitorTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }
}
