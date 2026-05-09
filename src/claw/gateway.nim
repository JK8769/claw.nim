
## gateway — Long-running gateway process: agents, channels, cron.
## Supports --stdio (Zen) and --daemon (headless) modes.

import std/[os, strutils, asyncdispatch, tables, posix, exitprocs, json, algorithm, options, osproc, times, sets, random, unicode, sequtils]
import lib/curl as curly, webby/httpheaders
import config, logger, bus, bus_types, session, agent/loop,
       agent/context as agent_ctx,
       agent/cortex, agent/binding, agent/invites, agent/todo as agent_todo,
       agent/notes as agent_notes,
       cli_admin, system_commands
import billing/[subscription as sub_mod, welcome as welcome_mod, company as company_mod, gate as gate_mod, gate_messages as gate_msgs, usage as usage_mod, plants as plants_mod]
import context as claw_context, utils, pricing
import tools/delegate as delegate_tool
import tools/registry as tools_registry
import tools/types as tools_types
import providers/http, providers/types as providers_types,
       providers/fallback, providers/health as provider_health, protocol
import channels/[base as channel_base, manager as channel_manager, nmobile as nmobile_channel]
import services/[heartbeat, scheduler as cron_service, heartbeat_orchestrator,
                  heartbeat_decl, notes_watcher]
import skills/loader as skills_loader_mod
import daemon/[socket, status]

proc isProcessAlive(pid: int): bool =
  if pid <= 0: return false
  kill(pid.Pid, 0) == 0


# ── Global state ────────────────────────────────────────────────────

type
  GatewayContext = ref object
    cfg: Config
    msgBus: MessageBus
    provider: LLMProvider
    healthRegistry: ProviderHealthRegistry
                            ## Shared cross-session circuit breaker.
                            ## Created once at startup, threaded into
                            ## every FallbackLLMProvider so health
                            ## state is global across sessions /
                            ## agents / chain instances.
    cronService: CronService
    offices: Table[string, AgentLoop]
    statusEmitter: StatusEmitter

var gCtx: GatewayContext = nil
var gChanManager: channel_manager.Manager = nil
var gSocketServer: SocketServer = nil
var isShuttingDown = false

# Channel for HTTP thread → async event loop agent requests.
# `senderOverride` and `channelOverride` let the CLI spoof the requester
# for testing data-layer gating (`agent send --from=<id>`). Empty strings
# mean "use the default SuperAdmin-as-sender resolution".
type AgentRequest = tuple[
  officeKey, message, senderOverride, channelOverride: string,
  respChan: ptr system.Channel[string]]
var gAgentRequestChan: system.Channel[AgentRequest]
gAgentRequestChan.open()

# Gateway startup time — used by /status to report uptime.
var gStartTime: float = 0.0

# Forward declarations so makeAgentLoop / askPeer can reference these
# helpers defined later in the file.
proc ensureOffice(agentName: string): AgentLoop
proc buildProviderChainForAgent(graph: WorldGraph,
                                 models: seq[string],
                                 healthRegistry: ProviderHealthRegistry = nil): LLMProvider

# Shared askPeer implementation — gets or creates the target peer's
# AgentLoop, runs her full processDirect (her own tools, trust gate,
# sessions), returns her reply text. Wired into every AgentLoop's
# delegate tool so "agent-to-agent" is a real capability transfer.
proc askPeerImpl(agentName, prompt, senderAlias, callerSessionKey: string): Future[string] {.async.} =
  let peer = ensureOffice(agentName)
  if peer == nil:
    return "Error: peer agent '" & agentName & "' not configured."
  let sessionKey = "delegate:" & senderAlias & ":" & agentName.toLowerAscii
  let sender = if senderAlias.len > 0: senderAlias else: "agent:unknown"
  return await peer.processDirect(prompt, sessionKey, sender, "internal")

proc makeAgentLoop(agentName: string): AgentLoop =
  ## Phase 4 of provider-config refactor (option C): every agent has an
  ## explicit per-agent FallbackLLMProvider chain built from their
  ## declared `models` list. Capability decisions live in the agent
  ## layer; providers are purely operational.
  ##
  ## Resolution:
  ##   - Build agent's `models` from declared `a.models`, falling
  ##     through to the deprecated singular `a.model` (auto-promoted
  ##     to `[a.model]`). After clawdsl's Phase 4 validation this
  ##     fallback shouldn't be hit for freshly-generated BASE.json,
  ##     but old BASE.json files predating Phase 4 might still have
  ##     `model` without `models`.
  ##   - If both are empty: defensive last-resort uses the company
  ##     chain (gCtx.provider). Should be unreachable after Phase 4
  ##     `claw co update` validates and errors — kept here so an
  ##     unmigrated company doesn't crash the gateway entirely.
  var perAgentProvider = gCtx.provider
  var perAgentModel = ""
  for a in gCtx.cfg.agents.named:
    if a.name.toLowerAscii() != agentName.toLowerAscii(): continue
    var agentModels = a.models
    if agentModels.len == 0 and a.model.len > 0:
      agentModels = @[a.model]
    if agentModels.len == 0:
      warnCF("gateway",
        "Agent has no models declared — using company chain. " &
        "Run `claw co migrate` and add `models \"...\"` to BASE.nims.",
        {"agent": agentName}.toTable)
      break
    perAgentModel = agentModels[0]
    try:
      let graph = loadWorld(gCtx.cfg.workspacePath())
      perAgentProvider = buildProviderChainForAgent(graph, agentModels,
                                                     gCtx.healthRegistry)
      infoCF("gateway", "Per-agent chain built",
        {"agent": agentName, "models": agentModels.join(",")}.toTable)
    except CatchableError as e:
      warnCF("gateway",
        "Per-agent chain build failed — using company default",
        {"agent": agentName, "models": agentModels.join(","),
         "error": e.msg}.toTable)
      perAgentModel = ""
    break
  newAgentLoop(gCtx.cfg, gCtx.msgBus, perAgentProvider, agentName,
               gCtx.cronService, model = perAgentModel, askPeer = askPeerImpl)

proc ensureOffice(agentName: string): AgentLoop =
  let key = agentName.toLowerAscii
  {.cast(gcsafe).}:
    if not gCtx.offices.hasKey(key):
      gCtx.offices[key] = makeAgentLoop(agentName.capitalizeAscii())
    return gCtx.offices[key]

# ── Shutdown ────────────────────────────────────────────────────────

proc gracefulShutdown() =
  if isShuttingDown: return
  isShuttingDown = true
  stderr.writeLine "\n[claw] Shutting down..."
  if gCtx != nil:
    gCtx.statusEmitter.emitGatewayStop()
    gCtx.statusEmitter.close()
    for office in gCtx.offices.values:
      try: office.stop()
      except: discard
  if gSocketServer != nil:
    gSocketServer.stop()
  if gChanManager != nil:
    waitFor gChanManager.stopAll()
  # Clean PID files (company-scoped and legacy service-scoped)
  for p in [gatewayPidPath(), pidFilePath()]:
    if fileExists(p):
      try: removeFile(p)
      except: discard
  stderr.writeLine "[claw] Stopped."

# ── Cron handler ────────────────────────────────────────────────────

proc cronHandlerLogic(job: cron_service.CronJob) {.async.} =
  if gCtx == nil: return
  debugCF("cronHandler", "Triggering job",
          {"id": job.id, "kind": job.payload.kind,
           "source_skill": job.sourceSkill}.toTable)

  # Dispatch by payload kind. Empty / "agent_turn" / "deliver" all
  # fall through to the legacy LLM-driven path. New payload kinds:
  #   - "tool_call" — invoke `tool` from the registry directly with
  #     parsed args, attributed to runAs (default nc:1). Free of LLM
  #     cost. Used by skill-declared periodic data sync (sungrow
  #     history, alarm refresh, etc.) — bookkeeping that doesn't
  #     need the LLM.
  #   - "agent_tick" — same shape as a heartbeat tick: synthetic
  #     message under a system:* session_key, processed by the
  #     named agent's LLM loop, comm tools disabled. Will absorb
  #     services/heartbeat.nim's responsibility in a follow-up.
  if job.payload.kind == "tool_call":
    let runAs = (if job.payload.runAs.len > 0: job.payload.runAs else: "nc:1")
    let agentLoop = block:
      var found: AgentLoop
      for _, al in gCtx.offices.pairs:
        found = al; break
      found
    if agentLoop == nil:
      warnCF("cronHandler", "tool_call dispatched with no agent loops loaded — skipping",
             {"job": job.name, "tool": job.payload.tool}.toTable)
      return
    var args = initTable[string, JsonNode]()
    if job.payload.args.len > 0:
      try:
        let parsed = parseJson(job.payload.args)
        if parsed.kind == JObject:
          for k, v in parsed.fields:
            args[k] = v
      except CatchableError as e:
        warnCF("cronHandler", "tool_call args parse failed",
               {"job": job.name, "error": e.msg}.toTable)
    let toolCtx = tools_types.ToolContext(
      channel: "system",
      sessionKey: "system:scheduler:" & job.id,
      senderID: runAs,
      recipientID: runAs,
      role: "system",
      agentName: "scheduler",
      agentID: runAs,
      logicalUserID: runAs,
      graph: agentLoop.contextBuilder.graph
    )
    try:
      let result = await agentLoop.tools.executeWithContext(
        job.payload.tool, args, toolCtx)
      let preview =
        if result.len > 200: result[0 ..< 200] & "…" else: result
      infoCF("cronHandler", "tool_call completed",
             {"job": job.name, "tool": job.payload.tool,
              "run_as": runAs,
              "source_skill": job.sourceSkill,
              "preview": preview}.toTable)
    except Exception as e:
      errorCF("cronHandler", "tool_call failed",
              {"job": job.name, "tool": job.payload.tool,
               "error": e.msg}.toTable)
    return

  let agentName = if job.payload.agentName != "": job.payload.agentName else: "Lexi"
  let officeKey = agentName.toLowerAscii()

  if job.payload.kind == "agent_tick":
    # System-keyed agent reflection. Same shape as heartbeat: synthetic
    # user message under a system:* session_key (which gates outbound
    # comm tools), processed by the named agent's LLM loop.
    if not gCtx.offices.hasKey(officeKey):
      gCtx.offices[officeKey] = makeAgentLoop(agentName)
    let inbound = bus_types.InboundMessage(
      channel: "system",
      sender_id: "system:tick",
      recipient_id: agentName,
      chat_id: "scheduler",
      content: (if job.payload.message.len > 0: job.payload.message
                else: "Scheduled tick from " & job.name),
      session_key: "system:tick:" & job.id,
      metadata: initTable[string, string]()
    )
    discard await gCtx.offices[officeKey].processMessage(inbound)
    infoCF("cronHandler", "agent_tick completed",
           {"job": job.name, "agent": agentName,
            "source_skill": job.sourceSkill}.toTable)
    return

  if job.payload.kind == "heartbeat_tick":
    # Three-phase heartbeat dispatch:
    #   1. Gather   — read HEARTBEAT.md, mail/, and run each
    #                 competency-declared duty's read tool deterministically
    #   2. Auto-act — fire any duty.act.auto whose `when` is truthy
    #                 (deferred to a follow-up sub-commit; for now hint-only)
    #   3. Prompt   — assemble structured sections, dispatch via processOneShot
    if not gCtx.offices.hasKey(officeKey):
      gCtx.offices[officeKey] = makeAgentLoop(agentName)
    let office = gCtx.offices[officeKey]
    if office.liveTaskCount > 0:
      infoCF("cronHandler",
             "heartbeat_tick skipped — agent busy",
             {"job": job.name, "agent": agentName,
              "live_tasks": $office.liveTaskCount}.toTable)
      return
    let agentWorkspace = gCtx.cfg.workspacePath() / "offices" / officeKey

    # Resolve agent's loaded competencies (practices ∪ team-inherited).
    var practices: seq[string]
    for a in gCtx.cfg.agents.named:
      if a.name == agentName:
        practices = a.practices
        break
    let competencies = office.contextBuilder.effectiveCompetencies(
      agentName, practices)
    let competenciesRoot = gCtx.cfg.workspacePath() / "competencies"
    let duties = dutiesForAgent(competenciesRoot, competencies)

    # Phase 1 — Gather. Run each duty's read tool deterministically.
    type ReadResult = object
      duty: HeartbeatDuty
      content: string
      isEmpty: bool
    var readResults: seq[ReadResult]
    for duty in duties:
      if duty.read.tool.len == 0:
        readResults.add(ReadResult(duty: duty, content: "", isEmpty: true))
        continue
      var args = initTable[string, JsonNode]()
      if duty.read.args != nil and duty.read.args.kind == JObject:
        for k, v in duty.read.args.fields:
          args[k] = v
      let toolCtx = tools_types.ToolContext(
        channel: "system",
        sessionKey: "system:heartbeat:" & job.id & ":" & duty.id,
        senderID: "nc:1",
        recipientID: "nc:1",
        role: "system",
        agentName: "scheduler",
        agentID: "nc:1",
        logicalUserID: "nc:1",
        graph: office.contextBuilder.graph,
      )
      try:
        let r = await office.tools.executeWithContext(
          duty.read.tool, args, toolCtx)
        let trimmed = r.strip()
        let empty = trimmed.len == 0 or
                    trimmed == "[]" or trimmed == "{}" or
                    trimmed == "null"
        readResults.add(ReadResult(
          duty: duty, content: trimmed, isEmpty: empty))
      except Exception as e:
        warnCF("cronHandler", "Heartbeat duty read failed",
               {"agent": agentName, "duty": duty.id,
                "tool": duty.read.tool, "error": e.msg}.toTable)
        readResults.add(ReadResult(
          duty: duty, content: "Error: " & e.msg, isEmpty: false))

    # Phase 2 — Auto-act. For each duty with act.mode == hamAuto,
    # evaluate the `when` predicate against the read result, build
    # tool args via template substitution, fire the tool
    # deterministically (no LLM round-trip), capture a one-line
    # confirmation for the prompt phase so the agent sees what
    # already happened.
    proc applyHeartbeatTemplate(s: string, readResult: string): string =
      ## Minimal template substitution for auto.args. Supported tokens:
      ##   {date}     → YYYY-MM-DD
      ##   {datetime} → YYYY-MM-DD HH:MM:SS
      ##   {result}   → the duty's read.result as a string (whole)
      ## JSON-path patterns like {result.key.nested} are reserved
      ## for a follow-up; for now they pass through unchanged.
      let now = now()
      result = s
      result = result.replace("{date}", now.format("yyyy-MM-dd"))
      result = result.replace("{datetime}", now.format("yyyy-MM-dd HH:mm:ss"))
      result = result.replace("{result}", readResult)
    proc substituteJsonArgs(node: JsonNode, readResult: string): JsonNode =
      ## Walk a JSON node tree, applying template substitution to all
      ## string leaves. Object/array structure preserved; non-strings
      ## (numbers, bools, null) untouched.
      if node == nil: return nil
      case node.kind
      of JString: result = %applyHeartbeatTemplate(node.getStr(), readResult)
      of JObject:
        result = newJObject()
        for k, v in node.fields:
          result[k] = substituteJsonArgs(v, readResult)
      of JArray:
        result = newJArray()
        for v in node.items:
          result.add(substituteJsonArgs(v, readResult))
      else: result = node
    var autoActions: seq[string] = @[]
    for rr in readResults:
      if rr.duty.act.mode != hamAuto: continue
      let shouldFire = case rr.duty.act.`when`:
        of "always": true
        of "result_not_empty": not rr.isEmpty
        else: not rr.isEmpty
      if not shouldFire: continue
      if rr.duty.act.autoTool.len == 0:
        warnCF("cronHandler", "auto act has no tool — skipping",
               {"duty": rr.duty.id}.toTable)
        continue
      var autoArgs = initTable[string, JsonNode]()
      let templated = substituteJsonArgs(rr.duty.act.autoArgs, rr.content)
      if templated != nil and templated.kind == JObject:
        for k, v in templated.fields:
          autoArgs[k] = v
      let autoCtx = tools_types.ToolContext(
        channel: "system",
        sessionKey: "system:heartbeat:" & job.id & ":" & rr.duty.id & ":auto",
        senderID: "nc:1",
        recipientID: "nc:1",
        role: "system",
        agentName: "scheduler",
        agentID: "nc:1",
        logicalUserID: "nc:1",
        graph: office.contextBuilder.graph,
      )
      try:
        let actResult = await office.tools.executeWithContext(
          rr.duty.act.autoTool, autoArgs, autoCtx)
        let preview =
          if actResult.len > 120: actResult[0 ..< 120] & "…"
          else: actResult
        autoActions.add("[" & rr.duty.sourceCompetency & "." & rr.duty.id &
                        "] auto: " & rr.duty.act.autoTool & " → " & preview)
        infoCF("cronHandler", "Heartbeat auto-act fired",
               {"agent": agentName, "duty": rr.duty.id,
                "tool": rr.duty.act.autoTool}.toTable)
      except Exception as e:
        autoActions.add("[" & rr.duty.sourceCompetency & "." & rr.duty.id &
                        "] auto: " & rr.duty.act.autoTool & " → ERROR: " & e.msg)
        warnCF("cronHandler", "Heartbeat auto-act failed",
               {"agent": agentName, "duty": rr.duty.id,
                "tool": rr.duty.act.autoTool, "error": e.msg}.toTable)

    # Phase 3 — Prompt. Assemble structured sections.
    var sections: seq[string] = @[]

    # HEARTBEAT.md → user's standing instructions, verbatim
    for path in [agentWorkspace / "HEARTBEAT.md",
                 agentWorkspace / "memory" / "HEARTBEAT.md"]:  # legacy fallback
      if fileExists(path):
        let body = try: readFile(path).strip except: ""
        if body.len > 0:
          sections.add("## Standing instructions from your user\n\n" & body)
        break

    # Mailbox alert
    let mailFiles = scanMailbox(agentWorkspace)
    if mailFiles.len > 0:
      sections.add("## Mailbox\n\n" & $mailFiles.len &
                   " unread item(s): " & mailFiles.join(", "))

    # Pending todo queue — items system-appended (mail arrival, peer
    # delegate-deferred) plus agent self-defers from prior ticks. The
    # agent's drain-the-queue work for this tick.
    let todoStore = newTodoStore(agentWorkspace)
    let todoBlock = todoStore.renderPendingForPrompt()
    if todoBlock.len > 0:
      sections.add("## Pending TODO (process at this tick)\n\n" & todoBlock)

    # Past-due notes from notes.org — TODOs whose `<date>` tag is
    # already in the past. Future-dated TODOs are picked up by the
    # notes-watcher and fire their own one-off agent_tick at the
    # exact due time; this section catches the ones that didn't get
    # processed when they fired (or were date-only without time, so
    # they roll into the next heartbeat after the date passes).
    let notesStore = newNotesStore(agentWorkspace)
    let notesBlock = notesStore.renderPastDueForPrompt()
    if notesBlock.len > 0:
      sections.add("## Past-due scheduled notes\n\n" & notesBlock)

    # Per-duty read sections (skip duties whose read came back empty)
    for rr in readResults:
      if rr.isEmpty: continue
      let title =
        if rr.duty.read.sectionTitle.len > 0: rr.duty.read.sectionTitle
        else: rr.duty.title
      sections.add("## " & title & " [" & rr.duty.sourceCompetency & "]\n\n" &
                   rr.content)

    # Auto-actions already fired (so the agent knows what's been done
    # without needing to re-do it or wonder)
    if autoActions.len > 0:
      sections.add("## Auto-actions fired this tick\n\n" &
                   autoActions.mapIt("- " & it).join("\n"))

    # Suggested actions (hint mode duties whose `when` evaluated truthy)
    var hints: seq[string] = @[]
    for rr in readResults:
      if rr.duty.act.mode != hamHint: continue
      let shouldFire = case rr.duty.act.`when`:
        of "always": true
        of "result_not_empty": not rr.isEmpty
        else: not rr.isEmpty
      if shouldFire:
        hints.add("- [" & rr.duty.sourceCompetency & "." & rr.duty.id & "] " &
                  rr.duty.act.hint)
    if hints.len > 0:
      sections.add("## Suggested actions for this tick\n\n" & hints.join("\n"))

    # Nothing-to-do predicate: skip the LLM call entirely when every
    # source returned empty AND no auto-actions fired. The dispatcher
    # already burned the deterministic gather pass (cheap), but a
    # ~30K-prompt LLM call to reflect on "nothing happened" is wasted
    # tokens. Skip-then-log gives the operator visibility into how
    # often quiet ticks are saving cost.
    if sections.len == 0:
      infoCF("cronHandler", "heartbeat_tick skipped — nothing to do",
             {"job": job.name, "agent": agentName,
              "duty_count": $duties.len}.toTable)
      logHeartbeat(agentWorkspace, "skipped", "nothing to do",
                   [("agent", agentName), ("duty_count", $duties.len)])
      return

    let nowStr = now().format("yyyy-MM-dd HH:mm")
    var prompt = "# Heartbeat Tick\n\nTime: " & nowStr & "\n\n" &
                 sections.join("\n\n") & "\n\n" &
      "**Communication discipline**: this is a routine internal tick. " &
      "Don't message the user unless your standing instructions or a " &
      "suggested action explicitly call for it.\n"

    try:
      discard await office.processOneShot(
        prompt, tools_registry.SystemHeartbeatSender)
      infoCF("cronHandler", "heartbeat_tick completed",
             {"job": job.name, "agent": agentName,
              "duty_count": $duties.len,
              "section_count": $sections.len,
              "auto_actions": $autoActions.len}.toTable)
      logHeartbeat(agentWorkspace, "completed", "",
                   [("agent", agentName),
                    ("duty_count", $duties.len),
                    ("section_count", $sections.len),
                    ("auto_actions", $autoActions.len)])
    except CatchableError as e:
      logHeartbeat(agentWorkspace, "error", e.msg,
                   [("agent", agentName)])
      warnCF("cronHandler", "heartbeat_tick raised — continuing",
             {"job": job.name, "agent": agentName,
              "error": e.msg}.toTable)
    return

  if job.payload.deliver:
    var meta = initTable[string, string]()
    if job.payload.replyToMessageID.len > 0:
      meta["message_id"] = job.payload.replyToMessageID
    if job.payload.appID.len > 0:
      meta["app_id"] = job.payload.appID
    gCtx.msgBus.publishOutbound(newOutbound(
      job.payload.channel, agentName, job.payload.to, job.payload.message,
      job.payload.replyToMessageID, job.payload.appID, meta))
  else:
    if not gCtx.offices.hasKey(officeKey):
      gCtx.offices[officeKey] = makeAgentLoop(agentName)
    let sender = if job.payload.senderID != "": job.payload.senderID else: "system:scheduler"
    # Reconstruct the inbound shape a real user message would have, so
    # the agent loop's outbound (and any reply tool the agent calls)
    # has the same routing handles — chat_id, message_id, app_id —
    # that drove the original conversation. processDirect's "direct"
    # chat-id default and stripped metadata loses the message_id;
    # without it, Feishu replies fall back to messages-send and hit
    # the wrong-app routing error this fix targets.
    var meta = initTable[string, string]()
    if job.payload.replyToMessageID.len > 0:
      meta["message_id"] = job.payload.replyToMessageID
    if job.payload.appID.len > 0:
      meta["app_id"] = job.payload.appID
    let inbound = bus_types.InboundMessage(
      channel: job.payload.channel,
      sender_id: sender,
      recipient_id: agentName,
      chat_id: job.payload.to,
      content: job.payload.message,
      session_key: sender,
      metadata: meta
    )
    let agentResponse = await gCtx.offices[officeKey].processMessage(inbound)
    if agentResponse != "":
      gCtx.msgBus.publishOutbound(newOutbound(
        job.payload.channel, agentName, job.payload.to, agentResponse,
        job.payload.replyToMessageID, job.payload.appID, meta))

