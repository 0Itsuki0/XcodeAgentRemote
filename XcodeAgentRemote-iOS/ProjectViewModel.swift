//
//  ProjectViewModel.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/24.
//

import SwiftUI

extension Array where Element == XcodeChatConversation {
    subscript(_ id: String) -> XcodeChatConversation? {
        get {
            return self.first(where: { $0.id.lowercased() == id.lowercased() })
        }
        set {
            guard
                let index = self.firstIndex(where: {
                    $0.id.lowercased() == id.lowercased()
                }), let newValue
            else {
                return
            }
            self[index] = newValue
        }
    }
}

extension Array where Element == XcodeProject {
    subscript(_ id: String) -> XcodeProject? {
        get {
            return self.first(where: { $0.id.lowercased() == id.lowercased() })
        }
        set {
            guard
                let index = self.firstIndex(where: {
                    $0.id.lowercased() == id.lowercased()
                }), let newValue
            else {
                return
            }
            self[index] = newValue
        }
    }
}

private let logger = Logger.shared
private let category = Logger.category(#fileID)

@Observable class ProjectViewModel {
    private(set) var projects: [XcodeProject] = []

    private(set) var error: NetworkError? {
        didSet {
            guard let error else { return }
            logger.error(category: category, error: error)
        }
    }

    let apiClient: APIServerClient

    private var isFetching: Bool = false

    private(set) var initialized = false

    @ObservationIgnored
    private var observationToken: NotificationCenter.ObservationToken?

    init(apiClient: APIServerClient) {
        self.apiClient = apiClient

        self.observationToken = NotificationCenter.default.addObserver(
            of: Never.self,
            for: .selectedConversationDidChange
        ) { [weak self] message in
            guard let self else { return }
            self.handleSelectedConversationDidChange(message)
        }
    }

    private func handleSelectedConversationDidChange(
        _ message: SelectedConversationDidChange
    ) {
        guard let conversation = message.conversation else {
            return
        }

        self.projects[conversation.projectId]?.conversations[
            conversation.conversationId
        ]?.isUnread = false
        self.projects[conversation.projectId]?.conversations[
            conversation.conversationId
        ]?.lastActivityDate = conversation.lastActivityDate
    }

    private func projectForConversation(_ id: String) -> XcodeProject? {
        return self.projects.first(where: {
            $0.conversations[id] != nil
        })
    }

    func loadProjects(checkInitial: Bool = false) async {
        guard !isFetching else { return }
        if checkInitial, initialized { return }
        self.isFetching = true
        self.error = nil
        defer {
            initialized = true
            isFetching = false
        }
        do {
            self.projects = try await apiClient.projects()
            self.projects = projects
        } catch {
            self.error = error
            self.projects = []
        }
    }
}
