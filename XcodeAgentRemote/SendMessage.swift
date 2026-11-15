//
//  SendMessage.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

/// Invoke python script to send a message.
/// Input: new conversation / conversationId / project (whatever is required by the script)

import Foundation

// MARK: - Input

/// Which chat a message goes to (the targets `xcode-chat` accepts).
nonisolated enum MessageTarget: Sendable {
    /// Start a new chat in the project (`.xcodeproj` / `.xcworkspace`).
    case newConversation(project: URL, name: String? = nil)
    /// Continue a chat of the project.
    case conversation(id: String, project: URL)
    /// Continue a chat, given its Xcode chat store folder (`<ProjectName>-<hash>`, name or path).
    case conversationInStore(id: String, store: String)
}

/// Overrides Xcode's Manual / Auto setting for one message.
nonisolated enum PermissionModeOverride: String, Sendable {
    case manual, auto
}

// MARK: - Output (Swift counterpart of xcode-chat's events.py)

/// One event `xcode-chat` streams while a turn runs (one JSON line on its stdout, discriminated by "type").
/// The last event is always `.result`.
nonisolated enum ChatEvent: Decodable, Sendable {
    case start(Start)
    case text(Text)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    /// The agent asked for permission to use a tool; the turn stops after this.
    case permissionRequest(PermissionRequest)
    case result(TurnResult)

    typealias JSONValue = ClaudeProvider.JSONValue

    /// Xcode's permission setting the turn ran with (`IDEChatAgentPermissionMode`).
    enum PermissionMode: String, Decodable, Sendable {
        case manual = "standard"
        case auto
        case dontAsk
        case bypassPermissions
    }

    struct Start: Decodable, Sendable {
        var conversation: String
        var session: String
        var provider: String
        var permissionMode: PermissionMode
        var newConversation: Bool

        enum CodingKeys: String, CodingKey {
            case conversation, session, provider
            case permissionMode = "permission_mode"
            case newConversation = "new_conversation"
        }
    }

    struct Text: Decodable, Sendable {
        enum Category: String, Decodable, Sendable {
            case thinking, prose
        }
        var category: Category
        var text: String
    }

    struct ToolUse: Decodable, Sendable {
        var id: String
        var name: String
        var input: [String: JSONValue]
    }

    struct ToolResult: Decodable, Sendable {
        var id: String
        var isError: Bool
        var output: String

        enum CodingKeys: String, CodingKey {
            case id, output
            case isError = "is_error"
        }
    }

    struct PermissionRequest: Decodable, Sendable {
        var toolUseID: String?
        var tool: String
        var input: [String: JSONValue]

        enum CodingKeys: String, CodingKey {
            case tool, input
            case toolUseID = "tool_use_id"
        }
    }

    struct TurnResult: Decodable, Sendable {
        enum Status: String, Decodable, Sendable {
            case completed, error
            case permissionRequired = "permission_required"
        }
        var status: Status
        var conversation: String
        var session: String
        /// The agent's final reply.
        var result: String?
        /// The request the turn stopped at (status `.permissionRequired`).
        var pending: PermissionRequest?
        /// The chat's folder in Xcode's chat store.
        var savedTo: String
        /// Tool calls that never finished (not shown in Xcode's transcript).
        var unfinishedTools: [String]

        enum CodingKeys: String, CodingKey {
            case status, conversation, session, result, pending
            case savedTo = "saved_to"
            case unfinishedTools = "unfinished_tools"
        }
    }

    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "start": self = .start(try Start(from: decoder))
        case "text": self = .text(try Text(from: decoder))
        case "tool_use": self = .toolUse(try ToolUse(from: decoder))
        case "tool_result": self = .toolResult(try ToolResult(from: decoder))
        case "permission_request": self = .permissionRequest(try PermissionRequest(from: decoder))
        case "result": self = .result(try TurnResult(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [TypeKey.type], debugDescription: "unknown event type \(type)"))
        }
    }
}

nonisolated enum SendMessageError: LocalizedError {
    case executableNotFound
    case failed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "xcode-chat is missing from the app bundle (Contents/MacOS/xcode-chat)"
        case .failed(let exitCode, let message):
            "xcode-chat exited with code \(exitCode): \(message)"
        }
    }
}

// MARK: - Send

#if os(macOS)
/// Runs one turn with the `xcode-chat` executable embedded in the app (`Contents/MacOS/xcode-chat`)
/// and streams its events as they happen, ending with `.result`.
/// Throws `SendMessageError.failed` when `xcode-chat` exits with a non-zero code (after the events it printed),
/// or a `DecodingError` for a line that is not a known event.
nonisolated func sendMessage(
    _ prompt: String,
    to target: MessageTarget,
    permissionMode: PermissionModeOverride? = nil
) -> AsyncThrowingStream<ChatEvent, Error> {
    var arguments: [String]
    switch target {
    case .newConversation(let project, let name):
        arguments = ["--project", project.path]
        if let name { arguments += ["--name", name] }
    case .conversation(let id, let project):
        arguments = ["--project", project.path, "--conversation", id]
    case .conversationInStore(let id, let store):
        arguments = ["--store", store, "--conversation", id]
    }
    if let permissionMode { arguments += ["--permission-mode", permissionMode.rawValue] }
    arguments.append(prompt)

    return AsyncThrowingStream { continuation in
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "xcode-chat") else {
            continuation.finish(throwing: SendMessageError.executableNotFound)
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let task = Task {
            do {
                try process.run()
                let decoder = JSONDecoder()
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    continuation.yield(try decoder.decode(ChatEvent.self, from: Data(line.utf8)))
                }
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    throw SendMessageError.failed(
                        exitCode: process.terminationStatus,
                        message: message.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
            if process.isRunning { process.terminate() }
        }
    }
}
#endif