proc cronHandler(job: cron_service.CronJob): Future[void] =
  return cronHandlerLogic(job)

# ── System commands (/status, /model, etc.) ─────────────────────────

proc fmtUptime(secs: float): string =
  let s = secs.int
  let days = s div 86400
  let hours = (s mod 86400) div 3600
  let mins = (s mod 3600) div 60
  let sec = s mod 60
  if days > 0: return $days & "d " & $hours & "h " & $mins & "m"
  if hours > 0: return $hours & "h " & $mins & "m " & $sec & "s"
  if mins > 0: return $mins & "m " & $sec & "s"
  $sec & "s"

proc fmtUnixTime(t: int64): string =
  if t <= 0: return "—"
  times.fromUnix(t).local.format("yyyy-MM-dd HH:mm:ss")

proc hasNonAscii(s: string): bool =
  ## Cheap "is this likely non-English?" check — any byte with the high
  ## bit set means multi-byte UTF-8, which covers Chinese, Japanese,
  ## Korean, Arabic, Cyrillic, etc. False positives (emoji) are fine —
  ## translation is idempotent on mostly-ASCII-with-emoji.
  for c in s:
    if c.uint8 >= 0x80: return true
  false

proc detectLang*(s: string): string =
  ## Dominant-script heuristic — returns a BCP-47 style tag. Walks
  ## codepoints once, tallies per-script votes, returns the plurality
  ## winner. Covers the common cases we see in practice; falls back to
  ## "en" for ASCII or unrecognised scripts.
  var han, hira, kata, hangul, cyr, arab, other = 0
  for r in s.runes:
    let cp = r.int32
    if cp < 0x80: discard
    elif cp in 0x4E00 .. 0x9FFF or cp in 0x3400 .. 0x4DBF: inc han
    elif cp in 0x3040 .. 0x309F: inc hira
    elif cp in 0x30A0 .. 0x30FF: inc kata
    elif cp in 0xAC00 .. 0xD7AF: inc hangul
    elif cp in 0x0400 .. 0x04FF: inc cyr
    elif cp in 0x0600 .. 0x06FF: inc arab
    else: inc other
  # Japanese is Hiragana/Katakana (han+kana is still Japanese, but if
  # only han with no kana it's almost certainly Chinese).
  if hira + kata > 0: return "ja"
  if hangul > 0: return "ko"
  if han > 0: return "zh"
  if cyr > 0: return "ru"
  if arab > 0: return "ar"
  "en"

const refusalByLang = {
  "en": "Sorry, I don't recognize you on this channel. Please send the " &
        "invitation code you received from the operator (e.g. `ABC-123` " &
        "or `nc:X/ABC-123`) to authenticate. If you don't have a code, " &
        "ask the operator to issue one for you.",
  "zh": "抱歉，我不认识您在该渠道上的身份。请发送运营人员发给您的" &
        "邀请码（例如 `ABC-123` 或 `nc:X/ABC-123`）进行身份验证。" &
        "如果您还没有邀请码，请联系运营人员为您生成一个。",
  "ja": "申し訳ありません。このチャンネルであなたを認識できません。" &
        "管理者から受け取った招待コード（例: `ABC-123` または " &
        "`nc:X/ABC-123`）を送信して認証してください。コードをお持ちで" &
        "ない場合は、管理者にコードの発行を依頼してください。",
  "ko": "죄송하지만, 이 채널에서 귀하를 인식할 수 없습니다. 운영자로부터" &
        "받은 초대 코드(예: `ABC-123` 또는 `nc:X/ABC-123`)를 보내서" &
        "인증해 주세요. 코드가 없다면 운영자에게 코드 발급을 요청하세요.",
}.toTable

proc maybeTranslate(cfg: ref Config, src, userSample: string,
                     targetLang: string = ""): Future[string] {.async.} =
  ## If the user's last message used non-English characters (or an
  ## explicit `targetLang` is provided), run the English `src` through
  ## the LLM and append the translation. `targetLang` uses BCP-47-ish
  ## tags (zh, en, ja, ko, …); when empty we detect from `userSample`.
  ## Returns the original src on any error so callers always get
  ## something printable.
  let lang =
    if targetLang.len > 0: targetLang.toLowerAscii
    else: detectLang(userSample)
  if lang == "en": return src
  try:
    let graph = loadWorld(cfg[].workspacePath())
    if graph == nil: return src
    let primary = firstProviderName(graph)
    let tech = resolveProviderTech(
      firstProviderDefaultModel(graph), primary,
      graph.providers, providerOverride = primary)
    if tech.apiBase == "" or tech.apiKey == "": return src
    let provider = createProvider(tech.model, tech.apiKey, tech.apiBase)
    let sysPrompt = "You are a terse translator. Translate the user's " &
                    "English text into the target language. Keep inline " &
                    "code spans, URLs, and code blocks EXACTLY as-is. " &
                    "Output only the translation, no preamble."
    let userPrompt = "Target language: " & lang &
                     "\n\nEnglish text to translate:\n" & src
    let messages = @[
      providers_types.Message(role: providers_types.RoleSystem, content: sysPrompt),
      providers_types.Message(role: providers_types.RoleUser, content: userPrompt)]
    var options = initTable[string, JsonNode]()
    options["temperature"] = %0.2
    let response = await provider.chat(messages, @[], tech.model, options)
    if response.content.len > 0:
      return src & "\n\n" & response.content
    return src
  except:
    return src

proc resolveSenderEntity*(graph: WorldGraph, msg: InboundMessage): WorldEntityID =
  ## Resolve a sender to an entity ID using a channel-aware identifier
  ## chain. For most channels this is just (channelKey, sender_id);
  ## Feishu adds tenant-stable union_id / user_id fallbacks because
  ## Feishu issues a different open_id per app, so a binding made
  ## via one app won't match a message arriving through another.
  ##
  ## The chain in order:
  ##   1. `<channel>:<app_id>` + sender_id  (or bare `<channel>` if no app_id)
  ##   2. Feishu only — `feishu:union` + metadata.union_id
  ##   3. Feishu only — `feishu:user`  + metadata.user_id
  ##
  ## Returns 0 when no chain hits. Mirrors the dispatcher's auth-gate
  ## fallback (gateway.nim message-recognition path) so admin/CLI
  ## callers get the same identity resolution as regular messages.
  if graph == nil: return WorldEntityID(0)
  let channelKey =
    if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
      msg.channel & ":" & msg.metadata["app_id"]
    else: msg.channel
  let (entID, _) = graph.resolveUserGraph(channelKey, msg.sender_id)
  if uint32(entID) > 0: return entID
  if msg.channel == "feishu":
    let uid = msg.metadata.getOrDefault("union_id", "")
    if uid.len > 0:
      let (x, _) = graph.resolveUserGraph("feishu:union", uid)
      if uint32(x) > 0: return x
    let usid = msg.metadata.getOrDefault("user_id", "")
    if usid.len > 0:
      let (x, _) = graph.resolveUserGraph("feishu:user", usid)
      if uint32(x) > 0: return x
  WorldEntityID(0)

proc resolveCallerNc(cfg: ref Config, msg: InboundMessage): string =
  ## Resolve the caller's `nc:N` alias from an inbound message.
  ## Returns "" when the world graph won't load or the user has no
  ## entity binding yet — call sites decide between "error" and
  ## "fall back to an explicit nc:id arg".
  let g = loadWorld(cfg[].workspacePath())
  let entID = resolveSenderEntity(g, msg)
  if uint32(entID) == 0: return ""
  toAlias(entID)

proc resolveCallerPermission(cfg: ref Config, msg: InboundMessage): Permission =
  ## Resolve the caller's declared entity permission into one of four
  ## tiers (pmSuperAdmin > pmAdmin > pmInternal > pmAny). The entry
  ## gate accepts pmInternal+; per-subcommand checks tighten further
  ## (e.g. /user bind needs pmSuperAdmin, /user add needs pmAdmin).
  let graph = loadWorld(cfg[].workspacePath())
  let entID = resolveSenderEntity(graph, msg)
  if uint32(entID) == 0 or not graph.entities.hasKey(entID):
    return pmAny
  let p = graph.entities[entID].role.toLowerAscii
  # Admin/SuperAdmin get their own tier; defer the broader internal-vs-
  # external check to `tierFromRoleName` so the role-string list lives
  # in one place (cli_admin.nim, mirroring clawdsl.nim's tier inference).
  case p
  of "superadmin": pmSuperAdmin
  of "admin":      pmAdmin
  else:
    if tierFromRoleName(p) == "int": pmInternal
    else: pmAny

proc buildProviderChainForAgent(graph: WorldGraph,
                                 models: seq[string],
                                 healthRegistry: ProviderHealthRegistry = nil): LLMProvider =
  ## Phase 2 of provider-config refactor: per-agent fallback chain.
  ##
  ## Walks the agent's `models` preference list. For each model name,
  ## finds the FIRST provider in `graph.providers` whose `models` list
  ## contains it, builds an HTTPProvider for that pair, and adds an
  ## entry to the chain in agent-preference order. Models without a
  ## serving provider are warn-and-skipped.
  ##
  ## Empty `models` → caller should fall back to the company default
  ## chain (`buildProviderChain`) instead. We don't do that here so the
  ## intent stays explicit at the call site.
  ##
  ## Compared to the company-level chain: the order is the AGENT's
  ## preference (model order), not the company's (provider order).
  ## So an agent can declare `models "deepseek-v4-flash", "kimi-k2.5"`
  ## and get cross-provider failover, while another agent declares
  ## `models "deepseek-v4-pro", "deepseek-v4-flash"` and stays on
  ## DeepSeek for both primary and fallback.
  var entries: seq[FallbackEntry] = @[]
  for model in models:
    var foundFor = ""
    if graph.providers != nil and graph.providers.kind == JObject:
      for pName, pNode in graph.providers.getFields():
        let pModels = pNode{"models"}
        if pModels == nil or pModels.kind != JArray: continue
        var matches = false
        for m in pModels:
          if m.getStr() == model:
            matches = true; break
        if not matches: continue
        let tech = resolveProviderTech(model, pName, graph.providers,
                                        providerOverride = pName)
        if tech.apiBase.len == 0 or tech.apiKey.len == 0:
          warnCF("claw",
                 "Skipping per-agent model — provider has no apiBase/apiKey",
                 {"model": model, "provider": pName}.toTable)
          break
        let prov = createProvider(tech.model, tech.apiKey, tech.apiBase)
        # Look up the model's context window from the catalog so the
        # chain can size-skip on per-call payload. 0 = unknown →
        # fitsEntry treats it as "always fits" (back-compat).
        let ctxWin = resolveContextWindow(model, 0)
        entries.add(FallbackEntry(provider: prov, model: model,
                                  name: pName, contextWindow: ctxWin))
        foundFor = pName
        let position =
          if entries.len == 1: "primary"
          else: "fallback #" & $(entries.len - 1)
        infoCF("claw",
               "Per-agent: registered " & position,
               {"model": model, "provider": pName,
                "base": tech.apiBase}.toTable)
        break
    if foundFor.len == 0:
      warnCF("claw",
             "Per-agent model has no serving provider — skipped",
             {"model": model}.toTable)
  if entries.len == 0:
    raise newException(IOError,
      "No usable model→provider mapping for the agent's preference " &
      "list. Check that the agent's `models` entries are listed in " &
      "some provider's `models` array in BASE.nims.")
  result =
    if entries.len > 1: newFallbackLLMProvider(entries, healthRegistry)
    else: entries[0].provider

proc buildProviderChain(cfg: Config, graph: WorldGraph,
                         healthRegistry: ProviderHealthRegistry = nil): LLMProvider =
  ## Construct the LLM provider as a fallback chain by iterating
  ## `graph.providers` in DECLARATION ORDER. The first usable entry
  ## becomes the primary; subsequent ones are fallbacks (in order).
  ## Each entry uses its own `defaultModel` — different vendors don't
  ## share model names (deepseek-v4-flash isn't a thing on opencode-go),
  ## so the chain runs with each provider's own advertised default.
  ##
  ## Post-Phase-4: this is the COMPANY-LEVEL chain, used only as the
  ## defensive fallback when an agent has no `models` declared (which
  ## a freshly-generated BASE.json never has). Each declared agent
  ## gets their own per-agent chain via `buildProviderChainForAgent`,
  ## ordered by their own `models` preference. `/model X:Y` is now
  ## per-agent and doesn't reorder this list.
  ##
  ## When only one provider is configured the chain has just the
  ## primary — the wrapper is a no-op pass-through, which keeps the
  ## type uniform without silent behaviour change.
  ##
  ## When only one provider is configured the chain has just the
  ## primary — the wrapper is a no-op pass-through, which keeps the
  ## type uniform without silent behaviour change.
  var fallbackEntries: seq[FallbackEntry] = @[]
  if graph.providers != nil and graph.providers.kind == JObject:
    for pName, pNode in graph.providers.getFields():
      # Phase 4 of provider-config refactor: each provider's `models[0]`
      # is its canonical primary model. The legacy `defaultModel` JSON
      # field is consulted as a back-compat fallback if `models` is
      # empty (old BASE.json files generated before Phase 4).
      let modelsNode = pNode{"models"}
      var m = ""
      if modelsNode != nil and modelsNode.kind == JArray and modelsNode.len > 0:
        m = modelsNode[0].getStr("")
      if m.len == 0:
        m = pNode{"defaultModel"}.getStr("")
      if m.len == 0:
        warnCF("claw", "Skipping provider — no models declared",
               {"provider": pName}.toTable)
        continue
      let tech = resolveProviderTech(m, pName, graph.providers,
                                      providerOverride = pName)
      if tech.apiBase.len == 0 or tech.apiKey.len == 0:
        warnCF("claw", "Skipping provider — missing apiBase/apiKey",
               {"provider": pName}.toTable)
        continue
      let p = createProvider(tech.model, tech.apiKey, tech.apiBase)
      let ctxWin = resolveContextWindow(tech.model, 0)
      fallbackEntries.add(FallbackEntry(provider: p, model: tech.model,
                                         name: pName,
                                         contextWindow: ctxWin))
      let position =
        if fallbackEntries.len == 1: "primary"
        else: "fallback #" & $(fallbackEntries.len - 1)
      infoCF("claw", "Registered " & position & " provider",
             {"provider": pName, "model": tech.model,
              "base": tech.apiBase}.toTable)
  if fallbackEntries.len == 0:
    raise newException(IOError,
      "No usable providers — every entry in graph.providers was missing " &
      "apiKey, apiBase, or defaultModel. Check BASE.nims and run " &
      "`claw co update`.")
  result =
    if fallbackEntries.len > 1: newFallbackLLMProvider(fallbackEntries,
                                                        healthRegistry)
    else: fallbackEntries[0].provider

