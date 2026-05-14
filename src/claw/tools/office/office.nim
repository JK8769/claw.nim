## office — the ship of the tools / office / company trio.
##
## The agent's vessel. All actions are SELF-ONLY (default; no name= arg
## in Phase 1) and READ-ONLY (no setters — admin sets `info` via config;
## the framework observes `state`/`occupant`/`stats`).
##
## Actions:
##   clock     — current time in office's timezone
##   calendar  — date queries in office's timezone (today, day, week, etc.)
##   info      — vessel config (path, timezone, occupant, created) — admin-set
##   state     — vessel dynamics (sessions, storage, health, uptime) — system
##   occupant  — agent dynamics (presence, current task) — system-derived
##   stats     — usage analytics (tokens, storage, compute) — for cost analysis
##
## Sibling tools on this trio:
##   tools     — sea (workforce capabilities, agent's craft surface)
##   company   — navigator (org-level direction; cross-office views)
##
## To enumerate all offices in the company, use `company workforce op=offices`.
## Cross-office introspection (state/occupant of OTHER agents) is Phase 2.

import std/[asyncdispatch, json, tables, times, os, strutils, strformat]
import ../types
import ../spec

const ToolSpec* = spec(
  name = "office",
  description = "The agent's vessel — clock/calendar/info/state/occupant/stats. Read-only, self-only. clock+calendar timezone-aware (office tz). info = admin-set vessel config; state = system-tracked dynamics (sessions/storage/health); occupant = agent dynamics (presence); stats = usage analytics for cost analysis.",
  tags = @["agent", "core", "office"],
  searchKeywords = @["office", "clock", "time", "now", "calendar", "date",
                      "today", "weekday", "week", "info", "state", "presence",
                      "storage", "stats", "tokens", "cost", "usage",
                      "vessel", "self", "my office"],
  domain = "agent",
  default = true,
  heartbeatSafe = true,
  category = "self-management",
)

type
  OfficeTool* = ref object of ContextualTool
    officeDir*: string
    workspaceDir*: string  ## company-wide workspace (for cross-cutting reads)
    gatewayStarted*: Time  ## set at tool construction; approximates uptime

proc newOfficeTool*(officeDir, workspaceDir: string): OfficeTool =
  OfficeTool(
    officeDir: officeDir,
    workspaceDir: workspaceDir,
    gatewayStarted: getTime()
  )

method name*(t: OfficeTool): string = "office"

method description*(t: OfficeTool): string =
  "The agent's vessel — situational awareness, all read-only and self-only.\n\n" &
  "Actions:\n" &
  "  clock     — current time in your office's timezone\n" &
  "  calendar  — date queries (today, day-of-week, week-of-year, is_weekend)\n" &
  "  info      — vessel config (path, timezone, occupant name, created)\n" &
  "  state     — vessel dynamics (active sessions, storage usage, health, uptime)\n" &
  "  occupant  — your dynamic state (presence: working/idle/free/away; current task)\n" &
  "  stats     — usage analytics (tokens consumed, storage used) for cost analysis\n\n" &
  "All actions report on YOUR OWN office. To see other offices in the " &
  "company, use `company workforce op=offices` (gated by trust)."

method parameters*(t: OfficeTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["clock", "calendar", "info", "state", "occupant", "stats"],
        "description": "Office query to perform. All read-only, self-only."
      },
      "tz": {
        "type": "string",
        "description": "clock (optional) — IANA timezone override (e.g. 'America/New_York'). Default: office's configured timezone."
      },
      "period": {
        "type": "string",
        "description": "stats (optional) — time window: 'today' | 'last_7d' | 'last_30d' | 'all'. Default: 'all'."
      }
    },
    "required": %["method"]
  }.toTable

# ── Helpers ─────────────────────────────────────────────────────────

