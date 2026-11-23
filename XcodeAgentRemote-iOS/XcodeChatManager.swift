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
        authHeaderName: String,
        authHeaderValue: String
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
                useAuth: useAuth,
                authHeaderName: authHeaderName,
                authHeaderValue: authHeaderValue
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
        authHeaderName: String,
        authHeaderValue: String
    ) {

        UserDefaultsKey.apiServerURL.setValue(
            value: urlString
        )
        UserDefaultsKey.apiServerUseAuth.setValue(value: useAuth)
        UserDefaultsKey.apiServerAuthHeaderName.setValue(
            value: authHeaderName
        )
        UserDefaultsKey.apiServerAuthHeaderValue.setValue(
            value: authHeaderValue
        )
        self.apiClient = APIServerClient(
            baseURLString: urlString,
            useAuth: useAuth,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue
        )
    }

}

@Observable class ProjectViewModel {
    private(set) var projects: [XcodeProject] = []

    private(set) var error: NetworkError?

    private let apiClient: APIServerClient

    private var isFetching: Bool = false

    private(set) var initialized = false

    init(apiClient: APIServerClient) {
        self.apiClient = apiClient
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
