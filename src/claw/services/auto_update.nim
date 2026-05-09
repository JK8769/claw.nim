## Phase 9 — auto-update orchestrator. Registers ONE scheduled job
## that polls upstream claw at `updates.check_interval_hours` cadence.
## Payload kind: `auto_update_tick`. The gateway's cronHandler matches
## that kind and dispatches to the upgrade-or-notify path.
##
## This service is the moral analog of `heartbeat_orchestrator`:
## reads BASE.json's `updates:` block at boot, registers (or removes,
## or updates cadence on) the scheduled job idempotently. Operators
## flip `enabled true/false` in BASE.nims + run `claw co update` and
## the job appears/disappears on the next gateway boot.
##
## NOTE: the actual git-pull-build-restart logic lives in
## `cli_upgrade.nim`. This service is just the scheduler glue.

import std/[options, tables, strutils]
import ../config
import ../logger
import ./scheduler

const
  AutoUpdateSourceTag* = "@framework:auto_update"
    ## Sentinel for `CronJob.sourceSkill`. Lets `reconcileSkillJobs`
    ## differentiate the auto-update job from skill-declared jobs.

proc registerAutoUpdate*(cfg: ref Config, sched: CronService) =
  ## Walk `cfg.updates`, reconcile against the scheduler.
  ## Idempotent: subsequent boots match by sourceSkill + name and
  ## update cadence in place; toggling `enabled false` removes the job.
  if sched == nil: return
  var declared: seq[CronJob] = @[]
  if cfg[].updates.enabled:
    let intervalH =
      if cfg[].updates.check_interval_hours > 0: cfg[].updates.check_interval_hours
      else: 4   # safety: don't poll faster than every hour by accident
    let intervalMs = int64(intervalH) * 3600 * 1000
    declared.add(CronJob(
      id: "",
      name: "auto-update-check",
      enabled: true,
      schedule: CronSchedule(
        kind: "every",
        everyMs: some(intervalMs)),
      payload: CronPayload(
        kind: "auto_update_tick",
        # Stash branch + autoApply in `agentName` and `message`
        # respectively — the gateway's dispatcher reads them back.
        # Re-using existing payload fields rather than extending the
        # schema for what's purely a single-job concern.
        agentName: cfg[].updates.branch,
        message: (if cfg[].updates.auto_apply: "auto" else: "notify") &
                 "|" & cfg[].updates.notify_agent,
      ),
      sourceSkill: AutoUpdateSourceTag,
    ))
  let r = sched.reconcileSkillJobs(AutoUpdateSourceTag, declared)
  infoCF("auto_update_orchestrator", "Reconciled auto-update schedule", {
    "enabled": $cfg[].updates.enabled,
    "auto_apply": $cfg[].updates.auto_apply,
    "branch": cfg[].updates.branch,
    "interval_hours": $cfg[].updates.check_interval_hours,
    "added": $r.added,
    "kept": $r.kept,
    "removed": $r.removed,
  }.toTable)
