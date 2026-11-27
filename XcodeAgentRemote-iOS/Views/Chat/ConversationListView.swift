//
//  ConversationListView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/26.
//

import SwiftUI

// TODO: - add a create new button (maybe use a menu and show a list of providers upon tap)
struct ConversationListView: View {

    let conversations: [XcodeConversation]
    let projectName: String
    let projectId: String
    let projectFile: URL
    let apiClient: APIServerClient

    let refresh: () async -> Void
    let error: NetworkError?
    let fetching: Bool

    @State private var searchQuery: String = ""

    private var allConversation: [XcodeConversation] {
        conversations.filter { !$0.isArchived }
    }

    private var filteredConversation: [XcodeConversation] {
        return self.allConversation.applySearchQuery(searchQuery)
    }

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
            ForEach(filteredConversation) { conversation in
                NavigationLink {
                    ChatView(
                        apiClient: apiClient,
                        conversation: conversation,
                        projectName: projectName,
                        projectId: projectId,
                        projectFile: projectFile
                    )
                } label: {
                    VStack(alignment: .leading, spacing: standardSpacing / 2) {

                        HStack(spacing: standardSpacing / 2) {
                            if conversation.isUnread
                                || conversation.id == tappedConversationId
                            {
                                UnreadMark()
                            }

                            Text(conversation.displayName)
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
        .refreshable {
            await self.refresh()
        }
        .overlay { centerOverlay }
        .searchable(
            text: $searchQuery,
            prompt: Text("Conversation name...")
        )
        .onChange(of: tappedConversationId, initial: true) {
            handleTappedConversation(shouldTryRefetch: true)
        }
        .onChange(of: allConversation, initial: true) {
            handleTappedConversation(shouldTryRefetch: false)
        }
    }

    private func handleTappedConversation(shouldTryRefetch: Bool) {
        guard let tappedConversationId else {
            self.searchQuery = ""
            return
        }
        if let project = allConversation.first(where: {
            $0.id == tappedConversationId
        }) {
            self.searchQuery = project.name
            return
        }

        if shouldTryRefetch { refreshSync() }
    }

    private func refreshSync() {
        Task {
            await refresh()
        }
    }

    @ContentBuilder
    private var centerOverlay: some View {
        if allConversation.isEmpty {
            if fetching {
                ProgressView()
                    .controlSize(.extraLarge)
            } else if error == nil {
                ContentUnavailableView(
                    label: {
                        Label(
                            "No conversations",
                            systemImage: SymbolNames.conversations
                        )
                    },
                    actions: {
                        Button("refresh", action: refreshSync)
                    }
                )
                .frame(maxHeight: .infinity, alignment: .center)
            }
        } else if filteredConversation.isEmpty {
            ContentUnavailableView(
                "No conversations",
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
            retry: refreshSync,
            retryDisabled: fetching
        )
    }
}
