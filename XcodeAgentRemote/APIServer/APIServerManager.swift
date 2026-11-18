//
//  APIServerManager.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/18.
//

import SwiftUI

private let logger = Logger.shared
private let category = Logger.category(#fileID)

enum ServerState: String, Equatable, Hashable, Sendable {
    case stopping
    case stopped
    case starting
    case running

    var symbolColor: Color {
        switch self {
        case .stopping, .stopped:
            .red
        case .starting, .running:
            .green
        }
    }

    var displayLabel: String {
        self.rawValue.capitalized
    }

    var actionButtonLabel: String {
        switch self {
        case .stopping:
            "Stop"
        case .stopped:
            "Start"
        case .starting:
            "Start"
        case .running:
            "Stop"
        }
    }
}

@Observable
class APIServerManager {
    private let server = APIServer()

    /// port to start the server on.
    /// Any changes will be applied on the next server.start.
    var port: Int {
        didSet {
            UserDefaultsKey.apiServerPort.setValue(value: self.port)
        }
    }
    var serverState: ServerState = .stopped
    var error: Error? {
        didSet {
            guard let error else { return }
            logger.error(category: category, error: error)
        }
    }

    init() {
        self.port =
            UserDefaultsKey.apiServerPort.getValue() as? Int
            ?? APIServerConstant.defaultPort
    }

    func startServer() {
        guard self.serverState == .stopped else { return }
        self.serverState = .starting
        Task {
            do {
                try await server.start(port: self.port)
                self.serverState = .running
            } catch {
                self.serverState = .stopped
                self.error = error
            }
        }
    }

    func stopServer() {
        guard self.serverState == .running else { return }
        self.serverState = .stopping
        Task {
            await server.stop()
            self.serverState = .stopped
        }
    }
}