proc handleSystemCommand(cfg: ref Config, msg: InboundMessage, al: AgentLoop): Future[string] {.async.} =
  let cmd = msg.content.strip()
  # Single gate at the entry: system commands are operator tools, not
  # a customer-facing API. Every `/…` goes through here, so one check
  # covers the entire slash surface. Non-admin callers get a polite
  # refusal that doesn't leak which commands exist.
  let callerPermGate = resolveCallerPermission(cfg, msg)
  if callerPermGate == pmAny:
    return "System commands (`/status`, `/user …`, `/channel …`, etc.) " &
           "are restricted to internal staff. Ask a SuperAdmin if you " &
           "need something administrative done."
  # Internal-tier passes the entry gate. Each subcommand applies its
  # own additional check below — e.g. `/user bind` requires pmSuperAdmin
  # (true SA only), `/user add` requires pmAdmin (Admin or SA), and
  # `/user invite` accepts any internal.
  if cmd == "/status":
    let workspace = cfg[].workspacePath()
    let graph = loadWorld(workspace)
    let pid = getpid()
    let upSecs = if gStartTime > 0: epochTime() - gStartTime else: 0.0
    let baseNims = getNimClawDir() / "BASE.nims"
    let baseJson = workspace / "BASE.json"
    var createdAt: int64 = 0
    if fileExists(baseNims):
      createdAt = baseNims.getCreationTime().toUnix()
    elif fileExists(baseJson):
      createdAt = baseJson.getCreationTime().toUnix()
    let updatedAt =
      if fileExists(baseJson): baseJson.getLastModificationTime().toUnix()
      else: 0'i64

    # User counts by kind — skips corporate/invite, skips declared
    # agents (those render in the AGENTS section).
    var ourAgents = initHashSet[string]()
    for a in cfg.agents.named: ourAgents.incl(a.name)
    var persons, ais, services, unknowns = 0
    if graph != nil:
      for id, ent in graph.entities.pairs:
        if ent.kind in {ekCorporate, ekInvite}: continue
        if ent.kind == ekAI and ent.name in ourAgents: continue
        case ent.kind
        of ekPerson: inc persons
        of ekAI: inc ais
        of ekService: inc services
        of ekUnknown: inc unknowns
        else: discard

    # Agents (declared).
    var agentLines: seq[string]
    for a in cfg.agents.named:
      var bits: seq[string] = @["`" & a.name & "`"]
      if a.model.len > 0: bits.add("model=" & a.model)
      if a.role.isSome and a.role.get().len > 0: bits.add("role=" & a.role.get())
      agentLines.add("  - " & bits.join(" · "))

    # Feishu app routing.
    var appLines: seq[string]
    for a in cfg.channels.feishu.apps:
      let who = if a.agent.len > 0: a.agent else: "(default)"
      appLines.add("  - `" & a.app_id & "` → " & who)

    var res = "**NimClaw System Status**\n"
    res.add("\n**Gateway**\n")
    res.add("- PID: `" & $pid & "`\n")
    res.add("- Uptime: " & fmtUptime(upSecs) & "\n")
    res.add("- Model: `" & al.model & "`\n")
    res.add("- Session: `" & msg.session_key & "`\n")
    res.add("- Stream intermediary: " &
            (if cfg.agents.defaults.stream_intermediary: "ON" else: "OFF") & "\n")

    res.add("\n**Company**\n")
    res.add("- Dir: `" & getNimClawDir() & "`\n")
    if createdAt > 0:
      res.add("- Created: " & fmtUnixTime(createdAt) & "\n")
    if updatedAt > 0:
      res.add("- Last `co update`: " & fmtUnixTime(updatedAt) & "\n")

    res.add("\n**Users** (" & $(persons + ais + services + unknowns) & " total)\n")
    res.add("- Person: " & $persons & "\n")
    res.add("- AI: " & $ais & "\n")
    res.add("- Service: " & $services & "\n")
    res.add("- Unknown: " & $unknowns & "\n")

    res.add("\n**Agents** (" & $cfg.agents.named.len & ")\n")
    if agentLines.len > 0: res.add(agentLines.join("\n") & "\n")
    else: res.add("  (none declared)\n")

    if appLines.len > 0:
      res.add("\n**Feishu apps** (" & $appLines.len & ")\n")
      res.add(appLines.join("\n") & "\n")

    return res
  elif cmd.startsWith("/stream "):
    let val = cmd.replace("/stream ", "").strip().toLowerAscii()
    if val in ["on", "true", "1"]:
      cfg.agents.defaults.stream_intermediary = true
      saveConfig(getConfigPath(), cfg[])
      return "Intermediary thought streaming enabled."
    elif val in ["off", "false", "0"]:
      cfg.agents.defaults.stream_intermediary = false
      saveConfig(getConfigPath(), cfg[])
      return "Intermediary thought streaming disabled."
    else:
      return "Invalid stream value. Use: `/stream on` or `/stream off`."
  elif cmd.startsWith("/model"):
    let parts = cmd.split(" ", 1)
    if parts.len < 2 or parts[1].strip().len == 0:
      # `/model` (read) is per-agent: shows whichever office's chain
      # the caller is currently chatting with. The fallback chain
      # below comes from `al.provider`, which was built from
      # `al.agentName`'s own `models` list.
      var output = "**" & al.agentName & "**'s primary: `" & al.model & "`\n"

      # Show what the chain WILL try on the next call, given current
      # health state. Diverges from the configured primary whenever
      # one or more upstream entries are unhealthy or cooling down.
      # Health is cross-session, so the "next usable entry" is the
      # same for all sessions — there's no per-session divergence
      # since per-session sticky was removed.
      if al.provider of FallbackLLMProvider:
        let fp = FallbackLLMProvider(al.provider)
        let cur = fp.nextUsableEntry()
        if cur.exhausted:
          output &= "Next call: ⚠️ chain exhausted (every provider unhealthy or cooling down). Use `/provider` to inspect; fix the underlying issue and `/provider reset <name>`, or `/model X:Y` to swap primary.\n\n"
        else:
          let entryMarker =
            if cur.idx == 0: " (primary)"
            else: " (fallback — primary entries are currently unusable)"
          output &= "Next call will try: `" & cur.name & "` / `" & cur.model & "`" & entryMarker & "\n\n"
        output &= "**Fallback chain:**\n"
        for i, entry in fp.entries:
          let marker =
            if cur.exhausted: " ← exhausted"
            elif i == cur.idx: " ← NEXT"
            elif i == 0: " (primary, currently unusable)"
            else: ""
          # Health badge from the cross-session registry. Disagrees
          # with `THIS SESSION` when, e.g., the registry knows
          # deepseek is unhealthy but this particular session has
          # been re-routed and is now happily on kimi.
          var healthBadge = ""
          if gCtx != nil and gCtx.healthRegistry != nil:
            let snap = gCtx.healthRegistry.snapshot()
            for tup in snap:
              if tup.name == entry.name:
                case tup.health.state
                of provider_health.hsHealthy: healthBadge = " ✓"
                of provider_health.hsCoolingDown: healthBadge = " ⏳"
                of provider_health.hsUnhealthy: healthBadge = " ⚠ unhealthy"
                break
          let ctxBadge =
            if entry.contextWindow > 0:
              "  ctx=" & $(entry.contextWindow div 1000) & "K"
            else: ""
          output &= "  [" & $i & "] `" & entry.name & "` / `" &
                    entry.model & "`" & ctxBadge & healthBadge &
                    marker & "\n"
        output &= "\n"

      let graph = loadWorld(cfg[].workspacePath())
      if graph.providers != nil and graph.providers.kind == JObject and graph.providers.len > 0:
        output &= "**Configured providers** (BASE.nims):\n"
        for key, pNode in graph.providers.getFields():
          let rawKey = pNode{"apiKey"}.getStr("")
          let hasKey = if rawKey.len > 0: "✓ key" else: "⚠ no key"
          output &= "**" & key & "** (" & hasKey & ")\n"
          if pNode.hasKey("models") and pNode["models"].kind == JArray:
            # Dedupe view-side too — even if BASE.json has stale
            # duplicates from a pre-dedupe `claw co update`, the
            # display stays clean.
            var seen = initHashSet[string]()
            for m in pNode["models"]:
              let modelId = m.getStr()
              if modelId in seen: continue
              seen.incl(modelId)
              let marker =
                if modelId == al.model: " ← " & al.agentName & "'s primary"
                else: ""
              output &= "  `" & key & ":" & modelId & "`" & marker & "\n"
          else:
            output &= "  (no models listed)\n"
      output &= "\nUsage: `/model <provider:model>` to switch primary; `/model list [<provider>]` to query the provider's /models API"
      return output
    var modelStr = parts[1].strip()

    # Accept natural-language verbs as a no-op prefix. Users
    # frequently type `/model switch X:Y`, `/model use X:Y`, or
    # `/model set X:Y` — they read more naturally than the bare
    # `/model X:Y` form. Without this, the verb gets captured as
    # part of the provider name and produces a misleading error
    # ("No API key found for provider `switch opencode-go`").
    for verb in ["switch ", "use ", "set "]:
      if modelStr.startsWith(verb):
        modelStr = modelStr[verb.len..^1].strip()
        break

    # /model list [provider]
    if modelStr == "list" or modelStr.startsWith("list "):
      let listParts = modelStr.split(" ", 1)
      # No provider arg → default to whichever provider serves the
      # caller's current primary model (`al.model`). Falls back to
      # graph.providers[0] if al.model isn't recognised.
      var listProvider =
        if listParts.len > 1: listParts[1].strip()
        else: ""
      let graph = loadWorld(cfg[].workspacePath())
      if listProvider.len == 0 and graph != nil and
         graph.providers != nil and graph.providers.kind == JObject:
        for k, pNode in graph.providers.getFields():
          if pNode.hasKey("models") and pNode["models"].kind == JArray:
            for m in pNode["models"]:
              if m.getStr() == al.model:
                listProvider = k
                break
            if listProvider.len > 0: break
        # Fallback: first declared provider.
        if listProvider.len == 0:
          for k, _ in graph.providers.getFields():
            listProvider = k
            break
      if listProvider.len == 0:
        return "No provider specified and none configured. Use " &
               "`/model list <provider>` (e.g. `/model list deepseek`)."
      let tech = resolveProviderTech("", listProvider, graph.providers, providerOverride = listProvider)
      if tech.apiBase == "": return "No API base URL for provider `" & listProvider & "`"
      if tech.apiKey == "": return "No API key for provider `" & listProvider & "`"
      try:
        let c = newCurly()
        var headers = emptyHttpHeaders()
        headers["Authorization"] = "Bearer " & tech.apiKey
        let resp = c.get(tech.apiBase & "/models", headers)
        if resp.code < 200 or resp.code >= 300:
          return "Failed to list models from `" & listProvider & "`: HTTP " & $resp.code
        let j = parseJson(resp.body)
        var models: seq[string] = @[]
        if j.hasKey("data") and j["data"].kind == JArray:
          for m in j["data"]:
            models.add(m{"id"}.getStr())
        if models.len == 0: return "No models found for `" & listProvider & "`"
        models.sort()
        var msg = "**Models for `" & listProvider & "`** (" & $models.len & "):\n"
        for m in models:
          msg &= "  `" & listProvider & ":" & m & "`\n"
        return msg
      except Exception as e:
        return "Error listing models: " & e.msg

    # Parse provider:model (or provider/model). Bare model names with
    # no separator are rejected — too ambiguous now that there's no
    # global default provider to infer from.
    var providerKey, modelName: string
    let colonPos = modelStr.find(':')
    if colonPos > 0:
      providerKey = modelStr[0..<colonPos]
      modelName = modelStr[colonPos+1..^1]
    else:
      let slashPos = modelStr.find('/')
      if slashPos > 0:
        providerKey = modelStr[0..<slashPos]
        modelName = modelStr[slashPos+1..^1]
      # else: providerKey stays empty — caught by the next check.

    let graph = loadWorld(cfg[].workspacePath())
    # Sanity-check parsed providerKey before lookup so malformed input
    # produces a useful error rather than "No API key found for
    # provider `<garbage>`". Provider names are alphanum + `-` only.
    if providerKey.len == 0:
      return "Couldn't parse provider name from `" & modelStr &
             "`. Expected `<provider>:<model>` (e.g. `/model deepseek:deepseek-v4-flash`)."
    var malformed = false
    for c in providerKey:
      if not (c.isAlphaNumeric or c == '-' or c == '_'):
        malformed = true; break
    if malformed:
      return "Provider name `" & providerKey & "` contains unexpected " &
             "characters. Expected `<provider>:<model>` (e.g. " &
             "`/model deepseek:deepseek-v4-flash`). Run `/model` to see " &
             "configured providers."
    let tech = resolveProviderTech(modelName, providerKey, graph.providers, providerOverride = providerKey)
    if tech.apiKey == "":
      # Distinguish "we know this provider but its key is missing" from
      # "we don't know this provider at all".
      let knownProvider =
        graph.providers != nil and graph.providers.kind == JObject and
        graph.providers.hasKey(providerKey)
      if not knownProvider:
        return "Unknown provider `" & providerKey & "`. Run `/model` to " &
               "see configured providers."
      return "No API key configured for provider `" & providerKey &
             "`. Set the relevant env var (or BASE.nims `apiKey \"...\"`) " &
             "and `claw co update`."

    # Per-agent switch: `/model X:Y` from Lexi's chat reorders Lexi's
    # `models` list so `Y` is position 0 (the agent's primary). Other
    # agents are untouched — Atlas keeps his preferences. The change
    # persists to BASE.json so it survives gateway restarts.
    #
    # Why per-agent: post-Phase 4, every agent has their own `models`
    # list and `buildProviderChainForAgent` reads it on each office
    # build. A "global default" pointer was redundant — `models[0]`
    # IS the agent's default. The earlier global-flip implementation
    # didn't survive office rebuilds because each office's chain is
    # rebuilt from `a.models[0]`, not from the cfg globals.
    #
    # Provider must serve the chosen model. We don't validate that
    # here at write time (the chain build will warn-and-skip if
    # there's no serving provider for `modelName`); operators see
    # the result in `/model` output.
    let targetAgent = al.agentName
    let targetKey = targetAgent.toLowerAscii
    let qualifiedModel = providerKey & ":" & modelName
    let graphFile = getConfigPath().parentDir() / "BASE.json"
    var newModels: seq[string] = @[]
    if fileExists(graphFile):
      var base = parseFile(graphFile)
      if base.hasKey("config") and base["config"].hasKey("agents") and
         base["config"]["agents"].hasKey("named"):
        for i in 0..<base["config"]["agents"]["named"].len:
          let agentEntry = base["config"]["agents"]["named"][i]
          if agentEntry{"name"}.getStr().toLowerAscii != targetKey: continue
          # Read existing models, prepend the new one, dedupe (preserving
          # later entries as fallbacks). Bare names match the new pick;
          # qualified `provider:model` names also match if the suffix
          # equals modelName — supports both shapes during transition.
          var existing: seq[string] = @[qualifiedModel]
          if agentEntry.hasKey("models") and agentEntry["models"].kind == JArray:
            for m in agentEntry["models"]:
              let s = m.getStr()
              if s.len == 0: continue
              # Drop any stale entry that points at the same model
              # (bare or qualified). Otherwise the agent ends up with
              # `[X, A, X, B]` after a swap-back-swap.
              let bare =
                if ':' in s: s.split(':', 1)[1]
                elif '/' in s: s.split('/', 1)[1]
                else: s
              if s == qualifiedModel or bare == modelName: continue
              existing.add(s)
          newModels = existing
          var modelsArr = newJArray()
          for m in existing: modelsArr.add(%m)
          base["config"]["agents"]["named"][i]["models"] = modelsArr
          # Mirror to the deprecated singulars for any back-compat
          # reader still on `agentEntry.model` / `agentEntry.provider`.
          # These will go away in the cfg-cleanup pass; until then,
          # keeping them in sync prevents stale display.
          base["config"]["agents"]["named"][i]["model"] = %modelName
          base["config"]["agents"]["named"][i]["provider"] = %providerKey
          break
      writeFile(graphFile, base.pretty(4))

    if newModels.len == 0:
      return "Couldn't find agent `" & targetAgent & "` in BASE.json. " &
             "This shouldn't happen — try `/co update` and retry."

    # Rebuild only the target agent's chain. Other offices are
    # untouched — their `models` lists weren't changed.
    let freshGraph = loadWorld(cfg[].workspacePath())
    let newProvider = buildProviderChainForAgent(freshGraph, newModels,
                                                  (if gCtx != nil: gCtx.healthRegistry
                                                   else: nil))
    al.provider = newProvider
    al.model = modelName
    # Reflect the change in the in-memory NamedAgentConfig too, so a
    # later office rebuild (e.g. via /restart-less re-ensureOffice)
    # picks up the new order without needing a config reload.
    for i in 0 ..< cfg.agents.named.len:
      if cfg.agents.named[i].name.toLowerAscii == targetKey:
        cfg.agents.named[i].models = newModels
        cfg.agents.named[i].model = modelName
        cfg.agents.named[i].provider = providerKey
        break

    # Don't clear the session on model switch. Conversation history is
    # in OpenAI-compatible message format; modern LLMs handle
    # context-continuation across model boundaries. Operators who
    # want a fresh start use `/session reset`.
    return "Switched **" & targetAgent & "**'s primary to `" &
           qualifiedModel & "` (other agents untouched). Persisted " &
           "to BASE.json — survives restart. Session history preserved."
  elif cmd == "/provider" or cmd == "/providers" or
       cmd.startsWith("/provider ") or cmd.startsWith("/providers "):
    # Health-state inspection + manual recovery for chain entries.
    # The cross-session circuit breaker (providers/health.nim) tracks
    # which providers have failed recently and skips them on the next
    # call. Operators see / clear that state via this command.
    let parts = cmd.split(" ", 2)
    if gCtx == nil or gCtx.healthRegistry == nil:
      return "No provider health registry active."
    if parts.len < 2 or parts[1].strip().len == 0 or parts[1] == "status":
      # /provider — list every chain entry with its health badge
      var output = "**Provider health** (cross-session circuit breaker):\n\n"
      let snap = gCtx.healthRegistry.snapshot()
      var seen = initHashSet[string]()
      for tup in snap: seen.incl(tup.name)
      # Walk the configured providers from BASE.json so untouched
      # ones (still implicitly healthy) also show up.
      let graph = loadWorld(cfg[].workspacePath())
      if graph.providers != nil and graph.providers.kind == JObject:
        for pName, _ in graph.providers.getFields():
          var found: Option[provider_health.ProviderHealth]
          for tup in snap:
            if tup.name == pName: found = some(tup.health); break
          let h =
            if found.isSome: found.get
            else: provider_health.ProviderHealth(state: provider_health.hsHealthy)
          let badge = case h.state
            of provider_health.hsHealthy: "✓ healthy"
            of provider_health.hsCoolingDown: "⏳ cooling down"
            of provider_health.hsUnhealthy: "⚠ unhealthy"
          output.add("**" & pName & "** " & badge & "\n")
          if h.state != provider_health.hsHealthy:
            if h.lastError.len > 0:
              output.add("  reason: " & h.lastError & "\n")
            if h.lastFailureTime > 0:
              output.add("  failed at: " & $fromUnix(h.lastFailureTime) & "\n")
          if h.state == provider_health.hsCoolingDown and h.cooldownUntil > 0:
            let remaining = h.cooldownUntil - getTime().toUnix
            if remaining > 0:
              output.add("  cooldown: " & $remaining & "s remaining\n")
            else:
              output.add("  cooldown: expired (re-probes on next call)\n")
          if h.lastSuccessTime > 0 and h.state == provider_health.hsHealthy:
            output.add("  last success: " & $fromUnix(h.lastSuccessTime) & "\n")
          # Performance tracking — only render when samples exist (skip
          # untouched providers and ones loaded before perf was added).
          if h.successCount > 0 and h.tokensPerSecAvg > 0.0:
            output.add("  perf: " &
                       formatFloat(h.tokensPerSecAvg, ffDecimal, 1) &
                       " tok/s avg, " &
                       formatFloat(h.avgResponseTimeSec, ffDecimal, 1) &
                       "s/call (" & $h.successCount & " samples)\n")
            let tmo = gCtx.healthRegistry.recommendedTimeoutSec(pName)
            output.add("  next call timeout: " & $tmo & "s\n")
      output.add("\nUsage: `/provider reset <name>` to manually mark " &
                 "a provider healthy after fixing the underlying issue " &
                 "(top-up balance, rotate API key).")
      return output
    let action = parts[1].strip()
    case action
    of "reset":
      if parts.len < 3 or parts[2].strip().len == 0:
        return "Usage: `/provider reset <name>` — name comes from /provider output."
      let pName = parts[2].strip()
      let cleared = gCtx.healthRegistry.resetProvider(pName)
      if cleared:
        return "✓ Marked `" & pName & "` healthy. Next call will probe it again."
      else:
        return "ℹ `" & pName & "` was already healthy or unknown — nothing to clear."
    else:
      return "Unknown subcommand `" & action & "`. Try `/provider` (status) or `/provider reset <name>`."
  elif cmd.startsWith("/user"):
    # Namespace for user management: `/user <subcmd> [<args>...]`.
    # Entry gate has confirmed pmInternal+; per-subcommand checks below
    # tighten further. Dispatch routes through runUserCommand /
    # mintCustomerInvite so CLI and chat share the same backend.
    # `/user invite` rewrites to the `/invite` alias below for
    # presentation-layer formatting.
    let rawParts = strutils.splitWhitespace(cmd)
    let argv = if rawParts.len > 1: rawParts[1 .. ^1] else: @[]
    if argv.len == 0 or argv[0] == "help":
      return renderCommandDetail("/user")
    let pr = parseArgs("/user", cmd, argv)
    if not pr.ok: return pr.error
    let parts = rawParts
    if parts.len < 2 or parts[1] == "help":
      return "**`/user` — user management**\n\n" &
             "**Creating users**\n\n" &
             "  `/user add <name> [<permission>]`   🔒 Admin\n" &
             "    Create a NEW internal-tier user (Member/Admin/Staff/\n" &
             "    Employee/SuperAdmin). Persists to BASE.nims, mints a\n" &
             "    one-shot bind code so they attach a channel identifier\n" &
             "    on their first message.\n" &
             "    Examples:\n" &
             "      `/user add Alice`          — Member (default)\n" &
             "      `/user add Bob Admin`\n\n" &
             "  `/user register <name> [<agent>] [<uses>] [--skill=...]`\n" &
             "    Create a NEW customer (external-tier). Persists to\n" &
             "    BASE.nims, mints an invite code with optional skill\n" &
             "    grants. Operator-issued.\n" &
             "    Examples:\n" &
             "      `/user register Alice`\n" &
             "      `/user register Acme Atlas 3 --skill=sungrow::acme-solar`\n\n" &
             "  `/user invite <customer-name> [<agent>] [<uses>]`\n" &
             "    Peer referral — same backend as `register` but the\n" &
             "    issuer is an existing customer (customer-to-customer\n" &
             "    onboarding). Use `invite list` to see outstanding codes.\n\n" &
             "**Promoting / editing**\n\n" &
             "  `/user join <nc:id> [<permission>]`   🔒 Admin\n" &
             "    Promote an EXISTING customer to internal-tier. Same\n" &
             "    nc:id, no new code (they already have a channel\n" &
             "    binding). BASE.nims block's permission line is updated.\n" &
             "    Example: `/user join nc:6 Member`\n\n" &
             "  `/user edit <nc:id> <field> <value>`   🔒 Admin\n" &
             "    Single-field update — `name`, `permission`, `jobTitle`,\n" &
             "    `kind`. For identifiers, use `/user rebind` instead.\n" &
             "    Examples:\n" &
             "      `/user edit nc:5 jobTitle \"Field Engineer\"`\n\n" &
             "  `/user rebind <nc:id> [--wipe]`   🔒 SuperAdmin\n" &
             "    Issue a fresh bind code for an existing internal user.\n" &
             "    Use for lost-device recovery or channel migration.\n\n" &
             "**Reading**\n\n" &
             "  `/user list` [filters]\n" &
             "    Roster of users. `--kind=`, `--tier=`, `--permission=`,\n" &
             "    `--sort=`, `--reverse`, `--recycled`, `--all`.\n\n" &
             "  `/user show <nc:id>`\n" &
             "    Detailed view (relationships, trust, mood) for one user.\n\n" &
             "  `/user trust`\n" &
             "    Edge list — one row per agent→person edge.\n\n" &
             "**Lifecycle**\n\n" &
             "  `/user remove <nc:id>`   🔒 Admin\n" &
             "    Soft remove (default) preserves history; `--hard` deletes.\n\n" &
             "Access:  `list`/`show`/`trust`/`register`/`invite` — any internal\n" &
             "         `add`/`join`/`edit`/`remove` — Admin or SuperAdmin\n" &
             "         `rebind` — SuperAdmin only"
    let sub = parts[1]
    let subArgs = if parts.len > 2: parts[2 .. ^1] else: @[]
    # Per-subcommand ACL: the entry gate above lets through any
    # internal-tier caller; tighten further by subcommand intent.
    #   list / show / trust / invite  → any internal (entry gate suffices)
    #   add / edit / remove           → Admin or SuperAdmin
    #   bind                          → SuperAdmin only
    if sub in ["list", "show", "trust"]:
      var cfgCopy = cfg[]
      let body = runUserCommand(cfgCopy, @[sub] & subArgs)
      let wantsJson = "--format=json" in subArgs or "--json" in subArgs
      if wantsJson: return body
      return codeBlock(body)
    if sub == "remove":
      if callerPermGate < pmAdmin:
        return "Only Admin or SuperAdmin can remove users. " &
               "(For removing a customer's access without deleting " &
               "their record, ask an Admin.)"
      var cfgCopy = cfg[]
      let body = runUserCommand(cfgCopy, @[sub] & subArgs)
      return codeBlock(body)
    if sub == "add":
      if callerPermGate < pmAdmin:
        return "Only Admin or SuperAdmin can add internal users. " &
               "(For customer onboarding, use `/user register`.)"
      var cfgCopy = cfg[]
      let body = runUserCommand(cfgCopy, @[sub] & subArgs)
      return codeBlock(body)
    if sub == "register":
      # Operator-issued customer creation — same access as the legacy
      # `/user invite` (any internal can mint a customer code).
      var cfgCopy = cfg[]
      let body = runUserCommand(cfgCopy, @[sub] & subArgs)
      return codeBlock(body)
    if sub == "join":
      if callerPermGate < pmAdmin:
        return "Only Admin or SuperAdmin can promote users. " &
               "(`/user join <nc:id> [<permission>]` — promotes an " &
               "existing customer to internal-tier.)"
      var cfgCopy = cfg[]
      let body = runUserCommand(cfgCopy, @[sub] & subArgs)
      return codeBlock(body)
    if sub == "edit":
      if callerPermGate < pmAdmin:
        return "Only Admin or SuperAdmin can edit users. " &
               "(`/user edit <nc:id> <field> <value>` — fields: " &
               "name, permission, jobTitle, kind.)"
      var cfgCopy = cfg[]
      let body = runUserCommand(cfgCopy, @[sub] & subArgs)
      return codeBlock(body)
    if sub in ["bind", "rebind"]:
      if callerPermGate < pmSuperAdmin:
        return "Only SuperAdmin can issue bind codes. " &
               "(For non-SuperAdmin internal onboarding, use `/user add`.)"
      var cfgCopy = cfg[]
      let body = runUserCommand(cfgCopy, @["rebind"] & subArgs)
      return codeBlock(body)
    if sub == "invite":
      # Customer-to-customer peer referral. Routes to the existing
      # `/invite` alias for paste-template formatting; the backend
      # (mintCustomerInvite) is shared with `register`. Open to any
      # internal — when we add Customer-tier callers (peer-issued
      # referrals), this is where the relaxed gate will live.
      let cmdRewrite = "/invite " & subArgs.join(" ")
      var fakeMsg = msg
      fakeMsg.content = cmdRewrite
      return await handleSystemCommand(cfg, fakeMsg, al)
    return "Unknown /user subcommand: `" & sub & "`.\n" &
           "Available: `list`, `show`, `trust`, `add`, `register`, " &
           "`join`, `edit`, `rebind`, `invite`, `remove`."

  elif cmd.startsWith("/invite"):
    # Legacy alias for `/user invite`. Entry gate has confirmed
    # pmInternal+ (any internal can mint a customer invite); we only
    # need the caller's nc:id here for invite provenance (the
    # `issuedBy` field on InviteConstraint).
    let workspace = cfg[].workspacePath()
    let g = loadWorld(workspace)
    var issuer = ""
    if g != nil:
      let channelKey =
        if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
          msg.channel & ":" & msg.metadata["app_id"]
        else: msg.channel
      let (entID, _) = g.resolveUserGraph(channelKey, msg.sender_id)
      if uint32(entID) > 0:
        issuer = toAlias(entID)
    var parts = strutils.splitWhitespace(cmd)
    # Strip optional flags. `--lang` = paste-template language.
    # `--skill` (repeatable) or `--skills` (comma-separated) build the
    # customer's skill allowlist — each entry is a grant in
    # `[user@]skill[/res,…]` form.
    var targetLang = ""
    var allowedSkills: seq[string]
    var positional: seq[string]
    for i in 0 ..< parts.len:
      let p = parts[i]
      if i == 0: positional.add(p); continue  # keep "/invite"
      if p.startsWith("--lang="):
        targetLang = p["--lang=".len .. ^1]
      elif p.startsWith("--skill="):
        allowedSkills.add(p["--skill=".len .. ^1])
      elif p.startsWith("--skills="):
        for s in p["--skills=".len .. ^1].split(','):
          let s2 = s.strip()
          if s2.len > 0: allowedSkills.add(s2)
      else:
        positional.add(p)
    parts = positional
    if parts.len < 2:
      return renderCommandDetail("/user")
    let customerName = parts[1]
    let agentName =
      if parts.len >= 3: parts[2]
      elif cfg[].agents.named.len > 0: cfg[].agents.named[0].name
      else: msg.recipient_id
    var maxUses = 1
    if parts.len >= 4:
      try: maxUses = parseInt(parts[3])
      except ValueError:
        return "Error: <uses> must be an integer, got '" & parts[3] &
               "'. Usage: `/invite <customer> [<agent>] [<uses>] " &
               "[--skill=<grant>]...`."
    let inv = mintCustomerInvite(workspace, issuer, customerName,
                                  agentName, maxUses, allowedSkills, targetLang)
    if not inv.ok:
      return "Error: " & inv.error
    # One clean, shareable line. Hand-authored per language — no runtime
    # translation, no Feishu spam-filter gymnastics. Operator forwards
    # this single line to the customer; the customer pastes it back as
    # their first message and the gateway intercept matches on substring.
    let brand = resolveCompanyBrand(g)
    let shareLine = inviteCodeMessage(brand, inv.code, targetLang)
    return "**Customer invite created**\n\n" &
           codeBlock("Customer: " & inv.customerName & " (" & inv.targetNcId & ")\n" &
                     "Agent:    " & inv.agentName & "\n" &
                     "Max uses: " & $inv.maxUses &
                     (if inv.allowedSkills.len > 0:
                        "\nSkills:   " & inv.allowedSkills.join(", ")
                      else: "") &
                     (if targetLang.len > 0: "\nLanguage: " & targetLang else: "")) & "\n\n" &
           "**Forward this to the customer:**\n\n" &
           codeBlock(shareLine) & "\n" &
           "They DM it to any channel routing to " & inv.agentName &
           ". Gateway authenticates pre-LLM and replies with a welcome\n" &
           "message in " & (if targetLang.len > 0: targetLang else: "their language") & "."

  elif cmd == "/help" or cmd.startsWith("/help "):
    # Pass the caller's actual tier so renderHelp can mark commands
    # the caller can't run with the lock icon.
    let parts = strutils.splitWhitespace(cmd)
    if parts.len >= 2:
      return renderCommandDetail(parts[1])
    return renderHelp(callerPermGate)

  elif cmd.startsWith("/channel"):
    # `/channel auth feishu <app_id> <app_secret> [<agent>]`
    # `/channel list`
    if callerPermGate < pmAdmin:
      return "Only Admin or SuperAdmin can manage channels."
    let rawParts = strutils.splitWhitespace(cmd)
    # parts[0] = "/channel", pass the rest to docopt.
    let argv = if rawParts.len > 1: rawParts[1 .. ^1] else: @[]
    let pr = parseArgs("/channel", cmd, argv)
    if not pr.ok: return pr.error
    let parts = rawParts
    if parts.len < 2:
      return renderCommandDetail("/channel")
    let sub = parts[1]
    if sub == "list":
      # Single source of truth — same CLI proc, wrapped in a code block
      # so the NAME/STATUS/CREDENTIAL/DETAILS columns stay aligned.
      var cfgCopy = cfg[]
      return codeBlock(runChannelCommand(cfgCopy, @["list"])) & "\n\n" &
             "After `/channel auth`, run `/restart` to bring the new " &
             "channel online."
    if sub == "auth":
      if parts.len < 3:
        return "Usage: `/channel auth <channel_type> <args…>` " &
               "(only `feishu` supported for now)."
      let chType = parts[2].toLowerAscii
      if chType != "feishu" and chType != "lark":
        return "Error: only `feishu` is supported right now. Got: `" & chType & "`"
      if parts.len < 5:
        return "Usage: `/channel auth feishu <app_id> <app_secret> [<agent>]`\n" &
               "Get credentials from https://open.feishu.cn/app"
      var authArgs: seq[string] = @[parts[3], parts[4]]
      if parts.len >= 6: authArgs.add(parts[5])
      # Reuse the canonical CLI path — same lark-cli auth call,
      # same BASE.nims upsert. Result string is already markdown-ish.
      return authFeishuChannel(cfg[], authArgs) & "\n\n" &
             "Run `/restart` to bring the new app online."
    if sub == "assign":
      # `/channel assign <app_id> <agent>` — reroute a Feishu app to a
      # different agent. Edits BASE.nims; `/restart` applies.
      if parts.len < 4:
        return "Usage: `/channel assign <app_id> <agent>`\n" &
               "Example: `/channel assign cli_a948ea9ee5785cd3 Atlas`"
      let appID = parts[2]
      let agentName = parts[3]
      return reassignFeishuApp(cfg[], appID, agentName)
    return "Unknown /channel subcommand: `" & sub & "`.\n" &
           "Try `/channel list`, `/channel auth feishu …`, or " &
           "`/channel assign <app_id> <agent>`."

  elif cmd == "/co" or cmd == "/company" or
       cmd.startsWith("/co ") or cmd.startsWith("/company "):
    if callerPermGate < pmAdmin:
      return "Only Admin or SuperAdmin can run `/co` commands."
    # Subcommands:
    #   `/co update` — rebuild BASE.json from BASE.nims (no restart).
    #   `/co cost`   — token+USD breakdown across all agents.
    let parts = strutils.splitWhitespace(cmd)
    let sub = if parts.len > 1: parts[1] else: ""
    if sub == "update":
      let (ok, output) = rebuildBaseJson(getNimClawDir())
      if ok:
        return "✅ BASE.json rebuilt from BASE.nims. Changes take effect on " &
               "next `/restart`.\n\n" &
               (if output.strip().len > 0: codeBlock(output) else: "")
      else:
        return "❌ BASE.nims rebuild failed — BASE.json NOT updated. Fix the " &
               "error below and retry:\n\n" & codeBlock(output)
    if sub == "cost":
      # Aggregate per-agent tokens across the company. Cost uses each
      # agent's declared model rate from the pricing table; unknown
      # models show "—" in the cost column so the operator can tell
      # the difference between $0 (truly unused) and "no rate yet".
      var rows: seq[string] = @[
        "AGENT       MODEL                  IN       OUT      TOTAL    COST"]
      var coTokensIn, coTokensOut = 0
      var coCost = 0.0
      var unknownModels: seq[string]
      for a in cfg.agents.named:
        let key = a.name.toLowerAscii()
        var tIn, tOut = 0
        if gCtx.offices.hasKey(key):
          let al2 = gCtx.offices[key]
          tIn = al2.liveTokensInTotal
          tOut = al2.liveTokensOutTotal
        coTokensIn += tIn
        coTokensOut += tOut
        let model = a.model
        let cost = estimateCost(tIn, tOut, model)
        let costStr =
          if knownModel(model): fmtCost(cost)
          elif tIn + tOut == 0: "-"
          else: "— (" & model & " not priced)"
        if not knownModel(model) and model.len > 0 and model notin unknownModels:
          unknownModels.add(model)
        if knownModel(model): coCost += cost
        rows.add(a.name.alignLeft(12) & model.alignLeft(23) &
                 claw_context.formatTokens(tIn.int64).alignLeft(9) &
                 claw_context.formatTokens(tOut.int64).alignLeft(9) &
                 claw_context.formatTokens((tIn+tOut).int64).alignLeft(9) &
                 costStr)
      rows.add("")
      rows.add("TOTAL                              " &
               claw_context.formatTokens(coTokensIn.int64).alignLeft(9) &
               claw_context.formatTokens(coTokensOut.int64).alignLeft(9) &
               claw_context.formatTokens((coTokensIn+coTokensOut).int64).alignLeft(9) &
               fmtCost(coCost))
      var body = codeBlock(rows.join("\n"))
      body.add("\n\nTotals reset on each `/restart`. Rates are per-million " &
               "tokens from each provider's current pricing page.")
      if unknownModels.len > 0:
        body.add("\n\nℹ️  Untracked model(s): " & unknownModels.join(", ") &
                 " — add rates in `src/claw/pricing.nim` to include in totals.")
      return body
    return "Usage: `/co update` or `/co cost`."

  elif cmd == "/agent" or cmd == "/agents" or
       cmd.startsWith("/agent ") or cmd.startsWith("/agents "):
    if callerPermGate < pmAdmin:
      return "Only Admin or SuperAdmin can manage agents."
    # Live-state inspection. `/agent` or `/agent list` → one-line per agent
    # with WORKING/idle + iteration + elapsed + outcome (OK/error). Idle rows
    # show how the previous turn ended so operators can spot silent failures
    # (HTTP 524 timeouts, tool-loop exhaustion, etc.) without tailing the log.
    # `/agent <name>` → full detail including last-turn tool log and error.
    let parts = strutils.splitWhitespace(cmd)
    let sub = if parts.len > 1: parts[1] else: "list"
    let now = epochTime()
    proc shortErr(e: string): string =
      if e.len == 0: return ""
      truncate(e.replace("\n", " ").replace("\r", " "), 40)
    proc fmtTokens(n: int): string =
      if n == 0: "-" else: claw_context.formatTokens(n.int64)
    proc toolDisplay(t: TaskSnapshot): string =
      if t == nil: "-"
      elif t.lastTool.len > 0: t.lastTool
      else: "(no tool yet)"
    if sub == "list":
      # MODEL column shows the live model on the agent loop when the
      # office is open (reflects /model overrides without restart),
      # falling back to the static config for out-of-office agents.
      # REPORTS-TO and SERVES come from the graph: REPORTS-TO is the
      # first reportsTo target's name (with `+N` if there are more),
      # SERVES is the count of `serves` edges (customer fan-out).
      let workspace = cfg[].workspacePath()
      let agentGraph = loadWorld(workspace)
      let agentInvites = loadInvites(workspace)
      proc agentRelationships(name: string): (string, string) =
        if agentGraph == nil: return ("-", "-")
        if not agentGraph.nameIndex.hasKey(name): return ("-", "-")
        let id = agentGraph.nameIndex[name]
        if not agentGraph.entities.hasKey(id): return ("-", "-")
        let ent = agentGraph.entities[id]
        var reports = "-"
        if ent.reportsTo.len > 0:
          let firstID = ent.reportsTo[0].targetID
          if agentGraph.entities.hasKey(firstID):
            reports = agentGraph.entities[firstID].name
            if ent.reportsTo.len > 1:
              reports.add(" +" & $(ent.reportsTo.len - 1))
        # Count distinct customers served by this agent, drawing from
        # two sources: (1) declared `serves "..."` edges in BASE.nims
        # and (2) entities pre-allocated by invites issued via this
        # agent (INVITES.json `agentName` + `targetNcId`) whose target
        # entity has at least one identifier — i.e. a real customer
        # actually claimed the invite (the redemption flow stamps the
        # customer's identifier onto the pre-allocated entity rather
        # than updating `usedBy`).
        #
        # Customers promoted to internal-tier (Member / Staff /
        # Employee / Admin / SuperAdmin) are excluded — once they
        # join the team, they're not the agent's customers anymore.
        # The invite-derived path filters; declared `serves` edges
        # are kept as-is (operator's explicit intent).
        var customers = initHashSet[WorldEntityID]()
        for link in ent.serves: customers.incl(link.targetID)
        for inv in agentInvites.values:
          if inv.agentName != name: continue
          if inv.targetNcId.len == 0 or not inv.targetNcId.startsWith("nc:"): continue
          let cid = parseAlias(inv.targetNcId)
          if uint32(cid) == 0 or not agentGraph.entities.hasKey(cid): continue
          let target = agentGraph.entities[cid]
          if target.identifiers.len == 0: continue
          if isInternalRole(target.role): continue
          customers.incl(cid)
        let serves = (if customers.len > 0: $customers.len else: "-")
        (reports, serves)
      var rows: seq[string] = @["AGENT       MODEL                   REPORTS-TO    SERVES  STATE       ITER   ELAPSED     TOKENS      LAST TOOL            OUTCOME"]
      for a in cfg.agents.named:
        let key = a.name.toLowerAscii()
        let namePad = a.name.alignLeft(12)
        let (reportsTo, servesN) = agentRelationships(a.name)
        let reportsPad = reportsTo.alignLeft(14)
        let servesPad = servesN.alignLeft(8)
        if not gCtx.offices.hasKey(key):
          let modelPad = (if a.model.len > 0: a.model else: "-").alignLeft(24)
          rows.add(namePad & modelPad & reportsPad & servesPad &
                   "OOO".alignLeft(12) & "-".alignLeft(7) & "-".alignLeft(12) &
                   "-".alignLeft(12) & "-".alignLeft(21) & "out-of-office")
          continue
        let al2 = gCtx.offices[key]
        let modelPad = (if al2.model.len > 0: al2.model else: "-").alignLeft(24)
        let tokStr = fmtTokens(al2.liveTokensTotal)
        if al2.liveTasks.len > 0:
          # One row per in-flight task so concurrent turns are both visible.
          for sk, task in al2.liveTasks.pairs:
            let iterStr = $task.iteration & "/" & $task.maxIterations
            let elStr = fmtUptime(now - task.startedAt)
            let outcome = "running (" & truncate(sk, 24) & ")"
            rows.add(namePad & modelPad & reportsPad & servesPad &
                     "Working".alignLeft(12) & iterStr.alignLeft(7) &
                     elStr.alignLeft(12) & tokStr.alignLeft(12) &
                     toolDisplay(task).alignLeft(21) & outcome)
          continue
        # Idle — show how the last turn ended, if any.
        let last = al2.liveLastFinished
        if last == nil:
          rows.add(namePad & modelPad & reportsPad & servesPad &
                   "In-Office".alignLeft(12) & "-".alignLeft(7) &
                   "-".alignLeft(12) & tokStr.alignLeft(12) & "-".alignLeft(21) & "never-ran")
        else:
          let iterStr = $last.iteration & "/" & $last.maxIterations
          let elStr = fmtUptime(now - last.finishedAt) & " ago"
          let outcome =
            if last.lastError.len > 0: "❌ " & shortErr(last.lastError)
            else: "✓ ok (turn " & $al2.liveTurnCount & ")"
          rows.add(namePad & modelPad & reportsPad & servesPad &
                   "In-Office".alignLeft(12) & iterStr.alignLeft(7) &
                   elStr.alignLeft(12) & tokStr.alignLeft(12) &
                   toolDisplay(last).alignLeft(21) & outcome)
      return codeBlock(rows.join("\n"))
    let name = sub
    let key = name.toLowerAscii()
    if not gCtx.offices.hasKey(key):
      return "**Agent " & name & "** — Out-of-Office (office not opened this session)."
    let al2 = gCtx.offices[key]
    var lines: seq[string] = @[]
    if al2.liveTasks.len > 0:
      # At least one in-flight turn — list each separately.
      lines.add("State:      Working (" & $al2.liveTasks.len & " concurrent turn(s))")
      for sk, task in al2.liveTasks.pairs:
        lines.add("")
        lines.add("  Session:    " & sk)
        lines.add("  Sender:     " & task.senderID)
        lines.add("  Message:    " & task.messagePreview)
        lines.add("  Iteration:  " & $task.iteration & "/" & $task.maxIterations)
        lines.add("  Elapsed:    " & fmtUptime(now - task.startedAt))
        if task.lastTool.len > 0:
          lines.add("  Last tool:  " & task.lastTool)
        if task.toolLog.len > 0:
          lines.add("  Tool log:   " & task.toolLog.join(" → "))
        if task.tokens > 0:
          lines.add("  Tokens:     " & $task.tokens & " so far")
      lines.add("")
      lines.add("Total turns since boot:  " & $al2.liveTurnCount)
      lines.add("Total tokens since boot: " & $al2.liveTokensTotal)
    else:
      # Idle — show the last completed turn, if any.
      let last = al2.liveLastFinished
      if last == nil:
        return "**Agent " & name & "** — In-Office, hasn't taken a turn yet."
      let sinceStr = fmtUptime(now - last.finishedAt)
      lines.add("State:      In-Office (last turn " & sinceStr & " ago)")
      lines.add("Last msg:   " & last.messagePreview)
      lines.add("Iterations: " & $last.iteration & "/" & $last.maxIterations)
      if last.lastTool.len > 0:
        lines.add("Last tool:  " & last.lastTool)
      if last.toolLog.len > 0:
        lines.add("Tool log:   " & last.toolLog.join(" → "))
      if last.lastError.len > 0:
        lines.add("Outcome:    ❌ " & last.lastError)
      else:
        lines.add("Outcome:    ✓ ok")
      if last.tokens > 0:
        lines.add("Tokens:     " & $last.tokens & " (last turn)")
      lines.add("Total turns since boot:  " & $al2.liveTurnCount)
      lines.add("Total tokens since boot: " & $al2.liveTokensTotal)
    return "**Agent " & name & "**\n\n" & codeBlock(lines.join("\n"))

  elif cmd == "/session" or cmd.startsWith("/session "):
    # Conversation-state management. Each user has a separate session
    # per agent (keyed by `nc_<id>`), stored as JSONL on disk under
    # the agent's office. Clearing wipes both in-memory buffer and
    # disk files — the agent forgets that user entirely on next turn.
    let parts = strutils.splitWhitespace(cmd)
    if parts.len < 2 or parts[1] == "help":
      return "**`/session` — conversation-state management**\n\n" &
             "  `/session reset` (alias `/session new`)\n" &
             "    Clear YOUR session in the current chat. Next message\n" &
             "    starts a fresh thread with no prior history.\n\n" &
             "  `/session list`\n" &
             "    Show all your sessions across every agent in this\n" &
             "    company — message count, summary length, last\n" &
             "    activity per agent.\n\n" &
             "  `/session status [<agent>]`\n" &
             "    Regular user: show YOUR session's context utilisation\n" &
             "    with that agent — message count, token estimate,\n" &
             "    % of context window, threshold. Bare `/session status`\n" &
             "    (no agent) defaults to the current chat's agent.\n" &
             "    🔒 Admin: show ALL of the agent's sessions across all\n" &
             "    users (operator overview, sorted by token weight).\n" &
             "    Example: `/session status lexi`\n\n" &
             "  `/session status <agent> <nc:id>`\n" &
             "    Detail view of a specific session. 🔒 Admin required\n" &
             "    if the nc:id isn't your own.\n" &
             "    Example: `/session status lexi nc:5`\n\n" &
             "  `/session clear <agent>`\n" &
             "    Clear YOUR session with that agent (works from any\n" &
             "    chat, names the target agent explicitly). Same effect\n" &
             "    as `/session reset` when run from that agent's chat.\n" &
             "    Example: `/session clear lexi`\n\n" &
             "  `/session clear <agent> <nc:id>`   🔒 Admin\n" &
             "    Clear another user's session with that agent. Useful\n" &
             "    for resetting test conversations or recovering from\n" &
             "    corrupted state.\n" &
             "    Example: `/session clear lexi nc:7`\n\n" &
             "  `/session clear <agent> <session-key>`   🔒 Admin\n" &
             "    Clear an arbitrary session by literal key. Use for\n" &
             "    non-human sessions like `system_heartbeat` or\n" &
             "    `cli:user` that don't have an `nc:id`.\n" &
             "    Example: `/session clear lexi system_heartbeat`\n\n" &
             "  `/session technical [on|off|reset|status]`\n" &
             "    Toggle technical-communication mode (framework\n" &
             "    auto-emits Pattern 5 visibility messages — file\n" &
             "    paths + code snippets, bash commands + output\n" &
             "    excerpts) for YOUR session in the current chat.\n" &
             "    `on`/`off` = override the agent's competency-derived\n" &
             "    default; `reset` = clear the override (back to default);\n" &
             "    `status` (or no arg) = show the effective state.\n" &
             "    Example: `/session technical on`\n\n" &
             "  `/session stop`\n" &
             "    Cancel the agent's in-flight turn for YOUR session\n" &
             "    in the current chat. The dispatch loop exits at its\n" &
             "    next iteration or tool-dispatch boundary (usually\n" &
             "    within a few seconds). Conversation history preserved.\n" &
             "    Use when the agent is working on the wrong task and\n" &
             "    you want to halt without restarting the gateway.\n" &
             "    Example: `/session stop`\n\n" &
             "Note: `clear`/`reset` wipe the conversation, NOT the agent's\n" &
             "`memory_store` entries (those persist by design — that's their\n" &
             "purpose). `stop` doesn't wipe anything; it only halts the\n" &
             "current turn."
    let sub = parts[1]
    if sub == "status":
      # No agent arg → default to whichever office handled this slash
      # command (`al`). Running `/session status` in Lexi's chat means
      # "Lexi's session", same convention as `/session reset`.
      let agentName =
        if parts.len >= 3: parts[2]
        else: al.agentName
      let agentKey = agentName.toLowerAscii
      # Validate against declared agents — `gCtx.offices` is lazy-loaded
      # so an agent who hasn't received a message since gateway start
      # has no entry there yet. Don't reject just because the office
      # isn't materialised; reject only if the name isn't a real agent.
      var declared = false
      for a in cfg[].agents.named:
        if a.name.toLowerAscii == agentKey:
          declared = true
          break
      if not declared:
        return "Agent `" & agentName & "` is not declared in this " &
               "company. Try `/agent list` to see who's available."
      # Load the office on demand (idempotent — returns the existing
      # AgentLoop if it's already up). This is the same path the
      # message dispatcher uses, so `/session status atlas` works
      # whether or not Atlas has handled a message in this run.
      let al2 = ensureOffice(agentName)

      # Three modes:
      #   1. nc:id specified  → that session's detail (Admin+ if not own)
      #   2. no nc:id, Admin+ → ALL sessions for the agent (operator overview)
      #   3. no nc:id, plain  → caller's own session detail
      if parts.len >= 4:
        if not parts[3].startsWith("nc:"):
          return "Error: third argument must be an `nc:id` " &
                 "(e.g. `nc:5`), got `" & parts[3] & "`."
        let targetNc = parts[3]
        # Resolve caller's own nc:id to compare; non-Admin can only
        # view their own.
        let callerNc = resolveCallerNc(cfg, msg)
        if callerPermGate < pmAdmin and targetNc != callerNc:
          return "Only Admin or SuperAdmin can view another user's " &
                 "session. (Use `/session status " & agentName &
                 "` to see your own.)"
        let sessionKey = targetNc.replace(":", "_")
        let s = al2.sessionStatus(sessionKey)
        return formatSessionStatus(s)

      # No nc:id arg — Admin+ gets the operator overview, regular caller
      # gets their own detail. The Admin overview is the answer to
      # "how is Lexi doing across ALL users?"
      if callerPermGate >= pmAdmin:
        let workspace2 = cfg[].workspacePath()
        let g2 = loadWorld(workspace2)
        # Build a sessionKey → display-name lookup so the table reads
        # "nc:5  Jerry" instead of just nc-id digits. Walk the graph
        # entities, key by their nc-as-underscore form.
        var nameByKey = initTable[string, string]()
        if g2 != nil:
          for entID, ent in g2.entities:
            let alias = toAlias(entID)
            let key = alias.replace(":", "_")
            if ent.name.len > 0:
              nameByKey[key] = ent.name
        let statuses = al2.allSessionStatuses()
        return formatSessionList(statuses, al2.agentName, al2.model,
                                  al2.contextWindow, (al2.contextWindow * 75) div 100,
                                  nameByKey)
      else:
        # Plain user — their own session.
        let targetNc = resolveCallerNc(cfg, msg)
        if targetNc == "":
          return "Couldn't resolve your own `nc:id` from this channel. " &
                 "Pass it explicitly: " &
                 "`/session status " & agentName & " nc:N`."
        let sessionKey = targetNc.replace(":", "_")
        let s = al2.sessionStatus(sessionKey)
        return formatSessionStatus(s)
    elif sub == "clear":
      if parts.len < 3:
        return "Usage: `/session clear <agent>` (your session with that\n" &
               "agent) or `/session clear <agent> <nc:id>` (Admin+ — " &
               "another user's session)."
      let agentName = parts[2]
      let agentKey = agentName.toLowerAscii
      # Same lazy-office handling as `/session status` — accept any
      # declared agent, materialise the office on demand. Without this
      # an agent who hasn't received a message since gateway start
      # would be unreachable for `/session clear`.
      var declared = false
      for a in cfg[].agents.named:
        if a.name.toLowerAscii == agentKey:
          declared = true
          break
      if not declared:
        return "Agent `" & agentName & "` is not declared in this " &
               "company. Try `/agent list` to see who's available."
      let al2 = ensureOffice(agentName)
      # Resolve target. Three argument shapes:
      #   /session clear <agent>            → caller's own nc:id
      #   /session clear <agent> nc:N       → another user (Admin)
      #   /session clear <agent> <KEY>      → arbitrary session key
      #                                       (Admin) — for non-human
      #                                       sessions like
      #                                       `system_heartbeat`,
      #                                       `cli:user`, etc. The
      #                                       key is used verbatim,
      #                                       no nc:N translation.
      var targetNc = ""
      var literalKey = ""    # set when 3rd arg isn't `nc:N`
      if parts.len >= 4:
        if callerPermGate < pmAdmin:
          return "Only Admin or SuperAdmin can clear another user's " &
                 "session. (Use `/session clear " & agentName &
                 "` to clear your own.)"
        if parts[3].startsWith("nc:"):
          targetNc = parts[3]
        else:
          # Admin escape hatch for non-`nc:N` keys. Common reasons:
          # `system_heartbeat` (cron-driven heartbeat session that
          # bloats over time), `cli:user` (test fixture), legacy
          # `<channel>:...` raw keys that pre-date the nc-resolution
          # contract. The key is passed verbatim to clearSession.
          literalKey = parts[3]
      else:
        targetNc = resolveCallerNc(cfg, msg)
        if targetNc == "":
          return "Couldn't resolve your own `nc:id` from this channel. " &
                 "If you're an Admin clearing someone else's session, " &
                 "pass their nc:id explicitly: " &
                 "`/session clear " & agentName & " nc:N`."
      # The session manager keys on `nc_<num>` (underscore form), not
      # `nc:<num>` (colon form used in display). Literal keys are
      # passed through verbatim.
      let sessionKey =
        if literalKey.len > 0: literalKey
        else: targetNc.replace(":", "_")
      al2.sessions.clearSession(sessionKey)
      let labelDisplay =
        if literalKey.len > 0: "session `" & literalKey & "`"
        else: "session with `" & targetNc & "` (key `" & sessionKey & "`)"
      return "Cleared **" & agentName & "**'s " & labelDisplay & ".\n\n" &
             "On the next message, the agent starts a fresh thread — " &
             "no prior history, no carried-over summary. " &
             "`memory_store` entries are untouched."
    elif sub == "reset" or sub == "new":
      # Clear YOUR session in the current chat. The "current chat's
      # agent" is whichever office handled this slash command (`al`).
      let callerNc = resolveCallerNc(cfg, msg)
      if callerNc == "":
        return "Couldn't resolve your `nc:id` from this channel. " &
               "Use `/session clear " & al.agentName.toLowerAscii &
               " nc:<your-id>` instead."
      let sessionKey = callerNc.replace(":", "_")
      al.sessions.clearSession(sessionKey)
      return "Session reset for **" & al.agentName & "** (`" & sessionKey &
             "`). Next message starts a fresh thread — no prior history, " &
             "no carried-over summary. `memory_store` entries are untouched."
    elif sub == "technical":
      # Toggle the per-session technical-communication mode override
      # (gates framework auto-emit of Pattern 5 visibility messages on
      # tool calls). Defaults are derived at office construction from
      # the agent's `practices "technical-communication"`. This
      # subcommand lets the operator flip the mode on a specific
      # session at runtime — for instance, mute auto-emit for a
      # quick read-only diagnostic, or force-enable on an agent that
      # doesn't normally practice technical-communication.
      let callerNc = resolveCallerNc(cfg, msg)
      if callerNc == "":
        return "Couldn't resolve your `nc:id` from this channel."
      let sessionKey = callerNc.replace(":", "_")
      let arg =
        if parts.len >= 3: parts[2].toLowerAscii
        else: "status"
      if arg notin ["on", "off", "reset", "status"]:
        return "Error: argument must be one of `on`, `off`, `reset`, " &
               "`status`. Got `" & arg & "`."
      if arg == "status":
        let s = al.sessions.getOrCreate(sessionKey)
        let ovr = s.meta.techCommOverride
        let eff = al.effectiveTechComm(sessionKey)
        var report = "**`/session technical` status for `" & sessionKey &
                  "` with `" & al.agentName & "`:**\n\n"
        report.add("- Agent default (from `practices`): `" &
                (if al.techCommDefault: "on" else: "off") & "`\n")
        report.add("- Session override: `" &
                (if ovr.len == 0: "(none)" else: ovr) & "`\n")
        report.add("- **Effective**: `" &
                (if eff: "on" else: "off") & "`\n\n")
        report.add("When `on` and the channel renders code blocks " &
                "(currently Feishu), the framework auto-emits a " &
                "`reply_progress`-style message after each non-comm " &
                "tool call, with file paths + code snippets, bash " &
                "commands, and output excerpts. The agent's own " &
                "`reply_progress` for findings is then optional " &
                "(structural visibility is owned by the framework).")
        return report
      let val = if arg == "reset": "" else: arg
      al.sessions.setTechCommOverride(sessionKey, val)
      let eff = al.effectiveTechComm(sessionKey)
      let label =
        case arg
        of "on":    "**enabled** for this session"
        of "off":   "**disabled** for this session"
        of "reset": "**reset** (override cleared, using agent default)"
        else:       arg
      return "Technical-communication mode " & label & ".\n\n" &
             "Effective state now: `" & (if eff: "on" else: "off") &
             "`. Auto-emit visibility messages on tool calls will " &
             (if eff: "fire" else: "be suppressed") & " until you " &
             "change it again."
    elif sub == "stop":
      # Set the cancellation flag for the caller's session with the
      # current chat's agent. The agent's dispatch loop checks the
      # flag at the top of each iteration AND before each tool
      # dispatch — when set, breaks with a "cancelled by user"
      # finalContent and clears the flag. Doesn't kill the gateway,
      # doesn't disrupt other users; just halts THIS turn for THIS
      # session. The current in-flight tool call (if any) finishes;
      # the loop exits as soon as it reaches its next iteration or
      # tool-dispatch boundary, typically within a few seconds.
      let callerNc = resolveCallerNc(cfg, msg)
      if callerNc == "":
        return "Couldn't resolve your `nc:id` from this channel. " &
               "Use `/session clear " & al.agentName.toLowerAscii &
               "` to wipe instead."
      let sessionKey = callerNc.replace(":", "_")
      al.requestCancel(sessionKey)
      return "Stopping in-flight turn for `" & sessionKey &
             "` with **" & al.agentName & "**.\n\n" &
             "The loop ends at its next iteration or tool-dispatch " &
             "boundary (usually within a few seconds; up to ~30s if " &
             "stuck waiting on a slow `spawn`/`shell`). Conversation " &
             "history is preserved — your next prompt continues from " &
             "wherever the agent stopped. To wipe history too, " &
             "follow up with `/session reset`."
    elif sub == "list":
      # Enumerate caller's sessions across every declared agent.
      # For each agent: message count, summary length (rough proxy
      # for "how compacted is the history"), most-recent activity
      # if the meta is loadable. Useful for "where am I in
      # conversation with whom?"
      let callerNc = resolveCallerNc(cfg, msg)
      if callerNc == "":
        return "Couldn't resolve your `nc:id` from this channel."
      let sessionKey = callerNc.replace(":", "_")
      let workspace = cfg[].workspacePath()
      var output = "**Your sessions** (as `" & callerNc & "` / `" &
                   sessionKey & "`):\n\n"
      var anyFound = false
      for a in cfg[].agents.named:
        let agentLow = a.name.toLowerAscii
        let metaPath = workspace / "offices" / agentLow /
                       "sessions" / (sessionKey & ".meta.json")
        if not fileExists(metaPath): continue
        anyFound = true
        try:
          let meta = readSessionMetaFromPath(metaPath)
          let updatedStr =
            if meta.updated > 0:
              fromUnixFloat(meta.updated).format("yyyy-MM-dd HH:mm")
            else: "—"
          output.add("**" & a.name & "**\n")
          output.add("  messages: " & $meta.messageCount)
          if meta.summaryWatermark > 0:
            let live = meta.messageCount - meta.summaryWatermark
            output.add(" (`" & $meta.summaryWatermark & "` summarised, `" &
                       $live & "` live)")
          output.add("\n")
          if meta.summary.len > 0:
            output.add("  summary: " & $meta.summary.len & " chars\n")
          output.add("  last active: " & updatedStr & "\n\n")
        except CatchableError:
          output.add("**" & a.name & "** (couldn't read meta)\n\n")
      if not anyFound:
        return "No sessions found for `" & callerNc & "`. Send a " &
               "message to any agent to start one."
      output.add("Operations: `/session reset` (clear THIS chat's " &
                 "session), `/session status <agent>` (detailed view), " &
                 "`/session clear <agent>` (clear another agent's " &
                 "session with you).")
      return output
    return "Unknown /session subcommand: `" & sub & "`.\n" &
           "Try `/session reset`, `/session list`, `/session status " &
           "<agent>`, `/session clear <agent>`, or `/session help`."

  elif cmd == "/restart":
    if callerPermGate < pmAdmin:
      return "Only Admin or SuperAdmin can restart the gateway."
    # Admin+: stop the current gateway and launch a fresh one
    # so config/DSL changes (e.g. a freshly added Feishu app) take
    # effect without dropping to a terminal.
    #
    # Step 0: rebuild BASE.json from BASE.nims FIRST. If this fails
    # (syntax error, missing template, etc.), bail out immediately —
    # the running gateway keeps serving on the old config, which is
    # strictly better than killing it only to fail the replacement.
    let (rebuildOk, rebuildOutput) = rebuildBaseJson(getNimClawDir())
    if not rebuildOk:
      return "❌ BASE.nims rebuild failed — gateway NOT restarted. Fix and " &
             "retry:\n\n" & codeBlock(rebuildOutput)
    let clawBin = getAppFilename()
    let myPidHere = getpid()
    # Detached child survives our death (setsid under poDaemon). The
    # shutdown path is defence-in-depth because `FeishuChannel.stop`'s
    # `joinThread` can hang on a lark-cli subscriber still blocked in
    # `readLine` — if we just SIGTERM and trust the graceful shutdown,
    # a half-dead gateway keeps its lark-cli children alive and races
    # the new gateway for Feishu events.
    #   1. SIGTERM the whole process group (picks up lark-cli children).
    #   2. Wait up to 5s for graceful exit.
    #   3. SIGKILL fallback on the group + PID if still alive.
    #   4. `exec` the new gateway — no shell wrapper stays as parent.
    # The new gateway's own startup guard (isProcessAlive check against
    # the PID file) is left to handle the pathological case where
    # SIGKILL itself failed — better to refuse to start than duplicate.
    # PGID guard: only group-kill when PGID == PID (gateway is its own
    # session leader via poDaemon/setsid). Foreground `claw gateway`
    # launched from a terminal shares its PGID with the shell — we
    # don't want to take the shell down too.
    let logPath = getNimClawDir() / "logs" / "restart.log"
    let dirPath = getNimClawDir()
    let script =
      "sleep 2; " &
      "OLD=" & $myPidHere & "; " &
      "PGID=$(ps -o pgid= -p \"$OLD\" 2>/dev/null | tr -d ' '); " &
      "if [ -n \"$PGID\" ] && [ \"$PGID\" = \"$OLD\" ]; then " &
      "  kill -TERM -\"$PGID\" 2>/dev/null; " &
      "else " &
      "  kill -TERM \"$OLD\" 2>/dev/null; " &
      "fi; " &
      "for i in $(seq 1 25); do kill -0 \"$OLD\" 2>/dev/null || break; sleep 0.2; done; " &
      "if kill -0 \"$OLD\" 2>/dev/null; then " &
      "  if [ -n \"$PGID\" ] && [ \"$PGID\" = \"$OLD\" ]; then " &
      "    kill -KILL -\"$PGID\" 2>/dev/null; " &
      "  fi; " &
      "  kill -KILL \"$OLD\" 2>/dev/null; " &
      "  for i in $(seq 1 10); do kill -0 \"$OLD\" 2>/dev/null || break; sleep 0.2; done; " &
      "fi; " &
      "NIMCLAW_DIR='" & dirPath & "' exec '" & clawBin &
      "' gateway > '" & logPath & "' 2>&1"
    discard startProcess("/bin/sh",
                         args = @["-c", script],
                         options = {poDaemon, poUsePath})
    return "✅ BASE.json rebuilt. Restarting gateway in ~2s — I'll be " &
           "unreachable for a few seconds. **Please send a message** " &
           "yourself when you want to check I'm back (the gateway " &
           "doesn't push-notify). New app routings (e.g. freshly added " &
           "Feishu apps) and config changes take effect on the next message."
  return ""

