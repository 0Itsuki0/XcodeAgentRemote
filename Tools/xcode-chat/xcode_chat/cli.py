"""xcode-chat: run one Xcode coding-assistant turn and record it in Xcode's chat store.

usage:
  xcode-chat --project App.xcodeproj [--name TITLE] PROMPT                   # new chat (Claude)
  xcode-chat --project App.xcodeproj --conversation UUID PROMPT              # continue a chat
  xcode-chat --store App-<hash> --conversation UUID PROMPT                   # continue, by chat store folder
  ... --permission-mode manual|auto                                          # override Xcode's setting

Parameters:
  PROMPT
      The message to send. Everything after the options, joined with spaces.

  --project PATH
      The project the chat belongs to: the .xcodeproj or .xcworkspace file Xcode has open.
      Used for two things:
      - Xcode's chat store for it: ~/Library/Developer/Xcode/UserData/CodingAssistant/<ProjectName>-<hash>/
        (<hash> is computed from this exact path, so pass the same file Xcode opened).
      - The folder the agent runs in: the folder that contains the project file.
      Either --project or --store is required, not both.

  --store NAME_OR_PATH
      Instead of --project: the chat store folder itself, <ProjectName>-<hash>, as a folder name
      (looked up under ~/Library/Developer/Xcode/UserData/CodingAssistant/) or a full path.
      The project file is found from the chat's agent session and its snapshots.
      Only for an existing chat, so it needs --conversation.

  --conversation UUID
      The Xcode chat to continue: Xcode's chat UUID (the chat's folder name in the store,
      e.g. D868CB20-1251-4ECC-9047-041C449419CB), NOT the agent's session id.
      The agent session to resume is read from that chat's conversation.plist (assistantConfiguration).
      The chat's agent (provider) is also read from there; only "claude" is supported.
      Omit it to start a new chat (Claude) in the project.

  --name TITLE
      The chat's title as shown in Xcode. New chat: defaults to the first 40 characters of the prompt.
      Existing chat: renames it. Omit to keep the current title.

  --permission-mode manual|auto
      Overrides Xcode's Manual / Auto setting (Xcode's preferences, IDEChatAgentPermissionMode) for this turn.
      Omit to use Xcode's current setting.
      - manual: the agent asks before tools that change something; the turn stops at that request.
      - auto: the agent decides by itself.

Output:
  Runs a single turn without asking anything and streams its output on stdout as JSON lines (see events.py),
  ending with a "result" event. If the agent asks for permission to use a tool, the turn stops there
  ("permission_request" event, result status "permission_required"); what ran so far is saved.
  Errors before the turn starts (bad project, unknown chat, ...) go to stderr.
  Exit code 0, or 1 when the turn ended in an error or could not start.
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
    parser = argparse.ArgumentParser(
        prog="xcode-chat",
        description="Run one Xcode coding-assistant turn and record it in Xcode's chat store. "
                    "Streams the turn as JSON lines on stdout, ending with a \"result\" event.")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument(
        "--project", metavar="PATH",
        help="the .xcodeproj / .xcworkspace Xcode has open. Picks Xcode's chat store for it "
             "(<ProjectName>-<hash of this path>) and runs the agent in the folder containing it")
    target.add_argument(
        "--store", metavar="NAME_OR_PATH",
        help="instead of --project: the chat store folder <ProjectName>-<hash> (folder name or full path). "
             "The project is found from the chat's session and snapshots. Needs --conversation")
    parser.add_argument(
        "--conversation", metavar="UUID",
        help="Xcode's chat UUID to continue (the chat's folder name in the store), not the agent's session id. "
             "Omit to start a new chat")
    parser.add_argument(
        "--name", metavar="TITLE",
        help="chat title shown in Xcode. New chat: defaults to the start of the prompt. Existing chat: renames it")
    parser.add_argument(
        "--permission-mode", choices=list(settings.OVERRIDE_MODES),
        help="override Xcode's Manual / Auto setting for this turn (default: Xcode's current setting)")
    parser.add_argument("prompt", nargs="+", metavar="PROMPT", help="the message to send")
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
