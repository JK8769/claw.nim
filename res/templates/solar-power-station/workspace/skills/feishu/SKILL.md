---
name: feishu
version: 0.1.0
description: "Feishu / Lark vendor implementation — request/reply productivity APIs (docs / sheets / calendar / tasks). Wraps the lark-cli subprocess via MCP stdio. Reached by agents through `channel docs vendor=feishu op=create ...` etc.; the messaging side stays in-binary at channels/feishu.nim (needs persistent connection)."
contract_version: 1
requires:
  tools: []
  deps:
    - package: nim
      manager: system
  env:
    - FEISHU_APP_ID
    - FEISHU_APP_SECRET
---

# vendor/feishu

Feishu / Lark vendor implementation of the channel-tool's vendor-action
contract. Exposes Lark's request/reply productivity features so agents
reach them through the unified `channel` tool surface — no agent-facing
vendor-specific tool name leaks.

## Architecture

Two halves of the Lark integration:

- **`channels/feishu.nim`** (in-binary): MESSAGING — send / receive /
  react / threading. Needs a persistent connection to Lark's event
  stream; lifecycle owned by the gateway.
- **This skill** (out-of-process MCP server): PRODUCTIVITY APIs — docs,
  sheets, calendar, tasks, drive, wiki, contacts. Pure request/reply,
  no persistent connection needed; vendor-skill MCP server is the right
  fit (mirrors the solar `vendor-sungrow` pattern).

Both halves share the same lark-cli subprocess binary and config
directory (`<NIMCLAW_DIR>/channels/feishu/lark-cli-<APP_ID>/`).

## Exposed tools (registered as `mcp_feishu_*`)

| Tool | Args | Returns |
|---|---|---|
| `docs_create` | `title: string, markdown: string` | `{doc_url: string}` — Lark Doc URL |
| `docs_fetch` | `url: string` | `{content: string, title: string}` — doc body |

More operations (sheets, calendar, tasks, drive, wiki, contacts) will
land in subsequent versions following the same pattern. Each tool is
a thin wrapper around a `lark-cli` subprocess invocation.

## Agent-facing surface

Agents reach these via the unified `channel` tool — they NEVER call
`mcp_feishu_*` directly:

```
channel docs vendor=feishu op=create   args={title: "May Report", markdown: "..."}
  → routes to mcp_feishu_docs_create
  → returns the doc_url

channel docs vendor=feishu op=fetch    args={url: "https://..."}
  → routes to mcp_feishu_docs_fetch
  → returns the content
```

This keeps the agent surface vendor-neutral: a Notion or Google Docs
vendor skill could implement the same `docs_create`/`docs_fetch`
contract and the agent's call site stays the same — only the vendor=
arg changes.

## Auto-promotion via channel capabilities

The chat / mail tools also consult Feishu's capabilities (declared in
`channels/feishu.nim`'s `capabilities()`) — when content is too long
for plain text and the destination channel has docs available, they
automatically promote large messages to a Lark Doc and send the URL.
That auto-promote uses this skill's `docs_create` under the hood.

## Status

This is a **starter implementation** with `docs_create` and
`docs_fetch` only. It compiles + runs against a configured Feishu app.
Sheets / calendar / tasks / drive / wiki / contacts can be added by
following the same `mcpTool: proc <op>(...): JsonNode` shape.
