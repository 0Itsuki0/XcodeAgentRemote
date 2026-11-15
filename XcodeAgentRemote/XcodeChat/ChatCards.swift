//
//  ChatCards.swift
//  XcodeAgentRemote
//
//  The cards Xcode shows for a turn (`responseContent` of a turn in conversation.plist), shared by all providers.
//
//  Every format here is copied from cards Xcode itself wrote, and checked field for field against them.
//  Xcode stores presentation in these cards (titles, SF Symbol names, SwiftUI fonts), not just data, and draws
//  what is stored, so a card we add renders like Xcode's own only if it carries the same fields.
//
//  Kinds of cards (Xcode's keys):
//  - textState: thinking / reply text. tableState: a markdown table of a reply, cut out of its text.
//  - fileOperationState: the file card, e.g. "README  −1  M" (line counts, badge). Read/edit/write of one file:
//    path, language, operationKind, line counts, and for a finished edit the whole file before and after
//    (pre/postToolCallSnapshot).
//  - toolCallState: the tool card: a title, an SF Symbol, and what it did (`kind`): `execute` for a terminal command
//    (with its styled command and output), `other` for tools shown by name only (Tool Search, Agent).
//  - webFetchState / toolCallSearchState: a fetched URL / a web search, shown inside a toolCallGroupState.
//  - toolCallGroupState: consecutive cards of the same kind (file reads, fetches, searches), shown as one group.
//  A denied or failed tool keeps its card; only its `status` changes (`cancelled` / `failed`), shown as a "!".
//
//  Tools with no known format use the tool card titled with the tool's name (`genericCard`, kind `execute`): a guess.
//
//  The Swift enums with associated values encode as Xcode's do: `case textState(TextBlock)` is
//  `{"textState": {"_0": {...}}}`, `case execute(command:)` is `{"execute": {"command": ...}}`, `case other` is
//  `{"other": {}}`.
//

import Foundation

