"""Xcode transcript entries (`responseContent` of a turn in conversation.plist), shared by all providers.

Every format here is copied from entries Xcode itself wrote, and checked field for field against them.
Xcode stores presentation in these entries (titles, SF Symbol names, SwiftUI fonts), not just data, and draws
what is stored, so an entry we add renders like Xcode's own only if it carries the same fields.

Kinds of entries (types in xcode_types.py):
- TextState: thinking / reply text.
- FileOperationState: the file card, e.g. "README  −1  M" (book icon, line counts, M badge). Read/edit/write of
  one file: path, language, operationKind, line counts, and for edits the whole file before and after
  (pre/postToolCallSnapshot). Consecutive reads are grouped in one ToolCallGroupState.
- ToolCallState: the tool card, e.g. "Terminal Command": a title, an SF Symbol and an attributed text.

Only these two card formats are known (verified against Xcode's own entries). Tools with no exact format use the
tool card, titled with the tool's name (`generic_card`): the file card needs a real file and line counts to
display. That card keeps kind = execute, the only tool kind whose shape we have seen, so Xcode may treat it like a
terminal command in ways that are not visible.
"""

from __future__ import annotations

import difflib
import os
import re
from typing import Any, Callable, Optional

from .store import new_id
from .turn import Text, TurnItem, ToolCall
from .xcode_types import (AttributedRuns, FileOperationState, FileOperationValue, OperationKind, ResponseContent,
                          ResultDetail, SequenceEntry, TextCategory, TextState, ToolCallGroupValue, ToolCallState,
                          ToolEntry)

LANGUAGES: dict[str, str] = {
    ".md": "markdown", ".swift": "swift", ".py": "python", ".js": "javascript", ".ts": "typescript",
    ".json": "json", ".m": "objective-c", ".h": "objective-c", ".c": "c", ".cpp": "cpp", ".sh": "shell",
}

# SwiftUI AttributedString attributes Xcode uses in the terminal card: monospaced subheadline,
# and bold (+0.3 weight) with primary color for each command name.
MONOSPACED_FONT: dict[str, Any] = {
    "tag": {"modifier": {"_0": "weight"}},
    "value": {
        "font": {
            "tag": {"staticModifier": {"_0": {"do": {"_0": {"monospaced": {}}}}}},
            "value": {"tag": {"style": {}}, "value": {"design": {}, "style": {"subheadline": {}}, "weight": {}}},
        },
        "modifier": 0.0,
    },
}
PLAIN_RUN: dict[str, Any] = {"SwiftUI.Font": MONOSPACED_FONT}
COMMAND_RUN: dict[str, Any] = {
    "SwiftUI.Font": {"tag": {"modifier": {"_0": "weight"}}, "value": {"font": MONOSPACED_FONT, "modifier": 0.3}},
    "SwiftUI.ForegroundColor": {"tag": {"system": {}}, "value": {"primary": {}}},
}
GENERIC_TOOL_IMAGE = "wrench.and.screwdriver"
MAX_OUTPUT = 4000

# A provider's mapping from one of its tool calls to an Xcode entry (None if the call never finished).
ToolEntryBuilder = Callable[[ToolCall], Optional[ToolEntry]]


def text_state(category: TextCategory, text: str) -> tuple[TextState, SequenceEntry]:
    """(responseContent entry, responseContentSequence entry) for a text block."""
    block_id = new_id()
    entry: TextState = {"textState": {"_0": {"category": category, "id": {"prose": {"_0": block_id}}, "text": text}}}
    return entry, {"prose": {"_0": block_id}}


def line_changes(old: str, new: str) -> tuple[int, int, str]:
    """(lines added, lines removed, added text) between two strings."""
    added: list[str] = []
    removed = 0
    for line in difflib.ndiff(old.splitlines(True), new.splitlines(True)):
        if line.startswith("+ "):
            added.append(line[2:])
        elif line.startswith("- "):
            removed += 1
    return len(added), removed, "".join(added).rstrip("\n")


