# lark-suite — Lark Suite (Feishu) productivity APIs

Vendor implementation of the channel-tool's vendor-action contract for
Lark Suite request/reply features (docs, sheets, calendar, tasks,
drive, wiki, contacts).

The MESSAGING half of the Lark/Feishu integration lives in-binary
(`src/claw/channels/feishu.nim`) because it needs a persistent
connection to the Lark event stream. This skill covers the
PRODUCTIVITY half — pure HTTP request/reply wrapped through `lark-cli`.

Both halves share the same lark-cli subprocess binary and config
directory (`<NIMCLAW_DIR>/channels/feishu/lark-cli-<APP_ID>/`).

## Setup

1. Configure a Feishu / Lark app (registers the credentials used by
   both messaging and this skill):
   ```bash
   claw channel add feishu <APP_ID> <APP_SECRET>
   ```

2. Install this skill in your deployment's BASE.nims:
   ```nim
   skill "lark-suite"
   ```

3. Rebuild and start the gateway. The skill auto-compiles to
   `workspace/skills/lark-suite/bin/lark-suite` and registers via MCP
   at gateway boot. The framework's MCP scan picks it up.

## Verifying

```bash
# Confirm the MCP tools registered
claw tools list | grep mcp_lark-suite_

# Should see:
#   mcp_lark-suite_docs_create
#   mcp_lark-suite_docs_fetch
```

## Agent-facing usage (via channel tool)

```
# Create a Lark Doc and get the URL
channel docs vendor=lark-suite op=create args={title: "May Report",
                                                markdown: "# Summary..."}

# Fetch a doc's content
channel docs vendor=lark-suite op=fetch  args={url: "https://..."}
```

The vendor name (`lark-suite`) is the only Lark-specific bit in the
agent's call. A Notion or Google Workspace vendor skill implementing
the same contract would just change the `vendor=` arg.

## Adding more operations

Each new operation = one `mcpTool: proc <op>(...): JsonNode` block in
`src/lark-suite.nim`. The proc body invokes `lark-cli` and parses the
output. The MCP framework auto-generates the JSON schema from the
proc signature.

Likely candidates by priority:
- `sheets_read` (sheet_id, range)
- `sheets_write` (sheet_id, range, values)
- `calendar_create_event` (calendar_id, title, start, end, attendees)
- `calendar_list_events` (calendar_id, from, to)
- `tasks_create` (title, assignee, due_date)
- `tasks_list` ([assignee])
- `drive_upload` (path, parent_folder_id?)
- `wiki_create_page` (space_id, title, markdown)

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
