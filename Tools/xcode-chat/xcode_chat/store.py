"""Xcode's coding-assistant chat store, shared by all providers.

Layout (one store per workspace / project file):

    ~/Library/Developer/Xcode/UserData/CodingAssistant/<ProjectName>-<hash>/
        CodingAssistantManifest.plist      list of every chat's metadata
        <chat UUID>/conversation.plist     the chat: transcript entries, provider, assistantConfiguration
        <chat UUID>/metadata.plist         name, dates, provider
        Snapshots/<UUID>.plist             git state before / after each turn

Xcode reads this store only when the project is opened; a running Xcode does not pick up changes.
"""

from __future__ import annotations

import glob
import hashlib
import os
import plistlib
import urllib.parse
import uuid
from datetime import datetime
from typing import Any, Iterable, cast

from .util import now, run
from .xcode_types import (ConversationPlist, Manifest, Metadata, ModelDefinition, RepositoryURL, ResponseContent,
                          SequenceEntry, Snapshot, SnapshotFile, TranscriptMessage)

STORE_ROOT: str = os.path.expanduser("~/Library/Developer/Xcode/UserData/CodingAssistant")


def new_id() -> str:
    return str(uuid.uuid4()).upper()


def read_plist(path: str) -> Any:
    """A plist's content, or None if it is missing or invalid."""
    try:
        with open(path, "rb") as f:
            return plistlib.load(f)
    except (OSError, plistlib.InvalidFileException):
        return None


def write_plist(obj: Any, path: str, binary: bool = False) -> None:
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        plistlib.dump(obj, f, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML, sort_keys=True)
    os.replace(tmp, path)


# --- Locating the store ----------------------------------------------------------


def xcode_path_hash(path: str) -> str:
    """Same hash Xcode uses for DerivedData / UserData folder names:
    MD5 of the workspace path, each 8-byte half written as 14 base-26 letters."""
    digest = hashlib.md5(path.encode()).digest()
    out = ""
    for half in (digest[:8], digest[8:]):
        value = int.from_bytes(half, "big")
        chars = [""] * 14
        for i in range(13, -1, -1):
            chars[i] = chr(ord("a") + value % 26)
            value //= 26
        out += "".join(chars)
    return out


def store_dir_for_project(project: str) -> str:
    """The store folder of a .xcodeproj / .xcworkspace: <ProjectName>-<hash of the project file path>."""
    name = os.path.splitext(os.path.basename(project))[0]
    return os.path.join(STORE_ROOT, name + "-" + xcode_path_hash(project))


def resolve_store_dir(store: str) -> str:
    """A store given by folder name (<ProjectName>-<hash>) or by path."""
    store = os.path.expanduser(store.rstrip("/"))
    return os.path.abspath(store if os.sep in store else os.path.join(STORE_ROOT, store))


def snapshot_roots(store_dir: str) -> list[str]:
    """The git repository roots recorded in a store's snapshots."""
    roots: list[str] = []
    for path in glob.glob(os.path.join(store_dir, "Snapshots", "*.plist")):
        snapshot_file = cast("SnapshotFile | None", read_plist(path))
        entries = snapshot_file.get("snapshots", []) if isinstance(snapshot_file, dict) else []
        if entries and isinstance(entries[0], dict) and "relative" in entries[0]:
            repository = cast(RepositoryURL, entries[0])
            roots.append(urllib.parse.unquote(urllib.parse.urlparse(repository["relative"]).path))
    return roots


def project_for_store(store_dir: str, folders: Iterable[str]) -> str | None:
    """Find the project file a store belongs to. The store name is <ProjectName>-<hash>, and the hash is
    one-way, so look in candidate folders, hash each project file there, and match."""
    name, _, path_hash = os.path.basename(store_dir).rpartition("-")
    for folder in dict.fromkeys(folders):
        for root, dirs, _ in os.walk(folder):
            for d in list(dirs):
                if d.endswith((".xcodeproj", ".xcworkspace")):
                    candidate = os.path.join(root, d)
                    if os.path.splitext(d)[0] == name and xcode_path_hash(candidate) == path_hash:
                        return candidate
                    dirs.remove(d)  # don't descend into project bundles
            dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("build", "DerivedData", "Pods", "node_modules")]
    return None


# --- Snapshots -------------------------------------------------------------------


