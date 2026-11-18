//
//  DashboardView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/18.
//

import SwiftUI

enum DashboardOption: String, Hashable, CaseIterable {
    case server

    var label: String {
        switch self {
        case .server:
            "API Server"
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
                APIServerView()
            }

        }
    }
}

struct APIServerView: View {
    @Environment(APIServerManager.self) private var serverManager

    private let middleStates = [ServerState.starting, .stopping]

    private var isMiddleState: Bool {
        middleStates.contains(serverManager.serverState)
    }

    private var portFormatStyle: IntegerFormatStyle<Int> {
        .number.grouping(.never)
    }

    var body: some View {
        @Bindable var serverManager = serverManager

        VStack {
            VStack(alignment: .leading) {
                HStack {
                    self.symbol

                    Text(serverManager.serverState.displayLabel)
                        .foregroundStyle(.secondary)

                    Spacer().frame(width: 8)

                    Button(serverManager.serverState.actionButtonLabel) {
                        switch serverManager.serverState {
                        case .stopping, .running:
                            break
                        case .stopped:
                            serverManager.startServer()
                        case .starting:
                            serverManager.stopServer()
                        }
                    }
                    .buttonStyle(.link)
                    .disabled(self.isMiddleState)
                }
                .font(.subheadline)

                if serverManager.serverState == .running {
                    let formattedPort = serverManager.port.formatted(
                        portFormatStyle
                    )

                    Text(
                        """
                        Server listening on `127.0.0.1:\(formattedPort)`
                        Recommend to start a tunnel with `ngrok` to connect from iOS. 
                        ex: `ngrok http \(formattedPort) --url https://<YOUR_DEV_DOMAIN>`
                        [Static dev domains is supported for all users for free](https://ngrok.com/blog/free-static-domains-ngrok-users)
                        """
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Form {
                Section {
                    TextField(
                        "Port",
                        value: $serverManager.port,
                        format: portFormatStyle
                    )
                } footer: {
                    Text("Restart the server to apply any changes.")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        }
        .navigationTitle(DashboardOption.server.label)

    }

    @ContentBuilder
    private var symbol: some View {
        Image(systemName: "circle.fill")
            .foregroundStyle(serverManager.serverState.symbolColor)
            .symbolEffect(
                .pulse,
                isActive: isMiddleState
            )
    }
}