# ── stdio handler (Zen mode) ─────────────────────────────────────────

proc handleStdio(msg: JsonNode): seq[JsonNode] {.gcsafe.} =
  ## Handle JSONL messages from stdin (Zen). Runs on stdio thread.
  {.cast(gcsafe).}:
    let meth = msg{"method"}.getStr("")

    case meth
    of "chat.message":
      let agent = msg{"agent"}.getStr("Lexi")
      let message = msg{"message"}.getStr("")
      let chatId = msg{"chat_id"}.getStr("")
      if message == "": return @[%*{"event": "chat.done", "chat_id": chatId}]

      # Route to agent via channel
      var respChan: system.Channel[string]
      respChan.open()
      gAgentRequestChan.send((agent.toLowerAscii(), message, "", "", addr respChan))
      let resp = respChan.recv()
      respChan.close()

      # Emit response as tokens (could be split for streaming later)
      emitStdout(%*{"event": "chat.token", "chat_id": chatId, "content": resp})
      return @[%*{"event": "chat.done", "chat_id": chatId}]

    of "click":
      let target = msg{"target"}.getStr("")
      infoCF("stdio", "Click", {"target": target}.toTable)
      # Service actions are handled by the gateway directly
      return @[]

    of "status":
      var agents = newJArray()
      if gCtx != nil:
        for name, office in gCtx.offices:
          agents.add(%*{"name": name, "status": "active"})
      var channels = newJArray()
      if gChanManager != nil:
        for name, ch in gChanManager.channels:
          channels.add(%*{"name": name, "running": ch.isRunning()})
      return @[%*{"event": "status", "pid": getpid(), "agents": agents, "channels": channels}]

    else:
      return @[%*{"event": "error", "message": "unknown method: " & meth}]

