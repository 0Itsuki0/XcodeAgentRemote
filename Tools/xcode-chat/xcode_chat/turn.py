"""Provider-neutral items of one turn."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Union

from .events import PermissionRequestEvent
from .xcode_types import TextCategory


@dataclass
class Text:
    """Text the agent produced."""
    category: TextCategory
    text: str


@dataclass
class ToolCall:
    """A tool call the agent made, filled in as it runs."""
    id: str
    name: str
    input: dict[str, Any]
    result: str | None = None  # None until the call finished
    is_error: bool = False
    pre: str | None = None     # file content before the call, for file-changing tools
    post: str | None = None    # file content after the call


TurnItem = Union[Text, ToolCall]


@dataclass
class TurnResult:
    """What one turn produced."""
    items: list[TurnItem] = field(default_factory=list)  # in arrival order
    result: str | None = None                             # the agent's final reply
    is_error: bool = False
    pending: PermissionRequestEvent | None = None         # set when the turn stopped at a permission request
