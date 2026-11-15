"""Events streamed on stdout while a turn runs: one JSON object per line, discriminated by "type".

    {"type": "start", "conversation", "session", "provider", "permission_mode", "new_conversation"}
    {"type": "text", "category": "thinking" | "prose", "text"}
    {"type": "tool_use", "id", "name", "input"}
    {"type": "tool_result", "id", "is_error", "output"}
    {"type": "permission_request", "tool_use_id", "tool", "input"}   the turn stops after this
    {"type": "result", "status", "conversation", "session", "result", "pending", "saved_to", "unfinished_tools"}   always last
"""

from __future__ import annotations

import json
import sys
from dataclasses import asdict, dataclass, field
from typing import Any, Callable, Literal, Union

from .settings import PermissionMode
from .xcode_types import TextCategory


@dataclass
class StartEvent:
    conversation: str
    session: str
    provider: str
    permission_mode: PermissionMode
    new_conversation: bool
    type: Literal["start"] = "start"


@dataclass
class TextEvent:
    category: TextCategory
    text: str
    type: Literal["text"] = "text"


@dataclass
class ToolUseEvent:
    id: str
    name: str
    input: dict[str, Any]
    type: Literal["tool_use"] = "tool_use"


@dataclass
class ToolResultEvent:
    id: str
    is_error: bool
    output: str
    type: Literal["tool_result"] = "tool_result"


@dataclass
class PermissionRequestEvent:
    tool_use_id: str | None
    tool: str
    input: dict[str, Any]
    type: Literal["permission_request"] = "permission_request"


TurnStatus = Literal["completed", "error", "permission_required"]


@dataclass
class ResultEvent:
    status: TurnStatus
    conversation: str
    session: str
    result: str | None                        # the agent's final reply
    pending: PermissionRequestEvent | None    # the request the turn stopped at
    saved_to: str
    unfinished_tools: list[str] = field(default_factory=list)
    type: Literal["result"] = "result"


Event = Union[StartEvent, TextEvent, ToolUseEvent, ToolResultEvent, PermissionRequestEvent, ResultEvent]
Emit = Callable[[Event], None]


def to_json(event: Event) -> dict[str, Any]:
    """The event as a JSON object, with "type" first."""
    body = asdict(event)
    return {"type": body.pop("type"), **body}


def emit(event: Event) -> None:
    """Write one event to stdout as a JSON line."""
    sys.stdout.write(json.dumps(to_json(event)) + "\n")
    sys.stdout.flush()
