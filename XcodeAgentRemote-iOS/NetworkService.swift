//
//  NetworkService.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

import Foundation

private let logger = Logger.shared
private let category = Logger.category(#fileID)

nonisolated enum NetworkError: Error, LocalizedError {
    case cancelled
    case timeout
    case unauthorized
    case cannotConnectToHost
    /// other Non-2xx response; `message` is the server's error message, if it sent one.
    case badResponse(code: Int, message: String?)
    /// fail to decode response
    case invalidResponseFormat(Error)
    case other(Error)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Request cancelled."
        case .timeout:
            "Request timeout."
        case .badResponse(let code, let message):
            "Network failed. Code:\(code)." + (message.map { " \($0)" } ?? "")
        case .other(let error):
            "Error making network request: \(error.localizedDescription)."
        case .unauthorized:
            "Unauthorized."
        case .cannotConnectToHost:
            "Could not connect to the server."
        case .invalidResponseFormat(let error):
            "Received invalid response format: \(error.localizedDescription)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .timeout:
            "Please check the network connection."
        case .badResponse(code: _, message: _):
            "Please check your network."
        case .unauthorized:
            "Please check the authorization header."
        case .cannotConnectToHost:
            "Please check the connection URL."
        default:
            nil
        }
    }
}

nonisolated enum NetworkService {

    /// For ordinary request / response calls.
    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        // Fail fast when there is no connection instead of silently waiting for one.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// For streamed responses (SSE) that stay open as long as a turn runs.
    private static let streamingURLSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // The longest gap allowed between two pieces of data: a turn can be quiet for minutes (e.g. a long tool call).
        configuration.timeoutIntervalForRequest = 30 * 60
        // No cap on the whole stream: a turn takes as long as it takes.
        configuration.timeoutIntervalForResource = .infinity
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Sends a request and returns the response body. Throws `NetworkError.badResponse` for a non-2xx status.
    static func sendURLRequest(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        requestTimeout: TimeInterval? = nil,
    ) async throws(NetworkError) -> Data {
        let request = makeRequest(
            url: url,
            method: method,
            headers: headers,
            body: body,
            requestTimeout: requestTimeout
        )
        do {
            let (data, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
                let networkError = networkError(httpResponse, data: data)
            {
                throw networkError
            }
            return data
        } catch {
            throw mapError(error, url: url)
        }
    }

    /// Sends a request and returns the response body as it arrives (for streamed responses such as SSE).
    /// Throws `NetworkError.badResponse` for a non-2xx status. Cancelling the task that reads the bytes closes
    /// the connection.
    static func streamURLRequest(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
    ) async throws(NetworkError) -> URLSession.AsyncBytes {
        let request = makeRequest(
            url: url,
            method: method,
            headers: headers,
            body: body,
            requestTimeout: nil
        )
        do {
            let (bytes, response) = try await streamingURLSession.bytes(
                for: request
            )

            if let httpResponse = response as? HTTPURLResponse,
                let error = networkError(httpResponse, data: Data())
            {
                var data = Data()
                do {
                    for try await byte in bytes { data.append(byte) }
                } catch {}
                throw networkError(httpResponse, data: data) ?? error
            }
            return bytes
        } catch {
            throw mapError(error, url: url)
        }
    }

    private static func makeRequest(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        requestTimeout: TimeInterval?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.allHTTPHeaderFields = headers
        request.httpBody = body
        // Per-call cap, when the caller can't wait for the session-wide default.
        if let requestTimeout {
            request.timeoutInterval = requestTimeout
        }
        return request
    }

    static func networkError(_ urlResponse: HTTPURLResponse, data: Data)
        -> NetworkError?
    {
        switch urlResponse.statusCode {
        case 401:
            return .unauthorized
        case ..<200, 300...:
            return .badResponse(
                code: urlResponse.statusCode,
                message: errorMessage(from: data)
            )
        default:
            return nil
        }
    }

    /// The server's error message from an error body (`{"error": {"message": …}}`), if there is one.
    private static func errorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            .message
            ?? String(data: data, encoding: .utf8).flatMap {
                $0.isEmpty ? nil : $0
            }
    }

    private static func mapError(_ error: Error, url: URL) -> NetworkError {
        switch error {
        case is CancellationError:
            // Swift task cancellation must propagate as-is, so callers can tell "asked to stop" from a failure.
            return .cancelled
        case let urlError as URLError where urlError.code == .cancelled:
            // URLSession's own cancellation: also "asked to stop", not a transport failure.
            return .cancelled
        case let urlError as URLError
        where urlError.code == .cannotFindHost
            || urlError.code == .cannotConnectToHost:
            return NetworkError.cannotConnectToHost
        case let urlError as URLError
        where urlError.code == .timedOut
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet:
            return NetworkError.timeout
        case let error as NetworkError:
            // Already mapped (e.g. badResponse): don't nest it in dataTaskError.
            return error
        default:
            return NetworkError.other(error)
        }
    }

    /// Decodes JSON. Keys are used as they are (the shared types declare their own coding keys); dates are
    /// ISO 8601 strings, as the server (Hummingbird) writes them.
    static func decode<T>(_ type: T.Type, from data: Data) throws(NetworkError)
        -> T
    where T: Decodable {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw .invalidResponseFormat(error)
        }
    }

    static func decode<T>(_ type: T.Type, from string: String)
        throws(NetworkError)
        -> T
    where T: Decodable {
        try decode(type, from: Data(string.utf8))
    }

    /// Encodes JSON, dates as ISO 8601 strings (as the server expects).
    static func encode<T>(_ value: T) throws -> Data where T: Encodable {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}
