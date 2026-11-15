"""Xcode's coding-assistant settings that apply to all chats (shared by all providers)."""

from __future__ import annotations

from typing import Literal, cast

from .util import run

# Xcode's permission menu (Manual / Auto), stored in Xcode's preferences:
#   defaults read com.apple.dt.Xcode IDEChatAgentPermissionMode
# Values (IDEIntelligenceChat.AgentPermissionMode): "standard" (Manual), "auto" (Auto),
# and "dontAsk" / "bypassPermissions" (options Xcode hides by default).
PermissionMode = Literal["standard", "auto", "dontAsk", "bypassPermissions"]
PERMISSION_MODES: tuple[PermissionMode, ...] = ("standard", "auto", "dontAsk", "bypassPermissions")

# The --permission-mode override: Xcode's menu items.
OverrideMode = Literal["manual", "auto"]
OVERRIDE_MODES: dict[OverrideMode, PermissionMode] = {"manual": "standard", "auto": "auto"}


def agent_permission_mode() -> PermissionMode:
    """Xcode's current permission mode; "standard" (Manual) if it is not set."""
    value = (run(["defaults", "read", "com.apple.dt.Xcode", "IDEChatAgentPermissionMode"]) or "").strip()
    return cast(PermissionMode, value) if value in PERMISSION_MODES else "standard"
