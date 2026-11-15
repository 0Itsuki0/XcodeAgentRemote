"""Claude (Xcode provider "claude", model "claude-code").

Launches the agent the way Xcode does: `xcrun mcpbridge run-agent claude` (Xcode's bundled binary,
CLAUDE_CONFIG_DIR, xcode-tools MCP config, settings) plus the flags Xcode adds, and talks to it over stream-json.
"""

from __future__ import annotations

import glob
import json
import os
import re
import signal
import subprocess
import uuid
from types import FrameType
from typing import IO, Any, Literal, TypedDict, Union, cast

from .. import cards
from ..events import Emit, PermissionRequestEvent, TextEvent, ToolResultEvent, ToolUseEvent
from ..settings import PermissionMode
from ..turn import Text, ToolCall, TurnResult
from ..util import read_text, run
from ..xcode_types import ToolEntry
from .base import Provider

CONFIG_DIR: str = os.path.expanduser("~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig")

ALLOWED_TOOLS: str = ",".join([
    "mcp__xcode-tools", "ReadMcpResourceTool", "ListMcpResourcesTool", "Agent", "Task",
    "EnterPlanMode", "AgentEnterMode", "ToolSearch", "TodoWrite",
    "TaskCreate", "TaskGet", "TaskList", "TaskUpdate", "TaskOutput",
])

FILE_TOOLS: tuple[str, ...] = ("Edit", "Write")  # tools whose file content is captured before and after they run

ClaudePermissionMode = Literal["default", "auto", "dontAsk", "bypassPermissions"]

# Xcode's permission mode (settings.py) → Claude's --permission-mode.
PERMISSION_MODES: dict[PermissionMode, ClaudePermissionMode] = {
    "standard": "default", "auto": "auto", "dontAsk": "dontAsk", "bypassPermissions": "bypassPermissions",
}

# --- stream-json messages (only the fields used) -------------------------------------


class UserMessageContent(TypedDict):
    role: Literal["user"]
    content: str


class UserInput(TypedDict):
    """Sent to the agent: the prompt."""
    type: Literal["user"]
    message: UserMessageContent
    parent_tool_use_id: None
    session_id: str


class ControlErrorResponseBody(TypedDict):
    subtype: Literal["error"]
    request_id: str
    error: str


class ControlResponse(TypedDict):
    """Sent to the agent: the answer to a control request this tool does not support."""
    type: Literal["control_response"]
    response: ControlErrorResponseBody


AgentInput = Union[UserInput, ControlResponse]


class TextBlock(TypedDict):
    type: Literal["text"]
    text: str


class ThinkingBlock(TypedDict):
    type: Literal["thinking"]
    thinking: str


class ToolUseBlock(TypedDict):
    type: Literal["tool_use"]
    id: str
    name: str
    input: dict[str, Any]


class _ToolResultBlockRequired(TypedDict):
    type: Literal["tool_result"]
    tool_use_id: str


class ToolResultBlock(_ToolResultBlockRequired, total=False):
    content: Union[str, list[dict[str, Any]]]
    is_error: bool


class _CanUseToolRequestRequired(TypedDict):
    subtype: Literal["can_use_tool"]
    tool_name: str
    input: dict[str, Any]


class CanUseToolRequest(_CanUseToolRequestRequired, total=False):
    tool_use_id: str


class _ResultMessageRequired(TypedDict):
    type: Literal["result"]


class ResultMessage(_ResultMessageRequired, total=False):
    subtype: str
    result: str
    is_error: bool


def system_prompt() -> str | None:
    """Xcode's system prompt addition, rendered from its template inside Xcode."""
    developer_dir = (run(["xcode-select", "-p"]) or "").strip()
    path = os.path.normpath(os.path.join(
        developer_dir, "../PlugIns/IDEIntelligenceChat.framework/Resources/AgentSystemPromptAddition.idechatprompttemplate"))
    template = read_text(path)
    # Keep every `{% if MCPTool_X %}` section (all Xcode tools are available) and drop the tags.
    return re.sub(r"\{%[^%]*%\}", "", template) if template else None


