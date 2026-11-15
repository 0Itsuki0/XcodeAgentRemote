#  Xcode Agent Remote


hello world


## Run Xcode Agent Programmatically

### Current Approach

Do what Xcode does, outside of Xcode: `XcodeAgentRemote/XcodeChat/` (shared by all agents) and `XcodeAgentRemote/Providers/` (per agent).

- run the agent the same way Xcode does
    - `xcrun mcpbridge run-agent claude`: Xcode's bundled binary, config dir, Xcode MCP tools
    - plus the flags Xcode adds: stream-json, Xcode's system prompt (from its template inside Xcode), Xcode's skills plugin, allowed tools
    - new chat: new session. existing chat: resume the session id stored in `conversation.plist`
- write the turn into Xcode's chat files, in Xcode's own format
    - `conversation.plist`, `metadata.plist`, `CodingAssistantManifest.plist`, `Snapshots/`
- permission mode follows Xcode's Manual / Auto setting (`IDEChatAgentPermissionMode` in Xcode's preferences: `standard` = Manual, `auto` = Auto), can be overridden per message
- single turn only. if the agent asks for permission, the turn wait 
- part of the app itself, no separate executable
- the app calls it through `sendMessage` and gets typed events back
- the agent's history is the Claude session `.jsonl`, shared with Xcode. Xcode's chat files are only what Xcode displays

#### Permission: Hook vs agent build in.

- Xcode: a `PreToolUse` hook. a denied tool comes back to the agent as `PreToolUse:Bash hook error: User selected: Don’t Allow`
    - not in Xcode's plugin (`--plugin-dir` has skills and `.mcp.json`, no hooks)
    - only some tools asked: Bash and Write. Edit failed before asking (file missing), WebFetch went through
- here: Claude's built in permission prompt (`--permission-prompt-tool stdio`, `can_use_tool` requests)
    - a denied tool comes back as `The user denied this tool use.`, no answer in time as `No answer to this permission request within N seconds.`
    - asked for Bash, Write and Edit
