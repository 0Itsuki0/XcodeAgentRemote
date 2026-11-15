"""xcode-chat: run one Xcode coding-assistant turn and record it in Xcode's chat store.

usage:
  xcode-chat --project App.xcodeproj [--name TITLE] PROMPT                   # new chat (Claude)
  xcode-chat --project App.xcodeproj --conversation UUID PROMPT              # continue a chat
  xcode-chat --store App-<hash> --conversation UUID PROMPT                   # continue, by chat store folder
  ... --permission-mode manual|auto                                          # override Xcode's setting

Runs a single turn without asking anything and streams its output on stdout as JSON lines (see events.py),
ending with a "result" event. If the agent asks for permission to use a tool, the turn stops there
("permission_request" event, result status "permission_required"); what ran so far is saved.
Exit code 0, or 1 when the turn ended in an error.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass

from . import cards, settings, store
from .events import ResultEvent, StartEvent, TurnStatus, emit
from .providers import DEFAULT_PROVIDER, PROVIDERS, get_provider
from .settings import PermissionMode
from .util import fail, now


@dataclass
class Options:
    project: str | None
    store: str | None
    conversation: str | None
    name: str | None
    permission_mode: PermissionMode | None
    prompt: str


def parse_args() -> Options:
    parser = argparse.ArgumentParser(prog="xcode-chat", description="Run one Xcode coding-assistant turn.")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--project", help="path to the .xcodeproj or .xcworkspace")
    target.add_argument("--store", help="Xcode chat store folder, <ProjectName>-<hash> (name or path); needs --conversation")
    parser.add_argument("--conversation", help="UUID of an existing chat to continue")
    parser.add_argument("--name", help="chat title")
    parser.add_argument("--permission-mode", choices=list(settings.OVERRIDE_MODES),
                        help="override Xcode's Manual / Auto setting")
    parser.add_argument("prompt", nargs="+")
    args = parser.parse_args()
    if args.store and not args.conversation:
        parser.error("--store needs --conversation")
    mode = settings.OVERRIDE_MODES[args.permission_mode] if args.permission_mode else None
    return Options(project=args.project, store=args.store, conversation=args.conversation, name=args.name,
                   permission_mode=mode, prompt=" ".join(args.prompt))


def main() -> None:
    opts = parse_args()

    # Store and existing chat.
    project: str | None = None
    if opts.project:
        project = os.path.abspath(opts.project)
        if not os.path.exists(project):
            fail("no such project: " + project)
        store_dir = store.store_dir_for_project(project)
    else:
        store_dir = store.resolve_store_dir(opts.store or "")
        if not os.path.isdir(store_dir):
            fail("no such chat store: " + store_dir)

    conversation = store.Conversation.load(store_dir, opts.conversation) if opts.conversation else None
    if opts.conversation and conversation is None:
        fail("no conversation at " + store.Conversation.path(store_dir, opts.conversation))

    # Provider: the chat's own for an existing chat, the default for a new one.
    provider_name = conversation.provider_name if conversation else DEFAULT_PROVIDER
    provider = get_provider(provider_name)
    if provider is None:
        provider_identifier = conversation.model_definition.get("providerIdentifier") if conversation else None
        fail("conversation uses agent %r (providerIdentifier %s); supported: %s" % (
            provider_name, json.dumps(provider_identifier), ", ".join(PROVIDERS)))

    session_id: str
    if conversation is not None:
        existing_session = provider.session_id(conversation.assistant_configuration)
        if not existing_session:
            fail("conversation has no agent sessionID")
        session_id = existing_session
        if opts.name:
            conversation.data["name"] = opts.name
    else:
        session_id = provider.new_session_id()
        conversation = store.Conversation.create(store_dir, provider.model_definition(),
                                                 provider.assistant_configuration(session_id),
                                                 opts.name or opts.prompt[:40])

    if project is None:  # --store: find the project from the session's folder and the snapshots
        folders = [provider.session_cwd(session_id)] + store.snapshot_roots(store_dir)
        project = store.project_for_store(store_dir, [f for f in folders if f])
        if not project:
            fail("could not find the project file for " + store_dir)
    work_dir = os.path.dirname(project)
    resume = opts.conversation is not None
    permission_mode = opts.permission_mode or settings.agent_permission_mode()

    emit(StartEvent(conversation=conversation.id, session=session_id, provider=provider.name,
                    permission_mode=permission_mode, new_conversation=not resume))

    # One turn, like Xcode: snapshot, run the agent, snapshot, record.
    snapshot_before = store.write_snapshot(store_dir, work_dir)
    start_date = now()
    turn = provider.run_turn(work_dir, session_id, resume, opts.prompt, permission_mode, emit)
    finished_date = now()
    snapshot_after = store.write_snapshot(store_dir, work_dir)

    content, sequence, is_modification, unfinished = cards.build_response(turn.items, provider.tool_entry)
    conversation.append_turn(opts.prompt, start_date, finished_date, content, sequence, is_modification,
                             snapshot_before, snapshot_after)
    conversation.save()

    status: TurnStatus = "permission_required" if turn.pending else "error" if turn.is_error else "completed"
    emit(ResultEvent(status=status, conversation=conversation.id, session=session_id, result=turn.result,
                     pending=turn.pending, saved_to=conversation.directory, unfinished_tools=unfinished))
    sys.exit(1 if status == "error" else 0)
