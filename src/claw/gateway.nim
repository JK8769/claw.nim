
## gateway — Long-running gateway process: agents, channels, cron.
## Supports --stdio (Zen) and --daemon (headless) modes.

import std/[os, strutils, asyncdispatch, tables, posix, exitprocs, json, algorithm, options, osproc, times, sets, random]
import curly, webby/httpheaders
import config, logger, bus, bus_types, session, agent/loop, agent/cortex, agent/binding, agent/invites, cli_admin
import providers/http, providers/types as providers_types, protocol
import channels/[base as channel_base, manager as channel_manager]
import services/[heartbeat, cron as cron_service]
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
  debugCF("cronHandler", "Triggering job", {"id": job.id}.toTable)

  let agentName = if job.payload.agentName != "": job.payload.agentName else: "Lexi"
  let officeKey = agentName.toLowerAscii()

  if job.payload.deliver:
    gCtx.msgBus.publishOutbound(newOutbound(job.payload.channel, agentName, job.payload.to, job.payload.message))
  else:
    if not gCtx.offices.hasKey(officeKey):
      gCtx.offices[officeKey] = newAgentLoop(gCtx.cfg, gCtx.msgBus, gCtx.provider, agentName, gCtx.cronService)
    let sender = if job.payload.senderID != "": job.payload.senderID else: "system:scheduler"
    let agentResponse = await gCtx.offices[officeKey].processDirect(job.payload.message, sender, sender, channel = job.payload.channel)
    if agentResponse != "":
      gCtx.msgBus.publishOutbound(newOutbound(job.payload.channel, agentName, job.payload.to, agentResponse))

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

