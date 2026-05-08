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

import std/[os, times, strutils]
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

proc logHeartbeat*(workspace, message: string) =
  ## Append a timestamped line to `<workspace>/memory/heartbeat.log`.
  ## Used by the dispatcher for "skipped — busy", "skipped — empty",
  ## and "tick errored" notes that don't belong in the gateway's
  ## global log. Failures are silent (auditing should never crash a
  ## tick).
  let logFile = workspace / "memory" / "heartbeat.log"
  let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
  try:
    let f = open(logFile, fmAppend)
    f.writeLine("[$1] $2".format(timestamp, message))
    f.close()
  except:
    discard
