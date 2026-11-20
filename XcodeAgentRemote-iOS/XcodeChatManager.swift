//
//  XcodeChatManager.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/20.
//

import SwiftUI

enum ServerConfigurationState: String, Equatable, Hashable, Sendable {
    case invalid
    case validating
    case validated

    enum InvalidReason: String, Equatable, Hashable, Sendable {
        case invalidURL
        case pingFailed
    }
}

@Observable class XcodeChatManager {
    //    var baseURL: String {
    //        didSet {
    //            UserDefaultsKey.apiServerURL.setValue(value: self.baseURL)
    //        }
    //    }
    //
    //    var authHeader: AuthHeader {
    //        didSet {
    //            UserDefaultsKey.apiServerAuthHeaderName.setValue(
    //                value: self.authHeader.name
    //            )
    //            UserDefaultsKey.apiServerAuthHeaderValue.setValue(
    //                value: self.authHeader.value
    //            )
    //        }
    //    }
    //
    //    var useAuth: Bool {
    //        didSet {
    //            UserDefaultsKey.apiServerUseAuth.setValue(value: self.useAuth)
    //        }
    //    }

    //    init() { }

    private var apiClient: APIServerClient?

    //    init() {
    //        self.client = APIServerClient(host: <#T##String#>)
    //    }

    func updateServerConfiguration() async throws {

    }
}
