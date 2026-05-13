## todo — the BATCHED leg of the focus / schedule / todo trio.
##
## Untimed queue at <office>/notes/todo.jsonl. Items appended by `defer`
## become pending; the heartbeat scans them and surfaces in the agent's
## prompt. `done` writes a tombstone and verifies the item is no longer
## in `pending()` before returning success (closes the say-do gap on
## the mark-done verb).
##
## Choose by use case (sibling tools):
##   - "do at next heartbeat, untimed"      → todo defer / done       (this tool)
##   - "fire at a specific time / date"     → schedule add (cron + notes.org backends)
##   - "do this NOW with a constrained hat" → focus
##
## Calendar-style (date-tagged) scheduling moved to the `schedule` tool
## as `action=add due=...` (notes.org backend) and `action=complete`.

import std/[asyncdispatch, json, tables, strutils]
import ../types
import ../spec
import ../../agent/todo

const ToolSpec* = spec(
  name = "todo",
  description = "Untimed batch queue (defer/done). Heartbeat scans pending items and surfaces them in your prompt. For time-anchored work use the `schedule` tool; for immediate constrained work use `focus`.",
  tags = @["agent", "core"],
  domain = "agent",
  default = true,
  heartbeatSafe = true,
  category = "self-management",
)

type
  TodoTool* = ref object of ContextualTool
    officeDir*: string

proc newTodoTool*(officeDir: string): TodoTool =
  TodoTool(officeDir: officeDir)

method name*(t: TodoTool): string = "todo"

method description*(t: TodoTool): string =
  "The BATCHED leg of the focus / schedule / todo trio — untimed queue " &
  "at <office>/notes/todo.jsonl, surfaced on every heartbeat.\n\n" &
  "Actions:\n" &
  "  defer  — push an untimed item to your queue (processed at next " &
            "heartbeat). Requires summary.\n" &
  "  done   — close a queue item by id (verifies the tombstone is " &
            "visible before returning). Requires id.\n\n" &
  "For time-anchored work (specific date/time, recurrence, calendar " &
  "tags), use `schedule`. For immediate constrained-tool work, use " &
  "`focus`."

method parameters*(t: TodoTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["defer", "done"],
        "description": "Operation to perform. Untimed only — for time-anchored work use the `schedule` tool."
      },
      "summary": {
        "type": "string",
        "description": "One-line description (defer)."
      },
      "body": {
        "type": "string",
        "description": "Optional longer context (defer)."
      },
      "priority": {
        "type": "string",
        "enum": ["urgent", "normal", "low"],
        "description": "Defer priority (defaults to normal)."
      },
      "id": {
        "type": "string",
        "description": "Todo id from the heartbeat prompt's pending list, format `t-<8 hex>` (done action)."
      }
    },
    "required": %*["action"]
  }.toTable

# ── action handlers ───────────────────────────────────────────────

proc doDefer(t: TodoTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("summary"):
    return "Error: 'summary' is required for defer"
  let summary = args["summary"].getStr().strip()
  if summary.len == 0:
    return "Error: 'summary' must not be empty"
  let body = if args.hasKey("body"): args["body"].getStr() else: ""
  let priority =
    if args.hasKey("priority"): args["priority"].getStr().strip().toLowerAscii()
    else: "normal"
  if priority notin ["urgent", "normal", "low"]:
    return "Error: 'priority' must be one of: urgent, normal, low"

  let store = newTodoStore(t.officeDir)
  let id = store.append(
    source = "self_deferred",
    sourceID = "",
    summary = summary,
    body = body,
    priority = priority,
  )
  if id.len == 0:
    return "Error: failed to write todo entry (see gateway log)"
  return "Deferred to next heartbeat. id=" & id & ", priority=" & priority &
         ". Will appear in your todo queue on the next heartbeat tick."

proc doDone(t: TodoTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("id"):
    return "Error: 'id' is required for done"
  let id = args["id"].getStr().strip()
  if id.len == 0:
    return "Error: 'id' must not be empty"

  let store = newTodoStore(t.officeDir)
  if not store.markDone(id):
    return "Error: failed to write tombstone (see gateway log)"

  # Verification: re-load and confirm the id is no longer in pending.
  # Closes the say-do gap — return value reflects post-condition,
  # not just the syscall outcome.
  let verifyStore = newTodoStore(t.officeDir)
  for entry in verifyStore.pending():
    if entry.id == id:
      return "Error: tombstone written but item still appears in pending. " &
             "Likely a concurrent writer or store corruption — check " &
             (t.officeDir & "/notes/todo.jsonl")
  return "Verified todo " & id & " is no longer pending. " &
         "Will not reappear in future heartbeats."

method execute*(t: TodoTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.officeDir.len == 0:
    return "Error: tool not bound to an office workspace"
  if not args.hasKey("action"):
    return "Error: 'action' is required (defer | done). For time-anchored work use the `schedule` tool."
  let action = args["action"].getStr()
  case action
  of "defer":     return doDefer(t, args)
  of "done":      return doDone(t, args)
  of "schedule", "done_note":
    return "Error: action '" & action & "' moved to the `schedule` tool. " &
           "Use `schedule action=add due=... summary=...` for date-tagged " &
           "TODOs, or `schedule action=complete summary=...` to mark one done."
  else:
    return "Error: Unknown action '" & action &
           "'. Use: defer | done. (For time-anchored work use the `schedule` tool.)"