def tool_result_text(content: Union[str, list[dict[str, Any]], None]) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(str(b.get("text", "")) for b in content if isinstance(b, dict))
    return ""


def tool_summary(args: dict[str, Any]) -> str:
    """One line describing a tool call's input."""
    for key in ("command", "file_path", "notebook_path", "pattern", "url", "query", "description", "prompt"):
        value = args.get(key)
        if isinstance(value, str) and value:
            return value
    return json.dumps(args, separators=(",", ":"))[:300] if args else ""


class ClaudeProvider(Provider):
    name = "claude"
    model_identifier = "claude-code"

    def new_session_id(self) -> str:
        return str(uuid.uuid4())

    def session_cwd(self, session_id: str) -> str | None:
        """The `cwd` recorded in the session's transcript."""
        for path in glob.glob(os.path.join(CONFIG_DIR, "projects", "*", session_id + ".jsonl")):
            with open(path) as f:
                for line in f:
                    try:
                        cwd = json.loads(line).get("cwd")
                    except ValueError:
                        continue
                    if isinstance(cwd, str) and cwd:
                        return cwd
        return None

    # --- Running a turn ----------------------------------------------------------

    def launch_args(self, session_id: str, resume: bool, permission_mode: PermissionMode) -> list[str]:
        args = [
            "xcrun", "mcpbridge", "run-agent", self.name,
            "-p",
            "--input-format=stream-json",
            "--output-format=stream-json",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", PERMISSION_MODES[permission_mode],
            "--allow-dangerously-skip-permissions",
            "--thinking-display", "summarized",
            "--allowedTools", ALLOWED_TOOLS,
        ]
        prompt = system_prompt()
        if prompt:
            args += ["--append-system-prompt", prompt]
        plugin_dir = (run(["xcrun", "mcpbridge", "run-agent", "plugin", "path", "--plugin-format", self.name]) or "").strip()
        if plugin_dir:
            args += ["--plugin-dir", plugin_dir]
        return args + (["--resume", session_id] if resume else ["--session-id", session_id])

    def run_turn(self, work_dir: str, session_id: str, resume: bool, prompt: str,
                 permission_mode: PermissionMode, emit: Emit) -> TurnResult:
        agent = subprocess.Popen(self.launch_args(session_id, resume, permission_mode), cwd=work_dir,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        stdin = cast(IO[str], agent.stdin)
        stdout = cast(IO[str], agent.stdout)

        # If xcode-chat is stopped (e.g. the app cancels the turn), stop the agent too instead of leaving it running.
        def stop(signum: int, frame: FrameType | None) -> None:
            agent.terminate()
            raise SystemExit(128 + signum)

        for stop_signal in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(stop_signal, stop)

        def send(message: AgentInput) -> None:
            try:
                stdin.write(json.dumps(message) + "\n")
                stdin.flush()
            except BrokenPipeError:
                pass

        send({"type": "user", "message": {"role": "user", "content": prompt},
              "parent_tool_use_id": None, "session_id": session_id})

        turn = TurnResult()
        calls: dict[str, ToolCall] = {}  # tool_use id -> ToolCall
        for line in stdout:
            try:
                message: dict[str, Any] = json.loads(line)
            except ValueError:
                continue
            kind = message.get("type")

            if kind == "assistant":
                for block in message.get("message", {}).get("content", []):
                    self.handle_assistant_block(block, turn, calls, emit)

            elif kind == "user":
                content = message.get("message", {}).get("content")
                for block in content if isinstance(content, list) else []:
                    if block.get("type") == "tool_result":
                        self.handle_tool_result(cast(ToolResultBlock, block), calls, emit)

            elif kind == "control_request":
                request = cast(dict[str, Any], message.get("request", {}))
                if request.get("subtype") == "can_use_tool":
                    # Single turn: don't answer, stop here and report what the agent wants to do.
                    can_use = cast(CanUseToolRequest, request)
                    turn.pending = PermissionRequestEvent(
                        tool_use_id=can_use.get("tool_use_id"), tool=can_use["tool_name"], input=can_use["input"])
                    emit(turn.pending)
                    agent.terminate()
                    break
                send({"type": "control_response", "response": {
                    "subtype": "error", "request_id": str(message.get("request_id", "")), "error": "unsupported request"}})

            elif kind == "result":
                result = cast(ResultMessage, message)
                turn.result = result.get("result")
                turn.is_error = bool(result.get("is_error"))
                stdin.close()
                break

        agent.wait()
        return turn

    @staticmethod
    def handle_assistant_block(block: dict[str, Any], turn: TurnResult, calls: dict[str, ToolCall],
                               emit: Emit) -> None:
        block_type = block.get("type")
        if block_type == "thinking":
            thinking = cast(ThinkingBlock, block)["thinking"]
            if thinking:
                turn.items.append(Text("thinking", thinking))
                emit(TextEvent("thinking", thinking))
        elif block_type == "text":
            text = cast(TextBlock, block)["text"]
            if text:
                turn.items.append(Text("prose", text))
                emit(TextEvent("prose", text))
        elif block_type == "tool_use":
            tool_use = cast(ToolUseBlock, block)
            call = ToolCall(tool_use["id"], tool_use.get("name", "?"), tool_use.get("input") or {})
            path = call.input.get("file_path")
            if call.name in FILE_TOOLS and isinstance(path, str):
                call.pre = read_text(path)
            calls[call.id] = call
            turn.items.append(call)
            emit(ToolUseEvent(call.id, call.name, call.input))

    @staticmethod
    def handle_tool_result(block: ToolResultBlock, calls: dict[str, ToolCall], emit: Emit) -> None:
        call = calls.get(block["tool_use_id"])
        if call is None:
            return
        call.result = tool_result_text(block.get("content"))
        call.is_error = bool(block.get("is_error"))
        path = call.input.get("file_path")
        if call.name in FILE_TOOLS and isinstance(path, str):
            call.post = read_text(path)
        emit(ToolResultEvent(call.id, call.is_error, call.result))

    # --- Tool calls → Xcode cards --------------------------------------------------

    def tool_entry(self, call: ToolCall) -> ToolEntry | None:
        if call.result is None:
            return None
        args = call.input
        path = args.get("file_path")
        if not call.is_error:
            if call.name == "Read" and isinstance(path, str):
                lines = len(re.findall(r"^\s*\d+\t", call.result, re.M))
                return cards.file_operation_state(call.id, path, "read", lines, 0, "")
            if call.name == "Edit" and isinstance(path, str):
                new = str(args.get("new_string", ""))
                added, removed, source = cards.line_changes(str(args.get("old_string", "")), new)
                return cards.file_operation_state(call.id, path, "modified", added, removed, source or new,
                                                  call.pre, call.post)
            if call.name == "Write" and isinstance(path, str):
                added, removed, source = cards.line_changes(call.pre or "", str(args.get("content", "")))
                return cards.file_operation_state(call.id, path, "added" if call.pre is None else "modified",
                                                  added, removed, source, call.pre, call.post)
            command = args.get("command")
            if call.name == "Bash" and isinstance(command, str) and command:
                return cards.terminal_card(call.id, command, call.result)
        # Any other tool, or a failed call: the generic tool card, titled with the tool's name
        # (for MCP tools `mcp__<server>__<tool>`, just the tool).
        title = call.name.split("__", 2)[2] if call.name.startswith("mcp__") and call.name.count("__") >= 2 else call.name
        return cards.generic_card(call.id, title, tool_summary(args), call.result)
