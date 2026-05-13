## schedule — the timed leg of the focus / schedule / todo trio.
##
## Two backends, one surface:
##
##   • CRON service — for "fire at exact time" reminders and recurring
##     tasks. Use `at_seconds`, `every_seconds`, or `cron_expr`. The
##     framework's cron service actively fires at the moment and posts
##     back to the agent's message bus (or directly to the channel,
##     when `deliver=true`).
##
##   • NOTES.ORG — for calendar-style date-tagged TODOs. Use `due` (and
##     optionally `recur`) to write `* TODO summary <yyyy-MM-dd ++recur>`
##     to the agent's notes.org. The heartbeat scans notes.org and
##     surfaces past-due items in the agent's prompt — passive trigger.
##     Action `complete` flips the state to DONE in place.
##
## Pick the backend by which params you pass:
##   - `at_seconds` / `every_seconds` / `cron_expr` → cron
##   - `due` (with optional `recur`) → notes.org
##
## Sibling tools on the temporal axis:
##   focus — NOW (immediate; intra-agent with constrained tools)
##   todo  — BATCHED (untimed queue; defer/done only — heartbeat scan)

import std/[asyncdispatch, json, tables, strutils, times, locks, options]
import ../types
import ../spec
import ../../services/scheduler as cron_service
import ../../bus
import ../../utils
import ../../agent/notes

const ToolSpec* = spec(
  name = "schedule",
  description = "Time-anchored work. CRON backend: at_seconds | every_seconds | cron_expr — fires actively at the moment. NOTES.ORG backend: due (+ optional recur) — passive heartbeat scan. Action 'complete' marks a notes.org TODO as done.",
  tags = @["scheduling", "automation", "cron"],
  domain = "sched",
  default = true,
  heartbeatSafe = false,
  category = "scheduling",
)

type
  JobExecutor* = proc (content, sessionKey, channel, chatID: string): Future[string] {.async.}

  ScheduleTool* = ref object of ContextualTool
    cronService*: CronService
    executor*: JobExecutor
    msgBus*: MessageBus
    officeDir*: string  ## For notes.org calendar backend (due / complete).
    lock*: Lock

proc newScheduleTool*(cronService: CronService, executor: JobExecutor,
                      msgBus: MessageBus, officeDir: string): ScheduleTool =
  var st = ScheduleTool(
    cronService: cronService,
    executor: executor,
    msgBus: msgBus,
    officeDir: officeDir
  )
  initLock(st.lock)
  return st

method name*(t: ScheduleTool): string = "schedule"
method description*(t: ScheduleTool): string =
  "Time-anchored work — the timed leg of the focus / schedule / todo " &
  "trio. Two backends:\n\n" &
  "CRON (active fire): pass at_seconds, every_seconds, or cron_expr. " &
  "Cron service triggers at the exact moment; a payload posts back to " &
  "your message bus (or directly to channel if deliver=true).\n" &
  "  - at_seconds=600 → fire once in 10 min\n" &
  "  - every_seconds=3600 → fire every hour\n" &
  "  - cron_expr='0 9 * * *' → daily at 9am\n\n" &
  "NOTES.ORG (passive heartbeat scan): pass due (and optionally recur). " &
  "Writes `* TODO summary <date>` to your notes.org; the heartbeat scans " &
  "notes.org and surfaces past-due items in your prompt.\n" &
  "  - due='2026-08-01', summary='Quarterly site visit prep'\n" &
  "  - recur='++1mo' → monthly\n\n" &
  "Action 'complete' flips a notes.org TODO to DONE in place. For cron " &
  "jobs, use 'remove' or 'disable'.\n\n" &
  "Sibling tools: `focus` for NOW (intra-agent with constrained tools), " &
  "`todo` for BATCHED untimed work (defer/done)."

