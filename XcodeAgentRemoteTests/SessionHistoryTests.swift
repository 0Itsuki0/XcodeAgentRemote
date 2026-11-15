//
//  SessionHistoryTests.swift
//  XcodeAgentRemoteTests
//
//  Compares ClaudeProvider.SessionHistory with the official Agent SDK's getSessionMessages
//  (SDKReference/getSessionMessages.mjs) on every session of Xcode's Claude agent.
//  Needs Node and `npm install` in SDKReference/.
//

#if os(macOS)
import Foundation
import Testing
@testable import XcodeAgentRemote

struct SessionHistoryTests {

    /// What is compared per message: type, ids, and content blocks (type + tool id/name).
    struct MessageSummary: Codable, Equatable {
        struct Block: Codable, Equatable {
            var type: String
            var id: String?
            var name: String?
        }
        var type: String
        var uuid: String
        var session_id: String
        var blocks: [Block]?
    }

    static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig")
    static let sdkReference = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "SDKReference")

    /// Every session transcript of Xcode's Claude agent: <config>/projects/<project-dir>/<sessionId>.jsonl
    static func sessions() -> [URL] {
        let projects = configDirectory.appending(path: "projects")
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
        .sorted { $0.path < $1.path }
    }

    @Test(arguments: sessions(), [false, true])
    func matchesAgentSDK(session: URL, includeSystemMessages: Bool) throws {
        let swift = try ClaudeProvider.SessionHistory.load(contentsOf: session, includeSystemMessages: includeSystemMessages)
            .map(Self.summary)
        let sdk = try Self.sdkMessages(session: session, includeSystemMessages: includeSystemMessages)
        #expect(swift == sdk)
    }

    @Test(arguments: sessions())
    func decodesToolInputs(session: URL) throws {
        let typedTools: Set<String> = [
            "Agent", "Task", "Bash", "ExitPlanMode", "Edit", "Read", "Write", "Glob", "Grep", "NotebookEdit",
            "TodoWrite", "WebFetch", "WebSearch", "AskUserQuestion", "TaskCreate", "TaskGet", "TaskUpdate",
            "TaskStop", "ListMcpResourcesTool", "ReadMcpResourceTool",
        ]
        let toolUses = try ClaudeProvider.SessionHistory.load(contentsOf: session).flatMap { message in
            (message.message?.content ?? []).compactMap { block -> ClaudeProvider.ToolUseBlock? in
                if case .toolUse(let toolUse) = block { toolUse } else { nil }
            }
        }
        for toolUse in toolUses where typedTools.contains(toolUse.name) {
            if case .other = toolUse.toolInput {
                Issue.record("\(toolUse.name) input did not decode to its typed input: \(toolUse.input)")
            }
        }
    }

    // MARK: - Helpers

    static func summary(_ message: ClaudeProvider.SessionMessage) -> MessageSummary {
        MessageSummary(
            type: message.type.rawValue,
            uuid: message.uuid,
            session_id: message.sessionID,
            blocks: message.message?.content.map(blockSummary)
        )
    }

    static func blockSummary(_ block: ClaudeProvider.ContentBlock) -> MessageSummary.Block {
        switch block {
        case .text: MessageSummary.Block(type: "text")
        case .thinking: MessageSummary.Block(type: "thinking")
        case .redactedThinking: MessageSummary.Block(type: "redacted_thinking")
        case .toolUse(let toolUse): MessageSummary.Block(type: "tool_use", id: toolUse.id, name: toolUse.name)
        case .toolResult(let result): MessageSummary.Block(type: "tool_result", id: result.toolUseID)
        case .image: MessageSummary.Block(type: "image")
        case .unknown(let value):
            if case .object(let object) = value, case .string(let type) = object["type"] {
                MessageSummary.Block(type: type)
            } else {
                MessageSummary.Block(type: "unknown")
            }
        }
    }

    /// Runs SDKReference/getSessionMessages.mjs (the official SDK) on a session.
    static func sdkMessages(session: URL, includeSystemMessages: Bool) throws -> [MessageSummary] {
        try #require(
            FileManager.default.fileExists(atPath: sdkReference.appending(path: "node_modules").path),
            "run `npm install` in \(sdkReference.path)"
        )
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["node", "getSessionMessages.mjs", session.path] + (includeSystemMessages ? ["--system"] : [])
        process.currentDirectoryURL = sdkReference
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "getSessionMessages.mjs failed for \(session.lastPathComponent)")
        return try JSONDecoder().decode([MessageSummary].self, from: data)
    }
}
#endif
