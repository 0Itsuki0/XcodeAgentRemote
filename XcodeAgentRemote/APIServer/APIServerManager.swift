//
//  APIServerManager.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/18.
//

import SwiftUI

private let logger = Logger.shared
private let category = Logger.category(#fileID)

enum ServerState: Equatable, Hashable, Sendable {
    case stopping
    case stopped
    case starting
    case running
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

        }
    }

}
