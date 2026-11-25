//
//  ClaudeTranscriptEditing.swift
//  XcodeAgentRemote
//
//  Removing a tool use, or the result the agent wrote when it was stopped, from a session's transcript.
//

import Foundation

nonisolated extension ClaudeProvider {

    /// Removes a tool use and its result from the transcript: their lines (or only their blocks, if a message has
    /// other blocks).
    static func removeToolUse(_ toolUseID: String, sessionID: String) throws {
        _ = try removeBlocks(sessionID: sessionID) { _, block in
            isBlock(block, of: toolUseID)
        }
        PendingToolUses.remove(toolUseID, agent: agent)
    }

    /// The text Claude adds after a tool use's "rejected" result when the user stops it in Xcode (the close button).
    private static let interruptedText =
        "[Request interrupted by user for tool use]"

    /// The result Claude writes for a tool killed while it ran (the project closed by the app with AppleScript: Xcode
    /// doesn't notice, its agent's tool is killed).
    private static let killedResult = "Exit code 137"

    /// Removes the result the agent wrote when it was stopped while the tool ran, and only that, so a tool that finished
    /// on its own keeps its result (it is not run again):
    /// - the project closed by the app (AppleScript): `"content": "Exit code 137"`, `"is_error": true`,
    ///   `"toolUseResult": "Error: Exit code 137"`;
    /// - the user stopping it in Xcode (the close button): `"toolDenialKind": "user-rejected"`, then the interrupted
    ///   text;
    /// - the project closed by the app while Xcode's prompt was still open: `"toolDenialKind": "cancelled"` ("The user
    ///   doesn't want to take this action right now…").
    static func removeStoppedResult(of toolUseID: String, sessionID: String)
        throws -> Bool
    {
        let transcript = try transcriptFile(sessionID: sessionID)
        // The result's line, if it is one of those.
        var resultLine: String?
        for line in try String(contentsOf: transcript, encoding: .utf8).split(
            separator: "\n"
        ) where line.contains(toolUseID) {
            guard
                let entry = try? JSONDecoder().decode(
                    [String: JSONValue].self,
                    from: Data(line.utf8)
                ),
                case .object(let message)? = entry["message"],
                case .array(let blocks)? = message["content"],
                let result = blocks.first(where: {
                    isResultBlock($0, of: toolUseID)
                }), case .object(let fields) = result,
                case .string(let uuid)? = entry["uuid"]
            else { continue }
            let rejected = entry["toolDenialKind"] == .string("user-rejected")
                || entry["toolDenialKind"] == .string("cancelled")
            let killed =
                fields["content"] == .string(killedResult)
                && fields["is_error"] == .bool(true)
                && entry["toolUseResult"] == .string("Error: \(killedResult)")
            if rejected || killed { resultLine = uuid }
        }
        guard let resultLine else { return false }
        return try removeBlocks(sessionID: sessionID) { entry, block in
            if isResultBlock(block, of: toolUseID) {
                return entry["uuid"] == .string(resultLine)
            }
            // The interrupted text right after it (only when the user stopped it in Xcode).
            guard entry["parentUuid"] == .string(resultLine),
                case .object(let fields) = block
            else { return false }
            return fields["type"] == .string("text")
                && fields["text"] == .string(interruptedText)
        }
    }

    /// Removes the content blocks `isRemoved` picks (given the block's line), and the lines left without blocks. Lines
    /// that point at a removed line (`parentUuid`, `leafUuid`) are pointed past it, to the nearest line that stays, so
    /// the chain stays. Returns whether anything was removed.
    private static func removeBlocks(
        sessionID: String,
        where isRemoved: ([String: JSONValue], JSONValue) -> Bool
    ) throws -> Bool {
        let transcript = try transcriptFile(sessionID: sessionID)
        let lines = try String(contentsOf: transcript, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(
                String.init
            )
        var removedAny = false
        // Removed line uuid → its parent uuid.
        var removedParents: [String: JSONValue] = [:]
        var kept: [String] = []
        for line in lines {
            guard
                var entry = try? JSONDecoder().decode(
                    [String: JSONValue].self,
                    from: Data(line.utf8)
                ),
                case .object(var message)? = entry["message"],
                case .array(let blocks)? = message["content"]
            else {
                kept.append(line)
                continue
            }
            let others = blocks.filter { !isRemoved(entry, $0) }
            if others.count == blocks.count {
                kept.append(line)
                continue
            }
            removedAny = true
            if others.isEmpty {
                if case .string(let uuid)? = entry["uuid"] {
                    removedParents[uuid] = entry["parentUuid"] ?? .null
                }
            } else {
                message["content"] = .array(others)
                entry["message"] = .object(message)
                kept.append(try encodedLine(entry))
            }
        }
        /// The nearest line that stays, going up from a removed one.
        func survivingParent(of uuid: String) -> JSONValue {
            var parent = removedParents[uuid] ?? .null
            while case .string(let next) = parent, let up = removedParents[next]
            { parent = up }
            return parent
        }
        let relinked = try kept.map { line in
            guard !removedParents.isEmpty,
                var entry = try? JSONDecoder().decode(
                    [String: JSONValue].self,
                    from: Data(line.utf8)
                )
            else { return line }
            var changed = false
            for key in ["parentUuid", "leafUuid"] {
                if case .string(let uuid)? = entry[key],
                    removedParents[uuid] != nil
                {
                    entry[key] = survivingParent(of: uuid)
                    changed = true
                }
            }
            return changed ? try encodedLine(entry) : line
        }
        if removedAny {
            try relinked.joined(separator: "\n").write(
                to: transcript,
                atomically: true,
                encoding: .utf8
            )
        }
        return removedAny
    }

    private static func isResultBlock(_ block: JSONValue, of toolUseID: String)
        -> Bool
    {
        guard case .object(let fields) = block else { return false }
        return fields["type"] == .string("tool_result")
            && fields["tool_use_id"] == .string(toolUseID)
    }

    /// Whether a content block is the tool use with this id, or its result.
    private static func isBlock(_ block: JSONValue, of toolUseID: String)
        -> Bool
    {
        guard case .object(let fields) = block else { return false }
        switch fields["type"] {
        case .string("tool_use")?: return fields["id"] == .string(toolUseID)
        case .string("tool_result")?:
            return fields["tool_use_id"] == .string(toolUseID)
        default: return false
        }
    }

    /// One transcript line: compact JSON, slashes unescaped (as Claude writes them).
    private static func encodedLine(_ entry: [String: JSONValue]) throws
        -> String
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }
}
