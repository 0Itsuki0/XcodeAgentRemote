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

    /// validated api client
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
            authHeader: useAuth ? authHeader : nil
        )
    }

    func updateServerConfiguration(url: String, authHeader: AuthHeader?) {
        guard let url = URL(string: url) else {
            self.serverConfigurationState = .validationFailed("Invalid URL")
            return
        }
        self.serverConfigurationState = .validating
        Task { [weak self] in
            guard let self else { return }

            let apiClient = APIServerClient(
                baseURL: url,
                authHeader: authHeader
            )

            do {
                let _ = try await apiClient.health()
                self.apiClient = apiClient
                self.serverConfigurationState = .validated
                logger.info(category: category, message: "Server configured successfully.")
            } catch {
                self.serverConfigurationState = .validationFailed(
                    error.localizedDescription
                )
            }
        }
    }

    private let testConversation = "1170A351-FBFE-4317-8FA7-4F65AC6F3B64"
    private let testStore = "Demo10-edhhiszqgddxcwajapbakukmrdhy"

    func sendMessage(_ prompt: String) {
        guard let apiClient else { return }
        var stream = apiClient.sendMessage(
            prompt,
            to: .conversationInStore(id: testConversation, store: testStore),
            permissionModeOverride: nil,
            permissionTimeout: 120
        )
        Task {
            do {
                for try await event in stream {
                    logger.info(category: category, message: "Event: \(event)")
                }
            } catch {
                logger.error(category: category, error: error)
            }
        }
        //        var responses = 0
        //        while true {
        //            responses += 1
        //            for try await event in stream { events.append(event) }
        //            guard let waiting = waitingForUser(events).last else { return (events, responses) }
        //            stream = client.answer(answering(waiting))
        //        }

    }

    func waitingForUser(_ events: [ChatEvent]) -> [UserRequest] {
        let answered = Set(
            events.compactMap { event -> String? in
                if case .toolResult(let result) = event {
                    result.toolUseID
                } else {
                    nil
                }
            }
        )
        return events.compactMap { event -> UserRequest? in
            if case .userRequest(let request) = event,
                !answered.contains(request.toolUseID)
            {
                request
            } else {
                nil
            }
        }
    }

}
