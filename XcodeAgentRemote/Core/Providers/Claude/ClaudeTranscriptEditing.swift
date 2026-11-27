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

    /// The synthetic text Claude adds after the interrupted result when it resumes a session whose tool use had none.
    private static let noResponseText = "No response requested."

    /// For an answer given by resuming the session (the tool use had no result): removes what the agent wrote on resuming,
    /// its `[Tool call interrupted …]` result (`"toolDenialKind": "interrupted"`) and the `No response requested.` after
    /// it, and makes the resume prompt (the answer, a user message) the tool use's result: the user's answer, as a live
    /// turn records it (`permissionDecision.source` `user_temporary` / `user_reject`, the answers in `toolUseResult`).
    static func replaceResumeInterruption(
        with answer: ChatEvent.UserResponse,
        prompt: String,
        sessionID: String
    ) throws -> Bool {
        let toolUseID = answer.toolUseID
        let transcript = try transcriptFile(sessionID: sessionID)
        // The interrupted result's line, the `No response requested.` after it, and the prompt's line right after those
        // (its parent is the last of them): only that one becomes the result, so it directly follows the tool use.
        var resultLine: String?
        var noResponseLine: String?
        var promptLine: String?
        for line in try String(contentsOf: transcript, encoding: .utf8).split(
            separator: "\n"
        ) {
            guard
                let entry = try? JSONDecoder().decode(
                    [String: JSONValue].self,
                    from: Data(line.utf8)
                ),
                case .object(let message)? = entry["message"],
                case .string(let uuid)? = entry["uuid"]
            else { continue }
            if entry["toolDenialKind"] == .string("interrupted"),
                case .array(let blocks)? = message["content"],
                blocks.contains(where: { isResultBlock($0, of: toolUseID) })
            {
                resultLine = uuid
                noResponseLine = nil
                promptLine = nil
            } else if let resultLine, noResponseLine == nil,
                entry["parentUuid"] == .string(resultLine),
                entry["type"] == .string("assistant"),
                isText(message["content"], noResponseText)
            {
                noResponseLine = uuid
            } else if let resultLine, promptLine == nil,
                entry["parentUuid"] == .string(noResponseLine ?? resultLine),
                entry["type"] == .string("user"),
                isText(message["content"], prompt)
            {
                promptLine = uuid
            }
        }
        guard let resultLine else { return false }
        _ = try removeBlocks(sessionID: sessionID) { entry, block in
            if isResultBlock(block, of: toolUseID) {
                return entry["uuid"] == .string(resultLine)
            }
            // The `No response requested.` right after it.
            guard entry["parentUuid"] == .string(resultLine),
                case .object(let fields) = block
            else { return false }
            return fields["type"] == .string("text")
                && fields["text"] == .string(noResponseText)
        }
        if let promptLine {
            try makeResult(
                line: promptLine,
                of: answer,
                prompt: prompt,
                sessionID: sessionID
            )
        }
        return true
    }

    /// Whether a message's content is only this text (a string, or one text block).
    private static func isText(_ content: JSONValue?, _ text: String) -> Bool {
        switch content {
        case .string(let string)?: return string == text
        case .array(let blocks)?:
            guard blocks.count == 1, case .object(let fields) = blocks[0]
            else { return false }
            return fields["type"] == .string("text")
                && fields["text"] == .string(text)
        default: return false
        }
    }

    /// Rewrites the prompt's line (`uuid`) as the answer's tool result.
    private static func makeResult(
        line uuid: String,
        of answer: ChatEvent.UserResponse,
        prompt: String,
        sessionID: String
    ) throws {
        let allowed: Bool
        var output = prompt
        var toolUseResult: JSONValue?
        switch answer {
        case .questions(_, let answers):
            allowed = true
            toolUseResult = .object([
                "answers": .object(
                    answers.mapValues { .string($0.joined(separator: ", ")) }
                )
            ])
        case .declineQuestions(_, let message):
            allowed = false
            output = message ?? declinedMessage
        case .planApproval(_, let approve, let feedback):
            allowed = approve
            if !approve { output = feedback ?? rejectedPlanMessage }
        case .permission(_, let allow, let message):
            allowed = allow
            if !allow { output = message ?? deniedMessage }
        }
        let transcript = try transcriptFile(sessionID: sessionID)
        let lines = try String(contentsOf: transcript, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(
                String.init
            )
        let rewritten = try lines.map { line -> String in
            guard line.contains(uuid),
                var entry = try? JSONDecoder().decode(
                    [String: JSONValue].self,
                    from: Data(line.utf8)
                ),
                entry["uuid"] == .string(uuid),
                case .object(var message)? = entry["message"]
            else { return line }
            var result: [String: JSONValue] = [
                "type": .string("tool_result"),
                "tool_use_id": .string(answer.toolUseID),
                "content": .string(output),
            ]
            if !allowed { result["is_error"] = .bool(true) }
            message["content"] = .array([.object(result)])
            entry["message"] = .object(message)
            entry["permissionDecision"] = .object([
                "decision": .string(allowed ? "accept" : "reject"),
                "source": .string(allowed ? "user_temporary" : "user_reject"),
            ])
            if let toolUseResult { entry["toolUseResult"] = toolUseResult }
            return try encodedLine(entry)
        }
        try rewritten.joined(separator: "\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
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
