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
  ## `memory/HEARTBEAT.md`. Re-runs every tick so file edits land
  ## without a gateway restart.
  let notesFile = workspace / "memory" / "HEARTBEAT.md"
  var notes = ""
  if fileExists(notesFile):
    notes = readFile(notesFile)

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
  ## Append a JSONL entry to `<workspace>/heartbeat.jsonl`. Used by
  ## the dispatcher for skipped / completed / errored ticks. Each
  ## entry is one line: `{"ts": <epoch>, "kind": "...", "msg": "...",
  ## ...extra}`. JSONL beats the prior plain-text log because:
  ##   - Atomic single-line append
  ##   - jq / grep / parse work
  ##   - Future telemetry commands (`claw heartbeat stats <agent>`)
  ##     can aggregate without regex
  ##   - Doesn't accumulate prose
  ##
  ## File lives at the office ROOT (sibling to SOUL.md, HEARTBEAT.md),
  ## NOT in memory/ — heartbeat.jsonl is framework-owned audit, not
  ## agent-curated content. Operator can `tail -f` it to watch a
  ## live agent's tick history.
  ##
  ## Failures are silent (auditing should never crash a tick).
  let logFile = workspace / "heartbeat.jsonl"
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
