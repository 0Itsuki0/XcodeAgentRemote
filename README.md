# Xcode Agent Remote

[ngrok: Static dev domains for all ngrok users](https://ngrok.com/blog/free-static-domains-ngrok-users)

## Base Approach

<!-- TODO -->

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
- the app's marks of waiting tool uses: the app's `UserDefaults`, key `WaitingForUserToolUseIDsByAgent` (`[agent: [tool use id]]`)


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
    - `hook`: Xcode's PreToolUse hook. the same whether Xcode asked the user or allowed it by its rules
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

- approved, rejected with feedback

```json
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "User has approved your plan. You can now start coding. Start with updating your todo list …", "tool_use_id": "toolu_0175xuriiSDtDrK73TPskQw3"}]}, "toolUseResult": {"plan": "# Plan\n\n…", "isAgent": false, "filePath": "/Users/itsuki/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/plans/synthetic-gr…"}}
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "Run `echo second` instead.", "is_error": true, "tool_use_id": "toolu_01GvXVmcsLfYGcdv56xbLSo3"}]}, "toolUseResult": "Error: Run `echo second` instead."}
```

#### Stopped while the tool ran (Xcode's chat, the project closed)

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
- when the agent asks, the app marks the tool use waiting (stored in `UserDefaults`, per agent: `[agent: [tool use id]]`). removed once the answer arrives or the tool use has a result
- a tool use is a request **initiated by THIS App** when all three are `true` (Logic: `ClaudeProvider.userRequest`)
    - it has a result decided by the user: `permissionDecision.source` `user_temporary` (allowed / answered / approved) or `user_reject` (denied / declined / rejected)
    - it has no result yet, and it is a question or a plan
    - it has no result yet, it is marked, and it is the session's last message (else the mark is stale)
- `POST /message`:  the request is a `user_request` event, and the stream ends there.
- `GET /conversation/<id>`: the conversation's `history` has the same event
- the app quitting (or the turn being stopped) is not a pending request: the agent sees its stdin close, settles the request itself (`Tool permission request failed: … stream closed …`), finishes the turn
- the agent terminated while waiting is: the tool use stays without a result. If the user answers the request, the app resumes the chat with the answer as the prompt:
      1. the agent writes these entries to `.jsonl`, in order, before the model replies
          1. the `[Tool call interrupted …]` result for the old tool use, which had none
          2. the synthetic `No response requested.` assistant message
          3. the user's answer (the resume prompt), e.g. `Allowed: you may run the Bash call you asked permission for.`
      2. the agent repeats the tool call (its reply to the answer)
      3. the app checks whether it is the same call (logically) as the old one. if it is, and the answer is not a deny, the app answers it automatically, and once the turn ends removes the old tool use and its interrupted result: only the repeat remains. they stay (interrupted) if the answer was a deny (a repeat is not answered for it) or the agent didn't repeat the call

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
    - Xcode would ask the user about it: `XcodePermissions.wouldAsk` (`XcodeChat/Permission.swift`) makes Xcode's own decision from Xcode's settings, read fresh on every check
        - mode (`IDEChatAgentPermissionMode`): Manual → decided as below. Auto → the agent decides, counted as asking. dontAsk / bypassPermissions → never asks
        - tools: allowed by name, by the tools Xcode passes the agent (`--allowedTools`) or `toolRules`
        - Bash: split into simple commands (pipelines, `&&`, `;`, subshells, `$(…)` also inside assignments and redirects, `find -exec`). every one needs an `allow` rule (`shellCommandRules`): exact command name, the rule's other words in order with only options between them, leading `VAR=value` ignored, the longest matching pattern decides
        - files (Control File & Folder Access on): a Read / Write / Edit file outside the project folder, checked with `pathRules` (longest path wins): no rule → asks, `read` → writing asks, `write` → no ask, `deny` / `readDenyWrite` → refused without asking
        - anything it can't decide (missing settings, a command it can't parse) counts as asking
- the user answers through the app: the project is closed, then the `.jsonl` is read again
    - the tool use still has no result (it was waiting): the chat is resumed with the answer, the same as an agent killed while waiting. the agent repeats the call, it is answered without asking, and the old tool use is removed
    - it now has the result of a stop (it was running, closing the project killed it): that result is removed, and it continues like the no-result case. only these two results are removed; a result the tool produced itself (it finished before the close) stays, so it doesn't run again
        - by the app (AppleScript): Xcode doesn't notice, the tool is killed: a plain error result `Exit code 137` (`permissionDecision.source` `hook`)
        - by the user (the close button): Xcode notices: the `The tool use was rejected …` result (`"toolDenialKind": "user-rejected"`) and `[Request interrupted by user for tool use]` after it


**Why it works (scenario by scenario)**

- Xcode waits on its prompt, the user answers in the app: closing Xcode while it waits leaves no result (tested). the resume gives the agent the answer, it repeats the call, the call runs (or is denied) with that answer
- Xcode allowed it by itself and the check agrees: it is not shown as a request, the user never answers it, so Xcode is never closed and nothing is interrupted
- the check says Xcode asks, but Xcode allowed it (it was running): when the user answers, closing the project kills it and its agent writes `Exit code 137` as the result (tested). that is removed and the call runs again with the user's answer. cost: the part that already ran runs a second time
- the check says Xcode doesn't ask, but it did: shown as running, the request never reaches the app; it can only be answered in Xcode. known cases
    - a Bash command allowed by its rules that opens a file without access (the file supervisor asks; which files a command opens isn't in its input)
    - a setting changed while that chat was open (Xcode read its settings when the chat's agent started)
- answered in Xcode first: the tool use has a result, so it is no longer a request; the app's answer gets `noWaitingRequest`
- a question or a plan: always a request, whatever the settings
- the check was matched against what Xcode did on 23 Bash commands and 4 other tool uses (Write in a read-only folder, Write and Edit in `/tmp`, ToolSearch): all the same


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
    - `/health`, `/projects`, `/conversation`
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
    - the message box and the send button can't be focused or typed into from outside
- call into Xcode itself (the private method that sends a message)
    - needs SIP or library validation turned off. not something every Mac can do
- `MCP_XCODE_SESSION_ID`, `xcrun mcpbridge` tools
    - these are for the agent calling Xcode (build, run, read files…), not for sending a message to a chat
- make Xcode reload the chat while it remains open
    - nothing watches the chat files, no refresh button, switching tabs does nothing
- use hooks for permission request / response received
    - `PreToolCall` conflicts with Xcode registered ones (Xcode registered hook invoke after any ones set in `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json`)
    - hard (if no impossible) to control which chat to watch
    - have to inject for both Xcode-started sessions as well as every single message THIS app send.


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


## Additional Notes / Discussions

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
