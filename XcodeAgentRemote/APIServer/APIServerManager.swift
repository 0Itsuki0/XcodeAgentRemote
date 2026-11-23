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
    private let server: APIServer

    /// port to start the server on.
    /// Any changes will be applied on the next server.start.
    var port: Int {
        didSet {
            UserDefaultsKey.apiServerPort.setValue(value: self.port)
        }
    }

    var authHeader: AuthHeader {
        didSet {
            UserDefaultsKey.apiServerAuthHeaderName.setValue(
                value: self.authHeader.name
            )
            UserDefaultsKey.apiServerAuthHeaderValue.setValue(
                value: self.authHeader.value
            )
        }
    }

    var useAuth: Bool {
        didSet {
            UserDefaultsKey.apiServerUseAuth.setValue(value: self.useAuth)
        }
    }

    private(set) var serverState: ServerState = .stopped
    var error: Error? {
        didSet {
            guard let error else { return }
            logger.error(category: category, error: error)
        }
    }

    init(chatWatcher: ChatWatcher) {
        self.server = APIServer(chatWatcher: chatWatcher)
        self.port =
            UserDefaultsKey.apiServerPort.getValue() as? Int
            ?? APIServerConstants.defaultPort

        self.useAuth =
            UserDefaultsKey.apiServerUseAuth.getValue() as? Bool ?? false

        let authHeaderName =
            UserDefaultsKey.apiServerAuthHeaderName.getValue() as? String ?? ""
        let authHeaderValue =
            UserDefaultsKey.apiServerAuthHeaderValue.getValue() as? String ?? ""

        self.authHeader = AuthHeader(
            name: authHeaderName,
            value: authHeaderValue
        )
    }

    func startServer() {
        guard self.serverState == .stopped else { return }
        self.serverState = .starting
        Task {
            do {
                try await server.start(
                    port: self.port,
                    authHeader: self.useAuth ? self.authHeader : nil
                )
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
