//
//  AuthHeaderMiddleware.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/26.
//

import HTTPTypes
import Hummingbird

/// Rejects (401) every request that does not carry `APIServerConstants.authHeader` with its exact value.
/// An invalid header name rejects every request.
nonisolated struct AuthHeaderMiddleware<Context: RequestContext>:
    RouterMiddleware
{
    let name: HTTPField.Name?
    let value: String

    init(_ authHeader: AuthHeader) {
        self.name = HTTPField.Name(authHeader.name)
        self.value = authHeader.value
    }

    @concurrent func handle(
        _ request: Request,
        context: Context,
        next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let name, let received = request.headers[name],
            Self.constantTimeEqual(received, value)
        else {
            throw HTTPError(.unauthorized)
        }
        return try await next(request, context)
    }

    /// Compares without stopping at the first difference, so response timing doesn't reveal how much of a guess matched.
    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool
    {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |=
                (index < a.count ? a[index] : 0)
                ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}