# ── Legacy socket RPC handler ────────────────────────────────────────

proc handleSocketRpc(req: RpcRequest): JsonNode {.gcsafe.} =
  ## Handle legacy socket RPC (for headless mode / CLI).
  {.cast(gcsafe).}:
    if gCtx == nil: return %*{"error": "Gateway not ready"}

    case req.`method`
    of "status":
      var offices = newJArray()
      for name, office in gCtx.offices:
        offices.add(%*{"name": name})
      return %*{"pid": getpid(), "offices": offices}

    of "agent.list":
      var agents = newJArray()
      for name, office in gCtx.offices:
        agents.add(%*{"name": name, "status": "active"})
      return agents

    of "agent.send":
      let name = req.params{"name"}.getStr("")
      let message = req.params{"message"}.getStr("")
      if name == "" or message == "":
        return %*{"error": "name and message required"}
      let fromOverride = req.params{"from"}.getStr("")
      let chanOverride = req.params{"channel"}.getStr("")
      var respChan: system.Channel[string]
      respChan.open()
      gAgentRequestChan.send((name.toLowerAscii(), message,
                              fromOverride, chanOverride, addr respChan))
      let resp = respChan.recv()
      respChan.close()
      return %resp

    of "channel.list":
      var channels = newJArray()
      if gChanManager != nil:
        for name, ch in gChanManager.channels:
          channels.add(%*{"name": name, "running": ch.isRunning()})
      return channels

    else:
      return %*{"error": "unknown method: " & req.`method`}

