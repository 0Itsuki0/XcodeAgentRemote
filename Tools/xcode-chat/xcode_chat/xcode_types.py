"""Types of Xcode's coding-assistant chat store files (conversation.plist, metadata.plist, the manifest, snapshots).

Swift enums with associated values are encoded as {"<case>": {"_0": <value>}}; that is where every `_0` comes from.
Only the parts this tool reads or writes are typed.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Literal, TypedDict, Union

# --- Model / provider ------------------------------------------------------------


class BuiltInProvider(TypedDict):
    _0: dict[str, dict[str, Any]]  # {"<provider name>": {}}, e.g. {"claude": {}}


class ProviderIdentifier(TypedDict):
    builtIn: BuiltInProvider


class ModelDefinition(TypedDict):
    modelIdentifier: str  # e.g. "claude-code"
    providerIdentifier: ProviderIdentifier


# assistantConfiguration (JSON stored as bytes): Swift `.agent(AgentConfiguration(sessionID:))`


class AgentConfiguration(TypedDict):
    sessionID: str


class AgentConfigurationBox(TypedDict):
    _0: AgentConfiguration


class AssistantConfiguration(TypedDict):
    agent: AgentConfigurationBox


# --- Ids -------------------------------------------------------------------------


class IDBox(TypedDict):
    _0: str


class ProseID(TypedDict):
    prose: IDBox  # a text block's UUID


class ToolID(TypedDict):
    tool: IDBox  # the agent's tool_use id


SequenceEntry = Union[ProseID, ToolID]

# --- Response content: text --------------------------------------------------------

TextCategory = Literal["thinking", "prose"]


class TextStateValue(TypedDict):
    category: TextCategory
    id: ProseID
    text: str


class TextStateBox(TypedDict):
    _0: TextStateValue


class TextState(TypedDict):
    textState: TextStateBox


# --- Response content: file card ---------------------------------------------------

OperationKind = Literal["added", "modified", "deleted", "read", "copied", "moved", "refreshIssues"]
ToolStatus = Literal["pending", "inProgress", "completed", "cancelled"]


class PathComponent(TypedDict):
    id: int
    imageTypeName: str  # SF Symbol, e.g. "folder"
    title: str


class HeaderPathState(TypedDict):
    primaryComponents: list[PathComponent]


class Segment(TypedDict):
    linesAdded: int
    linesRemoved: int
    sourceCode: str
    toolCallID: str


class FileSnapshot(TypedDict):
    absoluteFilePath: str
    content: str


class _FileOperationValueRequired(TypedDict):
    displayName: str
    filePath: str
    headerPathState: HeaderPathState
    id: ToolID
    language: str
    linesAdded: int
    linesRemoved: int
    operationKind: OperationKind
    segments: list[Segment]
    showHeaderPath: bool
    sourceCode: str
    status: ToolStatus


class FileOperationValue(_FileOperationValueRequired, total=False):
    preToolCallSnapshot: FileSnapshot   # whole file before an edit
    postToolCallSnapshot: FileSnapshot  # whole file after an edit


class FileOperationBox(TypedDict):
    _0: FileOperationValue


class FileOperationState(TypedDict):
    fileOperationState: FileOperationBox


# --- Response content: tool card ---------------------------------------------------

# SwiftUI AttributedString, encoded as runs: [text, attributes, text, attributes, ...]
AttributedRuns = List[Union[str, Dict[str, Any]]]


class AttributedBox(TypedDict):
    _0: AttributedRuns


class AttributedContent(TypedDict):
    attributedContent: AttributedBox


class StringBox(TypedDict):
    _0: str


class ExecuteKindValue(TypedDict):
    command: str


class ExecuteKind(TypedDict):
    execute: ExecuteKindValue


class ProseDetail(TypedDict):
    prose: AttributedBox


class ConsoleDetail(TypedDict):
    console: StringBox


ResultDetail = Union[ProseDetail, ConsoleDetail]


class ToolCallValue(TypedDict):
    id: ToolID
    imageTypeName: str  # SF Symbol, e.g. "apple.terminal"
    kind: ExecuteKind
    name: str           # card title, e.g. "Terminal Command"
    resultContentState: AttributedContent
    resultDetailStates: list[ResultDetail]
    showHeaderPath: bool
    status: ToolStatus
    subActivityStates: list[Any]


class ToolCallBox(TypedDict):
    _0: ToolCallValue


class ToolCallState(TypedDict):
    toolCallState: ToolCallBox


# --- Response content: group of file cards ------------------------------------------


class GroupKeyValue(TypedDict):
    _0: OperationKind


class GroupKey(TypedDict):
    fileOperation: GroupKeyValue


class ToolCallGroupValue(TypedDict):
    groupKey: GroupKey
    members: list[FileOperationState]


class ToolCallGroupBox(TypedDict):
    _0: ToolCallGroupValue


class ToolCallGroupState(TypedDict):
    toolCallGroupState: ToolCallGroupBox


ToolEntry = Union[FileOperationState, ToolCallState]
ResponseContent = Union[TextState, FileOperationState, ToolCallState, ToolCallGroupState]

# --- conversation.plist ------------------------------------------------------------


class UserMessage(TypedDict):
    id: ProseID
    rawMessageText: str
    sentDate: datetime
    showDateSeparator: bool


class _TranscriptMessageRequired(TypedDict):
    deliveredMessages: dict[str, Any]
    finishedDate: datetime
    historyLogDate: datetime
    id: str
    isModification: bool
    responseContent: list[ResponseContent]
    responseContentSequence: list[SequenceEntry]
    startDate: datetime
    userMessage: UserMessage


class TranscriptMessage(_TranscriptMessageRequired, total=False):
    snapshotIdBefore: str
    snapshotIdAfter: str


class AssistantMessageBox(TypedDict):
    _0: str  # the transcript message id


class EntryState(TypedDict):
    assistantMessage: AssistantMessageBox


class _ConversationPlistRequired(TypedDict):
    assistantConfiguration: bytes  # JSON, see AssistantConfiguration
    assistantKind: str             # "agent"
    chatModelDefinitionId: ModelDefinition
    entryStates: list[EntryState]
    id: str
    name: str
    startDate: datetime
    transcriptMessages: list[TranscriptMessage]


class ConversationPlist(_ConversationPlistRequired, total=False):
    lastAppliedEntry: str


# --- metadata.plist / CodingAssistantManifest.plist -----------------------------------


class Metadata(TypedDict):
    chatModelDefinitionIdentifier: ModelDefinition
    conversationType: str  # "assistant"
    id: str
    lastActivityDate: datetime
    name: str
    startDate: datetime


Manifest = List[Metadata]

# --- Snapshots/<UUID>.plist ----------------------------------------------------------


class _SnapshotRequired(TypedDict):
    id: str
    date: datetime
    diffStaged: str
    diffUnstaged: str


class Snapshot(_SnapshotRequired, total=False):
    revision: str  # HEAD


class RepositoryURL(TypedDict):
    relative: str  # file:///path/to/repo/


class SnapshotFile(TypedDict):
    id: str
    # Swift [URL: Snapshot] encodes as a flat [key, value, ...] list.
    snapshots: list[Union[RepositoryURL, Snapshot]]
