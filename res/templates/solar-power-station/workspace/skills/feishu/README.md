# vendor/feishu — Feishu / Lark productivity APIs

Vendor implementation of the channel-tool's vendor-action contract for
Feishu / Lark request/reply features (docs, sheets, calendar, tasks).

The messaging half of the Lark integration lives in-binary
(`src/claw/channels/feishu.nim`) because it needs a persistent
connection to the Lark event stream. This skill covers the
request/reply half — pure HTTP calls wrapped through `lark-cli`.

## Setup

1. Configure a Feishu app:
   ```bash
   claw channel add feishu <APP_ID> <APP_SECRET>
   ```
   This writes credentials to `<company>/channels/feishu/lark-cli-<APP_ID>/config.json`.

2. Install this skill in your deployment's BASE.nims:
   ```nim
   skill "feishu"
   ```

3. Rebuild and start the gateway. The skill auto-compiles to
   `workspace/skills/feishu/bin/feishu` and registers via MCP at
   gateway boot. The framework's MCP scan picks it up.

## Verifying

```bash
# Confirm the MCP tools registered
claw tools list | grep mcp_feishu_

# Should see:
#   mcp_feishu_docs_create
#   mcp_feishu_docs_fetch
```

## Agent-facing usage (via channel tool)

```
# Create a Lark Doc and get the URL
channel docs vendor=feishu op=create args={title: "May Report",
                                           markdown: "# Summary..."}

# Fetch a doc's content
channel docs vendor=feishu op=fetch args={url: "https://..."}
```

The vendor name (`feishu`) is the only Feishu-specific bit in the
agent's call. A Notion or Google Docs vendor skill implementing the
same contract would just change `vendor=feishu` → `vendor=notion`.

## Adding more operations

Each new operation = one `mcpTool: proc <op>(...): JsonNode` block in
`src/feishu.nim`. The proc body invokes `lark-cli` and parses the
output. The MCP framework auto-generates the JSON schema from the
proc signature.

Likely candidates by priority:
- `sheets_read` (sheet_id, range)
- `sheets_write` (sheet_id, range, values)
- `calendar_create_event` (calendar_id, title, start, end, attendees)
- `calendar_list_events` (calendar_id, from, to)
- `tasks_create` (title, assignee, due_date)
- `tasks_list` ([assignee])

Each maps to a `lark-cli <subcommand>` invocation; check `lark-cli
--help` for the full surface.

## Limitations

- Synchronous `lark-cli` subprocess invocation — no concurrent ops
  per server instance. For high-throughput use, multiple agents can
  invoke in parallel (each gets its own MCP server process).
- Auth tied to a single Feishu app — multi-app deployments need
  multiple instances or app-selection logic in the skill.
- Output parsing is conservative (extracts URL from last line for
  docs_create, returns full stdout for docs_fetch). Vendor-API
  changes may require parser updates.
