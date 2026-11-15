"""What every provider (agent) implements."""

from __future__ import annotations

import json
from abc import ABC, abstractmethod
from typing import cast

from ..events import Emit
from ..settings import PermissionMode
from ..turn import ToolCall, TurnResult
from ..xcode_types import AssistantConfiguration, ModelDefinition, ToolEntry


class Provider(ABC):
    """One agent Xcode can run.

    `name` is the key Xcode stores under chatModelDefinitionId.providerIdentifier.builtIn._0 in conversation.plist.
    """

    name: str = ""
    model_identifier: str = ""

    def model_definition(self) -> ModelDefinition:
        """chatModelDefinitionId / chatModelDefinitionIdentifier for this provider's chats."""
        return {"modelIdentifier": self.model_identifier, "providerIdentifier": {"builtIn": {"_0": {self.name: {}}}}}

    # assistantConfiguration is Swift's encoding of `.agent(AgentConfiguration(sessionID:))`:
    # {"agent": {"_0": {"sessionID": "..."}}} (`_0` = the enum case's first unlabeled value).

    def assistant_configuration(self, session_id: str) -> bytes:
        configuration: AssistantConfiguration = {"agent": {"_0": {"sessionID": session_id}}}
        return json.dumps(configuration, separators=(",", ":")).encode()

    def session_id(self, assistant_configuration: bytes | None) -> str | None:
        """The agent session id stored in a chat's assistantConfiguration, or None."""
        if assistant_configuration is None:
            return None
        try:
            configuration = cast(AssistantConfiguration, json.loads(assistant_configuration))
            return configuration["agent"]["_0"]["sessionID"]
        except (KeyError, TypeError, ValueError):
            return None

    @abstractmethod
    def new_session_id(self) -> str:
        ...

    def session_cwd(self, session_id: str) -> str | None:
        """The folder the agent ran a session in (used to find the project of a store), or None."""
        return None

    @abstractmethod
    def run_turn(self, work_dir: str, session_id: str, resume: bool, prompt: str,
                 permission_mode: PermissionMode, emit: Emit) -> TurnResult:
        """Run one turn of the agent in `work_dir` without asking anything, streaming its output through `emit`.
        If the agent asks for permission to use a tool, stop there and return the request as `pending`."""

    @abstractmethod
    def tool_entry(self, call: ToolCall) -> ToolEntry | None:
        """Xcode transcript entry (see cards.py) for one of this provider's tool calls, or None if it never finished."""
