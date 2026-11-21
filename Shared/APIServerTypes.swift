//
//  APIServerType.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/21.
//

import Foundation

/// A header name and the exact value required (`APIServerConstants.authHeader`).
nonisolated struct AuthHeader: Codable, Hashable, Sendable {
    /// Header name, e.g. "Authorization" or "X-Api-Key".
    var name: String
    /// The exact value required, e.g. "Bearer <secret>".
    var value: String
}

nonisolated struct SuccessResponse: Codable, Sendable {
    let status: String
    
    init() {
        self.status = "ok"
    }
}

/// The JSON body of an error: `{"error": {"message": …}}` for a failed request (Hummingbird's format),
/// and `{"message": …}` as the data of an SSE `error` event.
nonisolated struct ErrorResponse: Codable, Sendable {
    struct Body: Codable, Sendable {
        var message: String
    }
    var error: Body
}