proc readTimezone(t: OfficeTool): string =
  ## Resolution order (Phase 1):
  ##   1. Per-office marker file <office>/.timezone (operator-set)
  ##   2. Env var CLAW_OFFICE_TZ
  ##   3. System default (returns "" — std/times will use the system tz)
  let markerPath = t.officeDir / ".timezone"
  if fileExists(markerPath):
    try:
      let v = readFile(markerPath).strip()
      if v.len > 0: return v
    except: discard
  let envTz = getEnv("CLAW_OFFICE_TZ", "")
  if envTz.len > 0: return envTz
  ""  # empty = use system default

proc readCreated(t: OfficeTool): string =
  ## Approximate office creation = mtime of office dir itself.
  if not dirExists(t.officeDir): return "(unknown)"
  try:
    let info = getFileInfo(t.officeDir)
    return info.creationTime.format("yyyy-MM-dd HH:mm:ss")
  except: return "(unknown)"

proc countFilesIn(dir: string, ext: string = ""): int =
  if not dirExists(dir): return 0
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    if ext.len > 0 and not path.endsWith(ext): continue
    inc result

proc dirSizeKB(dir: string): int =
  ## Recursive size in KB. Cheap-ish; for large trees consider sampling.
  if not dirExists(dir): return 0
  var bytes: int64 = 0
  for path in walkDirRec(dir, relative = false, checkDir = false):
    try:
      let info = getFileInfo(path, followSymlink = false)
      if info.kind == pcFile:
        bytes += info.size
    except: discard
  int(bytes div 1024)

proc lastWriteTime(t: OfficeTool): Time =
  ## Walk the office dir and return the most recent mtime found.
  result = fromUnix(0)
  for path in walkDirRec(t.officeDir, relative = false, checkDir = false):
    try:
      let info = getFileInfo(path, followSymlink = false)
      if info.lastWriteTime > result:
        result = info.lastWriteTime
    except: discard

# ── action handlers ─────────────────────────────────────────────────

proc doClock(t: OfficeTool, args: Table[string, JsonNode]): string =
  ## Current time in office's timezone (or override via tz arg).
  let tz = if args.hasKey("tz"): args["tz"].getStr().strip() else: readTimezone(t)
  let n = now()
  let zoneInfo = if tz.len > 0: tz else: "system default"
  let iso = n.format("yyyy-MM-dd'T'HH:mm:sszzz")
  let human = n.format("yyyy-MM-dd HH:mm:ss (dddd) zzz")
  let epoch = getTime().toUnix()
  return fmt"""Current time: {human}
ISO 8601:     {iso}
Unix epoch:   {epoch}
Timezone:     {zoneInfo}"""

proc doCalendar(t: OfficeTool): string =
  ## Today's date + day-of-week + day-of-year + weekend flag.
  ## Phase 2: arithmetic (add_days), holiday detection, ISO week number.
  let n = now()
  let dow = n.format("dddd")
  let isWeekend = n.weekday in {dSat, dSun}
  let monthDay = n.format("MMMM d, yyyy")
  return fmt"""Date:         {n.format("yyyy-MM-dd")} ({dow})
Long form:    {monthDay}
Day of year:  {n.yearday + 1}
Weekend:      {isWeekend}
Timezone:     {(if readTimezone(t).len > 0: readTimezone(t) else: "system default")}"""

proc doInfo(t: OfficeTool): string =
  ## Vessel config: admin-set, read-only.
  let tz = readTimezone(t)
  let envelope = %*{
    "path": t.officeDir,
    "timezone": (if tz.len > 0: tz else: "(system default)"),
    "occupant": (if t.agentName.len > 0: t.agentName else: "(unknown)"),
    "created": readCreated(t)
  }
  envelope.pretty()