/// The cards Xcode shows for a turn: their types (Xcode's format) and the functions that build them.
nonisolated enum ChatCards {

    // MARK: Types

    /// Whether a text block is the agent's thinking or its reply.
    fileprivate enum TextKind: String, Encodable, Sendable {
        case thinking, prose
    }

    /// `{"prose": {"_0": <UUID>}}` for text, `{"tool": {"_0": <the agent's tool use id>}}` for tool calls.
    enum CardID: Encodable, Sendable {
        case prose(String)
        case tool(String)
    }

    /// What a tool did to the file a file card shows (the card's badge and line counts).
    enum FileAction: String, Encodable, Sendable {
        case added, modified, deleted, read, copied, moved, refreshIssues
    }

    /// How a tool call ended: `cancelled` when it was denied, `failed` when it returned an error (both shown as "!").
    enum CardStatus: String, Encodable, Sendable {
        case pending, inProgress, completed, cancelled, failed
    }

    /// One card of `responseContent` (or a member of a group).
    enum Card: Encodable, Sendable {
        case textState(TextBlock)
        case tableState(TableBlock)
        case fileOperationState(FileCard)
        case toolCallState(ToolCard)
        case webFetchState(WebFetchCard)
        case toolCallSearchState(WebSearchCard)
        case toolCallGroupState(CardGroup)
    }

    /// A block of the agent's text: thinking or reply.
    struct TextBlock: Encodable, Sendable {
        fileprivate var category: TextKind
        fileprivate var id: CardID
        fileprivate var text: String
    }

    /// A markdown table of the agent's reply, shown as a table.
    struct TableBlock: Encodable, Sendable {
        fileprivate var id: CardID
        /// The table's markdown lines.
        fileprivate var rawText: String
    }

    /// The file card.
    struct FileCard: Encodable, Sendable {
        /// The path shown in a file card's header: the file's folder.
        fileprivate struct HeaderPath: Encodable, Sendable {
            /// One folder of the header path.
            struct PathComponent: Encodable, Sendable {
                fileprivate var id: Int
                /// SF Symbol, e.g. "folder"
                fileprivate var imageTypeName: String
                fileprivate var title: String
            }
            fileprivate var primaryComponents: [PathComponent]
        }

        /// The lines one tool use changed in the file.
        fileprivate struct ChangeSegment: Encodable, Sendable {
            fileprivate var linesAdded: Int
            fileprivate var linesRemoved: Int
            fileprivate var sourceCode: String
            fileprivate var toolCallID: String
        }

        /// A file's whole content at one moment (before or after an edit).
        fileprivate struct FileSnapshot: Encodable, Sendable {
            fileprivate var absoluteFilePath: String
            fileprivate var content: String
        }

        fileprivate var displayName: String
        /// Why the tool failed (`failed` only).
        fileprivate var errorDescription: String?
        fileprivate var filePath: String
        fileprivate var headerPathState: HeaderPath
        fileprivate var id: CardID
        /// Syntax highlighting; left out for files of an unknown type.
        fileprivate var language: String?
        fileprivate var linesAdded: Int
        fileprivate var linesRemoved: Int
        fileprivate var operationKind: FileAction
        fileprivate var segments: [ChangeSegment]
        fileprivate var showHeaderPath: Bool
        fileprivate var sourceCode: String
        fileprivate var status: CardStatus
        /// The whole file before a finished edit.
        fileprivate var preToolCallSnapshot: FileSnapshot?
        /// The whole file after a finished edit.
        fileprivate var postToolCallSnapshot: FileSnapshot?
    }

    /// The tool card.
    struct ToolCard: Encodable, Sendable {
        /// What the tool did: a command it executed, or something shown by the card's title only.
        fileprivate enum Kind: Encodable, Sendable {
            case execute(command: String)
            case other
        }

        /// The styled text shown on the card itself.
        fileprivate enum Summary: Encodable, Sendable {
            case attributedContent([AttributedRun])
        }

        /// What the card shows when expanded: the styled command, or the command's output.
        fileprivate enum Detail: Encodable, Sendable {
            case prose([AttributedRun])
            case console(String)
        }

        fileprivate var id: CardID
        /// SF Symbol, e.g. "apple.terminal"
        fileprivate var imageTypeName: String
        fileprivate var kind: Kind
        /// The card's title, e.g. "Terminal Command".
        fileprivate var name: String
        /// Left out for `other` cards.
        fileprivate var resultContentState: Summary?
        fileprivate var resultDetailStates: [Detail]
        fileprivate var showHeaderPath: Bool
        fileprivate var status: CardStatus
        fileprivate var subActivityStates: [JSONValue]
    }

    /// A fetched web page (shown in a group).
    struct WebFetchCard: Encodable, Sendable {
        fileprivate var id: CardID
        fileprivate var status: CardStatus
        fileprivate var url: RelativeURL
    }

    /// A web search and the titles it found (shown in a group).
    struct WebSearchCard: Encodable, Sendable {
        /// One page the search found.
        fileprivate struct Result: Encodable, Sendable {
            fileprivate var title: String
        }

        fileprivate var id: CardID
        fileprivate var matchCount: Int
        fileprivate var queries: [String]
        fileprivate var results: [Result]
        /// The tool's name, e.g. "WebSearch".
        fileprivate var searchToolType: String
        fileprivate var status: CardStatus
    }

    /// A URL as Swift's `URL` encodes it.
    fileprivate struct RelativeURL: Encodable, Sendable {
        fileprivate var relative: String
    }

    /// Consecutive cards of the same kind, shown as one group.
    struct CardGroup: Encodable, Sendable {
        /// What the cards of a group have in common.
        fileprivate enum GroupKind: Encodable, Equatable, Sendable {
            /// The tools whose cards are grouped by tool.
            enum GroupedTool: Encodable, Equatable, Sendable {
                case webFetch
            }
            /// File reads: `{"fileOperation": {"_0": "read"}}`
            case fileOperation(FileAction)
            /// Web fetches: `{"toolCall": {"_0": {"webFetch": {}}}}`
            case toolCall(GroupedTool)
            /// Web searches: `{"search": {}}`
            case search
        }

        fileprivate var groupKey: GroupKind
        fileprivate var members: [Card]
    }

    /// A SwiftUI AttributedString is encoded as runs: `[text, attributes, text, attributes, ...]`.
    fileprivate enum AttributedRun: Encodable, Sendable {
        case text(String)
        case attributes(JSONValue)

        func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let text): try text.encode(to: encoder)
            case .attributes(let attributes): try attributes.encode(to: encoder)
            }
        }
    }

    // MARK: Constants

    /// The syntax highlighting language of a file card, by file extension.
    private static let languageByExtension: [String: String] = [
        "md": "markdown", "swift": "swift", "py": "python", "js": "javascript", "ts": "typescript",
        "json": "json", "m": "objective-c", "h": "objective-c", "c": "c", "cpp": "cpp", "sh": "shell",
    ]

    // SwiftUI AttributedString attributes Xcode uses in the terminal card: monospaced subheadline,
    // and bold (+0.3 weight) with primary color for each command name.
    private static let monospacedFont: JSONValue = .object([
        "tag": .object(["modifier": .object(["_0": .string("weight")])]),
        "value": .object([
            "font": .object([
                "tag": .object(["staticModifier": .object(["_0": .object(["do": .object(["_0": .object(["monospaced": .object([:])])])])])]),
                "value": .object([
                    "tag": .object(["style": .object([:])]),
                    "value": .object(["design": .object([:]), "style": .object(["subheadline": .object([:])]), "weight": .object([:])]),
                ]),
            ]),
            "modifier": .number(0.0),
        ]),
    ])
    /// Style of plain text in the terminal card: monospaced subheadline.
    private static let plainTextStyle: JSONValue = .object(["SwiftUI.Font": monospacedFont])
    /// Style of a command name in the terminal card: bold (+0.3 weight), primary color.
    private static let commandNameStyle: JSONValue = .object([
        "SwiftUI.Font": .object([
            "tag": .object(["modifier": .object(["_0": .string("weight")])]),
            "value": .object(["font": monospacedFont, "modifier": .number(0.3)]),
        ]),
        "SwiftUI.ForegroundColor": .object(["tag": .object(["system": .object([:])]), "value": .object(["primary": .object([:])])]),
    ])
    /// SF Symbol of the generic tool card.
    private static let genericToolIcon = "wrench.and.screwdriver"
    /// The longest tool output kept on a generic tool card.
    private static let maxOutputLength = 4000

    // MARK: Building cards

    /// A text block's card and its id (for `responseContentSequence`).
    private static func textBlock(_ category: TextKind, _ text: String) -> (Card, CardID) {
        let id = CardID.prose(ChatStore.newUUID())
        return (.textState(TextBlock(category: category, id: id, text: text)), id)
    }

    /// A table's card and its id (for `responseContentSequence`).
    private static func tableBlock(_ rawText: String) -> (Card, CardID) {
        let id = CardID.prose(ChatStore.newUUID())
        return (.tableState(TableBlock(id: id, rawText: rawText)), id)
    }

    /// A reply cut around its markdown tables (runs of lines starting with "|"), the way Xcode shows it:
    /// each table with its lines, the text around it without the blank lines that separate it from the table.
    private static func textAndTables(_ text: String) -> [(isTable: Bool, text: String)] {
        var parts: [(isTable: Bool, text: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map({ $0 + "\n" }) {
            let isTable = line.hasPrefix("|")
            if let last = parts.last, last.isTable == isTable {
                parts[parts.count - 1].text += line
            } else {
                parts.append((isTable, String(line)))
            }
        }
        if var last = parts.popLast() {  // the split added a line break after the last line
            last.text.removeLast()
            parts.append(last)
        }
        return parts.compactMap { part in
            guard !part.isTable else { return part }
            let trimmed = part.text.trimmingCharacters(in: .newlines)
            return trimmed.isEmpty ? nil : (false, trimmed)
        }
    }

    /// Lines added, lines removed, and the added text, between two strings.
    static func lineChanges(old: String, new: String) -> (added: Int, removed: Int, addedText: String) {
        var added: [Substring] = []
        var removed = 0
        for change in splitLines(new).difference(from: splitLines(old)) {
            switch change {
            case .insert(_, let line, _): added.append(line)
            case .remove: removed += 1
            }
        }
        var text = added.joined()
        while text.hasSuffix("\n") { text.removeLast() }
        return (added.count, removed, text)
    }

    /// The lines of a string, each with its line break.
    private static func splitLines(_ string: String) -> [Substring] {
        var lines: [Substring] = []
        var start = string.startIndex
        for index in string.indices where string[index] == "\n" || string[index] == "\r\n" || string[index] == "\r" {
            let end = string.index(after: index)
            lines.append(string[start..<end])
            start = end
        }
        if start < string.endIndex { lines.append(string[start...]) }
        return lines
    }

    /// The file card. `before` / `after` (the whole file) are only shown for a finished change.
    static func fileCard(
        toolID: String, path: String, kind: FileAction, added: Int, removed: Int, source: String,
        before: String? = nil, after: String? = nil, status: CardStatus = .completed, errorDescription: String? = nil
    ) -> Card {
        let file = path as NSString
        return .fileOperationState(FileCard(
            displayName: file.lastPathComponent,
            errorDescription: errorDescription,
            filePath: path,
            headerPathState: .init(primaryComponents: [
                .init(id: 0, imageTypeName: "folder", title: (file.deletingLastPathComponent as NSString).lastPathComponent)
            ]),
            id: .tool(toolID),
            language: languageByExtension[file.pathExtension.lowercased()],
            linesAdded: added,
            linesRemoved: removed,
            operationKind: kind,
            segments: [.init(linesAdded: added, linesRemoved: removed, sourceCode: source, toolCallID: toolID)],
            showHeaderPath: false,
            sourceCode: source,
            status: status,
            preToolCallSnapshot: status == .completed ? before.map { .init(absoluteFilePath: path, content: $0) } : nil,
            postToolCallSnapshot: status == .completed ? after.map { .init(absoluteFilePath: path, content: $0) } : nil
        ))
    }

    /// A command name in a shell command: the first word, and each word after `&&`, `||`, `|` or `;`.
    private static let commandNamePattern = try! NSRegularExpression(pattern: #"(^|&&|\|\||[|;])(\s*)([^\s|;&]+)"#)

    /// A shell command as AttributedString runs, with command names bold.
    private static func styledCommand(_ command: String) -> [AttributedRun] {
        var runs: [AttributedRun] = []
        var position = command.startIndex
        let whole = NSRange(command.startIndex..., in: command)
        for match in commandNamePattern.matches(in: command, range: whole) {
            guard let name = Range(match.range(at: 3), in: command) else { continue }
            if name.lowerBound > position {
                runs += [.text(String(command[position..<name.lowerBound])), .attributes(plainTextStyle)]
            }
            runs += [.text(String(command[name])), .attributes(commandNameStyle)]
            position = name.upperBound
        }
        if position < command.endIndex {
            runs += [.text(String(command[position...])), .attributes(plainTextStyle)]
        }
        return runs
    }

    /// The tool card in the format Xcode writes for terminal commands: the styled command, and its output.
    private static func executeCard(
        toolID: String, name: String, image: String, command: String, runs: [AttributedRun], output: String?,
        status: CardStatus
    ) -> Card {
        var details: [ToolCard.Detail] = [.prose(runs)]
        if let output, !output.isEmpty { details.append(.console(output)) }
        return .toolCallState(ToolCard(
            id: .tool(toolID),
            imageTypeName: image,
            kind: .execute(command: command),
            name: name,
            resultContentState: .attributedContent(runs),
            resultDetailStates: details,
            showHeaderPath: false,
            status: status,
            subActivityStates: []
        ))
    }

    /// Xcode's "Terminal Command" card. A denied command keeps its card, with the denial as its output.
    static func terminalCard(toolID: String, command: String, output: String?, status: CardStatus = .completed) -> Card {
        executeCard(toolID: toolID, name: "Terminal Command", image: "apple.terminal", command: command,
                    runs: styledCommand(command), output: output, status: status)
    }

    /// The tool card shown by its title and SF Symbol only (kind `other`), e.g. "Tool Search", or an agent's task.
    static func namedToolCard(toolID: String, name: String, icon: String, status: CardStatus = .completed) -> Card {
        .toolCallState(ToolCard(
            id: .tool(toolID), imageTypeName: icon, kind: .other, name: name, resultContentState: nil,
            resultDetailStates: [], showHeaderPath: false, status: status, subActivityStates: []))
    }

    /// The card of a fetched web page (grouped with the fetches next to it).
    static func webFetchCard(toolID: String, url: String, status: CardStatus = .completed) -> Card {
        .webFetchState(WebFetchCard(id: .tool(toolID), status: status, url: RelativeURL(relative: url)))
    }

    /// The card of a web search: its query and the titles of the pages it found (grouped with the searches next to it).
    static func webSearchCard(
        toolID: String, tool: String, query: String, titles: [String], status: CardStatus = .completed
    ) -> Card {
        .toolCallSearchState(WebSearchCard(
            id: .tool(toolID), matchCount: titles.count, queries: [query], results: titles.map { .init(title: $0) },
            searchToolType: tool, status: status))
    }

    /// The tool card for a tool with no known Xcode format: titled with the tool's name (a guess at Xcode's format).
    static func genericCard(
        toolID: String, title: String, summary: String, output: String?, status: CardStatus = .completed
    ) -> Card {
        executeCard(toolID: toolID, name: title, image: genericToolIcon, command: summary,
                    runs: [.text(summary), .attributes(plainTextStyle)],
                    output: String((output ?? "").prefix(maxOutputLength)), status: status)
    }

    // MARK: A turn's cards

    /// The group a card is shown in with the same kind of cards next to it; nil if it is shown on its own.
    private static func groupKind(of card: Card) -> CardGroup.GroupKind? {
        switch card {
        case .fileOperationState(let file) where file.operationKind == .read: .fileOperation(.read)
        case .webFetchState: .toolCall(.webFetch)
        case .toolCallSearchState: .search
        default: nil
        }
    }

    /// A turn's cards from its events: Xcode's `responseContent`, `responseContentSequence` and `isModification`.
    /// Thinking (`.intermediate`) and replies (`.assistantMessage`, with their tables cut out) as text blocks, each
    /// tool use as the provider's card for it with its result (`card`; nil: no card, e.g. a tool Xcode doesn't show).
    static func turnCards(
        for events: [ChatEvent], card: (ChatEvent.ToolUse, ChatEvent.ToolResult?) -> Card?
    ) -> (content: [Card], sequence: [CardID], isModification: Bool) {
        var results: [String: ChatEvent.ToolResult] = [:]
        for case .toolResult(let result) in events { results[result.toolUseID] = result }

        var response: (content: [Card], sequence: [CardID], isModification: Bool) = ([], [], false)
        // The open group: its kind, its index in `content`, and its members.
        var group: (kind: CardGroup.GroupKind, index: Int, members: [Card])?

        /// Adds a text or table block; it ends any open group.
        func append(_ block: (Card, CardID)) {
            response.content.append(block.0)
            response.sequence.append(block.1)
            group = nil
        }

        for event in events {
            switch event {
            case .intermediate(let thinking):
                // Xcode shows thinking without the line breaks it ends with.
                append(textBlock(.thinking, thinking.trimmingCharacters(in: .newlines)))
            case .assistantMessage(let reply):
                for part in textAndTables(reply) {
                    append(part.isTable ? tableBlock(part.text) : textBlock(.prose, part.text))
                }
            case .toolUse(let toolUse):
                guard let toolCard = card(toolUse, results[toolUse.id]) else { continue }
                response.sequence.append(.tool(toolUse.id))
                if case .fileOperationState(let file) = toolCard, file.status == .completed,
                    [.added, .modified, .deleted].contains(file.operationKind)
                {
                    response.isModification = true
                }
                guard let kind = groupKind(of: toolCard) else {
                    group = nil
                    response.content.append(toolCard)
                    continue
                }
                if group?.kind != kind {
                    group = (kind, response.content.count, [])
                    response.content.append(toolCard)  // replaced by the group below
                }
                group?.members.append(toolCard)
                if let group {
                    response.content[group.index] = .toolCallGroupState(CardGroup(groupKey: kind, members: group.members))
                }
            default:
                break
            }
        }
        return response
    }
}
