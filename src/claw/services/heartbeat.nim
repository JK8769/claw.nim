## Heartbeat — prompt + audit-log helpers.
##
## **History note (2026-05-09):** the in-process timer loop that this
## module used to own is gone. Heartbeats are now scheduled-task entries
## in `services/scheduler.nim` (kind=`heartbeat_tick`), registered at
## boot by `services/heartbeat_orchestrator.nim`, and dispatched from
## `gateway.nim`'s cronHandlerLogic. What remains here are the two pure
## helpers the dispatcher calls — prompt construction (which scans the
## agent's mailbox + reads HEARTBEAT.md every tick, freshly) and audit
## logging.
##
## Why split: the scheduler already has the timer + persistence + audit
## machinery; running a parallel heartbeat-only timer was duplicate
## plumbing. Moving the dispatch through the scheduler also makes
## heartbeats discoverable via `/schedule list`, debuggable via the
## same logs as other scheduled work, and reconciled at boot via the
## same path as skill-declared schedules.

import std/[os, times, strutils, json]
import ../agent/context

proc buildHeartbeatPrompt*(workspace: string): string =
  ## Build the synthetic-message body the scheduler hands to
  ## `AgentLoop.processOneShot` when a heartbeat_tick fires.
  ##
  ## Pure read of disk state at call time — `mail/` directory and
  ## `heart/HEARTBEAT.md`. Re-runs every tick so file edits land
  ## without a gateway restart.
  ##
  ## NOTE: this proc is the legacy minimal-prompt builder used only
  ## for ad-hoc `processOneShot` callers that don't go through the
  ## three-phase dispatcher. The real heartbeat path is in
  ## gateway.nim's `cronHandlerLogic` which assembles a richer
  ## prompt from competency duties, todo.jsonl, notes.org, and so on.
  let hbPath = workspace / "heart" / "HEARTBEAT.md"
  var notes = ""
  if fileExists(hbPath):
    notes = try: readFile(hbPath) except: ""

  var mailList = ""
  let mailFiles = scanMailbox(workspace)
  if mailFiles.len > 0:
    mailList = "\n**MAILBOX ALERT**: You have new/unread files in your `mail/` directory: " & mailFiles.join(", ") & ". Please review them if they contain important instructions or coordination.\n"

  let now = now().format("yyyy-MM-dd HH:mm")

  return """# Heartbeat Check

Current time: $1
$2
Check if there are any tasks I should be aware of or actions I should take.
Review the memory file for any important updates or changes.
Be proactive in identifying potential issues or improvements.

**CRITICAL**: Do NOT use any communication tools (like `send_message`) to notify the user of this routine check unless a high-priority action is required. Keep your response internal.

$3
""".format(now, mailList, notes)

proc logHeartbeat*(workspace, kind, msg: string,
                    extra: openArray[(string, string)] = []) =
  ## Append a JSONL entry to `<workspace>/heart/heartbeat.jsonl`.
  ## Used by the dispatcher for skipped / completed / errored ticks.
  ## Each entry is one line: `{"ts": <epoch>, "kind": "...",
  ## "msg": "...", ...extra}`. JSONL beats the prior plain-text log
  ## because:
  ##   - Atomic single-line append
  ##   - jq / grep / parse work
  ##   - Future telemetry commands (`claw heartbeat stats <agent>`)
  ##     can aggregate without regex
  ##   - Doesn't accumulate prose
  ##
  ## File lives in `<office>/heart/` alongside HEARTBEAT.md (the
  ## user's standing instructions for ticks). The `heart/` dir is
  ## the agent's heartbeat-subsystem state — what they should keep
  ## doing (HEARTBEAT.md), and what they've actually done at past
  ## ticks (heartbeat.jsonl). SOUL.md stays at the office root
  ## because it's always-on character, not heartbeat-specific.
  ##
  ## Failures are silent (auditing should never crash a tick).
  let heartDir = workspace / "heart"
  if not dirExists(heartDir):
    try: createDir(heartDir)
    except: discard
  let logFile = heartDir / "heartbeat.jsonl"
  var entry = newJObject()
  entry["ts"] = %epochTime()
  entry["kind"] = %kind
  if msg.len > 0:
    entry["msg"] = %msg
  for (k, v) in extra:
    entry[k] = %v
  try:
    let f = open(logFile, fmAppend)
    f.writeLine($entry)
    f.close()
  except:
    discard