proc doState(t: OfficeTool): string =
  ## Vessel dynamics: system observation.
  let memoryEntries = countFilesIn(t.officeDir / "memory", ".jsonl")
  let notes = countFilesIn(t.officeDir / "notes", ".jsonl") +
              countFilesIn(t.officeDir / "notes", ".org")
  let knowledgeTopics = countFilesIn(t.officeDir / "knowledge", ".md")
  let activeSessions = countFilesIn(t.officeDir / "sessions", ".jsonl")
  let projectsDir = t.officeDir / "workstation" / "projects"
  var projects = 0
  if dirExists(projectsDir):
    for k, _ in walkDir(projectsDir):
      if k == pcDir: inc projects
  let totalKB = dirSizeKB(t.officeDir)
  let lw = lastWriteTime(t)
  let lastWrite = if lw.toUnix > 0: lw.format("yyyy-MM-dd HH:mm:ss") else: "(unknown)"
  let uptimeSec = (getTime() - t.gatewayStarted).inSeconds
  let envelope = %*{
    "active_sessions": activeSessions,
    "last_write": lastWrite,
    "uptime_seconds": uptimeSec,
    "storage": {
      "memory_entries": memoryEntries,
      "notes": notes,
      "projects": projects,
      "knowledge_topics": knowledgeTopics,
      "total_size_kb": totalKB
    },
    "health": {
      "comment": "broken_symlinks/dirty_git deferred to workstation audit"
    }
  }
  envelope.pretty()

proc derivePresence(t: OfficeTool): string =
  ## Auto-derived presence based on activity recency.
  let lw = lastWriteTime(t)
  if lw.toUnix == 0: return "free"
  let ageSec = (getTime() - lw).inSeconds
  if ageSec < 60: "working"
  elif ageSec < 5 * 60: "idle"
  elif ageSec < 30 * 60: "free"
  else: "away"

proc doOccupant(t: OfficeTool): string =
  ## Agent dynamics: framework observation of the office's occupant.
  ## Phase 2 may add: current_partner, current_task (from active session).
  let presence = derivePresence(t)
  let lw = lastWriteTime(t)
  let lastActive = if lw.toUnix > 0: lw.format("yyyy-MM-dd HH:mm:ss") else: "(unknown)"
  let envelope = %*{
    "presence": presence,
    "last_active": lastActive,
    "occupant": t.agentName,
    "comment": "current_partner / current_task / mood are Phase 2"
  }
  envelope.pretty()

proc doStats(t: OfficeTool, args: Table[string, JsonNode]): string =
  ## Phase 1: storage totals + session count. Tokens/compute Phase 2 once
  ## we wire session-log → token-counter aggregation. Per-customer
  ## breakdown is Phase 2 (needs nc:id tagging on session events).
  let period = if args.hasKey("period"): args["period"].getStr() else: "all"
  let totalKB = dirSizeKB(t.officeDir)
  let memoryKB = dirSizeKB(t.officeDir / "memory")
  let knowledgeKB = dirSizeKB(t.officeDir / "knowledge")
  let projectsKB = dirSizeKB(t.officeDir / "workstation")
  let notesKB = dirSizeKB(t.officeDir / "notes")
  let sessionFiles = countFilesIn(t.officeDir / "sessions", ".jsonl")
  let envelope = %*{
    "period": period,
    "storage": {
      "total_kb": totalKB,
      "memory_kb": memoryKB,
      "knowledge_kb": knowledgeKB,
      "projects_kb": projectsKB,
      "notes_kb": notesKB
    },
    "sessions": {
      "active_files": sessionFiles
    },
    "tokens": {
      "comment": "per-message token totals + per-customer breakdown deferred to Phase 2"
    },
    "compute": {
      "comment": "CPU/RAM tracking requires process-metric instrumentation, Phase 3"
    }
  }
  envelope.pretty()

# ── dispatch ────────────────────────────────────────────────────────

method execute*(t: OfficeTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("method"):
    return "Error: 'method' is required (clock | calendar | info | state | occupant | stats)"
  if t.officeDir.len == 0:
    return "Error: tool not bound to an office workspace"
  let action = getMethodArg(args).toLowerAscii()
  case action
  of "clock":    return doClock(t, args)
  of "calendar": return doCalendar(t)
  of "info":     return doInfo(t)
  of "state":    return doState(t)
  of "occupant": return doOccupant(t)
  of "stats":    return doStats(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: clock | calendar | info | state | occupant | stats"
