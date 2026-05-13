---
name: lark-suite
version: 0.1.0
description: "Lark Suite (Feishu's productivity platform — docs, sheets, calendar, tasks, drive, wiki, contacts) exposed as a vendor MCP server. Wraps the lark-cli subprocess. Reached by agents through `channel docs vendor=lark-suite op=create ...` etc. The MESSAGING half of Lark/Feishu (chat, react, threading) stays in-binary at channels/feishu.nim — that needs a persistent connection; this skill is request/reply only."
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

# lark-suite

Lark Suite is the productivity half of ByteDance's Lark / Feishu
platform — Docs, Sheets, MeetingMinutes, Calendar, Tasks, Drive,
Wiki, Contacts. (The MESSENGER half — chat, react, edit, threading —
is a separate concern and ships as the in-binary `channels/feishu.nim`
because it needs a persistent connection.)

This skill exposes the request/reply Lark Suite APIs as a vendor MCP
server, mirroring the `vendor-sungrow` pattern used by the solar
adapter. Agents reach the features through the unified `channel` tool:

```
channel docs vendor=lark-suite op=create   args={title: "May Report",
                                                 markdown: "..."}
channel docs vendor=lark-suite op=fetch    args={url: "https://..."}
```

The vendor name (`lark-suite`) is the only Lark-specific bit in the
agent's call. A Notion or Google Workspace vendor skill implementing
the same `docs_create`/`docs_fetch` contract would only require the
agent to change `vendor=lark-suite` → `vendor=notion` (or
`vendor=google-workspace`).

## Why distribution-tier (alongside anygen)

Lark Suite is a productivity-platform integration — useful across many
templates (solar-power-station, customer-support, research-team,
marketing) the same way `anygen` is a useful cross-template content-
generation skill. Both belong in `res/distribution/skills/` rather
than being bundled with any single template.

## Setup

1. Configure a Feishu / Lark app:
   ```bash
   claw channel add feishu <APP_ID> <APP_SECRET>
   ```
   Credentials land in
   `<company>/channels/feishu/lark-cli-<APP_ID>/config.json`. Both
   the messaging channel and this productivity skill use that config.

2. Install in your deployment's BASE.nims:
   ```nim
   skill "lark-suite"
   ```

3. Rebuild (`claw co update`). The skill auto-compiles to
   `workspace/skills/lark-suite/bin/lark-suite` and the framework's
   MCP scan registers its tools at gateway boot.

## Verifying

```bash
claw tools list | grep mcp_lark-suite_

# Should see:
#   mcp_lark-suite_docs_create
#   mcp_lark-suite_docs_fetch
```

## Exposed tools (MCP)

| Tool | Args | Returns |
|---|---|---|
| `docs_create` | `title: string, markdown: string` | `{doc_url: string}` |
| `docs_fetch` | `url: string` | `{content: string, title: string}` |

Sheets / calendar / tasks / drive / wiki / contacts will land in
follow-up versions following the same `mcpTool: proc <op>(...):
JsonNode` shape. Each maps to a `lark-cli <subcommand>` invocation;
`lark-cli --help` documents the full surface.

## Auto-promotion via channel capabilities

The chat / mail tools also consult Feishu's capabilities (declared in
`channels/feishu.nim`'s `capabilities()`) — when content is too long
for plain text and the destination channel can host docs, they
automatically promote large messages to a Lark Doc and send the URL.
That auto-promotion uses this skill's `docs_create` under the hood.

## Limitations (starter implementation)

- Synchronous `lark-cli` subprocess invocation per call (no concurrent
  ops per server instance; the framework spawns multiple instances if
  needed for throughput).
- Auth tied to a single Feishu app per server; multi-app setups need
  parallel server instances or app-selection logic.
- Output parsing is conservative (extracts URL from last line for
  `docs_create`, returns full stdout for `docs_fetch`). Vendor API
  changes may require parser updates.
