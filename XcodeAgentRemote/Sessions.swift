//
//  Sessions.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

/// List project chat sessions.
///
/// session list source:  xcode chat data: `~/Library/Developer/Xcode/UserData/CodingAssistant`
/// chat history source
/// - claude: `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects`
///
/// ```
/// project_a
///  - project metadata (name, path to `.xcodeproj`, conversation store path (path to <ProjectName>-<hash>) )
///  - sessions
///     - session_1 (one session == one chat)
///     - session_2 ...
///  project_b
///  - project metadata
///  - sessions
///     - session_1 (one session == one chat)
///     - session_2 ...
///  ```
///
///  Each session contains
///  - id give by xcode (
///  - provider's session id
///  - folder / group
///  - provider (claude opus 5.5, claude haiku, codex ...)
///  - session history (loaded from each provider instead of the xcode chat data, `XcodeChat.history`). For not implemented providers, "NOT IMPLEMENTED"
///  - any other metadata available

import AppKit
import CryptoKit
import Foundation

/// One agent Xcode can run (Claude, Codex, ...): where its sessions live and how to read them.
/// Implemented per provider in `Providers/`.
nonisolated protocol AgentProvider: SendableMetatype {
    /// The agent: also the key Xcode stores for it under `chatModelDefinitionIdentifier.providerIdentifier.builtIn._0`.
    static var agent: AgentProviderName { get }
    /// A session's events, from the agent's own session storage.
    static func history(sessionID: String) throws -> [ChatEvent]
    /// The folder the agent ran a session in, if the session records it.
    static func workingDirectory(sessionID: String) -> URL?

    // MARK: Running a turn (XcodeChat/XcodeChat.swift)

    /// `chatModelDefinitionIdentifier.modelIdentifier` of the agent's chats, e.g. "claude-code".
    static var modelIdentifier: String { get }
    /// A session id for a new chat.
    static func newSessionID() -> String
    /// Runs one turn of the agent in `request.workingDirectory` and streams its events (not the prompt).
    /// If the agent asks the user (permission to use a tool, questions, a plan), waits for the answer to that tool use
    /// (`PendingUserRequests.waitForAnswer`); no answer is a deny. Records the file content around its
    /// file-changing tool uses, and the ones it denied, in `request.records`.
    /// Throws `XcodeChatError.agentFailed` (after all events) if the agent reports an error.
    /// Cancelling (stopping the iteration) stops the agent.
    static func runTurn(_ request: TurnRequest) -> AsyncThrowingStream<ChatEvent, Error>
    /// The session's tool use that waits for the user's answer: its last tool use, if it has no result and is a
    /// request (a question / plan, or marked waiting: `WaitingMarks`); nil if there is none.
    static func pendingToolUse(sessionID: String) -> ChatEvent.ToolUse?
    /// Removes a tool use and its result from the session's transcript (an earlier tool use the agent repeated).
    static func removeToolUse(_ toolUseID: String, sessionID: String) throws
    /// Removes the result the agent wrote for a tool use when it was stopped while the tool ran (Xcode's project
    /// closed), and the interrupted text after it if any, so the tool use is left without a result. A result the tool
    /// produced itself (it finished before the stop) stays. Returns whether there was one to remove.
    static func removeStoppedResult(of toolUseID: String, sessionID: String) throws -> Bool
    /// Whether two tool uses are the same call (the same tool, with the same input that matters).
    static func isSameCall(_ toolUse: ChatEvent.ToolUse, _ other: ChatEvent.ToolUse) -> Bool
    /// The card Xcode shows for one of the agent's tool uses; nil if it never finished (no result).
    static func card(
        for toolUse: ChatEvent.ToolUse, result: ChatEvent.ToolResult?, record: ToolUseRecords.Record?
    ) -> ChatCard.Card?
}

/// The providers implemented so far.
nonisolated enum AgentProviders {
    static let all: [any AgentProvider.Type] = [ClaudeProvider.self]

    static func provider(for agent: AgentProviderName) -> (any AgentProvider.Type)? {
        all.first { $0.agent == agent }
    }
}

nonisolated enum ChatHistoryError: LocalizedError {
    /// No chat store has a chat with this id.
    case chatNotFound(conversationID: String)
    /// The chat's agent could not be read from its metadata.
    case unknownProvider(conversationID: String)
    /// Loading history is not implemented for this agent (e.g. Codex).
    case notImplemented(agent: AgentProviderName)
    /// The chat has no agent session id.
    case sessionMissing(conversationID: String)
    /// The agent's session file is gone.
    case transcriptMissing(sessionID: String)

    var errorDescription: String? {
        switch self {
        case .chatNotFound(let id): "No Xcode chat \(id)"
        case .unknownProvider(let id): "Unknown agent for Xcode chat \(id)"
        case .notImplemented(let agent): "History is not implemented for agent \(agent.rawValue)"
        case .sessionMissing(let id): "Xcode chat \(id) has no agent session"
        case .transcriptMissing(let sessionID): "No session file for agent session \(sessionID)"
        }
    }
}

/// Xcode Agent Configuration
/// - current mode (auto vs manual)
nonisolated enum XcodeAgentConfiguration {

    /// Xcode's permission menu (Manual / Auto), for all chats.
    /// Stored in Xcode's preferences: `com.apple.dt.Xcode` → `IDEChatAgentPermissionMode`.
    enum PermissionMode: String, Sendable {
        case manual = "standard"
        case auto
        /// Options Xcode hides by default.
        case dontAsk
        case bypassPermissions
    }

    /// Xcode's current permission mode; Manual if it is not set.
    static var permissionMode: PermissionMode {
        let domain = "com.apple.dt.Xcode" as CFString
        CFPreferencesAppSynchronize(domain)  // re-read: Xcode may have changed it since
        let value =
            CFPreferencesCopyAppValue(
                "IDEChatAgentPermissionMode" as CFString,
                domain
            ) as? String
        return value.flatMap(PermissionMode.init(rawValue:)) ?? .manual
    }
}
