//
//  DashboardWindow.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/18.
//

import Combine
import SwiftUI

enum DashboardOption: String, Hashable, CaseIterable {
    case server
    case watcher
    case appleEvent

    var label: String {
        switch self {
        case .server:
            "API Server"
        case .watcher:
            "Chat Watcher"
        case .appleEvent:
            "Apple Event"
        }
    }

    var navigationTitle: String {
        switch self {
        case .server:
            "API Server Setting"
        case .watcher:
            "Chat Watcher"
        case .appleEvent:
            "Apple Event Permission"
        }
    }
}

struct DashboardWindow: View {
    static let identifier = "DashboardWindow"

    @State private var selection: DashboardOption = .watcher

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
            case .appleEvent:
                AppleEventView()
            }

        }
        .onWindow { window in
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
    }
}


struct SettingForm<Content: View>: View {
    @ContentBuilder let content: Content

    var body: some View {
        Form {
            self.content
        }
        .contentMargins(.top, -8)
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
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

struct ExplanationText: View {
    private let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) {
        self.text = text
    }
    var body: some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

    }
}

struct AppleEventView: View {
    @State private var permissionGranted: Bool = false
    @State private var automationStatus: XcodeAutomation.PermissionStatus =
        .notDetermined

    @State private var processing: Bool = false

    @Environment(\.openURL) private var openURL

    /// whether the window has focus
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        SettingForm {
            Section {
                Toggle(
                    "Automation Permission",
                    isOn: $permissionGranted
                )
            } header: {
                ExplanationText(
                    """
                    Apple event / Automation used for closing Xcode project before 
                    running the agent Programmatically to process the message and get response.

                    This is needed because Xcode only loads chat data on project opening.
                    It then keeps the project's chats in memory and 
                    may overwrite the turns this app records.

                    For more details, please refer to [Why not keep Xcode open](\(String.gitHub)#why-not-keep-xcode-open)
                    """
                )
            }
        }
        .navigationTitle(DashboardOption.appleEvent.navigationTitle)
        .onChange(of: self.permissionGranted) {
            self.handlePermissionToggle()
        }
        .onChange(of: appearsActive, initial: true) {
            guard appearsActive else { return }
            self.refreshPermissionStates(prompt: false)
        }
    }

    private func refreshPermissionStates(prompt: Bool) {
        self.processing = true
        Task {
            defer { processing = false }
            self.automationStatus = await XcodeAutomation.automationPermission(
                askIfNeeded: false
            )
            self.permissionGranted = automationStatus == .granted
        }
    }

    private func handlePermissionToggle() {
        guard !self.processing else { return }
        if self.equal(
            granted: self.permissionGranted,
            automationStatus: automationStatus
        ) {
            return
        }

        guard self.automationStatus == .notDetermined else {
            openAutomationSettings()
            return
        }

        self.refreshPermissionStates(prompt: true)
    }

    private func openAutomationSettings() {
        print(#function)
        if let url = URL(string: XcodeAutomation.settingURL) {
            self.openURL(url)
        }
    }

    private func equal(
        granted: Bool,
        automationStatus: XcodeAutomation.PermissionStatus
    ) -> Bool {
        granted == (automationStatus == .granted)
    }
}
