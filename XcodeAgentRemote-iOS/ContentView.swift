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
                Please download it from [Github](\(gitHubLink)) and set up accordingly.
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

struct ConversationListView: View {
    // TODO: - add search by conversation name

    let conversations: [XcodeConversation]
    let projectName: String
    let projectStore: String
    let projectId: String
    let apiClient: APIServerClient

    let refresh: () async -> Void
    let error: NetworkError?
    let fetching: Bool

    @Environment(\.tappedConversationId) private var tappedConversationId

    private let standardSpacing = UIConstants.standardSpacing

    var body: some View {
        Group {
            if let error = error {
                self.errorView(error)
            } else {
                self.conversationList
            }
        }
        .navigationTitle("Conversations")
        .navigationSubtitle(projectName)
        .toolbarTitleDisplayMode(.inline)

    }

    @ContentBuilder
    private var conversationList: some View {
        List {
            ForEach(conversations.filter { !$0.isArchived }) { conversation in
                let shouldHighlight = conversation.id == tappedConversationId
                NavigationLink {
                    ChatView(
                        apiClient: apiClient,
                        conversation: conversation,
                        projectName: projectName,
                        projectStore: projectStore,
                        projectId: projectId,
                        lastActivityDate: conversation.lastActivityDate
                    )
                } label: {
                    VStack(alignment: .leading, spacing: standardSpacing / 2) {

                        HStack(spacing: standardSpacing / 2) {
                            if conversation.isUnread || shouldHighlight {
                                UnreadMark()
                            }

                            Text(conversation.name)
                        }

                        if let lastActivity = conversation.lastActivityDate {
                            Text(
                                lastActivity.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                }
                .listRowBackground(
                    shouldHighlight ? Color.accentColor : nil
                )
            }
        }
        .contentMargins(.top, UIConstants.standardTopMargin)
        .refreshable {
            await self.refresh()
        }
        .overlay { centerOverlay }
    }

    @ContentBuilder
    private var centerOverlay: some View {
        if conversations.isEmpty {
            if fetching {
                ProgressView()
                    .controlSize(.extraLarge)
            } else if error == nil {
                ContentUnavailableView(
                    "No conversations",
                    systemImage: "list.bullet"
                )
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }

    @ContentBuilder
    private func errorView(_ error: NetworkError) -> some View {
        NetworkErrorView(
            error: error,
            retry: {
                Task {
                    await refresh()
                }
            },
            retryDisabled: fetching
        )
    }
}

extension Array where Element == XcodeConversation {
    var sortedByLastActivity: Self {
        return self.sorted(by: {
            ($0.lastActivityDate?.timeIntervalSince1970 ?? 0)
                > ($1.lastActivityDate?.timeIntervalSince1970 ?? 0)
        })
    }
}
