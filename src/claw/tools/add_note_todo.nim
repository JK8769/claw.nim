## add_note_todo — agent writes a TODO entry to her notes.org with
## optional `<date>` tag and recurrence.
##
## Pairs with `defer_to_todo` (untimed batch queue): use add_note_todo
## when the work has a SPECIFIC future time it should fire at.
## Untimed deferral goes through defer_to_todo (writes to todo.jsonl).
##
## Examples:
##   add_note_todo(summary="Quarterly review", due="2026-08-01 09:00")
##   add_note_todo(summary="Daily fleet check", due="2026-05-10 09:00", recur="++1d")
##   add_note_todo(summary="Read GBDT paper", body="https://...", due="2026-06-15")
##
## Output:
##   * TODO Quarterly review <2026-08-01 09:00>
##
## (For recurring) ↑ + ` ++1d` inside the date tag.

import std/[asyncdispatch, json, tables, strutils, times]
import types
import ../agent/notes

type
  AddNoteTodoTool* = ref object of ContextualTool
    workspace*: string

proc newAddNoteTodoTool*(workspace: string): AddNoteTodoTool =
  AddNoteTodoTool(workspace: workspace)

method name*(t: AddNoteTodoTool): string = "add_note_todo"

method description*(t: AddNoteTodoTool): string =
  "Schedule a future TODO with a specific due date/time. Writes to " &
  "your `notes/notes.org` as an org-mode-in-markdown headline. Use " &
  "this when the user asks for something at a specific time " &
  "(\"review my report next Monday\", \"daily fleet check at 9am\"). " &
  "For untimed batch work that should be processed at your next " &
  "heartbeat, use `defer_to_todo` instead."

method parameters*(t: AddNoteTodoTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "summary": {
        "type": "string",
        "minLength": 1,
        "description": "One-line description of the TODO. Be specific — future-you will read this without the current conversation context."
      },
      "due": {
        "type": "string",
        "description": "Due time. ISO-ish: \"2026-08-01\" (date only, fires on next heartbeat after that date) or \"2026-08-01 09:00\" (specific time, fires at exactly that time via the notes-watcher). Use the agent's local timezone."
      },
      "recur": {
        "type": "string",
        "description": "Optional recurrence after the first fire. Format: ++<count><unit>, where unit is d/w/mo/y. Examples: \"++1d\" (daily), \"++1w\" (weekly), \"++3mo\" (every 3 months). Omit for one-off TODOs."
      },
      "body": {
        "type": "string",
        "description": "Optional longer context — paste of the original ask, your reasoning, decision criteria. Stays inline under the headline."
      }
    },
    "required": %*["summary", "due"]
  }.toTable

proc validateDue(due: string): tuple[ok: bool, error: string] =
  let trimmed = due.strip()
  if trimmed.len == 0: return (false, "'due' must not be empty")
  try:
    if trimmed.contains(' '):
      discard parse(trimmed, "yyyy-MM-dd HH:mm", local())
    else:
      discard parse(trimmed, "yyyy-MM-dd", local())
    return (true, "")
  except CatchableError as e:
    return (false, "'due' must be \"yyyy-MM-dd\" or \"yyyy-MM-dd HH:mm\" (got: " & due & "): " & e.msg)

proc validateRecur(recur: string): tuple[ok: bool, error: string] =
  if recur.len == 0: return (true, "")
  if not recur.startsWith("++"):
    return (false, "'recur' must start with ++ (got: " & recur & ")")
  let rest = recur[2..^1]
  if rest.len < 2:
    return (false, "'recur' must be ++<count><unit> (got: " & recur & ")")
  var n = ""
  var unit = ""
  for ch in rest:
    if ch in {'0'..'9'}: n.add(ch)
    else: unit.add(ch)
  if n.len == 0 or unit notin ["d", "w", "mo", "y"]:
    return (false, "'recur' unit must be one of: d, w, mo, y (got: " & unit & ")")
  return (true, "")

method execute*(t: AddNoteTodoTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("summary"):
    return "Error: Missing 'summary' parameter"
  if not args.hasKey("due"):
    return "Error: Missing 'due' parameter — use defer_to_todo for untimed work"
  let summary = args["summary"].getStr().strip()
  let due = args["due"].getStr().strip()
  if summary.len == 0:
    return "Error: 'summary' must not be empty"
  let dueCheck = validateDue(due)
  if not dueCheck.ok: return "Error: " & dueCheck.error
  let recur = if args.hasKey("recur"): args["recur"].getStr().strip() else: ""
  let recurCheck = validateRecur(recur)
  if not recurCheck.ok: return "Error: " & recurCheck.error
  let body = if args.hasKey("body"): args["body"].getStr().strip() else: ""

  if t.workspace.len == 0:
    return "Error: tool not bound to an office workspace"

  # Compose org-mode headline. Bracket-form: `<YYYY-MM-DD HH:MM ++1d>`.
  var dateTag = "<" & due
  if recur.len > 0:
    dateTag.add(" " & recur)
  dateTag.add(">")
  let headline = "* TODO " & summary & " " & dateTag

  let store = newNotesStore(t.workspace)
  if not store.appendHeadline(headline, body):
    return "Error: failed to write to notes.org (see gateway log)"
  return "Wrote TODO to notes.org: " & headline & "\n" &
         "It will fire at " & due &
         (if recur.len > 0: " (recurring " & recur & ")" else: "") &
         ". The notes-watcher will pick it up; until then it shows in " &
         "your notes.org as untimed-from-now context."
