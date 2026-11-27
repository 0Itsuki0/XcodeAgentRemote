//
//  ProjectListView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/22.
//

import SwiftUI

struct ProjectListView: View {

    init(apiClient: APIServerClient) {
        self.projectViewModel = ProjectViewModel(apiClient: apiClient)
    }

    @State private var projectViewModel: ProjectViewModel

    @State private var searchQuery: String = ""

    @Environment(\.tappedConversationId) private var tappedConversationId

    private let standardSpacing = UIConstants.standardSpacing

    private var allProjects: [XcodeProject] {
        projectViewModel.projects.filter {
            $0.projectFile != nil
        }
    }

    private var filteredProject: [XcodeProject] {
        return self.allProjects.applySearchQuery(searchQuery)
    }

    var body: some View {
        Group {
            if let error = projectViewModel.error {
                self.errorView(error)
            } else {
                self.projectList
            }
        }
        .task {
            await projectViewModel.loadProjects()
        }
    }

    @ContentBuilder
    private var centerOverlay: some View {
        if allProjects.isEmpty {
            if projectViewModel.isFetching {
                ProgressView()
                    .controlSize(.extraLarge)
            } else if projectViewModel.error == nil {
                ContentUnavailableView(
                    label: {
                        Label(
                            "No projects",
                            systemImage: SymbolNames.projects
                        )
                    },
                    actions: {
                        Button("refresh", action: reloadProjectSync)
                    }
                )
                .frame(maxHeight: .infinity, alignment: .center)
            }
        } else if filteredProject.isEmpty {
            ContentUnavailableView(
                "No projects",
                systemImage: SymbolNames.search,
                description: Text(
                    "No results found for \"\(searchQuery.trimmed)\""
                )
            )
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    @ContentBuilder
    private func errorView(_ error: NetworkError) -> some View {
        NetworkErrorView(
            error: error,
            retry: reloadProjectSync,
            retryDisabled: projectViewModel.isFetching
        )
    }

    private func reloadProjectSync() {
        Task {
            await projectViewModel.loadProjects()
        }
    }

    @ContentBuilder
    private var projectList: some View {
        List {
            ForEach(filteredProject) { project in
                /// `allProjects` only has projects with a project file.
                if let projectFile = project.projectFile {
                    let unread =
                        project.conversations.contains {
                            !$0.isArchived
                                && ($0.id == tappedConversationId
                                    || $0.isUnread)
                        }
                    NavigationLink {
                        ConversationListView(
                            conversations: project.conversations,
                            projectName: project.name,
                            projectId: project.id,
                            projectFile: projectFile,
                            apiClient: projectViewModel.apiClient,
                            refresh: projectViewModel.loadProjects,
                            error: projectViewModel.error,
                            fetching: projectViewModel.isFetching
                        )
                        .environment(
                            \.tappedConversationId,
                            tappedConversationId
                        )
                    } label: {
                        HStack(spacing: standardSpacing / 2) {
                            if unread {
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
        }
        .contentMargins(.top, UIConstants.standardTopMargin)
        .refreshable {
            await projectViewModel.loadProjects()
        }
        .overlay { centerOverlay }
        .searchable(
            text: $searchQuery,
            prompt: Text("Project / conversation name...")
        )
        .onChange(of: tappedConversationId, initial: true) {
            handleTappedConversation(shouldTryRefetch: true)
        }
        .onChange(of: allProjects, initial: true) {
            handleTappedConversation(shouldTryRefetch: false)
        }
    }

    private func handleTappedConversation(shouldTryRefetch: Bool) {
        guard let tappedConversationId else {
            self.searchQuery = ""
            return
        }
        if let project = allProjects.first(where: {
            $0.conversations.contains(where: {
                $0.id == tappedConversationId && !$0.isArchived
            })
        }) {
            self.searchQuery = project.name
            return
        }

        if shouldTryRefetch { reloadProjectSync() }
    }
}

