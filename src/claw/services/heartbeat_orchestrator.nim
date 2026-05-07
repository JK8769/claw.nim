## Heartbeat orchestrator — Layer 2 (company policy applied to Layer 1
## primitives).
##
## Responsibility split, per the three-layer architecture:
##
##   • Layer 1 (system / runtime — universal): provides the cron timer,
##     the `processOneShot` stateless-tick mechanism, and the
##     `liveTaskCount` busy-check primitive. Knows nothing about which
##     agents exist or whether any company wants ticks at all.
##
##   • Layer 2 (company / nc:1 — policy): this module. Reads each
##     declared agent's `heartbeat_seconds` from BASE.json, registers a
##     timer per opted-in agent, and on each tick applies the company's
##     policy (skip-if-busy, future: bloat thresholds, failure pause).
##     Dispatches via Layer 1's `processOneShot` so no session JSONL
##     accumulates between ticks.
##
##   • Layer 3 (agent — behavior): the prompt content of each tick is
##     composed by `services/heartbeat.buildPrompt` and read by the
##     agent's normal iteration loop. The agent uses its declared tool
##     surface; if it wants to carry observations across ticks it does
##     so via `memory_store` writes inside its turn — explicit, not
##     accidental-via-history.
##
## What replaces the old hardcoded path in gateway.nim:
##
##   OLD:  newHeartbeatService(lexiWorkspace, ..., 14400, true)
##         → only Lexi got ticks; cadence baked into framework code;
##           sessions accumulated to thousands of messages over time.
##
##   NEW:  startHeartbeats(cfg, gCtx)
##         → walks `cfg.agents.named`, finds every agent with
##           `heartbeat_seconds > 0`, spawns one HeartbeatService each.
##           The on-tick callback skips when the office is busy and
##           dispatches via processOneShot when free. Zero JSONL.

import std/[asyncdispatch, strutils, os, tables]
import ./heartbeat
import ../config
import ../logger
import ../agent/loop
import ../tools/registry as tools_registry

type
  AgentHeartbeats* = ref object
    services*: seq[HeartbeatService]
      ## One service per opted-in agent. Held so the gateway shutdown
      ## path can stop them all cleanly.

proc startHeartbeats*(cfg: ref Config,
                       officeFor: proc(name: string): AgentLoop {.gcsafe.}):
                       AgentHeartbeats =
  ## Read each agent's `heartbeat_seconds` from cfg, spawn one
  ## HeartbeatService per opted-in agent. The callback applies
  ## skip-if-busy via the Layer 1 `liveTaskCount` primitive and
  ## dispatches via `processOneShot` (no persisted session).
  ##
  ## `officeFor` is the lazy-office accessor — passed in rather than
  ## reaching into a global gCtx because this module is Layer 2 and
  ## shouldn't import gateway internals. Caller (gateway.nim) wires
  ## up its `ensureOffice` shape.
  result = AgentHeartbeats(services: @[])
  for a in cfg[].agents.named:
    if a.heartbeat_seconds <= 0: continue
    let agentName = a.name
    let cadence = a.heartbeat_seconds
    let workspace = cfg[].workspacePath() / "offices" / agentName.toLowerAscii
    # Capture name + cadence into the closure. Each agent gets its own
    # service so cadences can vary per agent (Atlas faster, Lexi slower).
    let cb = proc(prompt: string): Future[void] {.async, gcsafe.} =
      {.cast(gcsafe).}:
        let office = officeFor(agentName)
        if office == nil:
          warnCF("heartbeat_orchestrator",
                 "Skipping tick — office not yet materialized",
                 {"agent": agentName}.toTable)
          return
        # Skip-if-busy policy. The agent has live work; running a
        # heartbeat tick now would compete for the same provider chain
        # and risk tripping the same rate limits / cooldowns the live
        # work depends on. Defer cleanly — the next scheduled tick
        # will check again.
        if office.liveTaskCount > 0:
          infoCF("heartbeat_orchestrator",
                 "Skipping tick — agent busy",
                 {"agent": agentName,
                  "live_tasks": $office.liveTaskCount}.toTable)
          return
        try:
          discard await office.processOneShot(
            prompt, tools_registry.SystemHeartbeatSender)
        except CatchableError as e:
          warnCF("heartbeat_orchestrator", "Tick raised — continuing",
                 {"agent": agentName, "error": e.msg}.toTable)
    let svc = newHeartbeatService(workspace, cb, cadence, true)
    result.services.add(svc)
    asyncCheck svc.start()
    infoCF("heartbeat_orchestrator", "Heartbeat enabled",
           {"agent": agentName,
            "cadence_seconds": $cadence}.toTable)

proc stopAll*(ah: AgentHeartbeats) =
  ## Stop every running heartbeat. Called from the gateway shutdown
  ## path; safe to call multiple times (each service idempotently
  ## flips its `running` flag off).
  if ah == nil: return
  for svc in ah.services:
    try: svc.stop() except CatchableError: discard
