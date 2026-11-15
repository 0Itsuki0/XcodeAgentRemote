// Prints what the official Agent SDK's getSessionMessages returns for one session transcript, as JSON,
// summarized to what SessionHistoryTests compares: message type, ids, and content blocks (type + tool id/name).
// usage: node getSessionMessages.mjs <CLAUDE_CONFIG_DIR>/projects/<project-dir>/<sessionId>.jsonl [--system]
// (run `npm install` in this folder first)

import path from "node:path";

const file = path.resolve(process.argv[2] ?? "");
const includeSystemMessages = process.argv.includes("--system");
// The SDK finds sessions under $CLAUDE_CONFIG_DIR/projects; set it before loading the SDK.
process.env.CLAUDE_CONFIG_DIR = path.dirname(path.dirname(path.dirname(file)));
const { getSessionMessages } = await import("@anthropic-ai/claude-agent-sdk");

function blocks(message) {
    if (message == null) return null;
    if (typeof message.content === "string") return [{ type: "text", id: null, name: null }];
    return message.content.map((b) => ({ type: b.type, id: b.id ?? b.tool_use_id ?? null, name: b.name ?? null }));
}

const messages = await getSessionMessages(path.basename(file, ".jsonl"), { includeSystemMessages });
console.log(JSON.stringify(messages.map((m) => ({
    type: m.type,
    uuid: m.uuid,
    session_id: m.session_id,
    blocks: blocks(m.message),
}))));
