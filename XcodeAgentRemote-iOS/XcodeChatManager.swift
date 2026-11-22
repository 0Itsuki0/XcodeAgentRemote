//
//  XcodeChatManager.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/20.
//

import SwiftUI

private let logger = Logger.shared
private let category = Logger.category(#fileID)

enum ServerConfigurationState: Equatable, Hashable, Sendable {
    case validationFailed(String)
    case validating
    case validated
}

enum RequestState: Equatable, Hashable, Sendable {
    case idle
    case requesting
}

@Observable class XcodeChatManager {

    private(set) var serverConfigurationState: ServerConfigurationState =
        .validating

    private var apiClient: APIServerClient?

    init() {
        let url = UserDefaultsKey.apiServerURL.getValue() as? String ?? ""
        let useAuth =
            UserDefaultsKey.apiServerUseAuth.getValue() as? Bool ?? false

        let authHeaderName =
            UserDefaultsKey.apiServerAuthHeaderName.getValue() as? String ?? ""
        let authHeaderValue =
            UserDefaultsKey.apiServerAuthHeaderValue.getValue() as? String ?? ""

        let authHeader = AuthHeader(
            name: authHeaderName,
            value: authHeaderValue
        )

        updateServerConfiguration(
            url: url,
            useAuth: useAuth,
            authHeader: authHeader
        )
    }

    func updateServerConfiguration(
        url: String,
        useAuth: Bool,
        authHeader: AuthHeader?,
        validate: Bool = true
    ) {
        guard let url = URL(string: url) else {
            self.serverConfigurationState = .validationFailed("Invalid URL")
            logger.error(
                category: category,
                errorMessage: "Invalid server url."
            )
            return
        }

        let apiClient = APIServerClient(
            baseURL: url,
            authHeader: useAuth ? authHeader : nil
        )
        self.apiClient = apiClient
        self.saveServerConfiguration(
            url: url.absoluteString,
            useAuth: useAuth,
            authHeader: authHeader
        )
        guard validate else { return }
        self.serverConfigurationState = .validating
        Task { [weak self] in
            guard let self else { return }

            do {
                let _ = try await apiClient.health()
                self.serverConfigurationState = .validated
                logger.info(
                    category: category,
                    message: "Server configured successfully."
                )
            } catch {
                logger.error(category: category, error: error)
                self.serverConfigurationState = .validationFailed(
                    error.localizedDescription
                )
            }
        }
    }

    private func saveServerConfiguration(
        url: String,
        useAuth: Bool,
        authHeader: AuthHeader?,
    ) {
        UserDefaultsKey.apiServerURL.setValue(
            value: url
        )
        UserDefaultsKey.apiServerUseAuth.setValue(value: useAuth)
        UserDefaultsKey.apiServerAuthHeaderName.setValue(
            value: authHeader?.name ?? ""
        )
        UserDefaultsKey.apiServerAuthHeaderValue.setValue(
            value: authHeader?.value ?? ""
        )
    }

    //
    //    /// - `store`: Xcode chat store folder (`<ProjectName>-<hash>`, name or path).
    //    func sendMessage(
    //        _ prompt: String,
    //        conversationId: String,
    //        store: String,
    //        permissionModeOverride: PermissionMode,
    //        permissionTimeout: TimeInterval = 180
    //    ) {
    //        guard let apiClient else { return }
    //        self.streamingEvents = []
    //        let stream = apiClient.sendMessage(
    //            prompt,
    //            to: .conversationInStore(id: conversationId, store: store),
    //            permissionModeOverride: permissionModeOverride,
    //            permissionTimeout: permissionTimeout
    //        )
    //        Task {
    //            defer {
    //                self.streamingEvents = []
    //            }
    //            do {
    //                for try await event in stream {
    //                    logger.info(category: category, message: "Event: \(event)")
    //                    self.streamingEvents?.append(event)
    //                }
    //            } catch {
    //                logger.error(category: category, error: error)
    //                self.error = error
    //            }
    //        }
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

@Observable class ChatViewModel {
    var isStreaming: Bool {
        streamingEvents != nil
    }

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

    private(set) var streamingEvents: [ChatEvent]? = nil
    private(set) var error: Error? = nil
    private(set) var requestState: RequestState = .idle

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
        guard self.requestState == .idle else { return }
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

    /// - `store`: Xcode chat store folder (`<ProjectName>-<hash>`, name or path).
    func sendMessage(
        _ prompt: String,
        conversationId: String,
        store: String,
        permissionModeOverride: PermissionMode,
        permissionTimeout: TimeInterval = 180
    ) {
        self.streamingEvents = []
        let stream = apiClient.sendMessage(
            prompt,
            to: .conversationInStore(id: conversationId, store: store),
            permissionModeOverride: permissionModeOverride,
            permissionTimeout: permissionTimeout
        )
        Task {
            defer {
                self.streamingEvents = []
            }
            do {
                for try await event in stream {
                    logger.info(category: category, message: "Event: \(event)")
                    self.streamingEvents?.append(event)
                }
            } catch {
                logger.error(category: category, error: error)
                self.error = error
            }
        }
    }

}
