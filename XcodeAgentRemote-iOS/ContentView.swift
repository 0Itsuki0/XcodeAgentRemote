//
//  ContentView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/14.
//

import CloudKit
import SwiftData
import SwiftUI

//@Observable class AppViewRouter {
//
//}

struct ContentView: View {
    @Environment(ServerSettingManager.self) private var serverSettingManager
    @State private var showSettings: Bool = false

    var body: some View {
        Group {
            if let apiClient = serverSettingManager.apiClient {
//                ProjectListView(apiClient: apiClient)
                ChatView.debugServerCall(apiClient)
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
        let projects = [DebugConstants.project]
        List {
            NavigationLink {
                ChatView.debugUI()
            } label: {
                Text("Dummy chat")
            }

            ForEach(projects) { project in
                NavigationLink {
                    ConversationListView(
                        conversations: project.conversations,
                        projectName: project.name
                    )
                } label: {
                    HStack(spacing: standardSpacing / 2) {
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
        //        .navigationDestination(item: , destination: )
        .contentMargins(.top, UIConstants.standardTopMargin)
        // TODO: - check if the call is cancelled immediately like ChatView
        // if yes, switch to .task with id.
        .refreshable {
            await projectViewModel.loadProjects(checkInitial: false)
        }

    }
}

struct ConversationListView: View {
    // TODO: - add search by conversation name

    let conversations: [XcodeChatConversation]
    let projectName: String

    private let standardSpacing = UIConstants.standardSpacing

    var body: some View {
        List {
            ForEach(conversations.filter { !$0.isArchived }) { conversation in
                NavigationLink {
                    // TODO: - add conversation detail view
                } label: {
                    VStack(alignment: .leading, spacing: standardSpacing / 2) {
                        HStack(spacing: standardSpacing / 2) {
                            if conversation.isUnread {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8)
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
            //            /// Xcode's model identifier for the agent, e.g. "claude-code" (the chat's metadata).
            //            var modelIdentifier: String?
            //            /// The agent's own session id (`conversation.plist` → `assistantConfiguration`).
            //            var providerSessionID: String?
            //            /// The navigator group (folder) the chat is in, if any.
            //            var group: String?
            //            var isArchived: Bool
            //            var isUnread: Bool
            //            /// The line under the chat's name in Xcode's navigator, e.g. "Editing README.md".
            //            var subtitle: String?
            //            var startDate: Date?
            //            var lastActivityDate: Date?

        }
        .contentMargins(.top, UIConstants.standardTopMargin)
        .navigationTitle("Conversations")
        .navigationSubtitle(projectName)
        .toolbarTitleDisplayMode(.inline)

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
