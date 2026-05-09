## todo — single tool for the agent's todo queue and notes.org TODOs.
##
## Replaces four split tools: defer_to_todo, mark_todo_done,
## add_note_todo, mark_note_done.
##
## Two storage backends, mirrored as paired actions:
##
##   defer / done       → <office>/notes/todo.jsonl
##                        Untimed batch queue. Items appended by
##                        `defer` become pending; `done` writes a
##                        tombstone and verifies the item is no
##                        longer in `pending()` before returning
##                        success (closes the say-do gap on the
##                        mark-done verb).
##
##   schedule / done_note → <office>/notes/notes.org
##                          Time-specific TODOs as org-mode-in-
##                          markdown headlines. `schedule` writes
##                          `* TODO ... <date ++recur>`; `done_note`
##                          flips the state to DONE in place.
##
## Choose by use case:
##   - "do at next heartbeat, untimed" → action=defer
##   - "fire at a specific time"        → action=schedule
##   - "I just processed queue item X"  → action=done id=...
##   - "I just processed past-due X"    → action=done_note summary=...

import std/[asyncdispatch, json, tables, strutils, times, os]
import ../types
import ../spec
import ../../agent/todo

const ToolSpec* = spec(
  name = "todo",
  description = "manage your todo queue (defer/done) and time-scheduled TODOs (schedule/done_note); done verifies tombstone landed",
  tags = @["agent", "core"],
  domain = "agent",
  default = true,
  heartbeatSafe = true,
  category = "self-management",
)
import ../../agent/notes

type
  TodoTool* = ref object of ContextualTool
    officeDir*: string

proc newTodoTool*(officeDir: string): TodoTool =
  TodoTool(officeDir: officeDir)

method name*(t: TodoTool): string = "todo"

method description*(t: TodoTool): string =
  "Manage your own todo queue and time-scheduled TODOs.\n\n" &
  "Actions:\n" &
  "  defer     — push an untimed item to your todo queue " &
  "(processed at next heartbeat). Requires summary.\n" &
  "  done      — close a queue item by id (verifies the tombstone " &
  "is visible before returning). Requires id.\n" &
  "  schedule  — write a future TODO with date/time tag to " &
  "notes.org. Requires summary, due.\n" &
  "  done_note — flip a notes.org TODO → DONE in place. " &
  "Requires summary (exact match).\n\n" &
  "Distinction: defer = untimed batch (todo.jsonl), schedule = " &
  "time-specific (notes.org). Don't use defer for time-bound work."

method parameters*(t: TodoTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["defer", "done", "schedule", "done_note"],
        "description": "Operation to perform"
      },
      "summary": {
        "type": "string",
        "description": "One-line description (defer / schedule); or exact match of the TODO text to close (done_note)"
      },
      "body": {
        "type": "string",
        "description": "Optional longer context (defer / schedule)"
      },
      "priority": {
        "type": "string",
        "enum": ["urgent", "normal", "low"],
        "description": "Defer priority (defaults to normal)"
      },
      "id": {
        "type": "string",
        "description": "Todo id from the heartbeat prompt's pending list, format `t-<8 hex>` (done action)"
      },
      "due": {
        "type": "string",
        "description": "Due time `yyyy-MM-dd` or `yyyy-MM-dd HH:mm`, agent's local timezone (schedule action)"
      },
      "recur": {
        "type": "string",
        "description": "Optional recurrence ++<count><d|w|mo|y> (schedule action)"
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
             (t.officeDir / "notes/todo.jsonl")
  return "Verified todo " & id & " is no longer pending. " &
         "Will not reappear in future heartbeats."

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

proc doSchedule(t: TodoTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("summary"):
    return "Error: 'summary' is required for schedule"
  if not args.hasKey("due"):
    return "Error: 'due' is required for schedule (use defer for untimed)"
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

  var dateTag = "<" & due
  if recur.len > 0:
    dateTag.add(" " & recur)
  dateTag.add(">")
  let headline = "* TODO " & summary & " " & dateTag

  let store = newNotesStore(t.officeDir)
  if not store.appendHeadline(headline, body):
    return "Error: failed to write to notes.org (see gateway log)"
  return "Wrote TODO to notes.org: " & headline & "\n" &
         "It will fire at " & due &
         (if recur.len > 0: " (recurring " & recur & ")" else: "") &
         ". The notes-watcher will pick it up; until then it shows " &
         "in your notes.org as untimed-from-now context."

proc doDoneNote(t: TodoTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("summary"):
    return "Error: 'summary' is required for done_note"
  let summary = args["summary"].getStr().strip()
  if summary.len == 0:
    return "Error: 'summary' must not be empty"

  let store = newNotesStore(t.officeDir)
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

  # Verification: re-load and confirm the line is now DONE.
  let verifyEntries = newNotesStore(t.officeDir).loadAll()
  for e in verifyEntries:
    if e.lineNum == matchLine:
      if e.state == nsDone:
        return "Verified '" & summary & "' is now DONE in notes.org. " &
               "Will not reappear in future heartbeat past-due lists."
      return "Error: rewrite reported success but state on line " &
             $matchLine & " is still " & $e.state &
             ". Check notes.org integrity."
  return "Error: rewrite reported success but matched line " &
         $matchLine & " no longer present. Check notes.org integrity."

method execute*(t: TodoTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.officeDir.len == 0:
    return "Error: tool not bound to an office workspace"
  if not args.hasKey("action"):
    return "Error: 'action' is required (defer | done | schedule | done_note)"
  let action = args["action"].getStr()
  case action
  of "defer":     return doDefer(t, args)
  of "done":      return doDone(t, args)
  of "schedule":  return doSchedule(t, args)
  of "done_note": return doDoneNote(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: defer | done | schedule | done_note"
