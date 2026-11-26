//
//  ContentView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/14.
//

import CloudKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @AppStorage(
        UserDefaultsKey.iosFirstLaunch.key,
        store: UserDefaultsKey.userDefaults
    ) var firstLaunch: Bool = true

    @Environment(ServerSettingManager.self) private var serverSettingManager
    @State private var showSettings: Bool = false

    var body: some View {
        Group {
            if firstLaunch {
                IntroductionView {
                    firstLaunch = false
                    showSettings = true
                }
            } else {
                self.subsequentLaunchRoot
            }
        }
        .animation(.smooth, value: firstLaunch)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(serverSettingManager)
        }
    }

    @ContentBuilder
    private var subsequentLaunchRoot: some View {
        Group {
            if let apiClient = serverSettingManager.apiClient {
                ProjectListView(apiClient: apiClient)
                //                ChatView.debugServerCall(apiClient)
            } else {
                ContentUnavailableView {
                    Label(
                        "Server not configured",
                        systemImage: "server.rack"
                    )
                } description: {
                    Text(
                        "Please set up the configuration parameters for your Mac server."
                    )
                    .padding(.top, UIConstants.standardSpacing)
                } actions: {
                    Button("Settings") {
                        // TODO: - show server settings directly instead of top settings
                        showSettings = true
                    }
                }
            }
        }
        .navigationTitle("Xcode Projects")
        .navigationSubtitle("Projects with existing conversations")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") {
                    showSettings = true
                }
            }
        }
        .labelStyle(.iconOnly)
    }
}

struct IntroductionView: View {
    let setup: () -> Void

    private let standardSpacing = UIConstants.standardSpacing
    var body: some View {
        VStack(spacing: standardSpacing * 2) {
            VStack(spacing: standardSpacing) {

                Image(.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128)
                VStack(spacing: standardSpacing / 2) {

                    Text("Xcode Agent Remote")
                        .font(.title)
                        .fontWeight(.heavy)

                    Text("Continue Xcode chat from anywhere.")
                        .font(.subheadline)
                }
            }

            Text(
                """
                This app works together with the MacOS app.
                Please download it from [Github](\(String.gitHub)) and set up accordingly.
                """
            )
            .foregroundStyle(.secondary)
            .font(.subheadline)

            Button("Set up iOS", action: setup)
                .buttonSizing(.flexible)
                .frame(maxWidth: .infinity)
                .buttonStyle(.glassProminent)
                .fontWeight(.medium)

        }
        .multilineTextAlignment(.center)
        .padding(.all, standardSpacing)
    }
}

struct UnreadMark: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 8)
    }
}
