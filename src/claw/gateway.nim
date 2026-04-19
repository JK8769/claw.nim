
## gateway — Long-running gateway process: agents, channels, cron.
## Supports --stdio (Zen) and --daemon (headless) modes.

import std/[os, strutils, asyncdispatch, tables, posix, exitprocs, json, algorithm]
import curly, webby/httpheaders
import config, logger, bus, bus_types, session, agent/loop, agent/cortex
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

proc handleSystemCommand(cfg: ref Config, msg: InboundMessage, al: AgentLoop): Future[string] {.async.} =
  let cmd = msg.content.strip()
  if cmd == "/status":
    return "**System Status**\n" &
           "- Session: `" & msg.session_key & "`\n" &
           "- Model: `" & al.model & "`\n" &
           "- Intermediary Stream: " & (if cfg.agents.defaults.stream_intermediary: "ON" else: "OFF")
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
        if plainContent.startsWith("/"):
          var sysMsg = msg
          sysMsg.content = plainContent
          response = await handleSystemCommand(cfg, sysMsg, gCtx.offices[officeKey])
        else:
          response = await gCtx.offices[officeKey].processMessage(msg)

        if response != "":
          var finalMeta = initTable[string, string]()
          finalMeta["final"] = "true"
          msgBus.publishOutbound(newOutbound(msg.channel, recipient, msg.chat_id, response, metadata = finalMeta))
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
          let resp = await gCtx.offices[officeKey].processDirect(message, cliSender, cliSender, chan)
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
