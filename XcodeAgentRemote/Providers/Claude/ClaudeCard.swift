//
//  ClaudeCard.swift
//  XcodeAgentRemote
//
//  Claude's tool calls as Xcode's cards (`AgentProvider.card`).
//

import Foundation

nonisolated extension ClaudeProvider {

    // MARK: Tool calls → Xcode cards

    /// A line of the Read tool's output: `<line number><tab><text>`.
    private static let readOutputLinePattern = try! NSRegularExpression(pattern: #"^\s*\d+\t"#, options: .anchorsMatchLines)

    /// Xcode's title and SF Symbol of the Tool Search card.
    private static let toolSearchCard = (name: "Tool Search", icon: "point.3.filled.connected.trianglepath.dotted")
    /// Xcode's SF Symbol of an agent task's card (titled with the task's description).
    private static let agentIcon = "square.on.square.intersection.dashed"
    /// Tools Xcode shows no card for.
    private static let toolsWithoutCard: Set<String> = ["TaskCreate"]

    /// The card for one of Claude's tool uses (`AgentProvider.card`), as Xcode shows it: file cards for Read, Edit
    /// and Write, the terminal card for Bash, fetch and search cards for WebFetch and WebSearch, title-only cards for
    /// ToolSearch and Agent, no card for the tools Xcode hides, the generic tool card for anything else.
    /// A denied tool use keeps its card as `cancelled`, a failed one as `failed`. Nil if it has no result.
    static func card(
        for call: ChatEvent.ToolUse, result toolResult: ChatEvent.ToolResult?, record: ToolUseRecords.Record?
    ) -> ChatCard.Card? {
        guard let toolResult, !toolsWithoutCard.contains(call.name) else { return nil }
        let result = toolResult.output
        let status: ChatCard.CardStatus =
            !toolResult.isError ? .completed : record?.denied == true ? .cancelled : .failed
        // Claude Code wraps a tool's error as `<tool_use_error>…</tool_use_error>`; the card shows the message.
        let errorDescription = status == .failed
            ? result.replacing("<tool_use_error>", with: "").replacing("</tool_use_error>", with: "") : nil

        switch call.name {
        case "Read":
            guard let path = call.stringInput("file_path") else { break }
            let lines = status == .completed
                ? readOutputLinePattern.numberOfMatches(in: result, range: NSRange(result.startIndex..., in: result)) : 0
            return ChatCard.fileCard(
                toolID: call.id, path: path, kind: .read, added: lines, removed: 0, source: "",
                status: status, errorDescription: errorDescription)
        case "Edit":
            guard let path = call.stringInput("file_path") else { break }
            let new = call.stringInput("new_string") ?? ""
            let changes = ChatCard.lineChanges(old: call.stringInput("old_string") ?? "", new: new)
            return ChatCard.fileCard(
                toolID: call.id, path: path, kind: .modified, added: changes.added, removed: changes.removed,
                source: changes.addedText.isEmpty ? new : changes.addedText,
                before: record?.fileBefore, after: record?.fileAfter, status: status, errorDescription: errorDescription)
        case "Write":
            guard let path = call.stringInput("file_path") else { break }
            let changes = ChatCard.lineChanges(old: record?.fileBefore ?? "", new: call.stringInput("content") ?? "")
            return ChatCard.fileCard(
                toolID: call.id, path: path, kind: record?.fileBefore == nil ? .added : .modified,
                added: changes.added, removed: changes.removed, source: changes.addedText,
                before: record?.fileBefore, after: record?.fileAfter, status: status, errorDescription: errorDescription)
        case "Bash":
            guard let command = call.stringInput("command"), !command.isEmpty else { break }
            return ChatCard.terminalCard(toolID: call.id, command: command, output: result, status: status)
        case "WebFetch":
            guard let url = call.stringInput("url") else { break }
            return ChatCard.webFetchCard(toolID: call.id, url: url, status: status)
        case "WebSearch":
            guard let query = call.stringInput("query") else { break }
            return ChatCard.webSearchCard(
                toolID: call.id, tool: call.name, query: query, titles: searchResultTitles(result), status: status)
        case "ToolSearch":
            return ChatCard.namedToolCard(
                toolID: call.id, name: toolSearchCard.name, icon: toolSearchCard.icon, status: status)
        case "Agent", "Task":
            return ChatCard.namedToolCard(
                toolID: call.id, name: call.stringInput("description") ?? call.name, icon: agentIcon, status: status)
        default:
            break
        }
        // Any other tool: the generic tool card, titled with the tool's name (for MCP tools `mcp__<server>__<tool>`,
        // just the tool).
        let parts = call.name.components(separatedBy: "__")
        let title = call.name.hasPrefix("mcp__") && parts.count >= 3 ? parts.dropFirst(2).joined(separator: "__") : call.name
        return ChatCard.genericCard(
            toolID: call.id, title: title, summary: inputSummary(call), output: result, status: status)
    }

    /// The titles of the pages a WebSearch found. Its output lists them on a line `Links: [{"title": …, "url": …}, …]`.
    private static func searchResultTitles(_ output: String) -> [String] {
        struct Link: Decodable { var title: String }
        return output.split(separator: "\n").flatMap { line -> [String] in
            guard line.hasPrefix("Links: "),
                  let links = try? JSONDecoder().decode([Link].self, from: Data(line.dropFirst("Links: ".count).utf8))
            else { return [] }
            return links.map(\.title)
        }
    }

    /// One line describing a tool call's input.
    private static func inputSummary(_ call: ChatEvent.ToolUse) -> String {
        for key in ["command", "file_path", "notebook_path", "pattern", "url", "query", "description", "prompt"] {
            if let value = call.stringInput(key), !value.isEmpty { return value }
        }
        guard !call.input.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(call.input)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return String(json.prefix(300))
    }
}
