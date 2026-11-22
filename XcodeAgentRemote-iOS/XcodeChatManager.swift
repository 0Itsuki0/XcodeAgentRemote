//
//  XcodeChatManager.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/20.
//

import SwiftUI

private let logger = Logger.shared
private let category = Logger.category(#fileID)
//
//enum ServerConfigurationState: Equatable, Hashable, Sendable {
//    case validationFailed(String)
//    case validating
//    case validated
//}
//
//enum RequestState: Equatable, Hashable, Sendable {
//    case idle
//    case requesting
//}

@Observable class ServerSettingManager {

    private(set) var apiClient: APIServerClient?

    private(set) var validating: Bool = false
    private(set) var validationError: String? = nil

//    @ObservationIgnored
//    private var observationToken: NotificationCenter.ObservationToken?

    init() {
        self.apiClient = .saved
//        self.observationToken = NotificationCenter.default.addObserver(
//            of: Never.self,
//            for: .serverConfigurationDidChange
//        ) { [weak self] message in
//            guard let self else { return }
//            logger.info(
//                category: category,
//                message: "API client updated."
//            )
//            self.apiClient = message.apiClient
//        }
    }

    /// Test whether a server configuration is valid by pinging `/health` endpoint
    func testConfiguration(
        urlString: String,
        useAuth: Bool,
        authHeader: AuthHeader
    ) {
        guard !self.validating else { return }
        self.validationError = nil
        self.validating = true

        Task {
            defer { self.validating = false }

            guard let url = URL(string: urlString) else {
                self.validationError = "Invalid URL"
                return
            }

            let apiClient = APIServerClient(
                baseURL: url,
                authHeader: useAuth ? authHeader : nil
            )

            do {
                let _ = try await apiClient.health()
            } catch {
                self.validationError = error.localizedDescription
            }
        }
    }

    func saveConfiguration(
        urlString: String,
        useAuth: Bool,
        authHeader: AuthHeader
    ) {

        UserDefaultsKey.apiServerURL.setValue(
            value: urlString
        )
        UserDefaultsKey.apiServerUseAuth.setValue(value: useAuth)
        UserDefaultsKey.apiServerAuthHeaderName.setValue(
            value: authHeader.name
        )
        UserDefaultsKey.apiServerAuthHeaderValue.setValue(
            value: authHeader.value
        )
        self.apiClient = APIServerClient(
            baseURLString: urlString,
            authHeader: useAuth ? authHeader : nil
        )
    }

}

extension APIServerClient {

}

@Observable class ProjectViewModel {
    private(set) var projects: [XcodeProject] = []

    private(set) var error: Error?

    private let apiClient: APIServerClient

    private var isFetching: Bool = false

    init(apiClient: APIServerClient) {
        self.apiClient = apiClient
    }

    func loadProjects() async {
        guard !isFetching else { return }
        self.isFetching = true
        defer { isFetching = false }
        do {
            self.projects = try await apiClient.projects()
            logger.info(
                category: category,
                message: "Server configured successfully."
            )
            self.projects = projects
        } catch {
            logger.error(category: category, error: error)
            self.error = error
            self.projects = []
        }
    }

}

@Observable class ChatViewModel {

    let conversationId: String
    var conversationName: String {
        conversationDetail?.name ?? ""
    }
    var projectName: String {
        conversationDetail?.project.name ?? ""
    }

    var history: [ChatEvent] {
        conversationDetail?.history ?? []
    }

    var pendingUserRequest: [ChatEvent.UserRequest] {
        self.history.waitingForUser
    }

    private(set) var isResponding: Bool = false
    private var isFetching: Bool = false

    //    private(set) var streamingEvents: [ChatEvent]? = nil
    private(set) var error: Error? = nil
    //    private(set) var requestState: RequestState = .idle

    private var conversationDetail: XcodeConversationDetail? = nil

    private let apiClient: APIServerClient

    init(apiClient: APIServerClient, conversationId: String) {
        self.apiClient = apiClient
        self.conversationId = conversationId
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
        } catch {
            logger.error(category: category, error: error)
            self.error = error
        }
    }

    // TODO: -
    // 1. with for try loop, if event is a user request, start a timer count down permissionTimeout
    // 2. show a count down in the view
    // 3. on timeout, cancel the task and reload the history
    /// - `store`: Xcode chat store folder (`<ProjectName>-<hash>`, name or path).
    func sendMessage(
        _ prompt: String,
        conversationId: String,
        store: String,
        permissionModeOverride: PermissionMode,
        permissionTimeout: TimeInterval = 180
    ) {
        guard !self.isResponding else { return }

        self.isResponding = true
        let stream = apiClient.sendMessage(
            prompt,
            to: .conversationInStore(id: conversationId, store: store),
            permissionModeOverride: permissionModeOverride,
            permissionTimeout: permissionTimeout
        )
        Task {
            defer {
                self.isResponding = false
            }
            do {
                for try await event in stream {
                    logger.info(category: category, message: "Event: \(event)")
                    self.appendHistory(event)
                }
            } catch {
                logger.error(category: category, error: error)
                self.error = error
            }
        }
    }

    private func appendHistory(_ event: ChatEvent) {
        self.conversationDetail?.history.append(event)
    }

    //        //        var responses = 0
    //        //        while true {
    //        //            responses += 1
    //        //            for try await event in stream { events.append(event) }
    //        //            guard let waiting = waitingForUser(events).last else { return (events, responses) }
    //        //            stream = client.answer(answering(waiting))
    //        //        }
    //
    //    }

}
