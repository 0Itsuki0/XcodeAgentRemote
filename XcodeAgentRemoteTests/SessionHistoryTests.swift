//
//  SessionHistoryTests.swift
//  XcodeAgentRemoteTests
//
//  Reading Claude's session transcripts (`.jsonl`) with ClaudeProvider:
//  - a session written by Xcode's bundled Claude itself (`xcrun mcpbridge run-agent claude`, none of the app's
//    functions) decodes to the history the turn must have: the prompt, the tool use, its result, the reply;
//  - the tool inputs of every session of Xcode's Claude agent decode to their typed input.
//

#if os(macOS)
import Foundation
import Testing
@testable import XcodeAgentRemote

struct SessionHistoryTests {

    static let configDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig")

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

    /// One message of `claude -p --output-format json` (a JSON array of the turn's messages); the `result` one has the
    /// session id (the fields read here).
    struct CLIMessage: Decodable {
        var type: String?
        var session_id: String?
        var is_error: Bool?
        var result: String?
    }

    @Test func decodesSessionWrittenByClaude() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SessionHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = "session-history-test-\(UUID().uuidString.prefix(8))"
        let prompt = "Use the Bash tool to run: echo \(marker). Then reply with only the word DONE."

        // Xcode's bundled Claude, run directly; Bash allowed so nothing asks.
        let output = try #require(
            runCommand(
                ["xcrun", "mcpbridge", "run-agent", "claude", "-p", prompt, "--output-format", "json",
                 "--allowedTools", "Bash"],
                in: folder),
            "the agent did not run")
        let messages = try JSONDecoder().decode([CLIMessage].self, from: Data(output.utf8))
        let result = try #require(messages.last { $0.type == "result" }, "no result message")
        let sessionID = try #require(result.session_id)
        let transcript = try #require(ClaudeProvider.transcript(sessionID: sessionID), "no transcript for the session")
        // Claude's folder for the test's temporary working directory (named after it): only this session, and its memory.
        let projectFolder = transcript.deletingLastPathComponent()
        defer {
            if projectFolder.lastPathComponent.hasSuffix(folder.lastPathComponent) {
                try? FileManager.default.removeItem(at: projectFolder)
            }
        }
        try #require(result.is_error != true, "the turn failed: \(result.result ?? "")")

        let history = try ClaudeProvider.history(sessionID: sessionID)
        #expect(history.first == .userMessage(prompt))
        let bash = history.compactMap { event -> ChatEvent.ToolUse? in
            if case .toolUse(let toolUse) = event, toolUse.name == "Bash" { toolUse } else { nil }
        }
        try #require(bash.count == 1, "expected one Bash tool use, got \(bash.count)")
        #expect(bash[0].stringInput("command")?.contains(marker) == true)
        let bashResults = history.compactMap { event -> ChatEvent.ToolResult? in
            if case .toolResult(let result) = event, result.toolUseID == bash[0].id { result } else { nil }
        }
        #expect(bashResults.count == 1)
        #expect(bashResults.first?.isError == false)
        #expect(bashResults.first?.output.contains(marker) == true)
        #expect(history.contains { if case .assistantMessage(let text) = $0 { text.contains("DONE") } else { false } })
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

}
#endif
