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

    var ngrokURL: String {
        didSet {
            UserDefaultsKey.ngrokURL.setValue(value: self.ngrokURL)
        }
    }

    var startAPIServerOnAppLaunch: Bool {
        didSet {
            UserDefaultsKey.startAPIServerOnAppLaunch.setValue(
                value: self.startAPIServerOnAppLaunch
            )
        }
    }

    var startNgrokTunnelOnServerStart: Bool {
        didSet {
            UserDefaultsKey.startNgrokTunnelOnServerStart.setValue(
                value: self.startNgrokTunnelOnServerStart
            )
        }
    }

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
    var serverError: Error? {
        didSet {
            guard let serverError else { return }
            logger.error(category: category, error: serverError)
        }
    }

    var ngrokRunning: Bool {
        return ngrokCommand != nil
    }
    private var ngrokCommand: CommandExecutor.RunningCommand?
    var ngrokError: Error? {
        didSet {
            guard let ngrokError else { return }
            logger.error(category: category, error: ngrokError)
        }
    }

    @ObservationIgnored
    private var observationToken: NotificationCenter.ObservationToken?

    init(
        watchingConversations: @Sendable @escaping () -> [String],
        watchConversation: @Sendable @escaping (String) async throws -> Void,
        stopWatchingConversation: @Sendable @escaping (String) async -> Void
    ) {
        self.server = APIServer(
            watchingConversations: watchingConversations,
            watchConversation: watchConversation,
            stopWatchingConversation: stopWatchingConversation
        )

        #if DEBUG
            UserDefaultsKey.ngrokURL.setValue(value: DebugConstants.ngrokURL)
            UserDefaultsKey.startAPIServerOnAppLaunch.setValue(value: true)
            UserDefaultsKey.startNgrokTunnelOnServerStart.setValue(value: true)
        #endif

        self.ngrokURL =
            UserDefaultsKey.ngrokURL.getValue() as? String
            ?? ""

        self.startAPIServerOnAppLaunch =
            UserDefaultsKey.startAPIServerOnAppLaunch.getValue() as? Bool
            ?? false

        self.startNgrokTunnelOnServerStart =
            UserDefaultsKey.startNgrokTunnelOnServerStart.getValue() as? Bool
            ?? false

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

        /// A process the app started isn't stopped with it: stop ngrok when the app quits. (Killed instead, e.g. stopped
        /// from Xcode, the app runs no code: the next launch stops that ngrok, `stopLeftoverNgrok`.)
        observationToken = NotificationCenter.default.addObserver(
            of: NSApplication.shared,
            for: .willTerminate
        ) { [weak self] _ in
            self?.ngrokCommand?.terminate()
        }
        Self.stopLeftoverNgrok()

        if self.startAPIServerOnAppLaunch {
            self.startServer()
        }
    }

    /// Stops the ngrok an earlier run of the app started and left running (the app was killed before it could stop
    /// it): it keeps the tunnel's URL, so this run's ngrok couldn't start.
    private static func stopLeftoverNgrok() {
        guard let pid = UserDefaultsKey.ngrokProcessID.getValue() as? Int else {
            return
        }
        UserDefaultsKey.ngrokProcessID.setValue(value: nil)
        // Only if that pid is still an ngrok (the pid may belong to another process by now).
        let command = CommandExecutor.runCommand([
            "ps", "-o", "comm=", "-p", "\(pid)",
        ])?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard command?.hasSuffix("ngrok") == true else { return }
        kill(pid_t(pid), SIGTERM)
    }

    // TODO: - consider adding additional arguments to route error to stdout
    //    itsuki@MacBook-Pro ~ %  ngrok http 8000 --url https://madison-vernal-unanecdotally.ngrok-free.dev --log stdout --log-level crit
    //    t=2026-11-24T16:02:05+0900 lvl=crit msg="command failed" err="failed to start tunnel: The endpoint 'https://madison-vernal-unanecdotally.ngrok-free.dev' is already online. Either\n1. stop your existing endpoint first, or\n2. start both endpoints with `--pooling-enabled` to load balance between them.\r\n\r\nERR_NGROK_334\r\n"
    //    ERROR:  failed to start tunnel: The endpoint 'https://madison-vernal-unanecdotally.ngrok-free.dev' is already online. Either
    //    ERROR:  1. stop your existing endpoint first, or
    //    ERROR:  2. start both endpoints with `--pooling-enabled` to load balance between them.
    //    ERROR:
    //    ERROR:  ERR_NGROK_334
    //    ERROR:  https://ngrok.com/docs/errors/err_ngrok_334
    //    ERROR:
    func startNgrokTunnel() {
        guard self.ngrokCommand == nil else { return }

        do {
            let command = try CommandExecutor.runCommandStream(
                [
                    "ngrok", "http", "\(port)", "--url", self.ngrokURL,
                ],
                onExit: { [weak self] error in
                    guard let self else { return }
                    Task {
                        await MainActor.run {
                            if let error {
                                self.ngrokError = error
                            }
                            self.stopNgrokTunnel()
                        }
                    }
                }
            )
            self.ngrokCommand = command
            UserDefaultsKey.ngrokProcessID.setValue(
                value: Int(command.processIdentifier)
            )
        } catch {
            self.ngrokError = error
        }
    }

    func stopNgrokTunnel() {
        /// Process exited: nothing to stop on the next launch.
        if let pid = self.ngrokCommand?.processIdentifier,
            UserDefaultsKey.ngrokProcessID.getValue()
                as? Int == Int(pid)
        {
            UserDefaultsKey.ngrokProcessID.setValue(
                value: nil
            )
        }
        ngrokCommand?.terminate()
        self.ngrokCommand = nil
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

                if self.startNgrokTunnelOnServerStart {
                    self.startNgrokTunnel()
                }
            } catch {
                self.serverState = .stopped
                self.serverError = error
            }
        }
    }

    func stopServer() {
        guard self.serverState == .running else { return }
        self.serverState = .stopping
        Task {
            await server.stop()
            self.serverState = .stopped
            self.stopNgrokTunnel()
        }
    }
}
