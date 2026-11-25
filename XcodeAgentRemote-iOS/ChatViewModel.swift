//
//  ChatViewModel.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/23.
//

import SwiftUI

private let logger = Logger.shared
private let category = Logger.category(#fileID)

@Observable class ChatViewModel {

    /// NOT using getters from `conversationDetail` so that
    /// 1. they can be set individually as necessary
    /// 2. ensure non-nil

    let conversationId: String
    /// should be the same as the store, but here for consistency
    let projectId: String

    private(set) var conversationName: String
    private(set) var projectName: String

    /// Xcode chat store folder (`<ProjectName>-<hash>`, name or path).
    private var projectStore: String

    private(set) var history: [ChatEvent] = []

    private(set) var lastActivityDate: Date?

    private(set) var pendingUserRequest: [ChatEvent.UserRequest] = []

    private(set) var isResponding: Bool = false

    private var isFetching: Bool = false

    private(set) var error: Error? = nil {
        didSet {
            guard let error else { return }
            logger.error(category: category, error: error)
        }
    }

    private var conversationDetail: XcodeConversationDetail? = nil {
        didSet {
            self.updateConversationParameters()
        }
    }

    private let apiClient: APIServerClient

    // TODO: - consider changing the value to a setting option
    private let permissionTimeout: TimeInterval = 180

    /// id to force the entire history to refresh
    private(set) var historyViewID = UUID()

    init(
        apiClient: APIServerClient,
        conversationId: String,
        conversationName: String,
        projectName: String,
        projectStore: String,
        projectId: String,
        lastActivityDate: Date?
    ) {
        self.apiClient = apiClient
        self.conversationId = conversationId
        self.conversationName = conversationName
        self.projectName = projectName
        self.projectStore = projectStore
        self.projectId = projectId
        self.lastActivityDate = lastActivityDate
    }

    #if DEBUG
        init(debugEventJson: URL?) {
            /// when using debugEventJson, API will not be called
            self.apiClient = APIServerClient(baseURL: URL.temporaryDirectory)
            self.conversationId = DebugConstants.conversationId
            self.conversationDetail = .init(
                id: DebugConstants.conversationId,
                name: "DebugConversation",
                isArchived: false,
                isUnread: false,
                history: Self.loadHistoryFromFile(debugEventJson),
                project: .init(
                    name: "DebugProject",
                    store: URL.temporaryDirectory
                )
            )
            self.conversationName = "DebugConversation"
            self.projectName = "DebugProject"
            self.projectStore = "Debug-Hash"
            self.projectId = "Debug-Hash"
            self.lastActivityDate = Date()
        }

        private static func loadHistoryFromFile(_ url: URL?) -> [ChatEvent] {
            do {
                guard let url else {
                    logger.info(
                        category: category,
                        message: "Debug sample URL not found."
                    )
                    return []
                }
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode([ChatEvent].self, from: data)
            } catch {
                logger.error(category: category, error: error)
                return []
            }
        }

    #endif

    func fetchConversationDetail() async {
        guard !self.isFetching else { return }
        self.isFetching = true
        defer { self.isFetching = false }
        do {
            let conversationDetail = try await apiClient.conversation(
                id: self.conversationId
            )
            self.conversationDetail = conversationDetail
            self.markConversationAsRead()
        } catch {
            self.error = error
        }
    }

    /// **Best effort** marking a conversation as read.
    /// Do it in background instead of waiting.
    /// Error: logging only
    private func markConversationAsRead() {
        Task {
            do {
                let _ = try await apiClient.markRead(
                    conversationID: conversationId
                )
            } catch {
                logger.error(category: category, error: error)
            }
        }
    }

    private func updateConversationParameters() {
        /// NOT resetting in case the failure is just a temporary network error
        guard let conversationDetail else { return }
        conversationName = conversationDetail.name
        projectName = conversationDetail.project.name
        projectStore = conversationDetail.project.store.lastPathComponent
        let resetHistory =
            !self.history.isEmpty && self.history != conversationDetail.history
        history = conversationDetail.history
        pendingUserRequest = history.waitingForUser
        logger.info(
            category: category,
            message:
                "Pending user request count: \(self.pendingUserRequest.count)"
        )
        if resetHistory { historyViewID = UUID() }
    }

    // TODO: -
    // 1. with for try loop, if event is a user request, start a timer count down permissionTimeout
    // 2. show a count down in the view
    // 3. on timeout, cancel the task and reload the history
    /// - `store`: Xcode chat store folder (`<ProjectName>-<hash>`, name or path).
    func sendMessage(
        _ prompt: String,
        permissionModeOverride: PermissionMode,
    ) {
        guard !self.isResponding else { return }
        self.appendHistory(.userMessage(prompt))
        self.isResponding = true
        let stream = apiClient.sendMessage(
            prompt,
            to: .conversationInStore(id: conversationId, store: projectStore),
            permissionModeOverride: permissionModeOverride,
            permissionTimeout: self.permissionTimeout
        )
        self.streamEvent(stream)
    }

    func answerPermission(
        toolUseID: String,
        allow: Bool,
        message: String?
    ) {
        let userResponse: ChatEvent.UserResponse = .permission(
            toolUseID: toolUseID,
            allow: allow,
            message: message
        )
        self.answer(with: userResponse)
    }

    func answerQuestions(
        toolUseID: String,
        answers: [String: [String]]
    ) {
        let userResponse: ChatEvent.UserResponse = .questions(
            toolUseID: toolUseID,
            answers: answers
        )
        self.answer(with: userResponse)
    }

    func declineQuestions(
        toolUseID: String,
        message: String?
    ) {
        let userResponse: ChatEvent.UserResponse = .declineQuestions(
            toolUseID: toolUseID,
            message: message
        )
        self.answer(with: userResponse)
    }

    func answerPlanApproval(
        toolUseID: String,
        approve: Bool,
        feedback: String?
    ) {
        let userResponse: ChatEvent.UserResponse = .planApproval(
            toolUseID: toolUseID,
            approve: approve,
            feedback: feedback
        )
        self.answer(with: userResponse)
    }

    private func answer(with userResponse: ChatEvent.UserResponse) {
        guard !self.isResponding else { return }
        self.pendingUserRequest.removeAll {
            $0.toolUseID == userResponse.toolUseID
        }
        self.appendHistory(.userResponse(userResponse))
        self.isResponding = true
        let stream = apiClient.answer(userResponse)
        self.streamEvent(stream)
    }

    private func streamEvent(_ stream: AsyncThrowingStream<ChatEvent, Error>) {
        Task { [weak self] in
            guard let self else { return }
            defer { self.isResponding = false }
            do {
                self.lastActivityDate = Date()
                for try await event in stream {
                    logger.info(category: category, message: "Event: \(event)")
                    self.appendHistory(event)
                }
                self.pendingUserRequest = history.waitingForUser
                logger.info(
                    category: category,
                    message:
                        "Pending user request count: \(self.pendingUserRequest.count)"
                )
                self.lastActivityDate = Date()
            } catch {
                self.error = error
            }
        }
    }

    private func appendHistory(_ event: ChatEvent) {
        self.history.append(event)
    }
}