method parameters*(t: ScheduleTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["add", "create", "list", "remove", "update",
                 "enable", "disable", "complete"],
        "description": "Action to perform. 'add'/'create' = register new " &
                       "(cron OR notes.org based on which params present). " &
                       "'complete' = flip a notes.org TODO to DONE."
      },
      "message": {
        "type": "string",
        "description": "Cron backend: the reminder/task message that fires when triggered (required for cron add)."
      },
      "summary": {
        "type": "string",
        "description": "notes.org backend: short title (required for due-style add and for complete)."
      },
      "body": {
        "type": "string",
        "description": "notes.org backend (optional): longer context written under the headline."
      },
      "at_seconds": {
        "type": "integer",
        "description": "CRON: one-time reminder, seconds from now (e.g. 600 for 10 min later)."
      },
      "every_seconds": {
        "type": "integer",
        "description": "CRON: recurring interval in seconds (e.g. 3600 for hourly)."
      },
      "cron_expr": {
        "type": "string",
        "description": "CRON: cron expression for complex recurring schedules (e.g. '0 9 * * *')."
      },
      "due": {
        "type": "string",
        "description": "NOTES.ORG: calendar date in 'yyyy-MM-dd' or 'yyyy-MM-dd HH:mm' (agent's local timezone)."
      },
      "recur": {
        "type": "string",
        "description": "NOTES.ORG (optional): recurrence as ++<count><unit>; unit is d|w|mo|y (e.g. '++1mo' for monthly)."
      },
      "job_id": {
        "type": "string",
        "description": "CRON: job ID (for remove/update/enable/disable)."
      },
      "enabled": {
        "type": "boolean",
        "description": "CRON: enable or disable the job (for update action only)."
      },
      "deliver": {
        "type": "boolean",
        "description": "CRON: if true, send message directly to channel; if false, agent processes the message. Default: true."
      }
    },
    "required": %["action"]
  }.toTable

# ── notes.org calendar validators (formerly in todo_unified) ──────

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

# ── action handlers ─────────────────────────────────────────────────

proc parseScheduleArgs(args: Table[string, JsonNode]): Option[CronSchedule] =
  if args.hasKey("at_seconds"):
    let node = args["at_seconds"]
    let atSeconds = if node.kind == JString: node.getStr().parseInt() else: node.getInt()
    let atMS = (getTime().toUnix * 1000) + (atSeconds * 1000)
    return some(CronSchedule(kind: "at", atMs: some(atMS.int64)))
  elif args.hasKey("every_seconds"):
    let node = args["every_seconds"]
    let everySeconds = if node.kind == JString: node.getStr().parseInt() else: node.getInt()
    let everyMS = everySeconds * 1000
    return some(CronSchedule(kind: "every", everyMs: some(everyMS.int64)))
  elif args.hasKey("cron_expr"):
    return some(CronSchedule(kind: "cron", expr: args["cron_expr"].getStr()))
  return none(CronSchedule)

proc addNotesEntry(t: ScheduleTool, args: Table[string, JsonNode]): string =
  ## notes.org backend — calendar-style date-tagged TODO.
  if t.officeDir.len == 0:
    return "Error: schedule tool not bound to an office workspace (notes.org backend unavailable)"
  if not args.hasKey("summary"):
    return "Error: 'summary' is required when using 'due' (notes.org backend)"
  let summary = args["summary"].getStr().strip()
  if summary.len == 0: return "Error: 'summary' must not be empty"
  let due = args["due"].getStr().strip()
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
         ". The heartbeat scan picks it up; until then it shows in " &
         "your notes.org as upcoming context."

