//
//  ClaudeSessionHistory.swift
//  XcodeAgentRemote
//
//  A session's conversation from its `.jsonl` transcript, and as the shared events.
//

import Foundation

// MARK: - load session history
nonisolated extension ClaudeProvider {

    nonisolated enum SessionHistory {

        /// Loads the full conversation of a session from its `.jsonl` transcript file
        /// (`<CLAUDE_CONFIG_DIR>/projects/<project-dir>/<sessionID>.jsonl`; for Xcode,
        /// `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects/…`).
        static func load(
            contentsOf url: URL,
            includeSystemMessages: Bool = false
        ) throws -> [SessionMessage] {
            try parse(
                Data(contentsOf: url),
                includeSystemMessages: includeSystemMessages
            )
        }

        /// Rebuilds the conversation from `.jsonl` transcript data, like the Agent SDK's `getSessionMessages`:
        /// follows `parentUuid` links from the newest main-thread message back to the start, restores parallel tool
        /// calls that branch off that chain, and returns user/assistant (and optionally system) messages in order.
        ///
        /// Not ported from the SDK: relinking of messages preserved across compaction (`compact_boundary`) and
        /// conversion of queued-command attachments into user messages.
        static func parse(_ data: Data, includeSystemMessages: Bool = false)
            -> [SessionMessage]
        {
            let decoder = JSONDecoder()
            let keptTypes: Set<String> = [
                "user", "assistant", "progress", "system", "attachment",
            ]
            var entries: [TranscriptEntry] = []
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard
                    let entry = try? decoder.decode(
                        TranscriptEntry.self,
                        from: Data(line)
                    ),
                    keptTypes.contains(entry.type), entry.uuid != nil
                else { continue }
                entries.append(entry)
            }

            // Index by uuid (a later line with the same uuid replaces an earlier one) and remember file order.
            var byUUID: [String: TranscriptEntry] = [:]
            var order: [String: Int] = [:]
            for (index, entry) in entries.enumerated() {
                byUUID[entry.uuid!] = entry
                order[entry.uuid!] = index
            }
            func parent(of entry: TranscriptEntry) -> TranscriptEntry? {
                entry.parentUUID.flatMap { byUUID[$0] }
            }
            func isConversational(_ entry: TranscriptEntry) -> Bool {
                entry.type == "user" || entry.type == "assistant"
            }

            // 1. Leaf: the newest main-thread entry nothing else on the main thread points to,
            //    walked up to its nearest user/assistant entry.
            func isMainThread(_ entry: TranscriptEntry) -> Bool {
                !entry.isSidechain && entry.teamName == nil
                    && entry.type != "progress"
                    && !(entry.type == "attachment"
                        && entry.attachmentType == "fork_briefing")
            }
            let mainThreadParents = Set(
                byUUID.values.filter(isMainThread).compactMap(\.parentUUID)
            )
            let tips = byUUID.values
                .filter {
                    isMainThread($0) && !mainThreadParents.contains($0.uuid!)
                }
                .sorted { order[$0.uuid!]! > order[$1.uuid!]! }

            var leaf: TranscriptEntry?
            var visited = Set<String>()
            findLeaf: for tip in tips {
                var walked: [String] = []
                var current: TranscriptEntry? = tip
                while let entry = current, !visited.contains(entry.uuid!),
                    !walked.contains(entry.uuid!)
                {
                    if isConversational(entry) {
                        leaf = entry
                        break findLeaf
                    }
                    walked.append(entry.uuid!)
                    current = parent(of: entry)
                }
                visited.formUnion(walked)
            }
            if leaf == nil {
                // Fallback: the newest user/assistant entry, preferring main-thread, non-meta ones.
                let conversational = entries.filter(isConversational)
                leaf =
                    conversational.last {
                        !$0.isSidechain && $0.teamName == nil && !$0.isMeta
                    } ?? conversational.last
            }
            guard let leaf else { return [] }

            // 2. Chain: follow parentUuid from the leaf back to the root.
            var chain: [TranscriptEntry] = []
            var inChain = Set<String>()
            var current: TranscriptEntry? = leaf
            while let entry = current, !inChain.contains(entry.uuid!) {
                inChain.insert(entry.uuid!)
                chain.append(entry)
                current = parent(of: entry)
            }
            chain.reverse()

            // 3. Parallel tool calls: each tool_use block of one API message is written as its own entry (same message
            //    id), and their tool_result entries branch off them, so the chain only covers one branch.
            let chainMessageIDs = Set(
                chain.filter { $0.type == "assistant" }.compactMap {
                    $0.message?.id
                }
            )
            let answeredInChain = Set(chain.flatMap(\.toolResultIDs))
            var toolUseIDs = Set<String>()
            var recovered: [TranscriptEntry] = []
            for entry in byUUID.values where entry.type == "assistant" {
                guard let id = entry.message?.id, chainMessageIDs.contains(id)
                else { continue }
                toolUseIDs.formUnion(entry.toolUseIDs)
                if !inChain.contains(entry.uuid!) { recovered.append(entry) }
            }
            for entry in byUUID.values
            where entry.type == "user" && !inChain.contains(entry.uuid!)
                && !entry.isSidechain
            {
                let results = entry.toolResultIDs
                if !results.isEmpty,
                    results.allSatisfy({
                        toolUseIDs.contains($0) && !answeredInChain.contains($0)
                    })
                {
                    recovered.append(entry)
                }
            }
            let conversation =
                recovered.isEmpty
                ? chain
                : (chain + recovered).sorted {
                    order[$0.uuid!]! < order[$1.uuid!]!
                }

            // 4. Keep user/assistant (and optionally system) messages of the main thread, without meta entries.
            return conversation.compactMap { entry -> SessionMessage? in
                guard
                    let type = SessionMessage.MessageType(rawValue: entry.type),
                    type != .system || includeSystemMessages,
                    !entry.isMeta, !entry.isSidechain, entry.teamName == nil
                else { return nil }
                return SessionMessage(
                    type: type,
                    uuid: entry.uuid!,
                    sessionID: entry.sessionID ?? "",
                    message: entry.message,
                    parentToolUseID: nil,
                    parentAgentID: nil
                )
            }
        }
    }

}

