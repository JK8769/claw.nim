## Heartbeat orchestrator — registers heartbeat_tick scheduled jobs
## with the unified scheduler at gateway boot.
##
## Layering, post-fold (2026-05-09):
##
##   • Layer 1 (system / runtime — universal): provides the scheduler
##     timer, persistence, and the dispatch hook. Knows nothing about
##     which agents exist or whether any company wants ticks at all.
##
##   • Layer 2 (company / nc:1 — policy): this module. Reads each
##     declared agent's `heartbeat_seconds` from BASE.json, registers
##     a `heartbeat_tick`-kind scheduled job per opted-in agent.
##     Idempotent — safe to call on every boot, reconciles cadence
##     changes (e.g. `heartbeat 14400 → 7200` in BASE.nims) without
##     duplicating jobs.
##
##   • Layer 3 (agent — behavior): the dispatcher (`gateway.nim`'s
##     cronHandlerLogic) handles a heartbeat_tick by skipping if the
##     agent is busy, rebuilding the prompt fresh from disk via
##     `heartbeat.buildHeartbeatPrompt`, and dispatching via
##     `AgentLoop.processOneShot` so no JSONL accumulates between
##     ticks.
##
## What changed from the prior implementation:
##
##   OLD:  per-agent HeartbeatService spawned its own asyncCheck timer
##         loop. The orchestrator held the seq[HeartbeatService] for
##         shutdown. Two parallel timer infrastructures (heartbeat +
##         scheduler) existed side by side.
##
##   NEW:  zero new timers. Heartbeats become rows in jobs.json with
##         kind="heartbeat_tick" and sourceSkill=`@framework:heartbeat`.
##         The scheduler's existing tick loop drives them. Visible in
##         /schedule list, reconciled with the same machinery as
##         skill-declared schedules. Cadence changes mid-deployment
##         are handled by the same reconcile path.

import std/[options, tables, strutils]
import ../config
import ../logger
import ./scheduler

const
  HeartbeatSourceTag* = "@framework:heartbeat"
    ## Sentinel value for `CronJob.sourceSkill` on heartbeat jobs.
    ## Distinguishes framework-declared from real-skill-declared
    ## (e.g. "sungrow") so reconcile knows whose declarations to
    ## diff against. The `@framework:` prefix is reserved — skills
    ## cannot have names starting with `@` so there's no collision.

proc registerHeartbeats*(cfg: ref Config, sched: CronService) =
  ## Walk `cfg.agents.named`, build a CronJob for each agent with
  ## `heartbeat_seconds > 0`, reconcile against the scheduler's
  ## persistent store. Replaces the prior pattern of spawning one
  ## HeartbeatService timer per agent.
  ##
  ## Idempotent: on subsequent boots, `reconcileSkillJobs` matches
  ## by (sourceSkill=HeartbeatSourceTag, name=`<agent>-heartbeat`)
  ## and updates schedule/payload in place if the cadence changed,
  ## or removes if the operator dropped `heartbeat_seconds` from
  ## BASE.nims.
  if sched == nil: return
  var declared: seq[CronJob] = @[]
  for a in cfg[].agents.named:
    if a.heartbeat_seconds <= 0: continue
    declared.add(CronJob(
      id: "",
      name: a.name.toLowerAscii() & "-heartbeat",
      enabled: true,
      schedule: CronSchedule(
        kind: "every",
        everyMs: some(int64(a.heartbeat_seconds) * 1000)),
      payload: CronPayload(
        kind: "heartbeat_tick",
        agentName: a.name,
      ),
      sourceSkill: HeartbeatSourceTag,
    ))
  let r = sched.reconcileSkillJobs(HeartbeatSourceTag, declared)
  infoCF("heartbeat_orchestrator", "Reconciled heartbeat schedules", {
    "agents_opted_in": $declared.len,
    "added": $r.added,
    "kept": $r.kept,
    "removed": $r.removed,
  }.toTable)