- what the user does / sees is the same: asked, allowed runs, denied doesn't, the agent is told it was denied
    - only the denial text differs (it ends up in the denied card's output, and the agent may word its reply differently)
    - which tools ask may differ
- the card is the same either way: a denied tool keeps its card with `status: cancelled` (the "!")


#### Current Testing State

**Confirmed**

- cards match Xcode's own, field for field (two turns Xcode wrote, replayed through the port)
    - Bash (terminal card), Read, Write (new file), Edit
    - WebFetch, WebSearch (group cards), ToolSearch, Agent (title only cards)
    - TaskCreate: no card
    - a table in a reply: cut out as its own table block
    - thinking and reply text
    - denied tool: its own card with `status: cancelled`. failed tool: `status: failed` with the error
- a turn the port writes matches what the old script wrote (which was checked against Xcode): chat, metadata, manifest, snapshots
- new chat, continue a chat, continue a chat by its store name
- permission in Manual mode: allow, deny, no answer in time (denied), answer to an unknown tool use (rejected)
- questions (AskUserQuestion): one choice, several choices (multi select), declined
- plans (ExitPlanMode): approved (then it runs), rejected with feedback (nothing runs)
    - both directly on the Mac and through the server
- cancelling a turn stops the agent, the turn is not saved
- errors: unknown chat, missing project, missing store, agent not implemented (e.g. codex)
- server + iOS client code (run from the Mac, against the app's server code)
    - `/health`, `/projects`, `/history`
    - message → permission request → answer → … : each response ends where the turn waits for an answer, the answer's response continues the turn
    - allow and deny, the denied tool doesn't run

**Not Confirmed**

- `isModification`: Xcode said false for a turn whose Write went outside the project (`/tmp`). the port says true
- tools never seen in Xcode: Xcode MCP tools (BuildProject…), TaskUpdate / TaskList, NotebookEdit, a failed Bash (non zero exit). they get the generic card, a guess
- each card format is from one Xcode example
- the agent itself failing: the turn should be saved, then the error sent
- chats written by the port, opened in Xcode (after reopening the project)
- the iOS app itself (only its client code was run, on the Mac)
- an event containing U+2028 on the iOS client (it splits lines on it)
- a turn whose permission request is never answered: its saved stream is never cleaned up


### Rejected

- resume the chat with the CLI (`xcrun agent claude --resume <sessionID>`)
    - only the Claude session `.jsonl` gets the turn. Xcode's chat never shows it
    - `/resume` in the CLI doesn't even list Xcode chats
- drive Xcode's chat UI with Accessibility
    - the message box and the send button can't be focused or typed into from outside
- call into Xcode itself (the private method that sends a message)
    - needs SIP or library validation turned off. not something every Mac can do
- `MCP_XCODE_SESSION_ID`, `xcrun mcpbridge` tools
    - these are for the agent calling Xcode (build, run, read files…), not for sending a message to a chat
- make Xcode reload the chat while it is open
    - nothing watches the chat files, no refresh button, switching tabs does nothing
- a Python script / `.pyz` that needs `python3` installed
    - not a single executable


### Sample Jsonl

Real lines from Claude's session files (`ClaudeAgentConfig/projects/<cwd>/<sessionID>.jsonl`), shortened: only `type`, `message` and `toolUseResult` kept, long text cut with `…`.

- one line per message. other line types (`attachment`, `mode`, `queue-operation`, `cost-state`, `last-prompt`, …) are bookkeeping
- every line also has `uuid`, `parentUuid`, `sessionId`, `timestamp`, `cwd`, `version`, `gitBranch`, `permissionMode`, `entrypoint` (`sdk-cli`) …
- questions, plans and permissions are all tools: a `tool_use` from the assistant, then a `tool_result` from the "user"
- the permission request itself is not in the file: it goes over the agent's stdin / stdout (last section)


#### User message (the prompt)

```json
{"type": "user", "message": {"role": "user", "content": "Use the Bash tool to run: touch /var/folders/…/allowed. Then reply DONE."}}
```

#### Assistant message: thinking, text

```json
{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "The user turned down the offer, so I'll report that and leave the task reminder aside.\n\n"}]}}
{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "DONE"}]}}
```

#### Tool use, tool output

```json
{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_01Hcn3Wpri2yGcS3F3LMFCUZ", "name": "Bash", "input": {"command": "touch /var/folders/…/allowed", "description": "Create the allowed marker file"}, "caller": {"type": "direct"}}]}}
{"type": "user", "message": {"role": "user", "content": [{"tool_use_id": "toolu_01Hcn3Wpri2yGcS3F3LMFCUZ", "type": "tool_result", "content": "(Bash completed with no output)", "is_error": false}]}, "toolUseResult": {"stdout": "", "stderr": "", "interrupted": false, "isImage": false, "noOutputExpected": true}}
```

#### Tool failed

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "<tool_use_error>File does not exist. Note: your current working directory is /Users/itsuki…", "is_error": true, "tool_use_id": "toolu_015Z5w83ewmhYfBLT4rCi23o"}]}, "toolUseResult": "Error: File does not exist. Note: your current working directory is /Users/itsuki/Desktop/…"}
```

#### Permission: allowed, denied, no answer in time

- allowed: just the tool's normal `tool_result` (above)
- denied: the deny message as an error result

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "The user denied this tool use.", "is_error": true, "tool_use_id": "toolu_019Ljw5dDxCWQjXMwqCDT3qw"}]}, "toolUseResult": "Error: The user denied this tool use."}
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "No answer to this permission request within 5 seconds.", "is_error": true, "tool_use_id": "toolu_01U3crSkeL1ToJ52AnZbWkJ4"}]}, "toolUseResult": "Error: No answer to this permission request within 5 seconds."}
```

