//
//  ChatWatcherView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/26.
//

import SwiftUI

struct ChatWatcherView: View {
    @Environment(ChatWatcher.self) private var chatWatcher

    @State private var projects: [XcodeProject] = Self.listProject()
    @State private var searchQuery: String = ""

    private var filteredProject: [XcodeProject] {
        return self.projects.applySearchQuery(searchQuery)
    }

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    ContentUnavailableView(
                        label: {
                            Label(
                                "No projects",
                                systemImage: SymbolNames.projects
                            )
                        },
                        description: {
                            self.makeExplanationText(showNoProjectMessage: true)
                        },
                        actions: {
                            Button("Refresh", action: self.refresh)
                        }
                    )
                } else if filteredProject.isEmpty {
                    ContentUnavailableView(
                        "No projects",
                        systemImage: SymbolNames.search,
                        description: Text(
                            "No results found for \"\(searchQuery.trimmed)\""
                        )
                    )
                } else {
                    SettingForm {
                        Section {
                            ForEach(filteredProject) { project in
                                NavigationLink {
                                    ConversationListView(
                                        projectName: project.name,
                                        conversations: project.conversations
                                            .filter { !$0.isArchived },
                                        refresh: self.refresh
                                    )
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(project.name)

                                        if let projectFile = project.projectFile
                                        {
                                            HStack {
                                                Text(
                                                    projectFile
                                                        .lastPathComponent
                                                )
                                                .foregroundStyle(.secondary)
                                                .font(.subheadline)
                                                Button(
                                                    "Open",
                                                    systemImage: "arrow.right"
                                                ) {
                                                    NSWorkspace.shared
                                                        .activateFileViewerSelecting(
                                                            [
                                                                projectFile
                                                            ])
                                                }
                                                .font(.footnote)
                                                .fontWeight(.medium)
                                                .labelStyle(.iconOnly)
                                                .buttonStyle(.link)
                                            }

                                        }
                                    }
                                }
                            }
                        } header: {
                            self.makeExplanationText(
                                showNoProjectMessage: false
                            )
                        }
                    }
                    .refreshable(action: self.refresh)
                }

            }
            .navigationTitle("Xcode Projects")
            .navigationSubtitle("Projects with existing conversations")
            .environment(self.chatWatcher)
            .searchable(
                text: $searchQuery,
                prompt: Text("Project / conversation name...")
            )

        }
    }

    @ContentBuilder
    private func makeExplanationText(showNoProjectMessage: Bool) -> some View {
        let message = """
            \(showNoProjectMessage ? "No projects with existing conversations found." : "")
            Watch a conversation to start receiving notification on new messages from assistant.

            The app uses `iCloud` for sending push notifications.

            To receive notifications on a conversation update:
            1. Sign in to the same iCloud account on both Mac and iOS.
            2. Enable push notification on iOS.
            """
        ExplanationText(LocalizedStringKey(message.trimmed))
            .padding(.bottom, 2)
    }

    private static func listProject() -> [XcodeProject] {
        return ChatStore.listProjects()
            .filter { $0.projectFile != nil }
    }

    private func refresh() {
        self.projects = Self.listProject()
    }
}

private struct ConversationListView: View {
    @Environment(ChatWatcher.self) private var chatWatcher

    let projectName: String
    let conversations: [XcodeConversation]
    let refresh: () -> Void

    @State private var searchQuery: String = ""

    private var filteredConversation: [XcodeConversation] {
        return self.conversations.applySearchQuery(searchQuery)
    }

    var body: some View {
        Group {
            if conversations.isEmpty {
                ContentUnavailableView(
                    label: {
                        Label(
                            "No conversations",
                            systemImage: SymbolNames.conversations
                        )
                    },
                    actions: {
                        Button("refresh", action: refresh)
                    }
                )

            } else if filteredConversation.isEmpty {
                ContentUnavailableView(
                    "No conversations",
                    systemImage: SymbolNames.search,
                    description: Text(
                        "No results found for \"\(searchQuery.trimmed)\""
                    )
                )
            } else {
                SettingForm {
                    Section {
                        ForEach(filteredConversation) {
                            conversation in
                            ConversationView(conversation: conversation)
                        }
                    } header: {
                        ExplanationText(
                            "Check a conversation to start watching."
                        )
                    }
                }
                .refreshable { refresh() }
            }
        }
        .navigationTitle("Conversations")
        .navigationSubtitle(projectName)
        .searchable(
            text: $searchQuery,
            prompt: Text("Conversation name...")
        )
    }
}

// TODO: - not working correctly for empty chat (aka: chat created in xcode but doesn't contain a single message -> no session history in the provider side)
private struct ConversationView: View {
    @Environment(ChatWatcher.self) private var chatWatcher
    let conversation: XcodeConversation

    @State private var watching: Bool = false
    @State private var processing: Bool = false
    @State private var error: Error? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(conversation.displayName)
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

                InlineErrorView(error: $error, autoDisappear: .seconds(3))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $watching)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(processing)
        }
        .onChange(of: watching) {
            self.onWatchingToggle()
        }
        .onChange(of: chatWatcher.watchingConversationIds, initial: true) {
            guard !self.processing else { return }
            self.watching = chatWatcher.watchingConversationIds.contains(
                self.conversation.id
            )
        }
        .onChange(of: chatWatcher.erroredConversations.keys) {
            if let error = chatWatcher.erroredConversations[
                self.conversation.id
            ] {
                self.error = error
            }
        }
    }

    private func onWatchingToggle() {
        guard !self.processing else { return }
        self.processing = true
        self.error = nil
        Task {
            defer { self.processing = false }
            if self.watching {
                do {
                    try await self.chatWatcher.watchConversation(
                        conversation.id
                    )
                } catch {
                    self.error = error
                    self.watching = false
                }
            } else {
                await self.chatWatcher.stopWatchingConversation(
                    conversation.id
                )
            }
        }
    }
}
