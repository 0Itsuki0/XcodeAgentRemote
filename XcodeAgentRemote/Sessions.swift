//
//  Sessions.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/15.
//

/// List sessions
///
/// session list source:  xcode chat data: `~/Library/Developer/Xcode/UserData/CodingAssistant`
/// chat history source
/// - claude: `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects`
///
/// ```
/// project_a
///  - session_1
///  - session_2 ...
///  project_b
///  - session_1
///  - session_2 ...
///  ```
///
///  Each session contains
///  - current mode (auto vs manual)
///  - provider (claude opus 5.5, claude haiku, codex ...)
///  - session history (loaded from each provider instead of the xcode chat data). For not implemented providers, "NOT IMPLEMENTED"
///  - any other metadata available
