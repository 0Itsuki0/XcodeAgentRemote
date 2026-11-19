//
//  ChatProject.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/19.
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