// MARK: - Conversion to the shared events

nonisolated extension ClaudeProvider.SessionMessage {
    /// This transcript message as `ChatEvent`s: user text → `.userMessage`, assistant text → `.assistantMessage`,
    /// thinking → `.intermediate`, tool use / tool result → `.toolUse` / `.toolResult`
    /// (images and redacted thinking are left out).
    var chatEvents: [ChatEvent] {
        guard let message else { return [] }
        return message.content.compactMap { block -> ChatEvent? in
            switch (message.role, block) {
            case (.user, .text(let text)):
                return .userMessage(text.text)
            case (.assistant, .text(let text)):
                return .assistantMessage(text.text)
            case (_, .thinking(let thinking)):
                return .intermediate(thinking.thinking)
            case (_, .toolUse(let toolUse)):
                guard case .object(let input) = toolUse.input else {
                    return .toolUse(
                        ChatEvent.ToolUse(
                            id: toolUse.id,
                            name: toolUse.name,
                            input: [:]
                        )
                    )
                }
                return .toolUse(
                    ChatEvent.ToolUse(
                        id: toolUse.id,
                        name: toolUse.name,
                        input: input
                    )
                )
            case (_, .toolResult(let result)):
                return .toolResult(
                    ChatEvent.ToolResult(
                        toolUseID: result.toolUseID,
                        output: Self.text(of: result.content ?? []),
                        isError: result.isError ?? false
                    )
                )
            default:
                return nil
            }
        }
    }

    /// The text of a tool result's content blocks (as a live turn reports it).
    static func text(of blocks: [ClaudeProvider.ContentBlock]) -> String {
        blocks.compactMap { block -> String? in
            if case .text(let text) = block { text.text } else { nil }
        }.joined()
    }
}