# ── Gateway main loop ───────────────────────────────────────────────

proc runGateway*(host: string, port: int, debug: bool, stream: bool,
                useStdio: bool = false, pane: string = "left") =
  # `/restart` exec's the new gateway through a `/bin/sh` helper, and
  # that shell inherits every open fd the OLD gateway had at fork time
  # (the old gateway's lark-cli / nkn-cli / MCP pipes are NOT marked
  # CLOEXEC). The exec'd new gateway then inherits all of those —
  # leaving us with 1000+ orphaned pipe fds before we've even called
  # `main()`. Once that count crosses libcurl's select() FD_SETSIZE
  # ceiling (~1024 on macOS), every HTTPS request fails with
  # `Unrecoverable error in select/poll`, and the failure looks like
  # "deepseek is down" when really the fd table is full.
  #
  # Defensive close of inherited fds 3..maxClose. stdin/stdout/stderr
  # stay open. macOS doesn't expose `closefrom`, so we loop manually;
  # `close()` on a non-open fd is a cheap no-op (returns EBADF).
  block closeInheritedFds:
    const maxClose = 8192
    for fd in 3 ..< maxClose:
      discard close(fd.cint)

  if useStdio: logger.stdioMode = true
  if debug: setLevel(DEBUG)

  # Strip inherited HTTP(S)_PROXY env so the gateway never explicitly
  # routes LLM/API traffic through a forward proxy. Transparent proxies
  # (FlClash/Mihomo TUN, system VPN, etc.) intercept at the OS level
  # without needing the env var; routing through an explicit forward
  # proxy on top of TUN doubles up the fd cost (every libcurl request
  # holds an extra pipe to the proxy) and made our gateway hit a libcurl
  # `multi_poll` "Unrecoverable error in select/poll" once subprocess
  # pipes piled up. Operators with a *real* corporate forward proxy
  # should configure it per-provider in BASE.nims instead of relying
  # on shell env inheritance — keeps the routing decision explicit.
  for k in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "http_proxy", "https_proxy", "all_proxy"]:
    if existsEnv(k): delEnv(k)

  # PID file — company-scoped so `claw company list` can show RUNNING per company.
  # Startup guard. A stale PID file (owner SIGKILLed, so addExitProc
  # didn't fire) is fine — `isProcessAlive` filters that out. A live
  # PID is fatal: two gateways on the same Feishu event stream split
  # messages arbitrarily between them and neither recovers. If this
  # fires during `/restart`, the old gateway's shutdown failed and
  # needs manual intervention (`kill -9` + check for orphan lark-cli).
  let companyPidPath = gatewayPidPath()
  if fileExists(companyPidPath):
    try:
      let oldPid = readFile(companyPidPath).strip().parseInt()
      if isProcessAlive(oldPid):
        stderr.writeLine "Error: gateway already running (PID ", oldPid, ") — refusing to start a duplicate."
        stderr.writeLine "If this came from `/restart`, the old gateway didn't die; inspect with `ps -p ", oldPid, "` and `kill -9` if stuck."
        stderr.writeLine "Otherwise: `claw company stop`."
        quit(1)
    except: discard

  let myPid = getpid()
  try:
    createDir(companyPidPath.parentDir)
    writeFile(companyPidPath, $myPid)
    # Legacy service-scoped path — keep writing it for backward compat with
    # any old scripts; will be removed after a release cycle.
    try:
      createDir(pidFilePath().parentDir)
      writeFile(pidFilePath(), $myPid)
    except: discard
    addExitProc(proc() {.noconv.} =
      for pPath in [gatewayPidPath(), pidFilePath()]:
        if fileExists(pPath):
          try:
            let fPid = readFile(pPath).strip().parseInt()
            if fPid == getpid(): removeFile(pPath)
          except: discard
    )
  except:
    errorCF("claw", "Failed to write PID file", {"error": getCurrentExceptionMsg()}.toTable)

  # Ensure runtime dir exists
  let rtDir = runtimeDir()
  if not dirExists(rtDir):
    try: createDir(rtDir) except: discard

  # Logging
  let logDir = logsDir()
  if not dirExists(logDir):
    try: createDir(logDir)
    except: discard
  discard enableFileLogging(logDir / "gateway.log")
  gStartTime = epochTime()
  infoCF("claw", "Starting", {"host": host, "port": $port, "pid": $myPid}.toTable)

  # Register the system-command catalog once per process. Source of truth
  # that every channel adapter reads to render its platform-native menu.
  register(SystemCommand(
    name: "/help", summary: "List all slash commands.",
    usage: "/help [<command>]", group: "utility",
    menuHint: "Help", permission: pmAny,
    examples: @["/help", "/help /invite"]))
  register(SystemCommand(
    name: "/status", summary: "System status snapshot (PID, uptime, users, agents, channels).",
    usage: "/status", group: "utility",
    menuHint: "Status", permission: pmAny,
    examples: @["/status"]))
  register(SystemCommand(
    name: "/stream", summary: "Toggle intermediary thought streaming.",
    usage: "/stream <on|off>", group: "agent-control",
    permission: pmAdmin,
    args: @[CmdArg(name: "value", description: "on or off", required: true)],
    examples: @["/stream on", "/stream off"]))
  register(SystemCommand(
    name: "/model", summary: "Switch model, or list known models.",
    usage: "/model [<provider:model> | list [<provider>]]",
    group: "agent-control", permission: pmAdmin,
    examples: @["/model", "/model list", "/model deepseek:deepseek-reasoner"]))
  register(SystemCommand(
    name: "/channel", summary: "Register, inspect, or reroute chat channels (Feishu apps, etc.).",
    usage: "/channel <list|auth|assign> [<args>...]",
    doc: """Channel management.

Usage:
  /channel list
  /channel auth feishu <app_id> <app_secret> [<agent>]
  /channel assign <app_id> <agent>

`assign` reassigns an already-registered Feishu app to a different
declared agent. Edits BASE.nims; run `/restart` after for lark-cli
subscribers to route events to the new agent's office.
""",
    group: "admin", menuHint: "Channels", permission: pmAdmin,
    examples: @["/channel list",
                "/channel auth feishu cli_a93085a978781cd5 SECRET Atlas",
                "/channel assign cli_a948ea9ee5785cd3 Atlas"]))
  register(SystemCommand(
    name: "/user", summary: "User management (list, show, trust, add, register, join, edit, rebind, invite, remove).",
    usage: "/user <list|show|trust|add|register|join|edit|rebind|invite|remove> [<args>...]",
    doc: """User management.

Usage:
  /user list [--kind=<k>] [--tier=<t>] [--permission=<p>] [--sort=<s>] [--reverse] [--format=<f>]
  /user show <nc-id>
  /user trust
  /user add <name> [<permission>]
  /user register <customer-name> [<agent>] [<uses>] [--lang=<l>] [--skill=<s>]... [--skills=<cs>]
  /user join <nc-id> [<permission>]
  /user edit <nc-id> <field> <value>
  /user bind <nc-id> [--wipe]
  /user rebind <nc-id> [--wipe]
  /user invite <customer-name> [<agent>] [<uses>] [--lang=<l>] [--skill=<s>]... [--skills=<cs>]
  /user remove <nc-id>

Options:
  --kind=<k>        Person | AI | Unknown | Service
  --tier=<t>        int | ext | ?
  --permission=<p>  Filter on `list` (e.g. --permission=Member)
  --sort=<s>        nc | name | kind | permission | tier | role
  --reverse         Reverse sort order
  --format=<f>      table | json  [default: table]
  --wipe            On `bind`/`rebind`, revoke all existing identifiers
                    at mint time (lost-device flow). Default is additive:
                    only the channel consuming the code gets a new
                    binding; other channels stay intact.
  --lang=<l>        Customer's language for paste templates (zh, en, ja, ko, ru, ar, ...)
  --skill=<s>       Allowed skill grant (repeatable) — `[user@]skill[/res,...]`
  --skills=<cs>     Comma-separated shorthand for --skill
""",
    group: "admin", menuHint: "Users", permission: pmAny,
    examples: @["/user list --kind=Unknown",
                "/user show nc:4",
                "/user trust",
                "/user add Anna",
                "/user add Bob Admin",
                "/user register Acme Atlas 3",
                "/user register Alice --skill=sungrow::acme-solar",
                "/user join nc:6 Member",
                "/user edit nc:7 permission Member",
                "/user rebind nc:7",
                "/user invite Alice",
                "/user invite Acme Atlas 1 --lang=zh",
                "/user invite JK Atlas --skill=njmkuser@sungrow/627305",
                "/user remove nc:7"]))
  register(SystemCommand(
    name: "/agent",
    summary: "Live agent state — WORKING/idle, current iteration, last tool, elapsed time. `/agent list` for all, `/agent <name>` for detail.",
    usage: "/agent [<name>|list]", group: "admin",
    menuHint: "Agent state", permission: pmAdmin,
    examples: @["/agent list", "/agent Atlas", "/agent Lexi"]))
  register(SystemCommand(
    name: "/restart",
    summary: "Rebuild BASE.json from BASE.nims AND restart the gateway. Fails safely if the rebuild errors — the running gateway stays up.",
    usage: "/restart", group: "admin",
    menuHint: "Restart gateway", permission: pmAdmin,
    examples: @["/restart"]))
  register(SystemCommand(
    name: "/session",
    summary: "Conversation-state management. `/session reset` clears your current chat's session; `/session list` shows all your sessions across agents; `/session status <agent>` shows context utilisation; `/session clear <agent>` is the cross-chat variant.",
    usage: "/session reset | new | list | status <agent> | clear <agent> [<nc:id>]",
    group: "agent-control", menuHint: "Session management",
    permission: pmAny,
    examples: @["/session reset", "/session list", "/session status lexi",
                 "/session clear lexi", "/session clear lexi nc:7"]))
  register(SystemCommand(
    name: "/co",
    summary: "Company management. `/co update` rebuilds BASE.json from BASE.nims; `/co cost` shows token + USD spend across all agents.",
    usage: "/co <update|cost>", group: "admin",
    menuHint: "Company admin", permission: pmAdmin,
    examples: @["/co update", "/co cost"]))

  # Config & provider
  var cfg = new(Config)
  cfg[] = loadConfig(getConfigPath())
  cfg.agents.defaults.stream_intermediary = stream
  let graph = loadWorld(cfg[].workspacePath())
  let primaryProvider = firstProviderName(graph)
  let tech = resolveProviderTech(firstProviderDefaultModel(graph),
                                  primaryProvider, graph.providers,
                                  providerOverride = primaryProvider)
  infoCF("claw", "Provider", {"model": tech.model, "base": tech.apiBase}.toTable)

  let msgBus = newMessageBus()

  # Cross-session provider health registry. Shared across the
  # company-wide chain AND every per-agent chain — one failed call
  # (any session, any agent) marks the provider broken; every
  # subsequent call from any session skips that provider until
  # manual recovery.
  let healthPath = workspacePath(cfg[]) / "automation" / "provider-health.json"
  let healthRegistry = newProviderHealthRegistry(healthPath)

  # Build the LLM provider with a fallback chain. See
  # `buildProviderChain` for the full doc; same helper is reused on
  # `/model <provider>:<model>` so the in-flight switch produces the
  # exact same shape of provider as a fresh startup.
  let provider = buildProviderChain(cfg[], graph, healthRegistry)
  let cronStorePath = workspacePath(cfg[]) / "automation" / "jobs.json"
  var cronServiceInstance = newCronService(cronStorePath)

  # Status emitter
  let statusEmitter = newStatusEmitter()
  statusEmitter.emitGatewayStart(myPid)

  # Channels
  gChanManager = newManager(cfg[], msgBus)
  gChanManager.initChannels()

  gCtx = GatewayContext(
    cfg: cfg[],
    msgBus: msgBus,
    provider: provider,
    healthRegistry: healthRegistry,
    cronService: cronServiceInstance,
    offices: initTable[string, AgentLoop](),
    statusEmitter: statusEmitter
  )

  cronServiceInstance.onJob = cronHandler

  # Default agent — Lexi gets pre-materialized so first inbound
  # message doesn't pay the office-construction latency.
  if not gCtx.offices.hasKey("lexi"):
    gCtx.offices["lexi"] = makeAgentLoop("Lexi")
  # Load skill-declared schedules from each skill's SCHEDULES.json
  # and reconcile with the persistent scheduler store. This runs once
  # per gateway boot — same way `requires.tools` and `requires.deps`
  # are resolved at `claw create` time, but at runtime so a freshly
  # installed skill picks up its schedules without a rebuild.
  block loadSkillSchedules:
    let workspace = workspacePath(cfg[])
    let workstationSkillsDir = workspace / "workstation" / "skills"
    let scheduleLoader = newSkillsLoader(
      workspace,
      workspace / ".nimclaw" / "workspace" / "competencies",
      getNimClawDir() / "workspace" / "skills",
      getNimClawDir() / "foundation" / "skills",
      getEnv("OPENCLAW_EXTENSIONS", getHomeDir() / ".openclaw" / "extensions"),
      workstationSkillsDir
    )
    let allDecls = scheduleLoader.listAllSkillSchedules()
    if allDecls.len > 0:
      # Group by source skill so reconcile can prune jobs whose skill
      # removed the declaration.
      var bySkill = initTable[string, seq[CronJob]]()
      let bootMs = getTime().toUnix * 1000
      for d in allDecls:
        var args = ""
        if d.args != nil and d.args.kind == JObject:
          args = $d.args
        let payload = CronPayload(
          kind: d.kind,
          tool: d.tool,
          args: args,
          runAs: d.runAs,
          agentName: d.agent,
          message: d.message,
        )
        let schedule =
          if d.everySeconds > 0:
            CronSchedule(kind: "every", everyMs: some(int64(d.everySeconds) * 1000))
          else:
            CronSchedule(kind: "once",
              atMs: some(parseTime(d.atIso, "yyyy-MM-dd'T'HH:mm:sszzz", utc()).toUnix * 1000))
        # Honour at_hour by pinning first fire to the next occurrence
        # of that local hour. Subsequent fires inherit the same hour
        # via every_seconds=86400. Used to avoid syncing data that
        # hasn't settled yet (e.g. sungrow daily aggregates finalise
        # a few hours after midnight; sync at 09:00, not 02:00).
        var preFire: Option[int64]
        if d.atHour >= 0 and d.atHour <= 23:
          let nowLocal = now()
          var target = dateTime(nowLocal.year, nowLocal.month, nowLocal.monthday,
                                d.atHour, 0, 0, zone = local())
          let targetMs = target.toTime.toUnix * 1000
          if targetMs > bootMs:
            preFire = some(targetMs)
          else:
            # Today's slot already passed — use tomorrow's.
            target = target + 1.days
            preFire = some(target.toTime.toUnix * 1000)
        let job = CronJob(
          id: "",                              # filled by reconcile
          name: d.name,
          enabled: d.enabled,
          schedule: schedule,
          payload: payload,
          state: CronJobState(nextRunAtMs: preFire),
          sourceSkill: d.skillName,
        )
        bySkill.mgetOrPut(d.skillName, @[]).add(job)
      for skill, jobs in bySkill.pairs:
        let r = cronServiceInstance.reconcileSkillJobs(skill, jobs)
        infoCF("scheduler", "Reconciled skill schedules",
               {"skill": skill,
                "added": $r.added,
                "kept": $r.kept,
                "removed": $r.removed}.toTable)

  # Heartbeats fold into the unified scheduler — register one
  # heartbeat_tick scheduled job per opted-in agent. Replaces the
  # prior per-agent HeartbeatService timer. Same skip-if-busy
  # behaviour, same processOneShot dispatch, fewer parallel timer
  # loops; everything visible via /schedule list and
  # automation/jobs.json.
  registerHeartbeats(cfg, cronServiceInstance)

  # Notes-watcher: scans each agent's notes.org every 5 min,
  # registers future-dated TODOs as one-off agent_tick scheduler
  # entries. Initial scan at boot picks up any notes left from
  # prior runs. Async loop runs forever; resilient to per-agent
  # parse errors.
  asyncCheck startNotesWatcher(cfg, cronServiceInstance)

  # IPC setup — stdio (Zen mode) or socket (headless daemon)
  var stdioServer: StdioServer = nil

  if useStdio:
    # Zen mode: JSONL on stdin/stdout
    stdioServer = newStdioServer(handleStdio)
    stdioServer.start()

    # Emit dashboard via stdout
    const dashTtml = """
        <Panel title="Agents">
          <Table id="agents" cols="name,status,ops,tokens" mmap="true"/>
        </Panel>
        <Panel title="Channels">
          <Table id="channels" cols="name,running" mmap="true"/>
        </Panel>
        <Panel title="Activity">
          <Log id="feed" max="20" mmap="true"/>
        </Panel>
    """
    # Emit mount event — Zen will render this
    emitStdout(%*{
      "event": "mount",
      "pane": pane,
      "title": "NimClaw",
      "ttml": dashTtml
    })

    # Register agents as chat provider. Per-agent model — each office
    # has its own primary now (post-Phase 4), no global default.
    var agentList = newJArray()
    for name, office in gCtx.offices:
      agentList.add(%*{"name": name, "description": "", "model": office.model})
    emitStdout(%*{
      "event": "chat.provider",
      "service": serviceRuntimeName(),
      "agents": agentList
    })

    infoCF("claw", "Zen stdio mode", {"pane": pane}.toTable)
  else:
    # Headless daemon: socket for CLI agent.send
    gSocketServer = newSocketServer(handleSocketRpc)
    gSocketServer.start()

  stderr.writeLine "claw running on " & host & ":" & $port & " (PID " & $myPid & ")"

  # SuperAdmin auto-bind — for fresh companies where the declared
  # SuperAdmin has no channel identifier yet. Prints a one-shot code
  # that the first matching inbound message burns.
  block:
    let workspace = cfg[].workspacePath()
    let g = loadWorld(workspace)
    let newCodes = ensureSuperAdminBindings(g, workspace)
    if newCodes.len > 0:
      let targets = bindTargets(cfg[])
      for c in newCodes:
        stderr.writeLine ""
        stderr.writeLine "  \u{1F511}  SuperAdmin binding code for " & c.targetName &
                         " (" & c.targetNcId & "):  " & c.code
        stderr.writeLine "      Send this code as your first message to:"
        for line in targets.splitLines():
          stderr.writeLine "    " & line
        stderr.writeLine ""

  # Per-session task chain — prevents same-session interleaved writes to
  # the session history file. Different sessions run in parallel (including
  # different customers on the same agent, now that allowedTools/context
  # are task-local and no longer shared state on the AgentLoop).
  var sessionTails = initTable[string, Future[void]]()

  # Launch a session task through a proc with explicit parameters. Nim async
  # closures capture locals through a hoisted env; when the spawn site sits
  # inside a `while true:` loop, successive iterations' captures can alias
  # (observed: two parallel tasks' `cChatID` both pointing at the last
  # iteration's value, cross-wiring replies). Routing the spawn through a
  # proc guarantees fresh parameter storage per call.
  proc launchSessionTask(chainKey, channel, chatID, sessionKey, appID,
                         recipient, office: string,
                         cMsg: InboundMessage,
                         graph: WorldGraph,
                         prevTail: Future[void],
                         bannerPrefix: string = ""): Future[void] =
    result = (proc() {.async.} =
      try:
        if prevTail != nil and not prevTail.finished:
          try: await prevTail except: discard
        let r = await gCtx.offices[office].processMessage(cMsg, graph)
        if r != "":
          var fMeta = initTable[string, string]()
          fMeta["final"] = "true"
          let finalText =
            if bannerPrefix.len > 0: bannerPrefix & r else: r
          # Thread the response under the inbound message so group-chat
          # replies show up nested under the @mention that triggered
          # them. Same threading as the agent's own `reply` tool does,
          # keeping both publish paths consistent.
          let replyTo = cMsg.metadata.getOrDefault("message_id", "")
          # Outbound sender_agent mirrors the inbound recipient_id (empty
          # = main-line). `recipient` is the office routing key with a
          # "Lexi" fallback — using it as sender_agent would make main-
          # line conversations reply out through lexi.<pub>.
          let outSender = cMsg.recipient_id
          msgBus.publishOutbound(newOutbound(channel, outSender, chatID, finalText,
                                             replyTo = replyTo,
                                             appID = appID, metadata = fMeta))
          statusEmitter.emitChannelMsg(channel, "out", outSender)
      except Exception as e:
        errorCF("claw", "Session task error",
                {"error": e.msg, "session": sessionKey}.toTable)
    )()

  # Message loop
  asyncCheck (proc() {.async.} =
    while true:
      try:
        let msg = await msgBus.consumeInbound()
        statusEmitter.emitChannelMsg(msg.channel, "in", msg.sender_id)
        discard  # TODO: emit activity event via stdio

        # `companyRoute` = this message is addressed to the company
        # surface, not a specific agent: either the empty recipient
        # (nmobile bare-pubkey main-line) or a recipient name that
        # matches a Corporate entity in the graph (e.g. Feishu app
        # explicitly assigned to "SunGrowCN" in the DSL). Bind /
        # invite / reception gates handle these without ever spinning
        # up an agent loop — same architectural rule the nmobile
        # main-line already followed, now also applied per-channel
        # when the operator routes a Feishu app at the corporate node.
        var companyRoute = msg.recipient_id.len == 0
        if not companyRoute:
          let g = loadWorld(cfg[].workspacePath())
          if g != nil:
            for ent in g.entities.values:
              if ent.kind == ekCorporate and ent.name == msg.recipient_id:
                companyRoute = true
                break

        # Office key still needs an agent-shaped fallback because the
        # system-command fast path expects a real AgentLoop. Lexi gets
        # a no-op office spawned that's never asked to think; the
        # actual reply happens via the bind/invite/reception gates.
        let recipient =
          if companyRoute or msg.recipient_id == "": "Lexi"
          else: msg.recipient_id
        let officeKey = recipient.toLowerAscii()

        if not gCtx.offices.hasKey(officeKey):
          infoCF("claw", "Opening office", {"agent": recipient}.toTable)
          gCtx.offices[officeKey] = makeAgentLoop(recipient)

        # Extract plain text from JSON content (e.g. Feishu)
        var plainContent = msg.content.strip()
        if plainContent.startsWith("{"):
          try:
            let j = parseJson(plainContent)
            if j.hasKey("text"):
              plainContent = j["text"].getStr().strip()
          except: discard

        var response = ""
        # Load the world graph ONCE per inbound message. The four inline
        # checks below (bindCheck, invite-redemption, stranger-gate,
        # group-chat filter) all share `msgGraph` instead of each doing
        # their own `loadWorld`. Mutations via `saveWorld` still persist
        # to disk; they're also visible downstream in the same message
        # because the in-memory graph is shared.
        let workspace = cfg[].workspacePath()
        var msgGraph = loadWorld(workspace)

        # SuperAdmin bind-code check — runs BEFORE the LLM so an
        # unauthenticated first-contact carrying the printed code can
        # claim the declared SuperAdmin's identifier without ever
        # reaching the model. Wrong / absent codes fall through as a
        # normal guest message.
        block bindCheck:
          let g = msgGraph
          let channelKey =
            if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
              msg.channel & ":" & msg.metadata["app_id"]
            else: msg.channel
          # Stamp every Feishu identifier the event carries, so the
          # resolver recognizes this user across any app, DM, or group
          # chat in the same tenant without a follow-up bind:
          #   feishu:<app_id> = open_id   (per-app)
          #   feishu:union    = union_id  (per-tenant, cross-app)
          #   feishu:user     = user_id   (tenant-internal employee ID)
          var extras: seq[(string, string)]
          if msg.channel == "feishu":
            let unionID = msg.metadata.getOrDefault("union_id", "")
            if unionID.len > 0: extras.add(("feishu:union", unionID))
            let userID = msg.metadata.getOrDefault("user_id", "")
            if userID.len > 0: extras.add(("feishu:user", userID))
          let bound = tryBind(g, workspace, channelKey,
                              msg.sender_id, plainContent, extras)
          if bound.isSome:
            let b = bound.get
            stderr.writeLine "claw: bound " & b.targetNcId & " (" & b.targetName &
                             ") via " & channelKey & " ← " & msg.sender_id
            let en = "\u{2713} Bound to " & b.targetName & " (" & b.targetNcId &
                     ", SuperAdmin). You're now authenticated on this channel."
            response = await maybeTranslate(cfg, en, plainContent)
            # nMobile binds get a yellow book so the newly-bound SuperAdmin
            # can save each agent's extension directly — matches what a
            # customer sees after redeeming an invite through this channel.
            if msg.channel == "nmobile":
              response.add(nmobile_channel.nkyYellowBook(
                cfg[], loadLang(b.targetNcId, "en")))
            break bindCheck
        # Customer-invite intercept — parses `nc:X/CODE` (or bare code)
        # and, if it matches a pending invite with a pre-allocated target,
        # stamps the sender's identifiers onto that entity and burns the
        # code. Runs BEFORE the LLM: customer authenticates without their
        # invite string ever hitting the model. Falls through to normal
        # LLM handling for non-code content.
        if response == "":
          var g = msgGraph
          let (parsedNcId, parsedCode) = parseInviteString(plainContent)
          if parsedCode.len > 0:
            var invMap = loadInvites(workspace)
            # Normalize — accept code embedded in a larger message
            # ("send A4B-9X2", "A4B-9X2 please", etc.). Substring match
            # mirrors how the SuperAdmin bind-code path already works.
            var matchedKey = ""
            let haystack = parsedCode.toUpperAscii.replace("-", "").replace(" ", "")
            for k in invMap.keys:
              let needle = k.toUpperAscii.replace("-", "").replace(" ", "")
              if needle.len > 0 and needle in haystack:
                matchedKey = k; break
            if matchedKey.len > 0:
              var inv = invMap[matchedKey]
              if isValid(inv) and inv.targetNcId.len > 0 and
                 (parsedNcId.len == 0 or parsedNcId == inv.targetNcId):
                let targetID = parseAlias(inv.targetNcId)
                if uint32(targetID) > 0 and g.entities.hasKey(targetID):
                  let channelKey =
                    if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
                      msg.channel & ":" & msg.metadata["app_id"]
                    else: msg.channel
                  var ent = g.entities[targetID]
                  var persisted: seq[(string, string)] =
                    @[(channelKey, msg.sender_id)]
                  ent.identifiers[channelKey] = msg.sender_id
                  if msg.channel == "feishu":
                    let unionID = msg.metadata.getOrDefault("union_id", "")
                    if unionID.len > 0:
                      ent.identifiers["feishu:union"] = unionID
                      persisted.add(("feishu:union", unionID))
                    let userID = msg.metadata.getOrDefault("user_id", "")
                    if userID.len > 0:
                      ent.identifiers["feishu:user"] = userID
                      persisted.add(("feishu:user", userID))
                  g.entities[targetID] = ent
                  g.saveWorld()
                  persistPersonIdentifiers(
                    getNimClawDir() / "BASE.nims", ent.name, persisted)
                  # Sweep stale guests.json entries that match the
                  # customer's now-stamped identifiers. The customer
                  # may have ended up in an agent's per-office ledger
                  # if they messaged before the gate (or if the
                  # redeem_invite tool path fired); their guest entry
                  # is now stale because they have a real graph
                  # identity. Identifier match only — names not unique.
                  discard pruneGuestsAcrossOffices(workspace, ent.identifiers)
                  # Burn / decrement.
                  inv.usedBy = channelKey & ":" & msg.sender_id
                  inv.usedAt = getTime().toUnix()
                  if inv.maxUses > 0:
                    inv.maxUses -= 1
                    if inv.maxUses == 0: invMap.del(matchedKey)
                    else: invMap[matchedKey] = inv
                  else:
                    invMap[matchedKey] = inv
                  saveInvites(workspace, invMap)

                  # Auto-activate a 30-day trial if no subscription has
                  # been stamped (operator could have pre-stamped an
                  # `active` plan for paid customers — don't clobber).
                  let now = getTime().toUnix
                  if loadSubscription(inv.targetNcId).isNone:
                    stampSubscription(inv.targetNcId, defaultTrial(now))

                  # Language: invite's `lang` wins (operator chose at mint
                  # time), then customer's stored lang, then "en" fallback.
                  # Stored in the same per-customer file as the subscription
                  # so `co update` can't wipe either.
                  if inv.lang.len > 0 and loadLang(inv.targetNcId, "") != inv.lang:
                    stampLang(inv.targetNcId, inv.lang)
                  let ent3 = g.entities.getOrDefault(targetID)
                  let effLang = loadLang(inv.targetNcId, "en")

                  # Brand + support contact via the shared resolvers.
                  let brand = resolveBrand(g)
                  let contact = resolveSupportContact(g)

                  # Reload the subscription we just stamped so the welcome
                  # block shows the right dates.
                  let freshSub = loadSubscription(inv.targetNcId)
                  let subForWelcome =
                    if freshSub.isSome: freshSub.get() else: defaultTrial(now)

                  let ctx = WelcomeContext(
                    customerName: ent3.name,
                    agentName: inv.agentName,
                    lang: effLang,
                    sub: subForWelcome,
                    companyName: brand,
                    contact: contact,
                    plantNames: fetchPlantNames(inv.targetNcId)
                  )
                  # Welcome text is hand-authored per language — skip
                  # maybeTranslate (which is for one-off English strings).
                  response = welcomeMessage(ctx)
                  # For nMobile onboardees, append the "yellow book" — a
                  # directory of each agent's full NKN address so the
                  # customer can save them directly in the nMobile app.
                  if msg.channel == "nmobile":
                    response.add(nmobile_channel.nkyYellowBook(cfg[], effLang))
                  stderr.writeLine "claw: customer-invite redeemed " &
                                   inv.targetNcId & " via " & channelKey &
                                   " ← " & msg.sender_id & " [lang=" &
                                   effLang & "]"

        # Invite-only first-contact gate. A sender whose (channelKey,
        # senderID) doesn't match any entity in the graph (nor any
        # Feishu tenant-wide identifier fallback) gets a polite refusal
        # and is NOT passed to the agent loop. Without this, the loop
        # silently auto-registers every stranger as `ekUnknown`, which
        # means `user remove <nc:id>` is ineffective — the same person
        # comes right back as a fresh guest on their next message.
        # Bind-code and invite-code paths above already had their shot;
        # if we're here, the stranger sent neither.
        if response == "":
          let g2 = msgGraph
          let channelKey2 =
            if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
              msg.channel & ":" & msg.metadata["app_id"]
            else: msg.channel
          var recognized = false
          # Framework-internal senders (subagent task completions, cron
          # ticks, system events) use sender IDs prefixed `system:`.
          # These aren't users to be authenticated — they're internal
          # bus traffic. Bypass the auth gate so the message reaches
          # whoever's supposed to handle it (subagent results go back
          # to the parent agent, not get refused at the door).
          if msg.sender_id.startsWith("system:"):
            recognized = true
          if g2 != nil and not recognized:
            if uint32(resolveSenderEntity(g2, msg)) > 0:
              recognized = true
          if not recognized:
            # Structured trace so the JSONL log captures every refusal
            # with enough context to diagnose ghost-reception cases.
            # The previous `stderr.writeLine` didn't always reach the
            # log file (depends on how the gateway was launched), and
            # it didn't capture WHICH metadata fields were present —
            # which is the missing piece when a known user gets
            # refused (e.g. Feishu callback events that arrive
            # without union_id, leaving the recognition fallback chain
            # with nothing to match against).
            let appID = msg.metadata.getOrDefault("app_id", "")
            let unionID = msg.metadata.getOrDefault("union_id", "")
            let userID = msg.metadata.getOrDefault("user_id", "")
            warnCF("claw", "Refused unknown sender", {
              "channel": msg.channel,
              "channel_key": channelKey2,
              "sender_id": msg.sender_id,
              "app_id": appID,
              "has_union": $(unionID.len > 0),
              "has_user": $(userID.len > 0),
              "chat_id": msg.chat_id,
              "chat_kind": $msg.chat_kind,
              "content_preview": truncate(plainContent, 80)
            }.toTable)
            # Zero-LLM refusal: pick from a pre-translated catalog
            # based on detected script in the stranger's own message.
            # An English-ish message gets English; Chinese gets
            # Chinese; unsupported scripts fall back to a bilingual
            # EN+ZH template (SunGrow's primary customer base).
            let lang = detectLang(plainContent)
            response =
              if refusalByLang.hasKey(lang): refusalByLang[lang]
              else: refusalByLang["en"] & "\n\n" & refusalByLang["zh"]

        # Subscription gate — runs AFTER auth (we know who this nc:id
        # is) but BEFORE the agent loop (so no LLM tokens burned on
        # blocked customers). Skipped for internal users and for
        # paths that already set `response` (invite-redeem, refusal).
        # On block: `response` gets a canned, language-aware message
        # with brand + reason + support contact.
        # On grace: `response` stays empty, but `banner` is set so the
        # session task prepends it to the agent's reply.
        var banner = ""
        if response == "":
          let g3 = msgGraph
          if g3 != nil:
            let entID = resolveSenderEntity(g3, msg)
            if uint32(entID) > 0 and g3.entities.hasKey(entID):
              let ent = g3.entities[entID]
              # Internal users bypass the gate entirely.
              let tier = entityTier(cfg[], g3, ent)
              if tier == "ext":
                let ncId = toAlias(entID)
                let gr = subscriptionGate(g3, ncId, getTime().toUnix)
                let brand = resolveBrand(g3)
                let contact = resolveSupportContact(g3)
                let lang = loadLang(ncId, "en")
                case gr.decision
                of gdBlockNoPlan:
                  response = msgNoPlan(brand, contact, lang)
                of gdBlockRecycled:
                  response = msgRecycled(brand, contact, lang)
                of gdBlockSuspended:
                  let reason = if gr.sub.isSome: gr.sub.get().suspendReason else: ""
                  response = msgSuspended(brand, reason, contact, lang)
                of gdBlockExpired:
                  let expiresUnix = if gr.sub.isSome: gr.sub.get().expires else: 0'i64
                  response = msgExpired(brand, expiresUnix, contact, lang)
                of gdBlockDailyLimit:
                  let cap = if gr.sub.isSome: gr.sub.get().dailyTokens else: 0
                  response = msgDailyLimit(brand, cap, gr.tokensToday,
                                            getTime().toUnix, contact, lang)
                of gdAllowWithWarning:
                  if gr.shouldWarnNow:
                    banner = bannerGraceWarning(brand, gr.daysRemaining,
                                                 contact, lang)
                    markWarned(ncId)
                of gdAllow:
                  discard
                if response != "":
                  stderr.writeLine "claw: gate blocked " & ncId &
                                   " [" & $gr.decision & "]"

        # Group-chat response policy: reply iff @mention OR the sender
        # is in this agent's `serves` list (i.e. an explicit customer).
        # `reportsTo` is deliberately NOT a trigger — in multi-agent
        # deployments, multiple agents typically reportsTo the same boss
        # (e.g. Lexi + Atlas both reportsTo Jerry). Treating reportsTo
        # as an auto-response trigger would make EVERY agent try to
        # answer every boss message → cross-talk. Bosses @mention the
        # specific agent they want; 1:1 DMs bypass this filter entirely.
        var shouldRespond = true
        if msg.chat_kind == ckGroup and response == "":
          # Group chat policy: respond IFF @mentioned. No auto-response
          # for anyone — not even the agent's declared customers. A
          # group is a shared space where any participant might speak
          # to each other or to the group at large; the bot shouldn't
          # barge in without being named. Customers who want a reply
          # either @mention the bot, or DM it (1:1 DMs bypass this
          # filter entirely — `msg.chat_kind != ckGroup` there).
          let agentName = recipient
          let lcContent = plainContent.toLowerAscii
          # Match the canonical agent name, OR (for Feishu) the per-chat
          # bot display name stamped into metadata by the channel's
          # mention-discovery cache. Real Feishu @mentions with a
          # `@_user_N` placeholder were already rewritten to
          # `@<agentName>` by feishu.nim; the display-name check mops
          # up the literal-copy-paste case (`@小金 你好` typed as text).
          var mentioned = ("@" & agentName.toLowerAscii) in lcContent
          if not mentioned:
            let bName = msg.metadata.getOrDefault("bot_display_name", "")
            if bName.len > 0 and ("@" & bName.toLowerAscii) in lcContent:
              mentioned = true
          if not mentioned:
            shouldRespond = false
            infoCF("claw", "Group-chat silent (no @mention)",
                   {"agent": agentName, "sender": msg.sender_id,
                    "chat": msg.chat_id}.toTable)
        # Company-line reception gate. Any inbound that resolved to
        # `companyRoute` (bare-pubkey nMobile main-line OR a Feishu app
        # assigned to the corporate entity in the DSL) is a reception
        # surface, not a conversation. Bind/invite intercepts above
        # already had their shot; if nothing matched and it isn't a
        # slash command, reply with a static pointer and skip the LLM.
        if response == "" and shouldRespond and companyRoute and
           not plainContent.startsWith("/"):
          let lang = detectLang(plainContent)
          let zh = lang.startsWith("zh")
          if msg.channel == "nmobile":
            response =
              if zh:
                "这是公司主线（接待台），不接入助理对话。请直接私信下列助理："
              else:
                "This is the company main line (reception). It doesn't route to a chat assistant — please DM an agent directly:"
            response.add(nmobile_channel.nkyYellowBook(cfg[], if zh: "zh" else: "en"))
          else:
            # Feishu (and future channels): no per-agent extension model —
            # each agent runs as its own bot in its own app. Just point
            # the sender at the bind/invite codes that brought them here.
            response =
              if zh:
                "这是公司主线（接待台），不接入助理对话。如果您要绑定或加入，请发送绑定码 / 邀请码。"
              else:
                "This is the company main line (reception). It doesn't route to a chat assistant — if you're onboarding, please send your bind / invite code."

        if response == "" and shouldRespond:
          if plainContent.startsWith("/"):
            # System commands are operator-level actions — gateway/config
            # control, not conversation. The company main-line address
            # is the canonical surface for them: a customer DMing
            # `atlas.<pubkey>` or `cli_<app>_agent` with `/restart` gets
            # silently dropped, the agent never sees it, and the
            # gateway doesn't act on it.
            #
            # Carve-out for SuperAdmin/Admin senders: when an operator
            # types `/model` in their normal DM with an agent (the most
            # natural place to ask "what model is this agent using
            # right now?"), the command should still work. The gate's
            # purpose is keeping CUSTOMERS from triggering operator
            # actions — that's preserved by checking permission, not
            # just chat routing.
            let callerPerm = resolveCallerPermission(cfg, msg)
            if not companyRoute and callerPerm notin {pmSuperAdmin, pmAdmin}:
              infoCF("claw", "Dropped slash command — not routed to company",
                     {"sender": msg.sender_id,
                      "recipient": msg.recipient_id,
                      "channel": msg.channel,
                      "perm": $callerPerm,
                      "cmd": plainContent[0 ..< min(plainContent.len, 48)]}.toTable)
              continue  # skip the rest of handling; no reply to non-op paths
            # Fast path: system commands run in a spawned task so they
            # don't block the main inbound loop behind a 10-60s agent
            # turn on an unrelated chat. These handlers are read-only
            # (or fork-and-forget like /restart), so concurrent execution
            # with an in-flight agent run is safe.
            let cMsg = msg
            let cPlain = plainContent
            let cOffice = officeKey
            asyncCheck (proc() {.async.} =
              try:
                var sm = cMsg
                sm.content = cPlain
                let r = await handleSystemCommand(cfg, sm, gCtx.offices[cOffice])
                if r != "":
                  var fMeta = initTable[string, string]()
                  fMeta["final"] = "true"
                  let appID = cMsg.metadata.getOrDefault("app_id", "")
                  # Mirror inbound recipient_id, not the "Lexi" office
                  # fallback — a main-line /cmds reply must stay on the
                  # main-line contact thread.
                  let cOutSender = cMsg.recipient_id
                  msgBus.publishOutbound(newOutbound(cMsg.channel, cOutSender,
                                                     cMsg.chat_id, r,
                                                     appID = appID,
                                                     metadata = fMeta))
                  statusEmitter.emitChannelMsg(cMsg.channel, "out", cOutSender)
              except Exception as e:
                errorCF("claw", "System-command fast-path error",
                        {"error": e.msg}.toTable)
            )()
            # Leave response = "" so the main path's publish is skipped;
            # the spawned task owns the reply. Main loop continues to
            # consume the next inbound immediately.
          else:
            let chainKey = msg.session_key
            let prevTail =
              if sessionTails.hasKey(chainKey): sessionTails[chainKey]
              else: nil
            let newTail = launchSessionTask(
              chainKey = chainKey,
              channel = msg.channel,
              chatID = msg.chat_id,
              sessionKey = msg.session_key,
              appID = msg.metadata.getOrDefault("app_id", ""),
              recipient = recipient,
              office = officeKey,
              cMsg = msg,
              graph = msgGraph,
              prevTail = prevTail,
              bannerPrefix = banner)
            sessionTails[chainKey] = newTail
            # Schedule self-cleanup — drop the tail entry when this task
            # finishes, guarded by identity so a newer chained task isn't
            # wiped. Put the del hook on the Future's completion.
            let cleanupKey = chainKey
            let cleanupTail = newTail
            newTail.addCallback(proc() =
              if sessionTails.getOrDefault(cleanupKey) == cleanupTail:
                sessionTails.del(cleanupKey))

        if response != "":
          var finalMeta = initTable[string, string]()
          finalMeta["final"] = "true"
          # Preserve the app_id so a reply to a Feishu message on App B
          # goes out on App B's lark-cli (not whichever is first-enabled).
          let inboundAppID = msg.metadata.getOrDefault("app_id", "")
          # Responses from this path (bind intercept, invite redeem, gate
          # refusals — anything gateway-built, NOT agent LLM output) must
          # carry the ORIGINAL `recipient_id` as sender_agent, not the
          # "Lexi" fallback above. The fallback is the office routing key;
          # reusing it as sender_agent stamps gateway-built replies as
          # coming from Lexi, which on nmobile routes out through
          # `lexi.<pub>` instead of the main-line client the customer
          # actually DM'd.
          let outSender = msg.recipient_id
          msgBus.publishOutbound(newOutbound(msg.channel, outSender, msg.chat_id, response,
                                             appID = inboundAppID,
                                             metadata = finalMeta))
          statusEmitter.emitChannelMsg(msg.channel, "out", outSender)
          discard  # TODO: emit activity event via stdio
      except Exception as e:
        errorCF("claw", "Message loop error", {"error": e.msg}.toTable)
        await sleepAsync(1000)
  )()

  # Heartbeats live as scheduled jobs in cronServiceInstance; no
  # separate timer machinery to start.
  asyncCheck cronServiceInstance.start()
  asyncCheck gChanManager.startAll()

  # Drain agent requests from HTTP server thread
  asyncCheck (proc() {.async.} =
    while true:
      # Non-blocking check for agent requests
      var req: AgentRequest
      let (dataAvailable, data) = gAgentRequestChan.tryRecv()
      if dataAvailable:
        req = data
        let (officeKey, message, senderOverride, channelOverride, respChan) = req
        try:
          if not gCtx.offices.hasKey(officeKey):
            gCtx.offices[officeKey] = makeAgentLoop(officeKey.capitalizeAscii())
          # Sender resolution:
          #   --from=<id> explicit override → use that verbatim (lets CLI
          #                spoof a guest/customer for testing gating)
          #   otherwise → scan BASE.json for a SuperAdmin Person so the
          #               default "CLI terminal" invocation routes as Owner
          var cliSender = "cli:user"
          if senderOverride.len > 0:
            cliSender = senderOverride
          else:
            try:
              let basePath = getNimClawDir() / "BASE.json"
              if fileExists(basePath):
                let base = parseJson(readFile(basePath))
                let graph = base{"@graph"}
                if graph != nil and graph.kind == JArray:
                  for ent in graph:
                    if ent{"kind"}.getStr() == "Person" and
                       ent{"permission-group"}.getStr() == "SuperAdmin":
                      cliSender = ent{"name"}.getStr("cli:user")
                      break
            except: discard
          let chan = if channelOverride.len > 0: channelOverride else: "cli"
          # Same SuperAdmin bind-code check as the bus path — lets
          # `claw agent send --from=<raw-id> --channel=<ch> <code>`
          # exercise the bootstrap flow without a real channel.
          var resp = ""
          block bindCheck:
            let workspace = cfg[].workspacePath()
            let g = loadWorld(workspace)
            let bound = tryBind(g, workspace, chan, cliSender, message)
            if bound.isSome:
              let b = bound.get
              resp = "\u{2713} Bound to " & b.targetName & " (" & b.targetNcId &
                     ", SuperAdmin). You're now authenticated on channel " &
                     chan & "."
              break bindCheck
          if resp == "":
            resp = await gCtx.offices[officeKey].processDirect(message, cliSender, cliSender, chan)
          respChan[].send(resp)
        except Exception as e:
          respChan[].send("Error: " & e.msg)
      else:
        await sleepAsync(50)  # Don't spin when no requests
  )()

  signal(SIGHUP, SIG_IGN)
  signal(SIGTERM, proc(sig: cint) {.noconv.} =
    gracefulShutdown()
    quit(0)
  )
  setControlCHook(proc() {.noconv.} =
    gracefulShutdown()
    quit(0)
  )

  # Scan each agent's workstation dir (for now, just log what's there)
  for name, _ in gCtx.offices:
    let wsDir = cfg[].workspacePath() / "offices" / name / "workstation"
    if not dirExists(wsDir): continue
    let wsSkills = wsDir / "skills"
    let wsMcp = wsDir / "mcp"
    var skillCount = 0
    var toolCount = 0
    if dirExists(wsSkills):
      for k, _ in walkDir(wsSkills):
        if k == pcDir: inc skillCount
    if dirExists(wsMcp):
      for k, _ in walkDir(wsMcp):
        if k == pcDir: inc toolCount
    if skillCount > 0 or toolCount > 0:
      infoCF("gateway", "Workstation contents detected",
        {"agent": name, "skills": $skillCount, "tools": $toolCount}.toTable)

  stderr.writeLine "claw ready." & (if useStdio: "" else: " Press Ctrl+C to stop.")

  if useStdio:
    # In stdio mode, run event loop until stdin EOF
    asyncCheck (proc() {.async.} =
      while stdioServer.running:
        await sleepAsync(100)
      # stdin EOF — Zen closed. Shut down.
      gracefulShutdown()
      quit(0)
    )()

  while true:
    try:
      poll()
    except Exception as e:
      if e.msg.contains("Interrupted system call"): break
      errorCF("claw", "Poll exception", {"error": e.msg}.toTable)

  gracefulShutdown()
