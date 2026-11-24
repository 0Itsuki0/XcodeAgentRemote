//
//  DashboardWindow.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/18.
//

import SwiftUI

enum DashboardOption: String, Hashable, CaseIterable {
    case server
    case watcher

    var label: String {
        switch self {
        case .server:
            "API Server"
        case .watcher:
            "Chat Watcher"
        }
    }

    var navigationTitle: String {
        switch self {
        case .server:
            "API Server Setting"
        case .watcher:
            "Chat Watcher"
        }
    }
}

struct DashboardWindow: View {
    static let identifier = "DashboardWindow"

    @State private var selection: DashboardOption = .server

    var body: some View {
        NavigationSplitView {
            List(DashboardOption.allCases, id: \.self, selection: $selection) {
                option in
                Text(option.label)
                    .bold(option == selection)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(240)
        } detail: {
            switch selection {
            case .server:
                ServerSettingView()
            case .watcher:
                ChatWatcherConfigurationView()
            }

        }
        .onWindow { window in
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
    }
}

struct ChatWatcherConfigurationView: View {
    @Environment(ChatWatcher.self) private var chatWatcher

    // TODO: - add iCloud account state, add project / conversation list

    var body: some View {
        Button("watch") {
            //            let url = URL.desktopDirectory.appending(path: "test.txt")
            //            Task {
            //                do {
            ////                    try await chatWatcher.watchFile(at: url)
            //                } catch {
            //                    print(error)
            //                }
            //            }
        }
    }
}

// TODO: add auto ngrok. Force kill app may not stop ngrok correctly. run `killall ngrok` if needed.
struct ServerSettingView: View {
    @Environment(APIServerManager.self) private var serverManager

    private let middleStates = [ServerState.starting, .stopping]

    private var isMiddleState: Bool {
        middleStates.contains(serverManager.serverState)
    }

    private let portFormatStyle: IntegerFormatStyle<Int> = .nonGrouping

    var body: some View {
        @Bindable var serverManager = serverManager
        Form {
            Section {
                TextField(
                    "Port",
                    value: $serverManager.port,
                    format: portFormatStyle
                )

                // TODO: - add auth configuration

                Toggle(
                    "Start on app launch",
                    isOn: $serverManager.startAPIServerOnAppLaunch
                )
            } header: {
                VStack(alignment: .leading) {
                    Text("App Server")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    HStack {
                        self.symbol

                        Text(serverManager.serverState.displayLabel)
                            .foregroundStyle(.secondary)

                        Spacer().frame(width: 8)

                        Button(serverManager.serverState.actionButtonLabel) {
                            switch serverManager.serverState {
                            case .stopping, .starting:
                                break
                            case .stopped:
                                serverManager.startServer()
                            case .running:
                                serverManager.stopServer()
                            }
                        }
                        .buttonStyle(.link)
                        .disabled(self.isMiddleState)
                    }
                    .font(.subheadline)

                    Text(explanationText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    InlineErrorView(
                        error: $serverManager.serverError,
                        autoDisappear: .seconds(3)
                    ).padding(.top, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            } footer: {
                Text("Restart the server to apply any changes.")
                    .font(.caption)
            }

            NgrokSettingSection()
        }
        .contentMargins(.top, 0)
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .navigationTitle(DashboardOption.server.navigationTitle)

    }

    @ContentBuilder
    private var symbol: some View {
        StateSymbol()
            .foregroundStyle(serverManager.serverState.symbolColor)
            .symbolEffect(
                .pulse,
                isActive: isMiddleState
            )
    }

    private var explanationText: LocalizedStringKey {
        let formattedPort = serverManager.port.formatted(
            portFormatStyle
        )

        if serverManager.serverState == .running {
            return """
                Server listening on `127.0.0.1:\(formattedPort)`.
                """
        } else {
            return """
                Start a server listening on `127.0.0.1:\(formattedPort)`
                to expose necessary endpoints to the iOS app.
                """
        }
    }
}

struct InlineErrorView: View {
    @Binding var error: Error?
    let autoDisappear: Duration?
    var body: some View {
        if let error {
            Text(error.localizedDescription)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption)
                .foregroundStyle(.red)
                .task {
                    if let autoDisappear {
                        try? await Task.sleep(for: autoDisappear)
                        self.error = nil
                    }
                }
        }
    }
}

struct StateSymbol: View {
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
    }
}

struct NgrokSettingSection: View {
    @Environment(APIServerManager.self) private var serverManager
    private var running: Bool {
        serverManager.ngrokRunning
    }
    var body: some View {
        @Bindable var serverManager = serverManager
        Section {
            TextField(
                "URL",
                text: $serverManager.ngrokURL,
            )

            Toggle(
                "Start on server start",
                isOn: $serverManager.startNgrokTunnelOnServerStart
            )
        } header: {
            VStack(alignment: .leading) {
                Text("Ngrok Tunnel")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                HStack {
                    StateSymbol()
                        .foregroundStyle(running ? .green : .red)

                    Text(running ? "Tunneling" : "Stopped")
                        .foregroundStyle(.secondary)

                    Spacer().frame(width: 8)

                    Button(running ? "Stop" : "Start") {
                        running
                            ? serverManager.stopNgrokTunnel()
                            : serverManager.startNgrokTunnel()
                    }
                    .buttonStyle(.link)
                }
                .font(.subheadline)

                Text(explanationText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                InlineErrorView(
                    error: $serverManager.ngrokError,
                    autoDisappear: .seconds(3)
                ).padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        } footer: {
            Text("Restart the tunnel to apply any changes.")
                .font(.caption)
        }

    }

    private var explanationText: LocalizedStringKey {
        if running {
            return """
                Tunneling listening on `\(serverManager.ngrokURL)`.
                If app exits unexpectedly, `ngrok` might not be stopped correctly. 
                Run `killall ngrok` if needed.
                """
        } else {
            return """
                Start a tunnel with `ngrok` for connection from iOS using `https`. 
                [Static dev domains is supported for all users for free](https://ngrok.com/blog/free-static-domains-ngrok-users)
                """
        }
    }
}