def write_snapshot(store_dir: str, work_dir: str) -> str | None:
    """Record the git state of the project (like Xcode does before and after each turn); return its id."""
    top = (run(["git", "rev-parse", "--show-toplevel"], cwd=work_dir) or "").strip()
    if not top:
        return None
    snapshot: Snapshot = {
        "id": new_id(),
        "date": now(),
        "diffStaged": run(["git", "diff", "--cached"], cwd=top) or "",
        "diffUnstaged": run(["git", "diff"], cwd=top) or "",
    }
    revision = (run(["git", "rev-parse", "HEAD"], cwd=top) or "").strip()
    if revision:
        snapshot["revision"] = revision
    snapshot_id = new_id()
    snapshots_dir = os.path.join(store_dir, "Snapshots")
    os.makedirs(snapshots_dir, exist_ok=True)
    snapshot_file: SnapshotFile = {
        "id": snapshot_id,
        "snapshots": [{"relative": "file://" + top.rstrip("/") + "/"}, snapshot],
    }
    write_plist(snapshot_file, os.path.join(snapshots_dir, snapshot_id + ".plist"), binary=True)
    return snapshot_id


# --- Conversations ---------------------------------------------------------------


class Conversation:
    """One chat: <store>/<chat UUID>/conversation.plist (+ metadata.plist and its manifest entry)."""

    def __init__(self, store_dir: str, conv_id: str, data: ConversationPlist) -> None:
        self.store_dir: str = store_dir
        self.id: str = conv_id
        self.data: ConversationPlist = data
        self.last_activity: datetime | None = None

    @property
    def directory(self) -> str:
        return os.path.join(self.store_dir, self.id)

    @staticmethod
    def path(store_dir: str, conv_id: str) -> str:
        return os.path.join(store_dir, conv_id.upper(), "conversation.plist")

    @classmethod
    def load(cls, store_dir: str, conv_id: str) -> Conversation | None:
        data = read_plist(cls.path(store_dir, conv_id))
        return cls(store_dir, conv_id.upper(), cast(ConversationPlist, data)) if isinstance(data, dict) else None

    @classmethod
    def create(cls, store_dir: str, model_definition: ModelDefinition, assistant_configuration: bytes,
               name: str) -> Conversation:
        conv_id = new_id()
        return cls(store_dir, conv_id, {
            "assistantConfiguration": assistant_configuration,
            "assistantKind": "agent",
            "chatModelDefinitionId": model_definition,
            "entryStates": [],
            "id": conv_id,
            "name": name,
            "startDate": now(),
            "transcriptMessages": [],
        })

    @property
    def model_definition(self) -> ModelDefinition:
        return self.data["chatModelDefinitionId"]

    @property
    def provider_name(self) -> str | None:
        """The agent this chat uses: the key under providerIdentifier.builtIn._0."""
        builtin = self.model_definition.get("providerIdentifier", {}).get("builtIn", {}).get("_0", {})
        return next(iter(builtin), None)

    @property
    def assistant_configuration(self) -> bytes | None:
        return self.data.get("assistantConfiguration")

    @property
    def is_new(self) -> bool:
        return not self.data.get("transcriptMessages")

    def append_turn(self, prompt: str, start_date: datetime, finished_date: datetime,
                    response_content: list[ResponseContent], response_sequence: list[SequenceEntry],
                    is_modification: bool, snapshot_before: str | None, snapshot_after: str | None) -> None:
        entry_id = new_id()
        message: TranscriptMessage = {
            "deliveredMessages": {},
            "finishedDate": finished_date,
            "historyLogDate": start_date,
            "id": entry_id,
            "isModification": is_modification,
            "responseContent": response_content,
            "responseContentSequence": response_sequence,
            "startDate": start_date,
            "userMessage": {
                "id": {"prose": {"_0": new_id()}},
                "rawMessageText": prompt,
                "sentDate": start_date,
                "showDateSeparator": self.is_new,
            },
        }
        if snapshot_before:
            message["snapshotIdBefore"] = snapshot_before
        if snapshot_after:
            message["snapshotIdAfter"] = snapshot_after
        self.data["transcriptMessages"] = self.data.get("transcriptMessages", []) + [message]
        self.data["entryStates"] = self.data.get("entryStates", []) + [{"assistantMessage": {"_0": entry_id}}]
        self.data["lastAppliedEntry"] = entry_id
        self.last_activity = finished_date

    def save(self) -> None:
        """Write conversation.plist, metadata.plist and this chat's entry in the store's manifest."""
        metadata: Metadata = {
            "chatModelDefinitionIdentifier": self.model_definition,
            "conversationType": "assistant",
            "id": self.id,
            "lastActivityDate": self.last_activity or now(),
            "name": self.data.get("name", ""),
            "startDate": self.data.get("startDate", now()),
        }
        os.makedirs(self.directory, exist_ok=True)
        write_plist(self.data, os.path.join(self.directory, "conversation.plist"))
        write_plist(metadata, os.path.join(self.directory, "metadata.plist"))

        manifest_path = os.path.join(self.store_dir, "CodingAssistantManifest.plist")
        existing = cast("Manifest | None", read_plist(manifest_path)) or []
        manifest: Manifest = [m for m in existing if m.get("id") != self.id] + [metadata]
        write_plist(manifest, manifest_path)