- denied in Xcode (its hook)

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "PreToolUse:Bash hook error: User selected: Don’t Allow", "is_error": true, "tool_use_id": "toolu_01W7CY9HucWWtktDFRUwJJuw"}]}, "toolUseResult": "Error: PreToolUse:Bash hook error: User selected: Don’t Allow"}
```

#### User choice: AskUserQuestion

- the question

```json
{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_019u9REDsbqUiZkNezDLGfX8", "name": "AskUserQuestion", "input": {"questions": [{"question": "Which color do you prefer?", "header": "Color", "multiSelect": false, "options": [{"label": "Red", "description": "The color red"}, {"label": "Green", "description": "The color green"}, {"label": "Blue", "description": "The color blue"}]}]}, "caller": {"type": "direct"}}]}}
```

- answered: one choice, several choices (multi-select: labels joined with `, `)

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "Your questions have been answered: \"Which color do you prefer?\"=\"Green\". You can now conti…", "tool_use_id": "toolu_019u9REDsbqUiZkNezDLGfX8"}]}, "toolUseResult": {"questions": [{"multiSelect": false, "options": […], "question": "Which color do you prefer?", "header": "Color"}], "answers": {"Which color do you prefer?": "Green"}}}
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "Your questions have been answered: \"Which colors do you like?\"=\"Red, Blue\". You can now co…", "tool_use_id": "toolu_01K1CHivthYETYnjo8oThJg7"}]}, "toolUseResult": {"questions": [{"multiSelect": true, "options": […], "question": "Which colors do you like?", "header": "Colors"}], "answers": {"Which colors do you like?": "Red, Blue"}}}
```

- declined

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "The user declined to answer.", "is_error": true, "tool_use_id": "toolu_014cyDC7kDftDLKBuWSDi3Rp"}]}, "toolUseResult": "Error: The user declined to answer."}
```

#### Plan: ExitPlanMode

- the plan (after `EnterPlanMode`; the plan is also written to `ClaudeAgentConfig/plans/<name>.md`)

```json
{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_0175xuriiSDtDrK73TPskQw3", "name": "ExitPlanMode", "input": {"plan": "# Plan\n\n## Context\nYou asked for a one-step plan that runs `echo planned`.\n\n## Steps\n1. Ru…", "planFilePath": "/Users/itsuki/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/plans/synthetic-gr…"}, "caller": {"type": "direct"}}]}}
```

- approved, rejected with feedback

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "User has approved your plan. You can now start coding. Start with updating your todo list …", "tool_use_id": "toolu_0175xuriiSDtDrK73TPskQw3"}]}, "toolUseResult": {"plan": "# Plan\n\n…", "isAgent": false, "filePath": "/Users/itsuki/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/plans/synthetic-gr…"}}
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "Run `echo second` instead.", "is_error": true, "tool_use_id": "toolu_01GvXVmcsLfYGcdv56xbLSo3"}]}, "toolUseResult": "Error: Run `echo second` instead."}
```

#### Interrupted

- the agent stopped while a tool was running (or waiting for its permission). nothing is written then
- the next time the session is resumed, Claude adds this result for the tool use that has none

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "[Tool call interrupted: the session ended before this call's result was recorded, so its outcome is unknown. Check whether it took effect before relying on it or running it again.]", "is_error": true, "tool_use_id": "toolu_018pckhASC7nCM9urwCcsrhm"}]}, "toolUseResult": "[Tool call interrupted: the session ended before this call's result was recorded, so its outcome is unknown. Check whether it took effect before relying on it or running it again.]"}
```

#### Permission request / response (stream-json, not in the file)

- agent → us (stdout), for a permission, a question or a plan alike

```json
{"type": "control_request", "request_id": "15b24acf-5440-4596-933d-3465d5aaf634", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "display_name": "Bash", "input": {"command": "touch /tmp/control-capture-test", "description": "Create empty test file in /tmp"}, "description": "Create empty test file in /tmp", "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "touch /tmp/control-capture-test"}], "behavior": "allow", "destination": "localSettings"}, {"type": "addDirectories", "directories": ["/tmp"], "destination": "session"}, {"type": "setMode", "mode": "acceptEdits", "destination": "session"}], "blocked_path": "/tmp/control-capture-test", "tool_use_id": "toolu_01E8c6u8Qdr7aZDcqQoJwtfV"}}
```

- us → agent (stdin)
    - deny: `{"behavior": "deny", "message": …}` (also: declining questions, rejecting a plan with its feedback)
    - allow: `{"behavior": "allow", "updatedInput": <the tool's input>}` (also: approving a plan)
    - questions: allow, with the input plus `"answers": {"<question>": "<label>, <label>"}`

```json
{"type": "control_response", "response": {"subtype": "success", "request_id": "15b24acf-5440-4596-933d-3465d5aaf634", "response": {"behavior": "deny", "message": "The user denied this tool use."}}}
```


### Sample Send Message Calls

Real calls to the server (`POST /message`, JSON body, SSE response), from one chat.

- every response is `HTTP 200 text/event-stream`: `event: <type>` + `data: <ChatEvent JSON>` per event
- a response ends where the turn waits for the user (its last `tool_use` has no `tool_result`), or where the turn ends
- the answer to that tool use is another `POST /message`, and its response continues the same turn
- `project` is a file URL. in Swift: `sendMessage(_:to:…)` / `answerUserRequest(_:)` on the Mac, `AgentServerClient.sendMessage` / `.answer` on iOS

#### Regular message (new chat)

```
POST /message
{"prompt":{"prompt":"Reply with only the word pong.","permissionModeOverride":"manual","target":{"newConversation":{"agent":"claude","name":"Sample calls: ad2ff12c","project":"file:///Users/itsuki/Desktop/XcodeAgentRemote/XcodeAgentRemote.xcodeproj"}}}}

event: user_message
data: {"text":"Reply with only the word pong.","type":"user_message"}

event: assistant_message
data: {"type":"assistant_message","text":"pong"}
```

- other targets: `{"conversation":{"id":"<Xcode chat UUID>","project":"file:///…"}}`, `{"conversationInStore":{"id":"<Xcode chat UUID>","store":"<ProjectName>-<hash>"}}`
- optional: `"permissionModeOverride": "manual" | "auto"`, `"permissionTimeout": <seconds>` (default 600)

#### Tool call → approve

```
POST /message
{"prompt":{"prompt":"Use the Bash tool to run: touch /tmp/sample-calls-allowed. Then reply DONE.","permissionModeOverride":"manual","target":{"conversation":{"id":"68D951A3-2E67-4A6B-9DBA-F0E0002ADF8B","project":"file:///Users/itsuki/Desktop/XcodeAgentRemote/XcodeAgentRemote.xcodeproj"}}}}

event: user_message
data: {"type":"user_message","text":"Use the Bash tool to run: touch \/tmp\/sample-calls-allowed. Then reply DONE."}

event: tool_use
data: {"input":{"command":"touch \/tmp\/sample-calls-allowed","description":"Create an empty marker file in \/tmp"},"name":"Bash","type":"tool_use","id":"toolu_01Gpcs89uKnEUg1GcA9KSyUb"}
```

```
POST /message
{"answer":{"_0":{"permission":{"toolUseID":"toolu_01Gpcs89uKnEUg1GcA9KSyUb","allow":true}}}}

event: tool_result
data: {"tool_use_id":"toolu_01Gpcs89uKnEUg1GcA9KSyUb","type":"tool_result","output":"(Bash completed with no output)","is_error":false}

event: assistant_message
data: {"type":"assistant_message","text":"DONE"}
```

#### Question → choice

```
POST /message
{"prompt":{"prompt":"Use the AskUserQuestion tool to ask me which color I prefer, with exactly these options: Red, Green, Blue. Then reply with only the color I chose.","permissionModeOverride":"manual","target":{"conversation":{"id":"68D951A3-2E67-4A6B-9DBA-F0E0002ADF8B","project":"file:///…/XcodeAgentRemote.xcodeproj"}}}}

event: user_message
data: {"type":"user_message","text":"Use the AskUserQuestion tool to ask me which color I prefer, …"}

event: tool_use
data: {"input":{"questions":[{"multiSelect":false,"question":"Which color do you prefer?","options":[{"label":"Red","description":"The color red"},{"label":"Green","description":"The color green"},{"label":"Blue","description":"Th…
```

```
POST /message
{"answer":{"_0":{"questions":{"toolUseID":"toolu_019XY2sGxc3vptwUHm7RQUrg","answers":{"Which color do you prefer?":["Green"]}}}}}

event: tool_result
data: {"tool_use_id":"toolu_019XY2sGxc3vptwUHm7RQUrg","type":"tool_result","output":"Your questions have been answered: \"Which color do you prefer?\"=\"Green\". You can now continue with these answers in mind.","is_error":false}

event: assistant_message
data: {"type":"assistant_message","text":"Green"}
```

- answers are keyed by the question's text. several labels for a multi select question: `["Red","Blue"]`

#### Tool call → deny

```
POST /message
{"prompt":{"prompt":"Use the Bash tool to run: touch /tmp/sample-calls-denied. If it is denied, reply DENIED.","permissionModeOverride":"manual","target":{"conversation":{"id":"68D951A3-2E67-4A6B-9DBA-F0E0002ADF8B","project":"file:///…/XcodeAgentRemote.xcodeproj"}}}}

event: user_message
data: {"type":"user_message","text":"Use the Bash tool to run: touch \/tmp\/sample-calls-denied. If it is denied, reply DENIED."}

event: tool_use
data: {"input":{"description":"Create an empty marker file in \/tmp","command":"touch \/tmp\/sample-calls-denied"},"name":"Bash","type":"tool_use","id":"toolu_01L16Nhanm9HoMBXmyD6nsMo"}
```

```
POST /message
{"answer":{"_0":{"permission":{"toolUseID":"toolu_01L16Nhanm9HoMBXmyD6nsMo","allow":false,"message":"Not now."}}}}

event: tool_result
data: {"tool_use_id":"toolu_01L16Nhanm9HoMBXmyD6nsMo","type":"tool_result","output":"Not now.","is_error":true}

event: assistant_message
data: {"type":"assistant_message","text":"DENIED"}
```

#### Other answers

- decline the questions: `{"answer":{"_0":{"declineQuestions":{"toolUseID":"toolu_…"}}}}` (optional `"message"`)
- approve a plan (ExitPlanMode): `{"answer":{"_0":{"planApproval":{"approve":true,"toolUseID":"toolu_…"}}}}`
- reject a plan: `{"answer":{"_0":{"planApproval":{"approve":false,"feedback":"Run `echo second` instead.","toolUseID":"toolu_…"}}}}`
- no turn waiting for that tool use: `404`, `{"error":{"message":"No turn is waiting for an answer to tool use toolu_…"}}`
- the turn failed: the response ends with `event: error`, `data: {"message":"…"}`


### Xcode In memory cache for chat?

evidence:
- send a message from script
    - `conversation.plist`: 15 turns, the last one is the script's
- send a new message from xcode UI without reopen xcode
    - the agent still knew the script's message (it reads the Claude session `.jsonl`)
- conversation.plist
    - still 15 turns: the script's turn is gone, replaced by the one from Xcode
    - Xcode saved what it had in memory, without reading the file first
- the chat's text exists only in `conversation.plist` and the Claude session `.jsonl`. Nowhere else in Xcode's folders
- `Snapshots/` only hold git diffs, not the chat


what that means:
- reopen the project after using the script
- don't send from Xcode in that chat before reopening, or the script's turns are lost from Xcode's chat (the agent still remembers them)




## Xcode Agent Notes

- Configuration:  `~/Library/Developer/Xcode/CodingAssistant/`
- Chat data: `~/Library/Developer/Xcode/UserData/CodingAssistant`
    - claude session history: `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects`
    - The link: CodingAssistant/projectName/D868CB20-…/conversation.plist has a binary field: `assistantConfiguration`. Decoded, it contains: `{"agent":{"_0":{"sessionID":"2a561bc4-7ab8-4561-a88f-69e6a53ca073"}}}` where the sessionID is that under projects/projectName/sessionId.

### `xcrun` command

- `xcrun mcpbridge run-agent claude`: Launch a coding agent
    - Supported agents: `antigravity`, `claude`, `claude-ext`, `codex`, `copilot`, `mock-agent`
    - or simply `xcrun agent claude`

```bash
itsuki@MacBook-Pro ~ % xcrun mcpbridge -h
STDIO Bridge for Xcode MCP Tools

USAGE: mcpbridge <command> [options]

COMMANDS:
  run-agent  Launch a coding agent with Xcode-provided configuration

OPTIONS:
  -h, --help  Show this help message

DESCRIPTION:
    Without a subcommand, acts as a STDIO bridge between MCP (Model Context
    Protocol) clients and Xcode's MCP tool service. Reads JSON-RPC 2.0
    messages from stdin and forwards responses to stdout.

ENVIRONMENT VARIABLES:
    MCP_XCODE_PID         Optional. The process ID of the Xcode to connect to.
                          Overrides the default, which connects to the Xcode
                          selected by xcode-select.

    MCP_XCODE_SESSION_ID  Optional. A UUID identifying an Xcode tool session.

EXAMPLES:
    # Run as MCP bridge with auto-detected Xcode instance
    xcrun mcpbridge

    # Run with specific Xcode PID
    MCP_XCODE_PID=12345 xcrun mcpbridge

    # Launch Claude with Xcode config
    xcrun mcpbridge run-agent claude

    # Dry-run to see what would be executed
    xcrun mcpbridge run-agent --dry-run claude

    # Launch Claude with additional user args
    xcrun mcpbridge run-agent claude --model opus -p "fix the bug"

    # Export every available skill into ./xcode-skills
    xcrun agent skills export

    # Export to a chosen directory and overwrite anything already there
    xcrun agent skills export --replace-existing ~/my-skills

    # Print the path to Xcode's packaged plugins, materializing it if needed
    xcrun agent plugin path --plugin-format <name>
```

### Running From Terminal?

**Short answer: no public way to drive an Xcode chat from the terminal.** A session started with `xcrun agent claude` is a plain CLI session and never shows up in Xcode's chat list.

#### Why CLI sessions don't show up in Xcode

- `xcrun agent claude` (= `xcrun mcpbridge run-agent claude`) launches Xcode's bundled `claude` (`~/Library/Developer/Xcode/CodingAssistant/Agents/XcodeVersions/<build>/claude/claude`) with Xcode's config (`ClaudeAgentConfig`).
- Both CLI and Xcode sessions write their transcript to `ClaudeAgentConfig/projects/<cwd-with-dashes>/<sessionID>.jsonl`.
- Only Xcode also writes its own chat record (`UserData/CodingAssistant/<Project>-<hash>/<chat-UUID>/conversation.plist`, `metadata.plist`, `Snapshots/`, `CodingAssistantManifest.plist`). Xcode's chat list reads **only** from there, so CLI sessions never appear in Xcode. The link is one-way: Xcode chat → Claude session.
- Sessions are tagged by `entrypoint` in the `.jsonl`: CLI = `"cli"`, Xcode = `"sdk-cli"` (Xcode runs it through the SDK).

#### Resuming an Xcode chat from the terminal

- `/resume` in the CLI does **not** list Xcode chats. Claude Code deliberately filters out sessions whose `entrypoint` is `sdk-cli` / `sdk-ts` / `sdk-py` when the current session is a CLI one (`Session … filtered from /resume: entrypoint=sdk-cli`).
- Resuming by ID works:

```bash
cd /path/to/project   # must be the same cwd the Xcode chat used
xcrun agent claude --resume <sessionID>   # sessionID from conversation.plist → assistantConfiguration
```

- Anything added this way goes into the `.jsonl` only. Xcode's `conversation.plist` is not updated, so the chat shown in Xcode will stop matching the transcript.

#### What doesn't work

- `MCP_XCODE_PID` / `MCP_XCODE_SESSION_ID`: these pick which Xcode (and which tool session) the MCP bridge talks to. They are for the agent calling Xcode, not for sending a chat into Xcode.
- `xcrun mcpbridge` tools (`BuildProject`, `XcodeRead`, `RunProject`, `RenderPreview`, …): agent → Xcode only. None of them creates or sends a chat.
- Xcode AppleScript dictionary: build / run / test / debug / documents only. Nothing for chats.
- Xcode URL schemes (`xcode`, `xcdevice`, `xcdoc`, …): nothing chat-related.
- Private frameworks (`Xcode.app/Contents/PlugIns/IDEIntelligenceChat.framework`, `IDEIntelligenceAgents.framework`, `IDEIntelligenceACP.framework`): the only service-like name found is `com.apple.dt.internal.genAIAgentProxyService`, which looks internal to Xcode. No external XPC service, URL handler or App Intent was found for sending a prompt.

#### Unofficial options

1. **Drive Xcode's chat UI with the Accessibility API** (details below). Xcode runs the chat itself, so history and snapshots stay correct. Breaks if Apple changes the UI; Xcode must be open.
2. **Write Xcode's chat files yourself**: create `<UUID>/conversation.plist` + `metadata.plist`, add an entry to `CodingAssistantManifest.plist`, and set `assistantConfiguration` to base64 of `{"agent":{"_0":{"sessionID":"…"}}}`; run the session from the CLI with `--session-id`. The chat would show up as a record only, without snapshots, and Xcode may need a restart to notice it.
3. **Reverse engineer the private frameworks** (`class-dump` / disassembler on `IDEIntelligenceChat`) and call into Xcode via code injection. Lots of work, fragile, needs SIP / library-validation workarounds.

#### Option 1: Accessibility (UI scripting) details

Requirement: the app running the script (e.g. Terminal) needs **System Settings → Privacy & Security → Accessibility**. Without it: `osascript is not allowed assistive access. (-1728)`. Restart the app after enabling.

Accessibility tree of an open chat (Xcode 27C5020n), found by walking the window with `AXUIElementCopyAttributeValue`:

```
AXWindow  id=Xcode.WorkspaceWindow
└ … AXGroup  id="editor context"  desc="New Conversation"
    └ AXSplitGroup / AXSplitGroup
        └ AXGroup  sub=AXHostingView                     ← chat view (SwiftUI)
            ├ [0] AXScrollArea → AXOpaqueProviderGroup   ← transcript; messages are AXStaticText values
            ├ [1] AXScrollArea → AXUnknown               ← prompt input
            ├ [2] AXMenuButton  id=paperclip  title=Attachments
            ├ [3] AXMenuButton  help=Model   title=<model, e.g. Opus 5.5>
            ├ [4] AXMenuButton  help=Mode    title=<e.g. Manual Mode>
            └ [5] AXButton      id=arrow.up  desc=Submit  (AXPress; disabled while input is empty)
```

Findings:

- **Prompt input** is an `AXUnknown` with **no `AXValue`**, so text can't be set directly. Its `AXFocused` is settable, and it has a custom action named `Submit`. To enter text: focus it, then type with key events or paste (clipboard + ⌘V).
- **Send**: `AXPress` on the button with `AXIdentifier = "arrow.up"` (enabled only once the input has text), or perform the input's `Submit` action.
- **Read replies**: the transcript is `AXStaticText` elements under the first `AXScrollArea`. Poll it, or read `conversation.plist` / the session `.jsonl` instead (more reliable).
- **New chat**: menu item `File → New → Conversation` (`AXIdentifier = newCodingAssistant:`). Also `Conversation in New Tab` (`newCodingAssistantWithAlternate:`) and `Conversation in Editor Pane` (`newCodingAssistantWithShiftPlusAlternate:`).
- **Switch chat**: the editor tab bar has an `AXRadioButton` (`sub=AXTabButton`) per open chat, titled with the chat name; `Window` menu has `<Project> — <chat name>` items.
- Find elements by `AXIdentifier` (`arrow.up`, `paperclip`, `editor context`) rather than child indexes, since indexes change with the layout.

Sketch (AppleScript; finds the chat via the Submit button, pastes the prompt, presses Submit). **Not yet run end to end**:

```applescript
on run argv
    set prompt to item 1 of argv
    set the clipboard to prompt
    tell application "Xcode" to activate
    tell application "System Events" to tell process "Xcode"
        set submitButton to missing value
        repeat with b in (every button of entire contents of front window)
            if value of attribute "AXIdentifier" of b is "arrow.up" then
                set submitButton to b
                exit repeat
            end if
        end repeat
        set chatView to parent of submitButton -- AXHostingView
        set inputField to UI element 1 of UI element 2 of chatView -- AXScrollArea → AXUnknown
        set value of attribute "AXFocused" of inputField to true
        keystroke "v" using command down
        delay 0.3
        click submitButton
    end tell
end run
```

```bash
osascript send-to-xcode.applescript "echo back what i said"
```
