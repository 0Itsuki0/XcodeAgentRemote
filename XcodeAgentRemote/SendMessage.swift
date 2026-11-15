//
//  SendMessage.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

/// Invoke python script to send a message.
/// Input: new conversation / conversationId / project (whatever is required by the script)

import Foundation

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

/// Runs one turn with the `xcode-chat` executable embedded in the app (`Contents/MacOS/xcode-chat`)
/// and streams its events as they happen, ending with `.result`.
/// Throws `SendMessageError.failed` when `xcode-chat` exits with a non-zero code (after the events it printed),
/// or a `DecodingError` for a line that is not a known event.
nonisolated func sendMessage(
    _ prompt: String,
    to target: MessageTarget,
    permissionModeOverride: PermissionMode? = nil
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
    if let permissionModeOverride {
        arguments += ["--permission-mode", permissionModeOverride.rawValue]
    }
    arguments.append(prompt)

    return AsyncThrowingStream { continuation in
        guard
            let executable = Bundle.main.url(
                forAuxiliaryExecutable: "xcode-chat"
            )
        else {
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
                    continuation.yield(
                        try decoder.decode(
                            ChatEvent.self,
                            from: Data(line.utf8)
                        )
                    )
                }
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let message = String(
                        decoding: stderr.fileHandleForReading
                            .readDataToEndOfFile(),
                        as: UTF8.self
                    )
                    throw SendMessageError.failed(
                        exitCode: process.terminationStatus,
                        message: message.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
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
