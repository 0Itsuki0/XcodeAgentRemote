//
//  ServerSettingView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/22.
//

import SwiftUI

extension ServerSettingView {
    init() {
        let savedClient = APIServerClient.saved
        guard let savedClient else {
            self.urlString = ""
            self.useAuth = false
            self.authHeaderName = ""
            self.authHeaderValue = ""
            return
        }
        self.urlString = savedClient.baseURL.absoluteString
        self.useAuth = savedClient.useAuth
        self.authHeaderName = savedClient.authHeaderName
        self.authHeaderValue = savedClient.authHeaderValue
    }
}

struct ServerSettingView: View {
    @Environment(ServerSettingManager.self) private var serverSettingManager

    @State private var urlString: String
    @State private var useAuth: Bool
    @State private var authHeaderName: String
    @State private var authHeaderValue: String

    private let standardSpacing = UIConstants.standardSpacing

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                self.textEntryRow(
                    title: "URL",
                    text: $urlString,
                    prompt: "https://my.server.dev"
                )

                Toggle("Authorization", isOn: $useAuth)
                    .tint(.accentColor)
                    .fontWeight(.medium)

                if useAuth {
                    self.textEntryRow(
                        title: "Name",
                        text: $authHeaderName,
                        prompt: "ex: Authorization"
                    )
                    self.textEntryRow(
                        title: "Value",
                        text: $authHeaderValue,
                        prompt: "ex: Bearer tok_live_9f8e"
                    )
                }
            } header: {
                SettingHeader(
                    """
                    The app connects to the server started by the Mac app to obtain necessary Xcode chat data as well as sending chat messages.

                    1. Start the server from the Mac App.
                    2. Start a tunnel, for example with `ngrok`.
                    2. Fill in the connection parameters below.
                    """
                )
            }

            Section {
                fullSizeButton(
                    label: {
                        HStack(spacing: standardSpacing) {
                            Text("Test connection")
                            if serverSettingManager.validating {
                                ProgressView().controlSize(.small)
                            }
                        }
                    },
                    action: {
                        self.serverSettingManager.testConfiguration(
                            urlString: urlString,
                            useAuth: useAuth,
                            authHeaderName: authHeaderName,
                            authHeaderValue: authHeaderValue
                        )

                    },
                    error: serverSettingManager.validationError
                )
                .buttonStyle(.glass)
                .disabled(serverSettingManager.validating)

                fullSizeButton(
                    label: {
                        Text("Save configuration")
                    },
                    action: {
                        self.serverSettingManager.saveConfiguration(
                            urlString: urlString,
                            useAuth: useAuth,
                            authHeaderName: authHeaderName,
                            authHeaderValue: authHeaderValue
                        )
                        self.dismiss()
                    }
                )
                .buttonStyle(.glassProminent)
                .disabled(serverSettingManager.validating)

            }
        }
        .listSectionSpacing(standardSpacing)
        .contentMargins(.top, UIConstants.standardTopMargin)
        .navigationTitle("Server Configuration")
        .navigationSubtitle("Server hosted on your Mac")
        .navigationBarTitleDisplayMode(.inline)

    }

    @ContentBuilder
    private func fullSizeButton<Label: View>(
        @ContentBuilder label: () -> Label,
        action: @escaping () -> Void,
        error: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(
                action: action,
                label: {
                    label()
                        .fontWeight(.medium)
                        .padding(.vertical, 4)
                }
            )
            .buttonSizing(.flexible)

            if let error {
                Text(error.trimmed)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 8)

            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(.horizontal, 0)
        .listRowInsets(.vertical, 8)
        .listRowSeparator(.hidden)
    }

    @ContentBuilder
    private func textEntryRow(
        title: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        HStack(spacing: standardSpacing) {
            Text(title)
                .fontWeight(.medium)
            TextField(
                title,
                text: text,
                prompt: Text(prompt)
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
        }

    }
}
