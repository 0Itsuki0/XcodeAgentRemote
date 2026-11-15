#  Xcode Agent Remote


hello world


## Run Xcode Agent Programmatically

### Current Approach

Do what Xcode does, outside of Xcode: `Tools/xcode-chat`.

- run the agent the same way Xcode does
    - `xcrun mcpbridge run-agent claude`: Xcode's bundled binary, config dir, Xcode MCP tools
    - plus the flags Xcode adds: stream-json, Xcode's system prompt (from its template inside Xcode), Xcode's skills plugin, allowed tools
    - new chat: new session. existing chat: resume the session id stored in `conversation.plist`
- write the turn into Xcode's chat files, in Xcode's own format
    - `conversation.plist`, `metadata.plist`, `CodingAssistantManifest.plist`, `Snapshots/`
    - tool calls are written as Xcode's cards (file card, terminal card), checked against what Xcode itself writes
    - tools without a known card format use the terminal card with the tool name as title
- permission mode follows Xcode's Manual / Auto setting (`IDEChatAgentPermissionMode` in Xcode's preferences: `standard` = Manual, `auto` = Auto), can be overridden per message
- single turn only. if the agent asks for permission, the turn stops there and reports what it wanted to do
- output is streamed as typed events, ending with a result
- built into one executable (Python bundled), embedded in the app at `Contents/MacOS/xcode-chat`, for the app only
- the app calls it through `sendMessage` and gets typed events back
- the agent's history is the Claude session `.jsonl`, shared with Xcode. Xcode's chat files are only what Xcode displays


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
