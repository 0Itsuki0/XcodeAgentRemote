//
//  ProjectListView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/22.
//

import SwiftUI

struct ProjectListView: View {
    // TODO: - add search by project name, conversation name

    init(apiClient: APIServerClient) {
        self.projectViewModel = ProjectViewModel(apiClient: apiClient)
    }

    @State private var projectViewModel: ProjectViewModel
    @Environment(\.tappedConversationId) private var tappedConversationId

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
                let shouldHighlight = project.conversations.contains {
                    $0.id == tappedConversationId
                }
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
                    .environment(\.tappedConversationId, tappedConversationId)
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
                .listRowBackground(
                    shouldHighlight ? Color.accentColor : nil
                )
            }
        }
        .contentMargins(.top, UIConstants.standardTopMargin)
        .refreshable {
            await projectViewModel.loadProjects(checkInitial: false)
        }
    }
}
