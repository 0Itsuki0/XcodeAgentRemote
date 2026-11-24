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

struct ProjectListView: View {
    // TODO: - add search by project name, conversation name

    init(apiClient: APIServerClient) {
        self.projectViewModel = ProjectViewModel(apiClient: apiClient)
    }

    @State private var projectViewModel: ProjectViewModel

    private let standardSpacing = UIConstants.standardSpacing

    var body: some View {
        Group {
            if let error = projectViewModel.error {
                self.errorView(error)
            } else {
                self.projectList
            }
        }
        .task {
            await projectViewModel.loadProjects(checkInitial: true)
        }
    }

    @ContentBuilder
    private func errorView(_ error: NetworkError) -> some View {
        ContentUnavailableView {
            Label(
                "Error fetching projects",
                systemImage: "laptopcomputer.trianglebadge.exclamationmark"
            )
        } description: {
            let recovery: String =
                error.recoverySuggestion.map {
                    "\n\($0)"
                } ?? ""
            Text(error.localizedDescription + recovery)
                .padding(.top, UIConstants.standardSpacing)
        } actions: {
            Button("Retry") {
                Task {
                    await projectViewModel.loadProjects(checkInitial: false)
                }
            }
        }
    }

    @ContentBuilder
    private var projectList: some View {
        let projects = projectViewModel.projects.filter {
            $0.projectFile != nil
        }
        List {
            ForEach(projects) { project in
                NavigationLink {
                    ConversationListView(
                        conversations: project.conversations,
                        projectName: project.name,
                        projectStore: project.store.lastPathComponent,
                        projectId: project.id,
                        apiClient: projectViewModel.apiClient,
                        refresh: {
                            await projectViewModel.loadProjects(
                                checkInitial: false
                            )
                        }
                    )
                } label: {
                    HStack(spacing: standardSpacing / 2) {
                        if project.conversations.contains(
                            where: { $0.isUnread && !$0.isArchived }
                        ) {
                            UnreadMark()
                        }
                        Text(project.name)
                        let count = project.conversations.count
                        if count > 0 {
                            Text(
                                "(\(count.formatted(IntegerFormatStyle.nonGrouping)))"
                            )
                        }
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                }
            }
        }
        .contentMargins(.top, UIConstants.standardTopMargin)
        .refreshable {
            await projectViewModel.loadProjects(checkInitial: false)
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

    let conversations: [XcodeChatConversation]
    let projectName: String
    let projectStore: String
    let projectId: String
    let apiClient: APIServerClient

    let refresh: () async -> Void

    private let standardSpacing = UIConstants.standardSpacing

    var body: some View {
        List {
            ForEach(conversations.filter { !$0.isArchived }) { conversation in
                NavigationLink {
                    ChatView(
                        apiClient: apiClient,
                        conversation: conversation,
                        projectName: projectName,
                        projectStore: projectStore,
                        projectId: projectId
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

extension Array where Element == XcodeChatConversation {
    var sortedByLastActivity: Self {
        return self.sorted(by: {
            ($0.lastActivityDate?.timeIntervalSince1970 ?? 0)
                > ($1.lastActivityDate?.timeIntervalSince1970 ?? 0)
        })
    }
}