proc handleSystemCommand(cfg: ref Config, msg: InboundMessage, al: AgentLoop): Future[string] {.async.} =
  let cmd = msg.content.strip()
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
  elif cmd in ["/reset", "/new"]:
    al.sessions.clearSession(msg.session_key)
    return "Session history cleared for `" & msg.session_key & "`. Starting fresh!"
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
      var msg = "Current model: `" & al.model & "` (provider: `" & cfg.default_provider & "`)\n\n"
      let graph = loadWorld(cfg[].workspacePath())
      if graph.providers != nil and graph.providers.kind == JObject and graph.providers.len > 0:
        for key, pNode in graph.providers.getFields():
          let rawKey = pNode{"apiKey"}.getStr("")
          let hasKey = if rawKey.len > 0: "+" else: "-"
          msg &= "**" & key & "** " & hasKey & "\n"
          if pNode.hasKey("models") and pNode["models"].kind == JArray:
            for m in pNode["models"]:
              let modelId = m.getStr()
              let marker = if modelId == al.model: " <- current" else: ""
              msg &= "  `" & key & ":" & modelId & "`" & marker & "\n"
          else:
            msg &= "  (no models listed)\n"
      msg &= "\nUsage: `/model <provider:model>`\n  `/model list <provider>` -- query models from API"
      return msg
    let modelStr = parts[1].strip()

    # /model list [provider]
    if modelStr == "list" or modelStr.startsWith("list "):
      let listParts = modelStr.split(" ", 1)
      let listProvider = if listParts.len > 1: listParts[1].strip() else: cfg.default_provider
      let graph = loadWorld(cfg[].workspacePath())
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

    # Parse provider:model
    var providerKey, modelName: string
    let colonPos = modelStr.find(':')
    if colonPos > 0:
      providerKey = modelStr[0..<colonPos]
      modelName = modelStr[colonPos+1..^1]
    else:
      let slashPos = modelStr.find('/')
      if slashPos < 0:
        providerKey = cfg.default_provider
        modelName = modelStr
      else:
        providerKey = modelStr[0..<slashPos]
        modelName = modelStr[slashPos+1..^1]

    let graph = loadWorld(cfg[].workspacePath())
    let tech = resolveProviderTech(modelName, providerKey, graph.providers, providerOverride = providerKey)
    if tech.apiKey == "":
      return "No API key found for provider `" & providerKey & "`."

    al.provider = createProvider(tech.model, tech.apiKey, tech.apiBase)
    al.model = modelName
    cfg.default_provider = providerKey
    cfg.default_model = modelName
    cfg.agents.defaults.model = modelName

    if gCtx != nil:
      for key, office in gCtx.offices:
        office.provider = al.provider
        office.model = modelName

    let graphFile = getConfigPath().parentDir() / "BASE.json"
    if fileExists(graphFile):
      var base = parseFile(graphFile)
      base["config"]["default_provider"] = %providerKey
      base["config"]["default_model"] = %modelName
      base["config"]["agents"]["defaults"]["model"] = %modelName
      if base["config"]["agents"].hasKey("named"):
        for i in 0..<base["config"]["agents"]["named"].len:
          base["config"]["agents"]["named"][i]["provider"] = %providerKey
          base["config"]["agents"]["named"][i]["model"] = %modelName
      writeFile(graphFile, base.pretty(4))

    al.sessions.clearSession(msg.session_key)
    return "Switched to `" & providerKey & "/" & modelName & "`. Session cleared."
  elif cmd.startsWith("/invite"):
    # `/invite <customer-name> [<agent>] [<uses>]` — SuperAdmin-only
    # chat shortcut that pre-allocates a Customer Person entity + mints
    # an invite code, returns the bundled `nc:X/CODE` string to share.
    # The customer sends that string as their first message to any
    # channel routing to <agent> and the gateway's customer-invite
    # intercept authenticates them without involving the LLM.
    let workspace = cfg[].workspacePath()
    var g = loadWorld(workspace)
    var permOk = false
    var issuer = ""
    if g != nil:
      let channelKey =
        if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
          msg.channel & ":" & msg.metadata["app_id"]
        else: msg.channel
      let (entID, _) = g.resolveUserGraph(channelKey, msg.sender_id)
      if uint32(entID) > 0 and g.entities.hasKey(entID):
        issuer = toAlias(entID)
        let p = g.entities[entID].role.toLowerAscii
        if p in ["superadmin", "admin"]: permOk = true
    if not permOk:
      return "`/invite` requires SuperAdmin. Your current permission " &
             "doesn't allow minting customer access codes."
    let parts = cmd.splitWhitespace()
    if parts.len < 2:
      return "Usage: `/invite <customer-name> [<agent>] [<uses>]`\n" &
             "Examples:\n" &
             "  `/invite Alice`              → customer served by " &
             (if cfg.agents.named.len > 0: cfg.agents.named[0].name else: "default") &
             ", 1 use\n" &
             "  `/invite Acme Lexi 1`        → customer served by Lexi, 1 use\n" &
             "  `/invite BulkCustomer Lexi 10` → shared code, 10 redemptions"
    let customerName = parts[1]
    let agentName =
      if parts.len >= 3: parts[2]
      elif cfg.agents.named.len > 0: cfg.agents.named[0].name
      else: msg.recipient_id
    var maxUses = 1
    if parts.len >= 4:
      try: maxUses = parseInt(parts[3])
      except: discard
    if '"' in customerName:
      return "Error: customer name cannot contain a double-quote."
    # Validate agent exists.
    var agentID = WorldEntityID(0)
    if g.nameIndex.hasKey(agentName): agentID = g.nameIndex[agentName]
    if uint32(agentID) == 0 or not g.entities.hasKey(agentID) or
       g.entities[agentID].kind != ekAI:
      var known: seq[string]
      for id, ent in g.entities.pairs:
        if ent.kind == ekAI: known.add(ent.name)
      return "Error: no agent named `" & agentName & "`. Known: " &
             known.join(", ") & "."
    # Pre-allocate the customer entity.
    let newID = WorldEntityID(g.nextID)
    g.nextID += 1
    var ent = WorldEntity(
      id: newID,
      kind: ekPerson,
      name: customerName,
      role: "Customer",
      identifiers: initTable[string, string]()
    )
    g.entities[newID] = ent
    g.nameIndex[customerName] = newID
    var agent = g.entities[agentID]
    let annot = RelationshipAnnotation(
      role: urCustomer, trustLevel: 40, etiquette: "")
    agent.serves.add(RelationshipLink(
      targetID: newID, annotation: some(annot)))
    g.entities[agentID] = agent
    g.saveWorld()
    # Mint the code.
    var invMap = loadInvites(workspace)
    randomize()
    var code = generateInviteCode()
    while invMap.hasKey(code): code = generateInviteCode()
    let alias = toAlias(newID)
    invMap[code] = InviteConstraint(
      code: code, agentName: agentName, customerName: customerName,
      role: "customer", maxUses: maxUses, expiry: 0, pinless: false,
      issuedBy: issuer, createdAt: getTime().toUnix(),
      usedBy: "", usedAt: 0, targetNcId: alias)
    saveInvites(workspace, invMap)
    # Persist the Customer to BASE.nims so `co update` keeps them.
    # Identifiers get appended when they redeem.
    let baseNims = getNimClawDir() / "BASE.nims"
    if fileExists(baseNims):
      var bLines = readFile(baseNims).splitLines()
      var exists = false
      for l in bLines:
        if l.strip() == "person \"" & customerName & "\":":
          exists = true; break
      if not exists:
        # Insert before `build(currentSourcePath())`.
        var insertAt = bLines.len
        for i, l in bLines:
          if l.strip().startsWith("build(currentSourcePath"):
            insertAt = i; break
        let newBlock = @[
          "",
          "person \"" & customerName & "\":",
          "  permission \"Customer\""
        ]
        var merged = bLines[0 ..< insertAt]
        for l in newBlock: merged.add(l)
        for i in insertAt ..< bLines.len: merged.add(bLines[i])
        writeFile(baseNims, merged.join("\n"))
    return "**Customer invite created**\n\n" &
           "Share this string:  `" & alias & "/" & code & "`\n\n" &
           "  Customer: `" & customerName & "` (" & alias & ")\n" &
           "  Agent:    " & agentName & "\n" &
           "  Max uses: " & $maxUses & "\n\n" &
           "The customer DMs that string to any channel routing to " &
           agentName & " and gets authenticated before the LLM turn. " &
           "Use `/status` to confirm."

  elif cmd == "/restart":
    # SuperAdmin-only: stop the current gateway and launch a fresh one
    # so config/DSL changes (e.g. a freshly added Feishu app) take
    # effect without dropping to a terminal.
    # Permission check uses the declared entity permission, not the
    # relationship-annotation role.
    let workspace = cfg[].workspacePath()
    let g = loadWorld(workspace)
    var permOk = false
    if g != nil:
      let channelKey =
        if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
          msg.channel & ":" & msg.metadata["app_id"]
        else: msg.channel
      let (entID, _) = g.resolveUserGraph(channelKey, msg.sender_id)
      if uint32(entID) > 0 and g.entities.hasKey(entID):
        let p = g.entities[entID].role.toLowerAscii
        if p in ["superadmin", "admin"]: permOk = true
    if not permOk:
      return "`/restart` requires SuperAdmin. Ask one to run " &
             "`claw co stop && claw gateway` at the terminal."
    let clawBin = getAppFilename()
    let myPidHere = getpid()
    # Detached child survives our death (setsid under poDaemon).
    # Signal us directly with the known PID — avoids `co stop`'s
    # service-dir lookup which can miss when NIMCLAW env isn't
    # picked up cleanly in the forked shell. Wait for the process
    # to actually exit (up to ~5s) before starting the new gateway
    # so we don't hit the "already running" guard.
    let logPath = getNimClawDir() / "logs" / "restart.log"
    let script = "sleep 2 && kill -TERM " & $myPidHere & " 2>/dev/null ; " &
                 "for i in $(seq 1 25); do kill -0 " & $myPidHere &
                 " 2>/dev/null || break; sleep 0.2; done ; " &
                 "rm -f '" & getNimClawDir() & "/logs/gateway.pid' ; " &
                 "NIMCLAW_DIR='" & getNimClawDir() &
                 "' '" & clawBin & "' gateway > '" & logPath & "' 2>&1"
    discard startProcess("/bin/sh",
                         args = @["-c", script],
                         options = {poDaemon, poUsePath})
    return "Restarting gateway in ~2s. I'll be unreachable for a few " &
           "seconds — **please send a message yourself** when you want " &
           "to check I'm back (the gateway doesn't push-notify). New " &
           "app routings (e.g. freshly added Feishu apps) will be live " &
           "on the next message."
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
  if useStdio: logger.stdioMode = true
  if debug: setLevel(DEBUG)

  # PID file — company-scoped so `claw company list` can show RUNNING per company.
  let companyPidPath = gatewayPidPath()
  if fileExists(companyPidPath):
    try:
      let oldPid = readFile(companyPidPath).strip().parseInt()
      if isProcessAlive(oldPid):
        echo "Error: gateway is already running for this company (PID: ", oldPid, ")"
        echo "Use 'claw company stop' to stop it."
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

  # Config & provider
  var cfg = new(Config)
  cfg[] = loadConfig(getConfigPath())
  cfg.agents.defaults.stream_intermediary = stream
  let graph = loadWorld(cfg[].workspacePath())
  let tech = resolveProviderTech(cfg.agents.defaults.model, cfg.default_provider, graph.providers, providerOverride = cfg.default_provider)
  infoCF("claw", "Provider", {"model": tech.model, "base": tech.apiBase}.toTable)

  let msgBus = newMessageBus()
  let provider = createProvider(tech.model, tech.apiKey, tech.apiBase)
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
    cronService: cronServiceInstance,
    offices: initTable[string, AgentLoop](),
    statusEmitter: statusEmitter
  )

  cronServiceInstance.onJob = cronHandler

  # Default agent
  if not gCtx.offices.hasKey("lexi"):
    gCtx.offices["lexi"] = newAgentLoop(gCtx.cfg, gCtx.msgBus, gCtx.provider, "Lexi", gCtx.cronService)
  let lexiWorkspace = cfg[].workspacePath() / "offices" / "lexi"
  let hbService = newHeartbeatService(lexiWorkspace, proc(p: string): Future[void] {.async.} =
    discard await gCtx.offices["lexi"].processDirect(p, "system:heartbeat")
  , 1800, true)

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

    # Register agents as chat provider
    var agentList = newJArray()
    for name, office in gCtx.offices:
      agentList.add(%*{"name": name, "description": "", "model": gCtx.cfg.agents.defaults.model})
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

  # Message loop
  asyncCheck (proc() {.async.} =
    while true:
      try:
        let msg = await msgBus.consumeInbound()
        statusEmitter.emitChannelMsg(msg.channel, "in", msg.sender_id)
        discard  # TODO: emit activity event via stdio

        let recipient = if msg.recipient_id == "": "Lexi" else: msg.recipient_id
        let officeKey = recipient.toLowerAscii()

        if not gCtx.offices.hasKey(officeKey):
          infoCF("claw", "Opening office", {"agent": recipient}.toTable)
          gCtx.offices[officeKey] = newAgentLoop(gCtx.cfg, gCtx.msgBus, gCtx.provider, recipient, gCtx.cronService)

        # Extract plain text from JSON content (e.g. Feishu)
        var plainContent = msg.content.strip()
        if plainContent.startsWith("{"):
          try:
            let j = parseJson(plainContent)
            if j.hasKey("text"):
              plainContent = j["text"].getStr().strip()
          except: discard

        var response = ""
        # SuperAdmin bind-code check — runs BEFORE the LLM so an
        # unauthenticated first-contact carrying the printed code can
        # claim the declared SuperAdmin's identifier without ever
        # reaching the model. Wrong / absent codes fall through as a
        # normal guest message.
        block bindCheck:
          let workspace = cfg[].workspacePath()
          let g = loadWorld(workspace)
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
            response = "\u{2713} Bound to " & b.targetName & " (" & b.targetNcId &
                       ", SuperAdmin). You're now authenticated on this channel."
            break bindCheck
        # Customer-invite intercept — parses `nc:X/CODE` (or bare code)
        # and, if it matches a pending invite with a pre-allocated target,
        # stamps the sender's identifiers onto that entity and burns the
        # code. Runs BEFORE the LLM: customer authenticates without their
        # invite string ever hitting the model. Falls through to normal
        # LLM handling for non-code content.
        if response == "":
          let workspace = cfg[].workspacePath()
          var g = loadWorld(workspace)
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
                  response = "\u{2713} Welcome, " & ent.name & ". You're " &
                             "authenticated as a Customer (" & inv.targetNcId &
                             "). Ask me anything — I'm here to help."
                  stderr.writeLine "claw: customer-invite redeemed " &
                                   inv.targetNcId & " via " & channelKey &
                                   " ← " & msg.sender_id

        # Group-chat response policy: reply iff @mention OR the sender
        # has a `reportsTo`/`serves` relationship with this agent (in
        # either direction). Otherwise stay silent — avoids the group-
        # chat firehose without needing require_mention=true.
        var shouldRespond = true
        if msg.chat_kind == ckGroup and response == "":
          let agentName = recipient
          let mentioned = ("@" & agentName.toLowerAscii) in plainContent.toLowerAscii
          if not mentioned:
            let workspace = cfg[].workspacePath()
            let g = loadWorld(workspace)
            let channelKey =
              if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
                msg.channel & ":" & msg.metadata["app_id"]
              else: msg.channel
            var senderID = WorldEntityID(0)
            let (rid, _) = g.resolveUserGraph(channelKey, msg.sender_id)
            if uint32(rid) > 0:
              senderID = rid
            elif msg.channel == "feishu":
              let unionID = msg.metadata.getOrDefault("union_id", "")
              if unionID.len > 0:
                let (uid, _) = g.resolveUserGraph("feishu:union", unionID)
                if uint32(uid) > 0: senderID = uid
              if uint32(senderID) == 0:
                let userID = msg.metadata.getOrDefault("user_id", "")
                if userID.len > 0:
                  let (uid, _) = g.resolveUserGraph("feishu:user", userID)
                  if uint32(uid) > 0: senderID = uid
            var hasRel = false
            if uint32(senderID) > 0 and g.nameIndex.hasKey(agentName):
              let aID = g.nameIndex[agentName]
              if g.entities.hasKey(aID):
                let agentEnt = g.entities[aID]
                for lk in agentEnt.reportsTo:
                  if lk.targetID == senderID: hasRel = true; break
                if not hasRel:
                  for lk in agentEnt.serves:
                    if lk.targetID == senderID: hasRel = true; break
            if not hasRel:
              shouldRespond = false
              infoCF("claw", "Group-chat silent (no mention, no relationship)",
                     {"agent": agentName, "sender": msg.sender_id,
                      "chat": msg.chat_id}.toTable)
        if response == "" and shouldRespond:
          if plainContent.startsWith("/"):
            var sysMsg = msg
            sysMsg.content = plainContent
            response = await handleSystemCommand(cfg, sysMsg, gCtx.offices[officeKey])
          else:
            response = await gCtx.offices[officeKey].processMessage(msg)

        if response != "":
          var finalMeta = initTable[string, string]()
          finalMeta["final"] = "true"
          # Preserve the app_id so a reply to a Feishu message on App B
          # goes out on App B's lark-cli (not whichever is first-enabled).
          let inboundAppID = msg.metadata.getOrDefault("app_id", "")
          msgBus.publishOutbound(newOutbound(msg.channel, recipient, msg.chat_id, response,
                                             appID = inboundAppID,
                                             metadata = finalMeta))
          statusEmitter.emitChannelMsg(msg.channel, "out", recipient)
          discard  # TODO: emit activity event via stdio
      except Exception as e:
        errorCF("claw", "Message loop error", {"error": e.msg}.toTable)
        await sleepAsync(1000)
  )()

  asyncCheck hbService.start()
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
            gCtx.offices[officeKey] = newAgentLoop(gCtx.cfg, gCtx.msgBus, gCtx.provider,
              officeKey.capitalizeAscii(), gCtx.cronService)
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
