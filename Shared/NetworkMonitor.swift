//
//  NetworkMonitor.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/05/28.
//

import Foundation
import Network

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
nonisolated class NetworkMonitor {

    private(set) var isConnected = true
    private(set) var connectionType: ConnectionType = .unknown

    private let monitor = NWPathMonitor()
    private var monitorTask: Task<Void, Error>?

    enum ConnectionType: String {
        case wifi, cellular, ethernet, unknown
    }

    init() { startMonitoring() }

    deinit { self.stopMonitoring() }

    private func startMonitoring() {
        self.monitorTask = Task {
            for await path in self.monitor {
                let nowConnected = path.status == .satisfied
                let previous = self.isConnected
                self.isConnected = nowConnected
                self.connectionType = self.resolve(path)
                if previous != nowConnected {
                    NotificationCenter.default.post(
                        NetworkConnectivityDidChange(isConnected: nowConnected)
                    )
                }
            }
        }
    }

    private func resolve(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        return .unknown
    }

    func stopMonitoring() {
        self.monitorTask?.cancel()
        self.monitorTask = nil
    }
}
