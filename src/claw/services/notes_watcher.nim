## notes-watcher — scans each agent's notes.org periodically and
## registers future-dated TODO entries as scheduler jobs.
##
## Each future-timed TODO becomes one `agent_tick`-kind entry in
## the scheduler. When the date arrives, the dispatcher fires the
## agent with the note's summary as the prompt content; the agent
## acts on it during that tick.
##
## Lifecycle handled via `reconcileSkillJobs`: every scan
## reconciles `@framework:notes:<agent>` source against the
## current notes.org content. Adding / removing / editing TODOs
## drops the old entries and registers fresh ones idempotently.
## Marking a TODO as DONE removes its entry from the scheduler.
## No drift, no orphaned entries.
##
## Periodic scan cadence: 5 minutes by default. Light pass — just
## reads small text files, no LLM, no network. Quick edits the
## operator makes via filesystem are picked up within the cadence.

import std/[asyncdispatch, options, os, tables, strutils, times]
import ../agent/notes
import ../config
import ../logger
import ./scheduler

const
  NotesWatcherIntervalMs* = 5 * 60 * 1000   ## 5 min between scans
  NotesSourcePrefix* = "@framework:notes:"
    ## Scheduler-job sourceSkill prefix for notes-watcher entries.
    ## Each agent gets `@framework:notes:<agent_lower>` so reconcile
    ## scopes per-agent.

proc reconcileNotesForAgent*(agentName, officeDir: string,
                              sched: CronService): tuple[added, kept, removed: int] =
  ## Read notes.org, build CronJobs for every future-timed TODO,
  ## reconcile against the scheduler. Idempotent — safe to call on
  ## every scan tick.
  let store = newNotesStore(officeDir)
  let nowDt = now()
  let future = store.futureTimedTodos(nowDt)
  var declared: seq[CronJob] = @[]
  for e in future:
    if e.due.isNone: continue
    let dueMs = e.due.get().toTime.toUnix * 1000
    # Stable name from line number + summary preview. Different lines
    # are different jobs even if they have the same summary; same line
    # with edited summary is treated as a new job (old reconciled out).
    let summaryPart =
      if e.summary.len > 40: e.summary[0 ..< 40] else: e.summary
    let cleanSummary = summaryPart.replace('\n', ' ').strip()
    let name = "L" & $e.lineNum & ": " & cleanSummary
    let payload = CronPayload(
      kind: "agent_tick",
      agentName: agentName,
      message: "# Note due now\n\nYou scheduled this TODO for " &
               e.due.get().format("yyyy-MM-dd HH:mm") & ":\n\n" &
               "**" & e.summary & "**\n\n" &
               "Process it now. After you're done, call " &
               "`mark_note_done` with the summary so it doesn't " &
               "fire again." &
               (if e.recur.intervalSec > 0:
                 "\n\n(This is a recurring note. The next occurrence " &
                 "will be auto-scheduled by the notes-watcher when " &
                 "it next scans.)"
                else: ""),
    )
    let schedule = CronSchedule(
      kind: "once",
      atMs: some(dueMs),
    )
    declared.add(CronJob(
      id: "",
      name: name,
      enabled: true,
      schedule: schedule,
      payload: payload,
      state: CronJobState(nextRunAtMs: some(dueMs)),
      sourceSkill: NotesSourcePrefix & agentName.toLowerAscii(),
    ))
  let r = sched.reconcileSkillJobs(
    NotesSourcePrefix & agentName.toLowerAscii(), declared)
  return r

proc scanAllAgents*(cfg: ref Config, sched: CronService) =
  ## One pass over every agent's notes.org. Logs a summary line per
  ## agent that had any change.
  if sched == nil: return
  for a in cfg[].agents.named:
    let officeDir = cfg[].workspacePath() / "offices" / a.name.toLowerAscii()
    if not dirExists(officeDir): continue
    let r = reconcileNotesForAgent(a.name, officeDir, sched)
    if r.added > 0 or r.removed > 0:
      infoCF("notes_watcher", "Reconciled note schedules", {
        "agent": a.name,
        "added": $r.added,
        "kept": $r.kept,
        "removed": $r.removed,
      }.toTable)

proc startNotesWatcher*(cfg: ref Config, sched: CronService) {.async.} =
  ## Background loop: scans all agents' notes.org files every
  ## `NotesWatcherIntervalMs` ms. Runs until the gateway exits;
  ## resilient to per-agent parse errors (bad notes.org won't kill
  ## the watcher).
  if sched == nil: return
  infoCF("notes_watcher", "Started", {
    "interval_ms": $NotesWatcherIntervalMs,
    "agents_in_cfg": $cfg[].agents.named.len,
  }.toTable)
  # Initial scan at boot — picks up any notes left from previous
  # gateway runs.
  try:
    scanAllAgents(cfg, sched)
  except CatchableError as e:
    warnCF("notes_watcher", "Initial scan errored — continuing",
           {"error": e.msg}.toTable)
  while true:
    await sleepAsync(NotesWatcherIntervalMs)
    try:
      scanAllAgents(cfg, sched)
    except CatchableError as e:
      warnCF("notes_watcher", "Scan errored — continuing",
             {"error": e.msg}.toTable)
