

# Xcode Agent Remote

> By proceeding, you confirm your understanding of the [license](/LICENSE.md).

## Table of Contents

- [Apps](#apps)
    - [Download](#download)
    - [Permissions Required](#permissions-required)
    - [Requirements](#requirements)
    - [Set up](#set-up)
    - [Things to try on iOS](#things-to-try-on-ios)
    - [Agent Support](#agent-support)
    - [Demo Video](#demo-video)
- [Basic Idea / Approach](#basic-idea--approach)
- [Run Xcode Agent Programmatically](#run-xcode-agent-programmatically)
    - [Basic Idea](#basic-idea)
    - [`xcrun` Command](#xcrun-command)
    - [Important File locations](#important-file-locations)
    - [Sample Jsonl (Claude history)](#sample-jsonl-claude-history)
    - [Implementation Details / Q&A](#implementation-details--qa)
    - [Current Testing State](#current-testing-state)
    - [Rejected Approaches](#rejected-approaches)
    - [Sample Send Message Calls](#sample-send-message-calls)
    - [Implement A New Agent Provider](#implement-a-new-agent-provider)
- [Additional Notes / Discussions](#additional-notes--discussions)
    - [Ways to Drive an Xcode Chat](#ways-to-drive-an-xcode-chat)
        - [Running From Terminal?](#running-from-terminal)
        - [Accessibility (UI scripting) details](#accessibility-ui-scripting-details)

## Apps

### Download

- MacOS: [GitHub Release](https://github.com/0Itsuki0/XcodeAgentRemote/releases)
- iOS: Under review

Matching version: MacOS 1.0.0 + iOS 1.0.0

### Permissions Required

**MacOS**

| Permission | Why it is needed |
| --- | --- |
| Automation: Apple Events to Xcode (`AUTOMATION_APPLE_EVENTS`, `NSAppleEventsUsageDescription`) | to close the project's window in Xcode with AppleScript (`XcodeAutomation.closeProject`). Asked the first time, while Xcode is running (`XcodeAutomation.automationPermission`). A denied permission can only be changed in System Settings → Privacy & Security → Automation |

**iOS**

| Permission | Why it is needed |
| --- | --- |
| Notifications: alert, sound, badge (`requestAuthorization`) | to show a watched conversation's change as a notification and badge (asked in `NotificationSettingView`) |


### Requirements
- A Mac with Xcode 27.2 or later, with Xcode's coding agent set up and signed in
- A way to expose local endpoint to https to be connected from iOS
    - personally prefer ngrok. [ngrok supports Static dev domains for all users](https://ngrok.com/blog/free-static-domains-ngrok-users)
- Sign in to the same Apple ID / iCloud account on the Mac and the iPhone (only needed for notifications)

### Set up

**MacOS**
1. Open the Mac app. Under "App Server", configure the port, optionally authorization, and start the server.
2. Start a tunnel of your choice to expose local endpoint to https.
    - if using ngrok, you can also start it directly from the app given that you have `ngrok` cli installed and signed in, as well as obtained a URL for forwarding.
3. Under "Permission" tab, grant permission for Apple Event (Automation). It only uses this to close the
project's window before it sends a message. For more details, refer to the [Why not keep Xcode open section](#why-not-keep-xcode-open).
4. Optionally under "Chat Watcher" tab, watch specific conversations to receive real time push notifications on iOS when conversation updates (new messages, permission requests, and etc.).

**iOS**
1. Open "Settings" > "Server".
2. Enter the same https URL exposed by the tunnel. If you have set an Authorization header, enter the same header name and value as well.
3. Optionally test the connection with "Test connection", and then "Save configuration".
4. Under "Push Notification", grant permission to push notification if you want to receive real time notifications on watched conversations.


### Things to try on iOS
- Open a conversation to see its history
- Send a message and watch the reply stream in
- Ask the agent to do something that needs permission (for example, "create a file named test.txt")
and approve or deny it from the phone
- Ask the agent to enter the plan mode and approval / decline the plan
- Ask the agent to ask questions and answer the question from the phone
- Watch a conversation, allow notifications, and get a notification when there is a new message from assistant
- Open the conversation in Xcode to confirm all the interactions above are available from the Xcode UI as well

### Agent Support

| Agent | Support State |
| --- | --- |
| claude (claude code) | ✅ |
| codex | Working! |
| antigravity | Probably never |
| copilot | Probably never |

### Demo Video

https://github.com/user-attachments/assets/9c97d557-b1a3-4884-b324-e8c0c2df6a86

## Basic Idea / Approach

1. Local server to receive request from IOS (ping, list projects, get conversation, send message and stream response)
    - no unified server to avoid unnecessary hosting on itsuki's side which includes cloud hosting, authorization, database and etc.
    - each user is responsible for starting their own tunnel, for example, with ngrok. ([ngrok supports Static dev domains for all users](https://ngrok.com/blog/free-static-domains-ngrok-users))
    local server started from the mac app instead of a unified server
    - not using iCloud/CloudKit sync because this needs real time instead of just on a best-effort base, also to avoid overflowing user's iCloud storage.
2. Run Xcode Agent Programmatically to process the message and get response
    - close the Xcode project (AppleScript) before running the agent: Xcode keeps the project's chats in memory and would write over the turns the app records ([Why not keep Xcode open](#why-not-keep-xcode-open))
3. Send Push notification with CloudKit on watched conversations to notify iOS changes on (almost) real time.
    - using CloudKit to avoid hosting a unified server for all users or bundling itsuki's own developer certificate within the app


## Run Xcode Agent Programmatically

### Basic Idea

- use `xcrun mcpbridge run-agent <agent>`
    - Xcode's bundled binary, config dir, Xcode MCP tools.
    - `+` the flags Xcode adds: stream-json, Xcode's system prompt (from its template inside Xcode), Xcode's skills plugin, allowed tools
    - permission mode follows Xcode's Manual / Auto setting (`IDEChatAgentPermissionMode` in Xcode's preferences: `standard` = Manual, `auto` = Auto), can be overridden per message
    - Each call to `xcrun mcpbridge run-agent` is single turn only. If the agent asks for user interaction (choices, permission requests), the turn wait until timeout
- write the turn into Xcode's chat files, in Xcode's own format
    - `conversation.plist`, `metadata.plist`, `CodingAssistantManifest.plist`, `Snapshots/`
    - needed so that the user can later continue the chat within xcode
- when display chat history within the app, use provider specific chat history.
    - Xcode's chat files are only what Xcode displays. It is not necessarily the full history. It contains unnecessary styling / UI
- Before sending a message from the app, close xcode programmatically (with apple script) for the corresponding project.
    - This is needed to avoid doubled tool use, chat history overwrite. In addition, the entries we wrote into the Xcode's chat files needs a reopen on the project to load. (Xcode only read those when open a specific project. After that, it only writes to the file, but read from the session memory/cache.)

### `xcrun` Command

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

### Important File locations
- Agent Configuration:  `~/Library/Developer/Xcode/CodingAssistant/`
    - Xcode's agent binary (what `xcrun mcpbridge run-agent claude` runs): `Agents/XcodeVersions/<Xcode build>/claude/claude`
    - per agent process, temporary: `$TMPDIR/mcp-config-<UUID>.json` (`--mcp-config`), `$TMPDIR/com.apple.dt.IDEIntelligenceAgents/plugins/<Xcode build>/xcode-integration/` (`--plugin-dir`)
- Chat data (xcode copy): `~/Library/Developer/Xcode/UserData/CodingAssistant`, one folder per project: `<Project>-<hash>/`
    - `CodingAssistantManifest.plist`: the project's chats (a folder with it is a project's store)
    - `CodingAssistantNavigator.plist`: the chat list Xcode shows
    - `<chat UUID>/conversation.plist`: turns, their cards, `assistantConfiguration`
    - `<chat UUID>/metadata.plist`: name, dates, provider
    - `Snapshots/<UUID>.plist`: git state before / after each turn
- chat data (provider bundled by xcode)
    - claude session history: `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects`, stored as `.jsonl` files.
    - The link: `CodingAssistant/projectName/<conversation_id>/conversation.plist` has a binary field: `assistantConfiguration`. Decoded, it contains: `{"agent":{"_0":{"sessionID":"2a561bc4-7ab8-4561-a88f-69e6a53ca073"}}}` where the `sessionID` is that under provider session history's `projects/projectName/sessionId`.
    - `conversation_id` is xcode's own id. has nothing to do with `sessionId`.
- Xcode's system prompt addition (template): `$(xcode-select -p)/../PlugIns/IDEIntelligenceChat.framework/Resources/AgentSystemPromptAddition.idechatprompttemplate`
- Xcode's permission settings (global, Settings → Intelligence; read by `XcodeChat/Permission.swift` on every check): `~/Library/Group Containers/group.com.apple.dt.Xcode.SecureSettingsContainer/CodingAssistant/AgentToolPermissionSettings/`
    - `permissions.json`: `toolRules` (Allowed Tools), `shellCommandRules` (Allowed Commands), `pathRules` (files and folders), `grantCommonLocations`, `dangerouslyAllowAllShellCommands`, `automaticallyManageCommands`, `pathRulesApplyTo`, `removedDefaultCommands`, `removedDefaultPaths`
    - `supervisor-settings.json`: `{"enabled": true}` = Control File & Folder Access on
    - `toolPermissions.json`: older format, no longer updated by Xcode (not read)
- Xcode's permission mode: defaults `com.apple.dt.Xcode`, key `IDEChatAgentPermissionMode` (`standard` = Manual, `auto`, `dontAsk`, `bypassPermissions`)
- Xcode's file access supervisor (Endpoint Security client, asks / refuses when the agent opens a file): `/Applications/Xcode-beta.app/Contents/Developer/usr/libexec/agentfileaccesssupervisor`, preferences domain `com.apple.dt.CodeIntelligence.agentfileaccesssupervisor`
- Xcode's permission decisions in the unified log (values `<private>`): process `Xcode`, subsystem `com.apple.IDEIntelligenceChat` (`AgentToolUseCallbackDelegate`: "approved" / "requesting permission", rule specificity), and process `agentfileaccesssupervisor` ("Authorization Request" / "Authorization resolved"). e.g. `log stream --level debug --style compact --predicate 'process == "Xcode" OR process == "agentfileaccesssupervisor"'`


### Sample Jsonl (Claude history)

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

- the app quit (the agent's stdin closed) while the agent waited for the answer: the agent settles the request itself, as a deny

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "Tool permission request failed: AbortError: Tool permission stream closed before response received", "is_error": true, "tool_use_id": "toolu_01GQfvogsBJcmrikmsxe15EV"}]}, "toolUseResult": "Error: Tool permission request failed: AbortError: Tool permission stream closed before response received", "permissionDecision": {"decision": "reject", "source": "config", "reasonType": "other"}, "toolDenialKind": "permission-rule"}
```

#### Who decided: `permissionDecision`

- on the result's line, next to `toolUseResult`. `"toolDenialKind": "permission-rule"` with a reject
    - `user_temporary` / `user_reject`: the user, through the app (`can_use_tool`). what counts as a request the user answered (`ClaudeProvider.userRequest`)
        - except the app's own timeout deny: `user_reject` with `No answer to this …`. it was asked but not answered: a request with no response (the history shows `user_request`, then its `tool_result`, as the live turn streams it)
    - `hook`: Xcode's PreToolUse hook. the same whether Xcode asked the user or allowed it by its rules
        - except a deny the user clicked in Xcode's prompt: a reject with `PreToolUse:<tool> hook error: User selected: Don’t Allow`. that is the user's deny (`user_request`, then `user_response` with no message: the text is Xcode's). Xcode's other rejects (its rules, or its prompt failing, e.g. `Error requesting permission: … CancellationError`) are not
        - an Allow clicked in Xcode's prompt can't be told apart: an allow's result is the tool's output, and Xcode writes the same `accept` / `hook` for what its rules allow
    - `config`: the agent itself, without asking (`--allowedTools`, its own rules), or settled by itself (the stream closed, above)

```json
{"type": "user", "message": {"role": "user", "content": [{"tool_use_id": "toolu_01XM4UtqUgebxvwvh7TqFB5G", "type": "tool_result", "content": "(Bash completed with no output)", "is_error": false}]}, "toolUseResult": {"stdout": "", "stderr": "", "interrupted": false, "isImage": false, "noOutputExpected": true}, "permissionDecision": {"decision": "accept", "source": "user_temporary"}}
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "The user denied this tool use.", "is_error": true, "tool_use_id": "toolu_0197KBua14T4ZmrjtkE4CBtp"}]}, "toolUseResult": "Error: The user denied this tool use.", "permissionDecision": {"decision": "reject", "source": "user_reject"}, "toolDenialKind": "permission-rule"}
{"type": "user", "message": {"role": "user", "content": [{"tool_use_id": "toolu_01BpaaNc4vmBEKhkCj28gShv", "type": "tool_result", "content": "(Bash completed with no output)", "is_error": false}]}, "permissionDecision": {"decision": "accept", "source": "hook", "reasonType": "hook"}}
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_01Pj4HDDtk6THJGSfNcLNfvK", "content": [{"type": "tool_reference", "tool_name": "EnterPlanMode"}, {"type": "tool_reference", "tool_name": "ExitPlanMode"}]}]}, "toolUseResult": {"matches": ["EnterPlanMode", "ExitPlanMode"], "query": "select:EnterPlanMode,ExitPlanMode", "total_deferred_tools": 124}, "permissionDecision": {"decision": "accept", "source": "config", "reasonType": "rule"}}
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

- without `plan`: the agent may write the plan file (`Write` to `ClaudeAgentConfig/plans/<name>.md`) in the same message as `ExitPlanMode`. Claude fills `plan` in from that file when it writes the tool use; if the file isn't written yet, the tool use has no `plan` (seen 3 times in 88 calls). the permission request (`can_use_tool`) still has it, with `planFilePath`; the result line's `toolUseResult.plan` too

```json
{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_0128WXcMvNn9bNx6A8sPbsUv", "name": "ExitPlanMode", "input": {}, "caller": {"type": "direct"}}]}}
{"type": "control_request", "request_id": "…", "request": {"subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": {"plan": "# Plan\n\n…", "planFilePath": "/Users/itsuki/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/plans/abstract-percolating-meadow.md"}, "tool_use_id": "toolu_…"}}
```

- approved, rejected with feedback

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "User has approved your plan. You can now start coding. Start with updating your todo list …", "tool_use_id": "toolu_0175xuriiSDtDrK73TPskQw3"}]}, "toolUseResult": {"plan": "# Plan\n\n…", "isAgent": false, "filePath": "/Users/itsuki/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/plans/synthetic-gr…"}}
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "Run `echo second` instead.", "is_error": true, "tool_use_id": "toolu_01GvXVmcsLfYGcdv56xbLSo3"}]}, "toolUseResult": "Error: Run `echo second` instead."}
```

#### Stopped (Xcode's chat, the project closed)

- closed by the app (AppleScript): Xcode doesn't notice, the tool is killed: a plain error result
    - the same result as a command that was killed for another reason; the app removes it only right after it closed the project for that tool use (`removeStoppedResult`)

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "Exit code 137", "is_error": true, "tool_use_id": "toolu_01RJvSxtJJVZB21SrHjYowaw"}]}, "toolUseResult": "Error: Exit code 137", "permissionDecision": {"decision": "accept", "source": "hook", "reasonType": "hook"}}
```

- closed by the user (the close button): Xcode notices: a "rejected" result, then the interrupted text

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.", "is_error": true, "tool_use_id": "toolu_01AJGSJBsHVuSidRJ9vRyZiM"}]}, "toolUseResult": "User rejected tool use", "toolDenialKind": "user-rejected"}
{"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user for tool use]"}]}}
```

- closed by the app (AppleScript) while Xcode's prompt was still open (the tool never started): a "cancelled" result, no `permissionDecision`

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "The user doesn't want to take this action right now. STOP what you are doing and wait for the user to tell you how to proceed.", "is_error": true, "tool_use_id": "toolu_01VshYyvL6Tn5vEhNBYLpRjN"}]}, "toolUseResult": "The user doesn't want to take this action right now. STOP what you are doing and wait for the user to tell you how to proceed.", "toolDenialKind": "cancelled"}
```

#### Interrupted

- the agent stopped while a tool was running (or waiting for its permission). nothing is written then
- the next time the session is resumed, Claude adds this result for the tool use that has none

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "[Tool call interrupted: the session ended before this call's result was recorded, so its outcome is unknown. Check whether it took effect before relying on it or running it again.]", "is_error": true, "tool_use_id": "toolu_018pckhASC7nCM9urwCcsrhm"}]}, "toolUseResult": "[Tool call interrupted: the session ended before this call's result was recorded, so its outcome is unknown. Check whether it took effect before relying on it or running it again.]"}
```

- and, before the new prompt, an assistant message it didn't get from the model

```json
{"type": "assistant", "message": {"role": "assistant", "model": "<synthetic>", "content": [{"type": "text", "text": "No response requested."}]}}
```

#### Permission request / response (stream-json, not in the file)

- us → agent (stdin), first: `initialize`, registering the pass-through PreToolUse hook (the agent answers with a `control_response` for `"request_id": "initialize"`: its commands, models, …)

```json
{"type": "control_request", "request_id": "initialize", "request": {"subtype": "initialize", "hooks": {"PreToolUse": [{"matcher": null, "hookCallbackIds": ["pre_tool_use"]}]}}}
```

- agent → us (stdout), before every tool use: the hook. we answer no decision (`{}`), so the agent's own permission check decides (next)

```json
{"type": "control_request", "request_id": "b135a5b2-b7f6-45cc-b6b7-e8084ef396ae", "request": {"subtype": "hook_callback", "callback_id": "pre_tool_use", "input": {"session_id": "62cf1b6e-f502-40b4-8cdb-9acd80ad723b", "transcript_path": "…/ClaudeAgentConfig/projects/<project>/62cf1b6e-f502-40b4-8cdb-9acd80ad723b.jsonl", "cwd": "…", "prompt_id": "bbbda525-97fd-4cfd-9d29-f0ae279b73c0", "permission_mode": "default", "effort": {"level": "medium"}, "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "touch /tmp/hookcap-test", "description": "Create empty test file"}, "tool_use_id": "toolu_01JdVv6wD5EitjiQ8BMNyDAR"}, "tool_use_id": "toolu_01JdVv6wD5EitjiQ8BMNyDAR"}}
{"type": "control_response", "response": {"subtype": "success", "request_id": "b135a5b2-b7f6-45cc-b6b7-e8084ef396ae", "response": {}}}
```

- agent → us (stdout), when it asks the user: for a permission, a question or a plan alike

```json
{"type": "control_request", "request_id": "15b24acf-5440-4596-933d-3465d5aaf634", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "display_name": "Bash", "input": {"command": "touch /tmp/control-capture-test", "description": "Create empty test file in /tmp"}, "description": "Create empty test file in /tmp", "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "touch /tmp/control-capture-test"}], "behavior": "allow", "destination": "localSettings"}, {"type": "addDirectories", "directories": ["/tmp"], "destination": "session"}, {"type": "setMode", "mode": "acceptEdits", "destination": "session"}], "blocked_path": "/tmp/control-capture-test", "tool_use_id": "toolu_01E8c6u8Qdr7aZDcqQoJwtfV"}}
```

- us → agent (stdin)
    - deny: `{"behavior": "deny", "message": …}` (also: declining questions, rejecting a plan with its feedback)
    - allow: `{"behavior": "allow", "updatedInput": <the tool's input>}` (also: approving a plan)
    - questions: allow, with the input plus `"answers": {"<question>": "<label>, <label>"}`

```json
{"type": "control_response", "response": {"subtype": "success", "request_id": "15b24acf-5440-4596-933d-3465d5aaf634", "response": {"behavior": "deny", "message": "The user denied this tool use."}}}
{"type": "control_response", "response": {"subtype": "success", "request_id": "<request_id>", "response": {"behavior": "allow", "updatedInput": {"command": "touch /tmp/control-capture-test", "description": "Create empty test file in /tmp"}}}}
{"type": "control_response", "response": {"subtype": "success", "request_id": "<request_id>", "response": {"behavior": "allow", "updatedInput": {"questions": [{"question": "Which colors do you like?", "header": "Colors", "multiSelect": true, "options": […]}], "answers": {"Which colors do you like?": "Red, Blue"}}}}}
```


### Implementation Details / Q&A

#### How to determine whether there is a pending user request

A user request (permission request, choices) shows up as tool user, whether it is initiated by the app or Xcode.
We need to tell it apart from other tool user so that we can have the user to answer to those requests.

##### If initiated by THIS App

**Claude specific**

- the agent asks the user with Claude's built in permission prompt (`can_use_tool`), for a permission, questions (`AskUserQuestion`) and a plan (`ExitPlanMode`) alike
- a *pass through* `PreToolUse` hook is registered (answers no decision, Claude still decides what to ask): with it, Claude writes the tool use to the `.jsonl` before the answer
    - The write happens shortly after it asks, not at the same moment.
        - If `claude` is terminated, for example, due to a crash or a test's pkill, within a second of the request, the tool use is lost, aka: no entry is written to `.jsonl`.
    - without any `PreToolUse` hook, the tool use is only written after the answer
- when the agent asks, the app marks the tool use waiting (in memory while the app runs, per agent: `[agent: [tool use id]]`). removed once the answer arrives or the tool use has a result
- a tool use is a request **initiated by THIS App** when all three are `true` (Logic: `ClaudeProvider.userRequest`)
    - it has a result decided by the user: `permissionDecision.source` `user_temporary` (allowed / answered / approved) or `user_reject` (denied / declined / rejected; `No answer to this …` is the app's timeout: still a request, but no response)
    - it has no result yet, and it is a question or a plan
    - it has no result yet, it is marked, and it is the session's last message (else the mark is stale)
- `POST /conversations` / `POST /conversations/<id>/messages`:  the request is a `user_request` event, and the stream ends there.
- `GET /conversations/<id>`: the conversation's `history` has the same event
- the app quitting (or the turn being stopped) is not a pending request: the agent sees its stdin close, settles the request itself (`Tool permission request failed: … stream closed …`), finishes the turn
- the agent terminated while waiting is: the tool use stays without a result. If the user answers the request, the app resumes the chat with the answer as the prompt:
      1. the agent writes these entries to `.jsonl`, in order, before the model replies
          1. the `[Tool call interrupted …]` result for the old tool use, which had none
          2. the synthetic `No response requested.` assistant message
          3. the user's answer (the resume prompt), e.g. `Allowed: you may run the Bash call you asked permission for.`
      2. the agent repeats the tool call (its reply to the answer)
      3. the app checks whether it is the same call (logically) as the old one. if it is, and the answer is not a deny, the app answers it automatically, and once the turn ends removes the old tool use and its interrupted result: only the repeat remains
      4. if the agent didn't repeat the call (a deny, or a question / plan whose answer the prompt already gives): once the turn ends, the app removes the interrupted result and `No response requested.`, and makes the resume prompt the old tool use's result (`replaceResumeInterruption`): the user's answer, as a live turn records it (`permissionDecision` `accept` / `user_temporary` or `reject` / `user_reject`, a question's answers in `toolUseResult.answers`; a deny / decline / rejection's result is the user's message or the default text). only the prompt right after those two lines (its `parentUuid`), so the result directly follows the tool use. the history then reads like a live turn: the request, the answer, the reply

##### If initiated by Xcode

**Facts**

- Xcode asks with its own `PreToolUse` hook (a callback it registers when it starts the agent, not in any config file. it does not use provider's built in permission prompt claude's such as `can_use_tool`).
    - not every tool asks. based on permission setting and mode (manual vs auto).
    - the hook is a callback of Xcode's process: only Xcode can answer it
- the waiting tool use is in the `.jsonl`, with no result (because there is a `PreToolUse` hook from Xcode, like the one we added above)
- We **cannot** distinguish *a tool that is running* from `a tool waiting for permission` using the following.
    - `.jsonl`: both end with a tool use, no result
        ```json
        {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_012i2BhvPb5GLqqzncFXcaWD", "name": "Bash", "input": {"command": "touch /tmp/xcode-hook-order-test", "description": "Create empty test file in /tmp"}, "caller": {"type": "direct"}}]}}
        ```
    - `conversation.plist`: both has a turn without `finishedDate`, no card UI for neither
    - `Snapshots/`. It only snapshot at the start and the end of a turn
- We **COULD** distinguish *a tool that is running* from `a tool waiting for permission` with Xcode's agent debug log (`--debug-file`). It records: `tool_dispatch_start … toolUseId=<id>` once a tool runs, nothing for a tool use waiting for the user.
    - problem: undocumented format, temporary file per agent process
- answering it from the app (with `xcrun`) doesn't run the tool.
    - the agent gives it the `[Tool call interrupted …]` result, and makes the same tool use again as a new request. (same phenomenon as the *agent terminated while waiting* above)
- If we answered in Xcode's prompt (allowed or denied)
    - `.jsonl`: the tool result's line has `"permissionDecision": {"decision": "accept" | "reject", "source": "hook", "reasonType": "hook"}` (+ `"toolDenialKind": "permission-rule"` for a deny). a deny's result is `PreToolUse:<tool> hook error: User selected: Don’t Allow`
    ```json
    {"type": "user", "message": {"role": "user", "content": [{"tool_use_id": "toolu_01BpaaNc4vmBEKhkCj28gShv", "type": "tool_result", "content": "(Bash completed with no output)", "is_error": false}]}, "permissionDecision": {"decision": "accept", "source": "hook", "reasonType": "hook"}}
    ```
- Tool call allowed by Xcode without asking (e.g. ToolSearch, WebFetch)
    - `.jsonl`: the same `"permissionDecision": {"decision": "accept", "source": "hook", "reasonType": "hook"}`
    - so from the `.jsonl`, "Xcode asked the user and the user allowed" and "Xcode allowed it by itself" look the same


**General Approach**

- every turn the app runs (`sendMessage`, and resuming a chat to answer a request) first closes the project in Xcode (`XcodeAutomation.closeProject`): once the user answers through the app, Xcode can no longer answer it, and its agent stops
- a tool use of Xcode's chat is a request when it is the last message with no result, no mark (Xcode's agent never sets one), and
    - it is a question (AskUserQuestion) or a plan (ExitPlanMode), or
    - Xcode would ask the user about it: `PermissionRule.wouldAsk` (`XcodeChat/Permission.swift`) makes Xcode's own decision from Xcode's settings, read fresh on every check
        - mode (`IDEChatAgentPermissionMode`): Manual → decided as below. Auto → the agent decides, counted as asking. dontAsk / bypassPermissions → never asks
        - tools: allowed by name, by the tools Xcode passes the agent (`--allowedTools`) or `toolRules`
        - Bash: split into simple commands (pipelines, `&&`, `;`, subshells, `$(…)` also inside assignments and redirects, `find -exec`). every one needs an `allow` rule (`shellCommandRules`): exact command name, the rule's other words in order with only options between them, leading `VAR=value` ignored, the longest matching pattern decides
        - files (Control File & Folder Access on): a Read / Write / Edit file outside the project folder, checked with `pathRules` (longest path wins): no rule → asks, `read` → writing asks, `write` → no ask, `deny` / `readDenyWrite` → refused without asking
        - anything it can't decide (missing settings, a command it can't parse) counts as asking
- the user answers through the app: the project is closed, then the `.jsonl` is read again
    - the tool use still has no result (it was waiting): the chat is resumed with the answer, the same as an agent killed while waiting. if the agent repeats the call, it is answered without asking, and the old tool use is removed. if it doesn't, the resume's interrupted result and `No response requested.` are removed and the answer becomes the old tool use's result
    - it now has the result of a stop (closing the project stopped it): that result is removed, and it continues like the no-result case. only these results are removed (`removeStoppedResult`); a result the tool produced itself (it finished before the close) stays, so it doesn't run again
        - by the app (AppleScript), while the tool ran: Xcode doesn't notice, the tool is killed: a plain error result `Exit code 137` (`permissionDecision.source` `hook`)
        - by the app (AppleScript), while Xcode's prompt was still open: `The user doesn't want to take this action right now …` (`"toolDenialKind": "cancelled"`)
        - by the user (the close button): Xcode notices: the `The tool use was rejected …` result (`"toolDenialKind": "user-rejected"`) and `[Request interrupted by user for tool use]` after it
    - a real deny is never removed: every deny has `"toolDenialKind": "permission-rule"` and a `reject` `permissionDecision`. no stop result has either: `cancelled` and `user-rejected` have no `permissionDecision`, and `Exit code 137` has an `accept` one with no `toolDenialKind`

| What happened | `toolDenialKind` | `permissionDecision` | Result | Removed |
|---|---|---|---|---|
| denied through the app's API | `permission-rule` | `reject` / `user_reject` | the user's message, or `The user denied this tool use.` | no |
| questions declined through the API | `permission-rule` | `reject` / `user_reject` | `The user declined to answer.` | no |
| plan rejected through the API | `permission-rule` | `reject` / `user_reject` | the feedback | no |
| no answer in time (the app's timeout) | `permission-rule` | `reject` / `user_reject` | `No answer to this request within … seconds.` | no |
| denied in Xcode's prompt | `permission-rule` | `reject` / `hook` | `PreToolUse:<tool> hook error: User selected: Don’t Allow` | no |
| closed by the app while the tool ran | none | `accept` / `hook` | `Exit code 137` | yes |
| closed by the app while Xcode's prompt was open | `cancelled` | none | `The user doesn't want to take this action right now …` | yes |
| Xcode's close / stop button | `user-rejected` | none | `The user doesn't want to proceed with this tool use …` | yes |


**Why it works (scenario by scenario)**

- Xcode waits on its prompt, the user answers in the app: closing Xcode while it waits leaves no result, or the `cancelled` result, which is removed (both seen). the resume gives the agent the answer, it repeats the call, the call runs (or is denied) with that answer
- Xcode allowed it by itself and the check agrees: it is not shown as a request, the user never answers it, so Xcode is never closed and nothing is interrupted
- the check says Xcode asks, but Xcode allowed it (it was running): when the user answers, closing the project kills it and its agent writes `Exit code 137` as the result (tested). that is removed and the call runs again with the user's answer. cost: the part that already ran runs a second time
- the check says Xcode doesn't ask, but it did: shown as running, the request never reaches the app; it can only be answered in Xcode. known cases
    - a Bash command allowed by its rules that opens a file without access (the file supervisor asks; which files a command opens isn't in its input)
    - a setting changed while that chat was open (Xcode read its settings when the chat's agent started)
- answered in Xcode first: the tool use has a result, so it is no longer a request; the app's answer gets `noWaitingRequest`
- a question or a plan: always a request, whatever the settings
- the check was matched against what Xcode did on 23 Bash commands and 4 other tool uses (Write in a read-only folder, Write and Edit in `/tmp`, ToolSearch): all the same

**Why not use hooks for permission request / response received**

- `PreToolCall` conflicts with Xcode registered ones (Xcode registered hook invoke after any ones set in `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json`)
- hard (if no impossible) to control which chat to watch
- have to inject for both Xcode-started sessions as well as every single message THIS app send.


#### Different Permission request logic: Xcode Hook vs agent build in

Xcode uses its own `PreToolUse` hook for permission request.
We are using agent's built-in, in the case of claude, `--permission-prompt-tool stdio` + `can_use_tool` requests
Why are we not using it to reproduce what Xcode does? Does it matter?

- Xcode hook is not in Xcode's plugin (`--plugin-dir` has skills and `.mcp.json`, no hooks), aka: `xcrun mcpbridge run-agent <agent>` does not see it.
- what the user does / sees is the same: asked, allowed runs, denied doesn't, the agent is told it was denied
    - only the denial text differs (it ends up in the denied card's output, and the agent may word its reply differently)
- Xcode doesn't read the actual history from each agent, but only its own copy (`conversation.plist`)
    - we can create the card UI the same either way: a denied tool keeps its card with `status: cancelled` (the "!")


#### Why not keep Xcode open

**Xcode use in memory cache for chat**

Evidence:
- Open the xcode and send some message
- resume the same conversation by sending a message from THIS app's `sendMessage` function
    - `conversation.plist`: 15 turns, the last one is the turn from THIS app
    - Xcode UI is not updated to include the new turn
- send a new message from xcode UI without reopen xcode, for example, "repeat the last message"
    - the **agent** (not Xcode, not xcode UI, but the provider side such as claude, codex) will repeat the message we sent from the app (turn 15) → agent knew the message we sent from THIS app (turn 15) as the agent reads its own session history, In the case of claude, claude reads its own `jsonl`.
- `conversation.plist` after we send a new message from xcode UI
    - still 15 turns: the turn we sent from the app is gone, replaced by the one from Xcode UI
    - Conclusion: Xcode saved what it had in memory, without reading the file first

**Xcode can't be made to reload the chat while it remains open**
- nothing watches the chat files, no refresh button, switching tabs does nothing

What that means for us:
- close the project before we call the app's `sendMessage` function to avoid
    - loosing the turns send from the app
    - avoid the user from answering the same permission request / choices twice.


### Current Testing State

#### Confirmed

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
    - `/health`, `/projects`, `/conversations`
    - message → permission request → answer → … : each response ends where the turn waits for an answer, the answer's response continues the turn
    - allow and deny, the denied tool doesn't run

#### Not Confirmed

- `isModification`: Xcode said false for a turn whose Write went outside the project (`/tmp`). the port says true
- tools never seen in Xcode: Xcode MCP tools (BuildProject…), TaskUpdate / TaskList, NotebookEdit, a failed Bash (non zero exit). they get the generic card, a guess
- each card format is from one Xcode example
- the agent itself failing: the turn should be saved, then the error sent
- chats written by the port, opened in Xcode (after reopening the project)
- the iOS app itself (only its client code was run, on the Mac)
- an event containing U+2028 on the iOS client (it splits lines on it)
- a turn whose permission request is never answered: its saved stream is never cleaned up


### Rejected Approaches

- drive Xcode's chat UI with Accessibility
    - typing into the chat input does work, but it is still rejected: [Control Xcode with Accessibility API](#control-xcode-with-accessibility-api)
- call into Xcode itself (the private method that sends a message)
    - needs SIP or library validation turned off. not something every Mac can do

#### Control Xcode with Accessibility API

Typing a prompt into Xcode's chat window with the Accessibility API works: find the chat, click the input, paste, Submit (how, tree, constraints, script: [Accessibility (UI scripting) details](#accessibility-ui-scripting-details)).
Still not used, neither to send messages nor to answer Xcode's own requests.

**What it would give**

- Xcode runs the chat itself: no need to write the turn into Xcode's chat files (`conversation.plist`, `metadata.plist`, `CodingAssistantManifest.plist`, `Snapshots/`), no need to modify the provider's history (Claude's `.jsonl`)
- no need to close the project before a turn

**Why not: sending a message**

- foreground only
    - the input can only be focused by a real click, the click and ⌘V go to the frontmost app. Xcode must be frontmost, with the project window open, on the current Space (on another Space, Xcode reports 0 windows)
    - one chat at a time: several chats at once (easily happens with several remote clients) means taking turns on the one foreground window
    - the Mac can't be used while being controlled
    - a locked or sleeping Mac: synthetic clicks and keys don't reach Xcode. that is the normal state of a Mac in real remote use
- no way to stream the response
    - no stdout: the agent is Xcode's process, not the app's
    - polling the window: only the chat in the foreground is in the tree, so that chat has to stay in the foreground for the whole turn, and when the turn ends is hard to tell from the UI
    - watching the session file (`.jsonl`): when the turn **actually** ends isn't known, and passing the changes from a file watcher to the API's open stream is messy
    - with `xcrun mcpbridge run-agent`: stream-json gives every event and the exact end of the turn (`result`)
- breaks if Apple changes the chat UI (found on a beta build, Xcode 27C5020n). the chat files can change too, but that can be checked and tested
- can't be mixed with the `xcrun` approach for the same project: Accessibility needs the project open, `xcrun` needs it closed ([Why not keep Xcode open](#why-not-keep-xcode-open))

**Why not: answering a request initiated by Xcode**

The idea: keep deciding whether it is Xcode's request as today ([If initiated by Xcode](#if-initiated-by-xcode)), but answer with Xcode's own Yes / No buttons instead of closing the project and resuming the chat. No close, no `Exit code 137` / `cancelled` / `user-rejected` cleanup, no repeat, nothing runs twice.

- no guarantee the chat is the one in the foreground: only the visible chat is in the tree
- several chats can be waiting for a permission at the same time: each has to be brought to the foreground, one by one
- pressing Yes / No in the background (`AXPress`) wouldn't help: getting to the chat (window, tab) already needs the foreground
- no response after answering: Xcode's agent continues the turn, the app gets no stream of it, and the same problems as above (no stdout, turn end unknown from the `.jsonl`)

**Conclusion**

- keep `xcrun mcpbridge run-agent` + writing Xcode's chat files, for every turn
- keep answering Xcode's requests by closing the project and resuming the chat

### Sample Send Message Calls

Calls to the server (JSON body, SSE response), from one chat: `POST /conversations` starts it (with the id the client chose, and its first prompt), `POST /conversations/<id>/messages` takes its next prompts and the answers to its requests.

- every response is `HTTP 200 text/event-stream`: `event: <type>` + `data: <ChatEvent JSON>` per event
- the prompt is not echoed back: the caller has it
- a response ends where the turn waits for the user (its last event is a `user_request`), or where the turn ends
- the answer to that request is a `POST /conversations/<id>/messages`, and its response continues the same turn (also in a chat's first turn: the client has its id). the answer is not echoed back either (the client keeps it, as `user_response` in its history)
    - an allowed permission: the tool's own `tool_result` comes next
    - anything else (a deny, answered questions, a plan): no `tool_result` (its result is the answer itself)
- `project` is a file URL. in Swift: `sendMessage(_:to:…)` / `answerUserRequest(_:)` on the Mac, `APIServerClient.startConversation` / `.sendMessage` / `.answer` on iOS

#### Regular message (new chat)

```
POST /conversations
{"id":"7F58BC9E-9D95-4896-9FF2-F857662167F9","project":"file:\/\/\/Users\/itsuki\/Desktop\/XcodeAgentRemote\/XcodeAgentRemote.xcodeproj","agent":"claude","name":"Sample calls","prompt":"Reply with only the word pong.","permissionModeOverride":"manual"}

event: assistant_message
data: {"text":"pong","type":"assistant_message"}
```

- `id`: chosen by the client, a UUID in any case. before the stream: 400 not a UUID, 409 already a chat's, 404 no such project, 501 agent not implemented
- optional: `"name"` (default: the start of the prompt), `"permissionModeOverride": "manual" | "auto"`, `"permissionTimeout": <seconds>` (default 600). the same two in a `prompt` to `/conversations/<id>/messages`

#### Tool call → approve

```
POST /conversations/7F58BC9E-9D95-4896-9FF2-F857662167F9/messages
{"prompt":{"permissionModeOverride":"manual","prompt":"Use the Bash tool to run: touch /tmp/sample-calls-allowed. Then reply DONE."}}

event: tool_use
data: {"input":{"command":"touch \/tmp\/sample-calls-allowed","description":"Create empty marker file in \/tmp"},"name":"Bash","type":"tool_use","id":"toolu_019JRJBSVPfCxjfE8nZBjypA"}

event: user_request
data: {"type":"user_request","request":{"permission":{"_0":{"input":{"command":"touch \/tmp\/sample-calls-allowed","description":"Create empty marker file in \/tmp"},"id":"toolu_019JRJBSVPfCxjfE8nZBjypA","name":"Bash"}}}}
```

```
POST /conversations/7F58BC9E-9D95-4896-9FF2-F857662167F9/messages
{"answer":{"_0":{"permission":{"allow":true,"toolUseID":"toolu_019JRJBSVPfCxjfE8nZBjypA"}}}}

event: tool_result
data: {"is_error":false,"output":"(Bash completed with no output)","type":"tool_result","tool_use_id":"toolu_019JRJBSVPfCxjfE8nZBjypA"}

event: assistant_message
data: {"type":"assistant_message","text":"DONE"}
```

#### Question → choice

```
POST /conversations/7F58BC9E-9D95-4896-9FF2-F857662167F9/messages
{"prompt":{"permissionModeOverride":"manual","prompt":"Use the AskUserQuestion tool to ask me which color I prefer, with exactly these options: Red, Green, Blue. Then reply with only the color I chose."}}

event: tool_use
data: {"name":"AskUserQuestion","input":{"questions":[{"header":"Color","options":[{"label":"Red","description":"The color red"},{"label":"Green","description":"The color green"},{"label":"Blue","description":"The color blue"}],"question":"Which color do you prefer?","multiSelect":false}]},"type":"tool_use","id":"toolu_014HT2HpyJoEaRDU7SWo8T1D"}

event: user_request
data: {"type":"user_request","request":{"questions":{"toolUseID":"toolu_014HT2HpyJoEaRDU7SWo8T1D","_1":[{"options":[{"label":"Red","description":"The color red"},{"label":"Green","description":"The color green"},{"label":"Blue","description":"The color blue"}],"header":"Color","question":"Which color do you prefer?","multiSelect":false}]}}}
```

```
POST /conversations/7F58BC9E-9D95-4896-9FF2-F857662167F9/messages
{"answer":{"_0":{"questions":{"toolUseID":"toolu_014HT2HpyJoEaRDU7SWo8T1D","answers":{"Which color do you prefer?":["Green"]}}}}}

event: assistant_message
data: {"type":"assistant_message","text":"Green"}
```

- answers are keyed by the question's text. several labels for a multi select question: `["Red","Blue"]`

#### Tool call → deny

```
POST /conversations/7F58BC9E-9D95-4896-9FF2-F857662167F9/messages
{"prompt":{"permissionModeOverride":"manual","prompt":"Use the Bash tool to run: touch /tmp/sample-calls-denied. If it is denied, reply DENIED."}}

event: tool_use
data: {"name":"Bash","input":{"description":"Create empty marker file in \/tmp","command":"touch \/tmp\/sample-calls-denied"},"type":"tool_use","id":"toolu_01KZxEH1GRg1fjDY7DXAYyGD"}

event: user_request
data: {"type":"user_request","request":{"permission":{"_0":{"input":{"description":"Create empty marker file in \/tmp","command":"touch \/tmp\/sample-calls-denied"},"id":"toolu_01KZxEH1GRg1fjDY7DXAYyGD","name":"Bash"}}}}
```

```
POST /conversations/7F58BC9E-9D95-4896-9FF2-F857662167F9/messages
{"answer":{"_0":{"permission":{"allow":false,"toolUseID":"toolu_01KZxEH1GRg1fjDY7DXAYyGD","message":"Not now."}}}}

event: assistant_message
data: {"type":"assistant_message","text":"DENIED"}
```

#### Other answers

- decline the questions: `{"answer":{"_0":{"declineQuestions":{"toolUseID":"toolu_…"}}}}` (optional `"message"`)
- approve a plan (ExitPlanMode): `{"answer":{"_0":{"planApproval":{"approve":true,"toolUseID":"toolu_…"}}}}`
- reject a plan: `{"answer":{"_0":{"planApproval":{"approve":false,"feedback":"Run `echo second` instead.","toolUseID":"toolu_…"}}}}`
- no such chat (`/conversations/<id>/messages`): `404`
- no turn waiting for that tool use: `404`, `{"error":{"message":"No turn is waiting for an answer to tool use toolu_…"}}`
- the turn failed: the response ends with `event: error`, `data: {"message":"…"}`


### Implement A New Agent Provider

A provider is one type conforming to `AgentProvider` (`Providers/AgentProvider.swift`), in its own folder `Providers/<Name>/`, the way `Providers/Claude/` does it for Claude. Everything else (Xcode's chat files, the server, the iOS app) only talks to the protocol.

#### Step by step

1. **See how Xcode runs it**
    - `xcrun mcpbridge run-agent --dry-run <agent>`: the binary, the flags Xcode adds, its config dir. run it exactly like that, plus only what the app needs (its machine-readable input / output)
    - find where the agent keeps its sessions, and how a chat links to one: decode `assistantConfiguration` of `<chat UUID>/conversation.plist` (`{"agent":{"_0":{"sessionID":"…"}}}` for Claude)
2. **Collect real samples before writing code**: one session file per case of the checklist below, made with Xcode and with the agent run by hand. add them to this README the way [Sample Jsonl (Claude history)](#sample-jsonl-claude-history) does. every case below was guessed wrong at least once for Claude
3. **Session basics**: `agent`, `modelIdentifier` (Xcode's `chatModelDefinitionIdentifier.modelIdentifier`, e.g. `claude-code`), `newSessionID()`, `transcriptFile(sessionID:)` (also what `ChatWatcher` watches), `workingDirectory(sessionID:)`
4. **History** (`history(sessionID:)`): the session's lines → `ChatEvent`s, the same events a live turn streams, plus the prompt and the user's answers (`userMessage`, `assistantMessage`, `intermediate`, `toolUse`, `toolResult`, `userRequest`, `userResponse`)
5. **Run a turn** (`runTurn(_:)`): start the agent like Xcode, send the prompt, stream its output as `ChatEvent`s, and answer its requests to the user (`PendingUserRequestHandler.waitForAnswer`; no answer in `permissionTimeout` is a deny). record file contents around file-changing tools and the denied tool uses in `request.records` (the cards need them)
6. **Pending requests** (`pendingToolUse(sessionID:)`): the session's last tool use, when it waits for the user, both for the app's own turns and Xcode's ([How to determine whether there is a pending user request](#how-to-determine-whether-there-is-a-pending-user-request))
7. **Resume and repeat**: `isSameCall(_:_:)`, `removeToolUse(_:sessionID:)`, `removeStoppedResult(of:sessionID:)`, `replaceResumeInterruption(with:prompt:sessionID:)`, for a request answered after its agent stopped
8. **Cards** (`card(for:result:record:)`): what Xcode shows for each tool. copy Xcode's own cards field for field from turns Xcode wrote with that agent
9. **Register it**: add it to `AgentProviders.all`, and its Xcode model cache id to `XcodeAgentConfiguration.xcodeAgentID(of:)` (`IDEChatGatewayModels.<id>` in `com.apple.dt.Xcode`) so `GET /providers` lists its models
10. **Test against the real agent**: `SessionHistoryTests` with real session files, `SendMessageTests`, `ScenarioTests` (all of them, again after every change: a build passing proves nothing about the chat store paths or the agent's output)

#### What to confirm (and what went wrong for Claude)

**Running the agent**

- output granularity: Claude's stream-json without `--include-partial-messages` sends whole blocks, not tokens. `.intermediate` is one complete thinking block
- when the tool use reaches the session file: Claude writes it before the answer only with a `PreToolUse` hook registered (the app registers a pass-through one), and only shortly after it asks: an agent killed within a second of asking leaves no tool use at all
- the order the agent sends things in: Claude sends the assistant's `tool_use` block first, then asks (`can_use_tool`). the live stream gets `.toolUse`, then `.userRequest`
- how the agent asks the user, for each kind: permission, questions, plan. for Claude all three are the same `can_use_tool` request, answered allow / deny
- what the answer looks like in the session file, for each kind and each answer (allowed, denied with / without a message, questions answered / declined, plan approved / rejected with feedback)
- multi-select answers: Claude joins the labels with `, ` (`"Red, Blue"`). a label that itself contains `, ` can't be split back. check whether the new agent keeps them apart
- a request's input may be incomplete in the tool use and complete only in the request: Claude's `ExitPlanMode` has no `plan` when the agent writes the plan file in the same message ([Plan](#plan-exitplanmode)). only then is the plan taken from elsewhere (`isPlanWithoutPlan`): live, the `can_use_tool` input (`askedToolUse`); in history, `toolUseResult.plan`, or the plan file's `Write` while it waits. without it, the plan was asked as a permission, and the caller got its `.toolUse`. it happened in a test run, not in the earlier ones: the agent's choice to write both in one message is random
- the app's own timeout deny: give it a text you can recognise later (Claude: `No answer to this …`). it is a request that was asked and never answered: no `userResponse`

**Who decided (history)**

- every result needs to say whether the user decided it, and where: through the app, in Xcode's prompt, or by a rule. for Claude it is `permissionDecision.source` (`user_temporary` / `user_reject` / `hook` / `config`, [Who decided](#who-decided-permissiondecision))
- a deny the user clicked in Xcode's prompt looks like Xcode's other hook rejects except for its text (`User selected: Don’t Allow`). it is the user's deny; the others are not requests
- an Allow clicked in Xcode's prompt can't be told apart from a rule's allow (both `accept` / `hook`). find out whether the new agent records more

**Requests in the history and in the stream**

- a request replaces its tool use, the user's answer replaces its result: never both. an allowed permission is the answer, then the tool's own output (`.userResponse`, then `.toolResult`), in that order
- the caller doesn't get back what it sent: not the prompt (`.userMessage`, never streamed), not the answer (`.userResponse`, streamed by the provider, kept from the caller by `ClientEvents`). the history has both
- a question or a plan is always a request (the provider says which: `alwaysWaitsForUser`): the caller gets only its `.userRequest`, not its `.toolUse` (a permission's tool use can't be known in advance: it comes, then its request)
- the provider streams every event (Xcode's cards are built from all of them); what the caller doesn't get is decided outside the provider (`ClientEvents` in `XcodeChat.swift`). a request that isn't an allowed permission has the user's answer as its result: the caller doesn't get that result

**Xcode's chats, closed by the app**

- what each stop leaves in the session file, and that a real deny never looks like one. for Claude ([General Approach](#if-initiated-by-xcode) table)
    - killed while the tool ran: `Exit code 137` (`accept` / `hook`, no `toolDenialKind`)
    - closed while Xcode's prompt was open: `toolDenialKind` `cancelled` (no `permissionDecision`). this third kind was missed at first, though the close is the same AppleScript
    - Xcode's own close / stop button: `user-rejected`, then the interrupted text
    - every real deny has `permission-rule` and a `reject` decision: check both before removing anything
- what the agent writes when a session that ended without a result is resumed. for Claude, in order: the `[Tool call interrupted …]` result, a synthetic `No response requested.`, the resume prompt

**The repeat (answering a request after its agent stopped)**

- the agent makes the call again under a new id it assigns itself. the app can't choose it: keep the new id everywhere (the response and the result must match it)
- the repeat may not be asked about at all: Claude's agent allowed it by its own config (`source: config`), so no `can_use_tool` came. match the repeat when the agent sends the call (`isSameCall`), not only when it asks
- the caller doesn't get the repeat's tool use or a second request: the user already answered it. it gets only the repeat's `.toolResult` (`ClientEvents` matches the repeat with the provider's `isSameCall`)
- once the turn ended, remove the earlier tool use and its interrupted result (`removeToolUse`), whether or not the repeat was asked
- not repeated (a deny, or a question / plan whose answer was the prompt): remove the interrupted result and the synthetic `No response requested.`, and make the resume prompt the earlier tool use's result, recorded the way a live answer is (`replaceResumeInterruption`). the history then has the request and the user's answer, as in a live turn
- `isSameCall`: which input fields identify a call per tool. the agent rewords its description, a plan, a question's options

**Reading Xcode's chat store**

- the files are per chat: `<store>/<chat UUID>/conversation.plist`, `<store>/<chat UUID>/metadata.plist`. there is no store-level `metadata.plist` (reading it there threw for every chat, and no test caught it until the scenarios ran again)
- the provider of a chat comes from its metadata (`chatModelDefinitionIdentifier.providerIdentifier.builtIn._0`). check the new agent's key there

## Additional Notes / Discussions

### Ways to Drive an Xcode Chat

1. **Drive Xcode's chat UI with the Accessibility API** ([details](#accessibility-ui-scripting-details)). Xcode runs the chat itself, so history and snapshots stay correct. Breaks if Apple changes the UI; Xcode must be open.
2. **Write Xcode's chat files yourself**: create `<UUID>/conversation.plist` + `metadata.plist`, add an entry to `CodingAssistantManifest.plist`, and set `assistantConfiguration` to base64 of `{"agent":{"_0":{"sessionID":"…"}}}`; run the session from the CLI with `--session-id`. The chat would show up as a record only, without snapshots, and Xcode may need a restart to notice it.
3. **Reverse engineer the private frameworks** (`class-dump` / disassembler on `IDEIntelligenceChat`) and call into Xcode via code injection. Lots of work, fragile, needs SIP / library-validation workarounds.

#### Running From Terminal?

**Short answer: no public way to drive an Xcode chat from the terminal.** A session started with `xcrun agent claude` is a plain CLI session and never shows up in Xcode's chat list.

##### Why CLI sessions don't show up in Xcode

- `xcrun agent claude` (= `xcrun mcpbridge run-agent claude`) launches Xcode's bundled `claude` (`~/Library/Developer/Xcode/CodingAssistant/Agents/XcodeVersions/<build>/claude/claude`) with Xcode's config (`ClaudeAgentConfig`).
- Both CLI and Xcode sessions write their transcript to `ClaudeAgentConfig/projects/<cwd-with-dashes>/<sessionID>.jsonl`.
- Only Xcode also writes its own chat record (`UserData/CodingAssistant/<Project>-<hash>/<chat-UUID>/conversation.plist`, `metadata.plist`, `Snapshots/`, `CodingAssistantManifest.plist`). Xcode's chat list reads **only** from there, so CLI sessions never appear in Xcode. The link is one-way: Xcode chat → Claude session.
- Sessions are tagged by `entrypoint` in the `.jsonl`: CLI = `"cli"`, Xcode = `"sdk-cli"` (Xcode runs it through the SDK).

##### Resuming an Xcode chat from the terminal

- `/resume` in the CLI does **not** list Xcode chats. Claude Code deliberately filters out sessions whose `entrypoint` is `sdk-cli` / `sdk-ts` / `sdk-py` when the current session is a CLI one (`Session … filtered from /resume: entrypoint=sdk-cli`).
- Resuming by ID works:

```bash
cd /path/to/project   # must be the same cwd the Xcode chat used
xcrun agent claude --resume <sessionID>   # sessionID from conversation.plist → assistantConfiguration
```

- Anything added this way goes into the `.jsonl` only. Xcode's `conversation.plist` is not updated, so the chat shown in Xcode will stop matching the transcript.

##### What doesn't work

- `MCP_XCODE_PID` / `MCP_XCODE_SESSION_ID`: these pick which Xcode (and which tool session) the MCP bridge talks to. They are for the agent calling Xcode, not for sending a chat into Xcode.
- `xcrun mcpbridge` tools (`BuildProject`, `XcodeRead`, `RunProject`, `RenderPreview`, …): agent → Xcode only. None of them creates or sends a chat.
- Xcode AppleScript dictionary: build / run / test / debug / documents only. Nothing for chats.
- Xcode URL schemes (`xcode`, `xcdevice`, `xcdoc`, …): nothing chat-related.
- Private frameworks (`Xcode.app/Contents/PlugIns/IDEIntelligenceChat.framework`, `IDEIntelligenceAgents.framework`, `IDEIntelligenceACP.framework`): the only service-like name found is `com.apple.dt.internal.genAIAgentProxyService`, which looks internal to Xcode. No external XPC service, URL handler or App Intent was found for sending a prompt.

#### Accessibility (UI scripting) details

Requirement: the app running the script (e.g. Terminal) needs **System Settings → Privacy & Security → Accessibility**. Without it: `osascript is not allowed assistive access. (-1728)`. Restart the app after enabling.

Accessibility tree of an open chat (Xcode 27C5020n), found by walking the window with `AXUIElementCopyAttributeValue`:

```
AXWindow  id=Xcode.WorkspaceWindow
└ … AXGroup  id="editor context"  desc="New Conversation"
    └ AXSplitGroup / AXSplitGroup
        └ AXGroup  sub=AXHostingView                     ← chat view (SwiftUI)
            ├ AXScrollArea → AXOpaqueProviderGroup       ← transcript; messages are AXStaticText values
            ├ (AXStaticText + AXButton "Yes" / "No")     ← only while the agent is asking a question
            ├ AXScrollArea → AXUnknown                   ← prompt input
            ├ AXMenuButton  id=paperclip  title=Attachments
            ├ AXMenuButton  help=Model   title=<model, e.g. Opus 5.5>
            ├ AXMenuButton  help=Mode    title=<e.g. Manual Mode>
            └ AXButton      id=arrow.up  desc=Submit  (AXPress; disabled while input is empty)
```

What works (tested on Xcode 27C5020n):

- **Find the chat**: search the window for the button with `AXIdentifier = "arrow.up"`; its `AXParent` is the chat view.
- **Find the input**: the `AXUnknown` inside an `AXScrollArea` of the chat view. Find it by role, not index: a pending Yes/No question inserts extra children before it.
- **Focus the input**: a real mouse click at the input's position. Setting `AXFocused = true` reports success but does **not** move keyboard focus (Xcode's focused element stays elsewhere).
- **Enter text**: clipboard + ⌘V after the click. Confirmed by the Submit button switching from disabled to enabled.
- **New chat**: `AXPress` on the menu item `File → New → Conversation` (`AXIdentifier = newCodingAssistant:`). Also `Conversation in New Tab` (`newCodingAssistantWithAlternate:`) and `Conversation in Editor Pane` (`newCodingAssistantWithShiftPlusAlternate:`).
- **Switch chat**: the editor tab bar has an `AXRadioButton` (`sub=AXTabButton`) per open chat, titled with the chat name; `Window` menu has `<Project> — <chat name>` items.
- **Read replies**: the transcript is `AXStaticText` elements under the first `AXScrollArea`. Reading `conversation.plist` / the session `.jsonl` is more reliable.

Constraints:

- **Xcode must have a project window with a chat open** and be frontmost. The click and paste are real mouse/keyboard events, so don't use the Mac while the script runs (~4 s).
- **The input has no `AXValue`**: text can't be set directly, only typed or pasted. The script temporarily replaces the clipboard (restored afterwards).
- **Element references go stale** after typing: SwiftUI rebuilds the chat view, so look the Submit button up again before using it.
- **Can't send while a question is pending**: Submit stays disabled until the Yes/No question is answered.
- **Two Xcode installs** (e.g. Xcode + Xcode-beta) both have the process name `Xcode`, so `process "Xcode"` may pick the wrong one.
- **Sending works** (tested, besides `--dry-run`): either click the Submit button, or simulate a Return key press in the input.
- In AppleScript, store `entire contents of front window` in a variable before looping: `repeat with b in (entire contents …)` re-evaluates the expression every pass and finds nothing.
- **Speed: AppleScript vs Accessibility API.** The AppleScript below takes ~4.4 s per send; the Swift version takes ~0.3 s (both measured with `--dry-run`). The Accessibility API itself is fast: finding the Submit button takes 7–10 ms (79 elements), the input < 1 ms, the `File → New → Conversation` menu item ~60 ms. The AppleScript time is ~1.3 s of fixed `delay`s plus one System Events round trip per element checked while searching `entire contents` (done twice). The Swift version polls for the expected state instead of sleeping.
- **Foreground vs background.** Reading the tree (transcript, input, Submit and its enabled state) works with Xcode in the background, but not when the window is on another Space (Xcode then reports 0 windows). Sending needs Xcode frontmost: the input can only be focused by a real click, and the click and ⌘V are synthetic events that go to the frontmost app. Posting keys to Xcode's process (`CGEvent.postToPid`) wouldn't avoid this, since the keys still go to whatever has focus inside Xcode, and focusing needs the click. So the whole send happens in the foreground; background access only helps for reading, and replies are better read from the `.jsonl` / `conversation.plist` anyway.
- **Bringing Xcode to the front from a CLI tool**: `NSRunningApplication.activate()`, `NSWorkspace.openApplication` and setting `AXFrontmost` did not work; AppleScript `activate` (via `NSAppleScript`) did, in ~200 ms. Check the result with the app's `AXFrontmost` attribute: `NSWorkspace.frontmostApplication` doesn't update without a run loop.

Script (AppleScript). `--dry-run` checks that the text reached the input, then clears it without sending:

```applescript
-- usage: osascript send-to-xcode.applescript "<prompt>" [--dry-run]
on findSubmitButton()
    tell application "System Events" to tell process "Xcode"
        -- fetch once: `repeat with b in (entire contents …)` re-evaluates the expression every pass
        set allElements to entire contents of front window
        repeat with b in allElements
            try
                if value of attribute "AXIdentifier" of b is "arrow.up" then return contents of b
            end try
        end repeat
    end tell
    error "No open chat found"
end findSubmitButton

on run argv
    set prompt to item 1 of argv
    set dryRun to (count of argv) > 1 and item 2 of argv is "--dry-run"
    tell application "Xcode" to activate
    delay 0.5
    set submitButton to findSubmitButton()
    tell application "System Events" to tell process "Xcode"
        -- prompt input = the AXUnknown inside an AXScrollArea of the chat view
        -- (found by role: child indexes shift, e.g. when a Yes/No question is pending)
        set chatView to value of attribute "AXParent" of submitButton
        set inputField to missing value
        set scrollAreas to scroll areas of chatView
        repeat with s in scrollAreas
            set children to UI elements of s
            repeat with e in children
                if role of e is "AXUnknown" then set inputField to contents of e
            end repeat
        end repeat
        if inputField is missing value then error "Prompt input not found"

        -- focus with a real click (setting AXFocused does not move keyboard focus)
        set {x, y} to position of inputField
        set {w, h} to size of inputField
        click at {x + w / 2, y + h / 2}
        delay 0.3

        -- paste the prompt, then restore the clipboard
        set savedClipboard to the clipboard
        set the clipboard to prompt
        keystroke "v" using command down
        delay 0.5
        set the clipboard to savedClipboard
    end tell

    -- the chat view is rebuilt after typing, so old references go stale: look the button up again
    set submitButton to my findSubmitButton()
    tell application "System Events" to tell process "Xcode"
        if not (enabled of submitButton) then error "Text did not reach the input (or a question is pending)"
        if dryRun then
            keystroke "a" using command down
            key code 51 -- delete
            return "dry run OK: text reached the input; cleared without sending"
        end if
        click submitButton
    end tell
    return "sent"
end run
```

```bash
osascript send-to-xcode.applescript "echo back what i said"
osascript send-to-xcode.applescript "test" --dry-run
```

Swift version (Accessibility API directly, ~0.3 s). Same steps and `--dry-run` flag:

```swift
// usage: swiftc -O SendToXcode.swift -o send-to-xcode && ./send-to-xcode "<prompt>" [--dry-run]
import Cocoa

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func role(_ e: AXUIElement) -> String { (attr(e, kAXRoleAttribute) as? String) ?? "" }

func findSubmitButton(_ e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if depth > 60 { return nil }
    if role(e) == "AXButton", (attr(e, kAXIdentifierAttribute) as? String) == "arrow.up" { return e }
    for c in children(e) { if let f = findSubmitButton(c, depth: depth + 1) { return f } }
    return nil
}
// Submit button of the first chat found in any Xcode window
func findChat() -> (NSRunningApplication, AXUIElement)? {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode") {
        let windows = (attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in windows { if let s = findSubmitButton(w) { return (app, s) } }
    }
    return nil
}
func isEnabled(_ e: AXUIElement) -> Bool { (attr(e, kAXEnabledAttribute) as? Bool) ?? false }
func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if condition() { return true }; usleep(20_000) }
    return condition()
}
func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}
func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: send-to-xcode <prompt> [--dry-run]") }
let prompt = args[1]
let dryRun = args.contains("--dry-run")
guard AXIsProcessTrusted() else { fail("Accessibility permission missing for this process") }
let start = Date()

// 1. find the chat (works with Xcode in the background, but not on another Space)
guard var (xcode, submit) = findChat() else { fail("No open chat found") }
guard let chatView = attr(submit, kAXParentAttribute).map({ $0 as! AXUIElement }) else { fail("Chat view not found") }
// 2. prompt input = AXUnknown inside an AXScrollArea of the chat view (by role, not index)
guard let input = children(chatView).filter({ role($0) == "AXScrollArea" }).flatMap(children).first(where: { role($0) == "AXUnknown" })
else { fail("Prompt input not found") }

// 3. click and paste are real events: Xcode must be frontmost.
//    From a CLI tool, NSRunningApplication.activate(), NSWorkspace.openApplication and setting
//    AXFrontmost did not bring Xcode forward; AppleScript `activate` did. Target it by bundle path:
//    with Xcode + Xcode-beta installed, "Xcode" is ambiguous.
var scriptError: NSDictionary?
NSAppleScript(source: "tell application \"\(xcode.bundleURL!.path)\" to activate")!.executeAndReturnError(&scriptError)
// (check via AX: NSWorkspace.frontmostApplication doesn't update without a run loop)
guard waitUntil(timeout: 2, { (attr(AXUIElementCreateApplication(xcode.processIdentifier), "AXFrontmost") as? Bool) == true }) else { fail("Could not bring Xcode to the front") }

// 4. focus with a real click (setting AXFocused does not move keyboard focus)
var origin = CGPoint.zero, size = CGSize.zero
AXValueGetValue(attr(input, kAXPositionAttribute) as! AXValue, .cgPoint, &origin)
AXValueGetValue(attr(input, kAXSizeAttribute) as! AXValue, .cgSize, &size)
let point = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
}
_ = waitUntil(timeout: 1) { attr(AXUIElementCreateApplication(xcode.processIdentifier), kAXFocusedUIElementAttribute).map { role($0 as! AXUIElement) } == "AXTextArea" }

// 5. paste the prompt, then restore the clipboard
let pasteboard = NSPasteboard.general
let saved = pasteboard.string(forType: .string)
pasteboard.clearContents()
pasteboard.setString(prompt, forType: .string)
postKey(9, flags: .maskCommand) // ⌘V

// 6. Submit becomes enabled once the text is in. Re-find it each poll: the chat view is rebuilt after typing.
let landed = waitUntil(timeout: 2) {
    guard let (_, s) = findChat() else { return false }
    submit = s
    return isEnabled(s)
}
if let saved { pasteboard.clearContents(); pasteboard.setString(saved, forType: .string) }
guard landed else { fail("Text did not reach the input (or a question is pending)") }

if dryRun {
    postKey(0, flags: .maskCommand) // ⌘A
    postKey(51)                      // delete
    print(String(format: "dry run OK in %.2f s: text reached the input; cleared without sending", Date().timeIntervalSince(start)))
} else {
    guard AXUIElementPerformAction(submit, kAXPressAction as CFString) == .success else { fail("Submit press failed") }
    print(String(format: "sent in %.2f s", Date().timeIntervalSince(start)))
}
```

```bash
swiftc -O SendToXcode.swift -o send-to-xcode
./send-to-xcode "echo back what i said"
./send-to-xcode "test" --dry-run
```