def file_operation_state(tool_id: str, path: str, kind: OperationKind, added: int, removed: int, source: str,
                         pre: str | None = None, post: str | None = None) -> FileOperationState:
    """The file card."""
    state: FileOperationValue = {
        "displayName": os.path.basename(path),
        "filePath": path,
        "headerPathState": {"primaryComponents": [
            {"id": 0, "imageTypeName": "folder", "title": os.path.basename(os.path.dirname(path))}]},
        "id": {"tool": {"_0": tool_id}},
        "language": LANGUAGES.get(os.path.splitext(path)[1].lower(), "plaintext"),
        "linesAdded": added,
        "linesRemoved": removed,
        "operationKind": kind,
        "segments": [{"linesAdded": added, "linesRemoved": removed, "sourceCode": source, "toolCallID": tool_id}],
        "showHeaderPath": False,
        "sourceCode": source,
        "status": "completed",
    }
    if pre is not None:
        state["preToolCallSnapshot"] = {"absoluteFilePath": path, "content": pre}
    if post is not None:
        state["postToolCallSnapshot"] = {"absoluteFilePath": path, "content": post}
    return {"fileOperationState": {"_0": state}}


def command_runs(command: str) -> AttributedRuns:
    """A shell command as AttributedString runs, with command names bold."""
    runs: AttributedRuns = []
    pos = 0
    for match in re.finditer(r"(^|&&|\|\||[|;])(\s*)([^\s|;&]+)", command):
        start = match.start(3)
        if start > pos:
            runs += [command[pos:start], PLAIN_RUN]
        runs += [match.group(3), COMMAND_RUN]
        pos = match.end(3)
    if pos < len(command):
        runs += [command[pos:], PLAIN_RUN]
    return runs


def tool_card(tool_id: str, name: str, image: str, command: str, runs: AttributedRuns,
              output: str | None) -> ToolCallState:
    """The tool card, in the format Xcode writes for terminal commands."""
    details: list[ResultDetail] = [{"prose": {"_0": runs}}]
    if output:
        details.append({"console": {"_0": output}})
    return {"toolCallState": {"_0": {
        "id": {"tool": {"_0": tool_id}},
        "imageTypeName": image,
        "kind": {"execute": {"command": command}},
        "name": name,
        "resultContentState": {"attributedContent": {"_0": runs}},
        "resultDetailStates": details,
        "showHeaderPath": False,
        "status": "completed",
        "subActivityStates": [],
    }}}


def terminal_card(tool_id: str, command: str, output: str | None) -> ToolCallState:
    """Xcode's "Terminal Command" card."""
    return tool_card(tool_id, "Terminal Command", "apple.terminal", command, command_runs(command), output)


def generic_card(tool_id: str, title: str, summary: str, output: str | None) -> ToolCallState:
    """The tool card for a tool with no exact Xcode format: titled with the tool's name."""
    return tool_card(tool_id, title, GENERIC_TOOL_IMAGE, summary, [summary, PLAIN_RUN], (output or "")[:MAX_OUTPUT])


def build_response(items: list[TurnItem], tool_entry: ToolEntryBuilder
                   ) -> tuple[list[ResponseContent], list[SequenceEntry], bool, list[str]]:
    """Turn a provider's turn items into Xcode's
    (responseContent, responseContentSequence, isModification, names of tool calls that never finished)."""
    content: list[ResponseContent] = []
    sequence: list[SequenceEntry] = []
    unfinished: list[str] = []
    read_group: ToolCallGroupValue | None = None  # consecutive reads are shown as one group, like Xcode does
    is_modification = False
    for item in items:
        if isinstance(item, Text):
            text_entry, seq = text_state(item.category, item.text)
            content.append(text_entry)
            sequence.append(seq)
            read_group = None
            continue
        entry = tool_entry(item)
        if entry is None:
            unfinished.append(item.name)
            continue
        sequence.append({"tool": {"_0": item.id}})
        if "fileOperationState" in entry:
            file_entry: FileOperationState = entry  # type: ignore[assignment]
            operation = file_entry["fileOperationState"]["_0"]["operationKind"]
            if operation == "read":
                if read_group is None:
                    read_group = {"groupKey": {"fileOperation": {"_0": "read"}}, "members": []}
                    content.append({"toolCallGroupState": {"_0": read_group}})
                read_group["members"].append(file_entry)
                continue
            is_modification = is_modification or operation in ("added", "modified", "deleted")
        read_group = None
        content.append(entry)
    return content, sequence, is_modification, unfinished
