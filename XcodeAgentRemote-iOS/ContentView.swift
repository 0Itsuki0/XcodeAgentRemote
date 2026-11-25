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
    @Environment(ServerSettingManager.self) private var serverSettingManager
    @State private var showSettings: Bool = false

    var body: some View {
        Group {
            if let apiClient = serverSettingManager.apiClient {
                ProjectListView(apiClient: apiClient)
                //                ChatView.debugServerCall(apiClient)
            } else {
                ContentUnavailableView {
                    Label("Server not configured", systemImage: "server.rack")
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
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(serverSettingManager)
        }
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

    @Environment(\.tappedConversationId) private var tappedConversationId

    private let standardSpacing = UIConstants.standardSpacing

    var body: some View {
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
                            if conversation.isUnread {
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
        .navigationTitle("Conversations")
        .navigationSubtitle(projectName)
        .toolbarTitleDisplayMode(.inline)
        .refreshable {
            await self.refresh()
        }
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