proc addJob(t: ScheduleTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  acquire(t.lock)
  let channel = t.channel
  let chatID = t.chatID
  # Snapshot the message_id and app_id from the live session so the
  # cron-fired turn can reply via `messages-reply` rather than
  # `messages-send` — see CronPayload's docstring for why.
  let replyToMessageID = t.replyToMessageID
  let appID = t.appID
  release(t.lock)

  if channel == "" or chatID == "":
    return "Error: no session context (channel/chat_id not set). Use this tool in an active conversation."

  if not args.hasKey("message"): return "Error: message is required for cron add (or use 'due' for notes.org backend)"
  let message = args["message"].getStr()

  let scheduleOpt = parseScheduleArgs(args)
  if scheduleOpt.isNone:
    return "Error: one of at_seconds, every_seconds, cron_expr (cron) or due (notes.org) is required"

  let schedule = scheduleOpt.get()
  let deliver = if args.hasKey("deliver"): args["deliver"].getBool() else: true
  let messagePreview = truncate(message, 30)

  try:
    let payload = CronPayload(
      kind: "agent_turn",
      message: message,
      deliver: deliver,
      channel: channel,
      to: chatID,
      senderID: t.logicalUserID,
      agentName: t.agentName,
      agentID: t.agentID,
      model: "", # Default to current
      replyToMessageID: replyToMessageID,
      appID: appID
    )
    let job = await t.cronService.addJob(messagePreview, schedule, payload)
    return strutils.format("Created job '$1' (id: $2)", job.name, job.id)
  except Exception as e:
    return "Error adding job: " & e.msg

proc updateJob(t: ScheduleTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("job_id"): return "Error: job_id is required for update"
  let jobID = args["job_id"].getStr()

  let scheduleOpt = parseScheduleArgs(args)
  var messageOpt: Option[string] = none(string)
  if args.hasKey("message"): messageOpt = some(args["message"].getStr())

  var enabledOpt: Option[bool] = none(bool)
  if args.hasKey("enabled"): enabledOpt = some(args["enabled"].getBool())

  if scheduleOpt.isNone and messageOpt.isNone and enabledOpt.isNone:
    return "Error: Nothing to update — provide at_seconds/every_seconds/cron_expr, message, or enabled"

  if t.cronService.updateJob(jobID, scheduleOpt, messageOpt, enabledOpt):
    return "Updated job " & jobID
  else:
    return "Job " & jobID & " not found"

proc completeNote(t: ScheduleTool, args: Table[string, JsonNode]): string =
  ## notes.org backend — flip a TODO to DONE in place.
  if t.officeDir.len == 0:
    return "Error: schedule tool not bound to an office workspace (notes.org backend unavailable)"
  if not args.hasKey("summary"):
    return "Error: 'summary' is required for complete (exact match against the TODO text)"
  let summary = args["summary"].getStr().strip()
  if summary.len == 0: return "Error: 'summary' must not be empty"

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

method execute*(t: ScheduleTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"): return "Error: action is required"
  let action = args["action"].getStr()

  case action:
  of "add", "create":
    # Dispatch by backend signal. `due` selects notes.org; otherwise cron.
    if args.hasKey("due"):
      return addNotesEntry(t, args)
    return await t.addJob(args)
  of "complete":
    return completeNote(t, args)
  of "update": return t.updateJob(args)
  of "list":
    let jobs = t.cronService.listJobs(false)
    if jobs.len == 0: return "No scheduled jobs."
    var res = "Scheduled jobs:\n"
    for j in jobs:
      var schedInfo = "unknown"
      if j.schedule.kind == "every" and j.schedule.everyMs.isSome:
        schedInfo = "every " & $(j.schedule.everyMs.get div 1000) & "s"
      elif j.schedule.kind == "cron":
        schedInfo = j.schedule.expr
      elif j.schedule.kind == "at":
        schedInfo = "one-time"
      res.add(strutils.format("- $1 (id: $2, $3)\n", j.name, j.id, schedInfo))
    return res
  of "remove":
    if not args.hasKey("job_id"): return "Error: job_id is required"
    let jobID = args["job_id"].getStr()
    if t.cronService.removeJob(jobID):
      return "Removed job " & jobID
    else:
      return "Job " & jobID & " not found"
  of "enable", "disable":
    if not args.hasKey("job_id"): return "Error: job_id is required"
    let jobID = args["job_id"].getStr()
    let enabled = action == "enable"
    let job = t.cronService.enableJob(jobID, enabled)
    if job == nil: return "Job " & jobID & " not found"
    let status = if enabled: "enabled" else: "disabled"
    return strutils.format("Job '$1' $2", job.name, status)
  else:
    return "Error: unknown action: " & action
