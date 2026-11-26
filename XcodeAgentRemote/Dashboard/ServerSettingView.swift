
struct ServerSettingView: View {
    @Environment(APIServerManager.self) private var serverManager

    private let middleStates = [ServerState.starting, .stopping]

    private var isMiddleState: Bool {
        middleStates.contains(serverManager.serverState)
    }

    private let portFormatStyle: IntegerFormatStyle<Int> = .nonGrouping

    var body: some View {
        @Bindable var serverManager = serverManager
        SettingForm {
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

                    ExplanationText(explanationText)

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

                ExplanationText(explanationText)

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
