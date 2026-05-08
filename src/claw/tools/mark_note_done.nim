## mark_note_done — flip a notes.org TODO entry to DONE.
##
## Pairs with `add_note_todo`. Used by the agent during a heartbeat
## when a past-due TODO surfaces in her prompt and she's processed
## it. Edits notes.org in place (read-modify-write, O(N) on the
## file size — fine for the rare close-out path).

import std/[asyncdispatch, json, tables, strutils]
import types
import ../agent/notes

type
  MarkNoteDoneTool* = ref object of ContextualTool
    workspace*: string

proc newMarkNoteDoneTool*(workspace: string): MarkNoteDoneTool =
  MarkNoteDoneTool(workspace: workspace)

method name*(t: MarkNoteDoneTool): string = "mark_note_done"

method description*(t: MarkNoteDoneTool): string =
  "Mark a notes.org TODO as done. The heartbeat prompt's past-due " &
  "section shows each TODO with its summary; pass the same summary " &
  "string here (case-sensitive) and the parser will find it and " &
  "flip TODO → DONE in place. Idempotent — closing an already-done " &
  "item is a no-op."

method parameters*(t: MarkNoteDoneTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "summary": {
        "type": "string",
        "minLength": 1,
        "description": "Exact summary of the TODO to close (the text shown in the heartbeat prompt's past-due section, between `TODO ` and the `<date>` tag if present)."
      }
    },
    "required": %*["summary"]
  }.toTable

method execute*(t: MarkNoteDoneTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("summary"):
    return "Error: Missing 'summary' parameter"
  let summary = args["summary"].getStr().strip()
  if summary.len == 0:
    return "Error: 'summary' must not be empty"
  if t.workspace.len == 0:
    return "Error: tool not bound to an office workspace"

  let store = newNotesStore(t.workspace)
  let entries = store.loadAll()
  var matchLine = -1
  for e in entries:
    if e.state == nsTodo and e.summary == summary:
      matchLine = e.lineNum
      break
  if matchLine < 0:
    return "Error: no TODO matching summary '" & summary & "'. " &
           "Either it's already DONE or the text doesn't exactly match. " &
           "Re-read your notes.org to find the exact summary text."
  if not store.rewriteFlippingState(matchLine, nsTodo, nsDone):
    return "Error: failed to rewrite notes.org (see gateway log)"
  return "Marked '" & summary & "' as DONE in notes.org. Will not " &
         "reappear in future heartbeat past-due lists."
