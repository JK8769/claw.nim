## mark_todo_done — close a todo entry by id once the agent has
## processed it.
##
## The pair to `defer_to_todo`: defer adds an item to the queue,
## mark_todo_done removes it. Without this tool the queue would
## grow forever — items appended by mail-arrival, peer
## delegate-deferred, or agent self-defer would never get cleared.
##
## Underlying storage is append-only with last-wins semantics
## (see `agent/todo.nim`): marking done appends a tombstone line
## with the same id and `done: true`. Idempotent — re-marking is
## just another append.

import std/[asyncdispatch, json, tables, strutils]
import types
import ../agent/todo

type
  MarkTodoDoneTool* = ref object of ContextualTool
    workspace*: string

proc newMarkTodoDoneTool*(workspace: string): MarkTodoDoneTool =
  MarkTodoDoneTool(workspace: workspace)

method name*(t: MarkTodoDoneTool): string = "mark_todo_done"

method description*(t: MarkTodoDoneTool): string =
  "Close a todo entry once you've processed it. Pass the `id` from " &
  "the heartbeat prompt's `## Pending TODO` section. Idempotent — " &
  "marking an already-closed item is a no-op. Use this every time " &
  "you finish handling an item from the queue, otherwise the same " &
  "item appears in every future heartbeat tick."

method parameters*(t: MarkTodoDoneTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "id": {
        "type": "string",
        "minLength": 1,
        "description": "The todo id, format `t-<8 hex>`. Visible in the heartbeat prompt's pending-todo section as `id=t-...`."
      }
    },
    "required": %*["id"]
  }.toTable

method execute*(t: MarkTodoDoneTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("id"):
    return "Error: Missing 'id' parameter"
  let id = args["id"].getStr().strip()
  if id.len == 0:
    return "Error: 'id' must not be empty"
  if t.workspace.len == 0:
    return "Error: tool not bound to an office workspace"

  let store = newTodoStore(t.workspace)
  if not store.markDone(id):
    return "Error: failed to write tombstone (see gateway log)"
  return "Marked todo " & id & " as done. Will not reappear in future heartbeats."
