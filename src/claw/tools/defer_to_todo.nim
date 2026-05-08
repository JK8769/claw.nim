## defer_to_todo — agent's self-defer tool. Lets an agent push an
## item into her own todo queue (`<office>/notes/todo.jsonl`) for
## processing at her next heartbeat tick.
##
## Use case: agent is mid-conversation with the user, recognises a
## task that's better batched ("review my Q3 forecast methodology
## next Tuesday") rather than handled immediately. The agent calls
## `defer_to_todo(summary="...")` and continues. At her next
## heartbeat, the dispatcher reads todo.jsonl and includes the item
## in her gather phase.
##
## Distinct from `cron`/`schedule` (which fires a scheduled
## one-shot) and from `notes.org` `<date>` tags (which are
## time-specific scheduled future-state). defer_to_todo is for
## **untimed batch deferral** — "do at next heartbeat, whenever
## that happens to be."

import std/[asyncdispatch, json, tables, strutils]
import types
import ../agent/todo

type
  DeferToTodoTool* = ref object of ContextualTool
    workspace*: string

proc newDeferToTodoTool*(workspace: string): DeferToTodoTool =
  DeferToTodoTool(workspace: workspace)

method name*(t: DeferToTodoTool): string = "defer_to_todo"

method description*(t: DeferToTodoTool): string =
  "Defer an item to your own todo queue for processing at your next " &
  "heartbeat tick. Use when you recognise work that's better batched " &
  "than handled mid-conversation (e.g. \"check the inverter swap " &
  "schedule next week\", \"draft a response to Jerry's question on " &
  "the GBDT model\"). Do NOT use this for time-specific items — for " &
  "those, write a note in `notes/notes.org` with a `<date>` tag, or " &
  "use the `cron` tool. Untimed batch only."

method parameters*(t: DeferToTodoTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "summary": {
        "type": "string",
        "minLength": 1,
        "description": "One-line description of the deferred work. Be specific — future-you will read this without the current conversation context."
      },
      "body": {
        "type": "string",
        "description": "Optional longer context (paste of the relevant message, your reasoning for deferring, decision criteria for processing). Stays inline in the queue entry."
      },
      "priority": {
        "type": "string",
        "enum": ["urgent", "normal", "low"],
        "description": "Defaults to \"normal\". \"urgent\" surfaces it at the top of the next heartbeat's pending list."
      }
    },
    "required": %*["summary"]
  }.toTable

method execute*(t: DeferToTodoTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("summary"):
    return "Error: Missing 'summary' parameter"
  let summary = args["summary"].getStr().strip()
  if summary.len == 0:
    return "Error: 'summary' must not be empty"
  let body = if args.hasKey("body"): args["body"].getStr() else: ""
  let priority =
    if args.hasKey("priority"): args["priority"].getStr().strip().toLowerAscii()
    else: "normal"
  if priority notin ["urgent", "normal", "low"]:
    return "Error: 'priority' must be one of: urgent, normal, low"

  if t.workspace.len == 0:
    return "Error: tool not bound to an office workspace"

  let store = newTodoStore(t.workspace)
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
