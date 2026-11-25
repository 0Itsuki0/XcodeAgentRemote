//
//  AuthHeader.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import Foundation

/// A header name and the exact value required (`APIServerConstants.authHeader`).
nonisolated struct AuthHeader: Codable, Hashable, Sendable {
    /// Header name, e.g. "Authorization" or "X-Api-Key".
    var name: String
    /// The exact value required, e.g. "Bearer <secret>".
    var value: String

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    init() {
        self.init(name: "", value: "")
    }
}
