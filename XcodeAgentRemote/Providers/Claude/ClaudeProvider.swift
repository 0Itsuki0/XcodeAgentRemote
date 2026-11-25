//
//  ClaudeProvider.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

import Foundation

nonisolated enum ClaudeProvider {}

// MARK: - Provider

nonisolated extension ClaudeProvider: AgentProvider {
    static let agent = AgentProviderName.claude

    /// Xcode's config folder for its Claude agent (`CLAUDE_CONFIG_DIR`).
    static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(
            path: "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig"
        )

    /// `<config>/projects/<project-dir>/<sessionID>.jsonl`
    static func transcriptFile(sessionID: String) throws(XcodeChatError) -> URL
    {
        let projects = configDirectory.appending(path: "projects")
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: projects,
                includingPropertiesForKeys: nil
            )) ?? []

        let url = folders.lazy.compactMap {
            ChatStore.item(named: sessionID, suffix: ".jsonl", in: $0)
        }.first

        guard let url else {
            throw XcodeChatError.transcriptMissing(sessionID: sessionID)
        }
        return url

    }

    /// A session's events, with the requests to the user (`ChatEvent.userRequest`) the transcript shows.
    static func history(sessionID: String) throws -> [ChatEvent]
    {
        let transcript = try transcriptFile(sessionID: sessionID)
        let events = try SessionHistory.load(contentsOf: transcript).flatMap(
            \.chatEvents
        )
        return addingUserRequests(
            to: events,
            transcript: try Data(contentsOf: transcript),
            sessionID: sessionID
        )
    }

    /// The `cwd` recorded in the session's transcript.
    static func workingDirectory(sessionID: String) -> URL? {
        guard let transcript = try? transcriptFile(sessionID: sessionID),
            let data = try? Data(contentsOf: transcript)
        else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let cwd =
                (try? JSONDecoder().decode(TranscriptCWD.self, from: Data(line)))?
                .cwd
            {
                return URL(filePath: cwd, directoryHint: .isDirectory)
            }
        }
        return nil
    }
}
