import std/[os, strutils, posix, json]
import config, cli_admin, cli_providers, cli_onboard, protocol

type
  ServiceAction* = enum
    saOutput       ## Just print the message
    saGatewayRun   ## Caller should start gateway
    saGatewayKill  ## Caller should kill gateway

  ServiceResult* = tuple[action: ServiceAction, message: string]

const
  lifecycleCmds = ["new", "run", "start", "stop", "restart", "status", "deploy", "remove", "list", "use", "export"]
  configCmds = ["onboard", "provider", "channel", "agent", "plugin", "skill", "auth"]

proc isLifecycleCmd(s: string): bool =
  for c in lifecycleCmds:
    if s == c: return true

proc isConfigCmd(s: string): bool =
  for c in configCmds:
    if s == c: return true

# ── Service dir resolution ───────────────────────────────────────

proc serviceDir(name: string): string =
  ## Returns the canonical service dir path (does not check existence)
  if name == "": expandHome("~/.nimclaw")
  else: expandHome("~/.nimclaw-" & name)

proc localServiceDir(name: string): string =
  if name == "": getCurrentDir() / ".nimclaw"
  else: getCurrentDir() / ".nimclaw-" & name

proc isConfigured(dir: string): bool =
  ## A service dir is configured if it has a BASE.json
  fileExists(dir / "BASE.json")

proc resolveServiceDir(name: string): string =
  ## Find existing service dir.
  ## For default (unnamed) service: NIMCLAW_DIR env var takes priority (set by nimble for dev).
  ## Otherwise: deployed (~/) first, then local (./) — production behavior.
  if name == "":
    let envDir = getEnv("NIMCLAW_DIR")
    if envDir != "" and dirExists(envDir): return envDir
  let deployed = serviceDir(name)
  if deployed.isConfigured(): return deployed
  let local = localServiceDir(name)
  if local.isConfigured(): return local
  if dirExists(deployed): return deployed
  if dirExists(local): return local
  return ""

proc setServiceEnv(name: string): string =
  ## Resolve service dir, set NIMCLAW_DIR + NIMCLAW_SERVICE, load .env. Returns dir or "" on failure.
  let dir = resolveServiceDir(name)
  if dir == "": return ""
  putEnv("NIMCLAW_DIR", dir)
  let rtName = if name == "": "default" else: name.toLowerAscii()
  putEnv("NIMCLAW_SERVICE", rtName)
  resetNimClawDir()
  loadDotEnv()
  return dir

# ── PID management ───────────────────────────────────────────────

proc getGatewayPidPath*(): string =
  pidFilePath()

proc isProcessAlive*(pid: int): bool =
  if pid <= 0: return false
  return kill(pid.Pid, 0) == 0

proc killGateway*(): bool =
  let pidPath = getGatewayPidPath()
  if not fileExists(pidPath):
    echo "No gateway PID file found."
    return false
  try:
    let pidStr = readFile(pidPath).strip()
    let pid = pidStr.parseInt()
    if isProcessAlive(pid):
      echo "Stopping gateway (PID ", pid, ")..."
      discard kill(pid.Pid, SIGTERM)
      for _ in 1..10:
        if not isProcessAlive(pid): break
        sleep(200)
    removeFile(pidPath)
    echo "Gateway stopped."
    return true
  except:
    echo "Error: ", getCurrentExceptionMsg()
    return false

# ── Config dir pointer ───────────────────────────────────────────

proc daemonize*(binPath, logPath: string) =
  ## Fork and exec a daemon process. Parent returns on success, exits on failure.
  let pid = fork()
  if pid == 0:
    discard setsid()
    let devNull = open("/dev/null", fmRead)
    discard dup2(devNull.getFileHandle(), 0)
    devNull.close()
    var logFile: File
    if open(logFile, logPath, fmAppend):
      discard dup2(logFile.getFileHandle(), 1)
      discard dup2(logFile.getFileHandle(), 2)
      logFile.close()
    else:
      let devNull2 = open("/dev/null", fmWrite)
      discard dup2(devNull2.getFileHandle(), 1)
      discard dup2(devNull2.getFileHandle(), 2)
      devNull2.close()
    # Close inherited FDs (3..1023) so pipes from execCmdEx callers get EOF
    for fd in 3 .. 1023:
      discard close(fd.cint)
    discard execl(binPath.cstring, binPath.lastPathPart().cstring, nil)
    echo "execl failed for: ", binPath
    quit(1)
  elif pid > 0:
    sleep(200)
    if kill(pid.Pid, 0) == 0:
      echo binPath.lastPathPart(), " started (PID ", pid, ")"
    else:
      echo "Error: ", binPath.lastPathPart(), " failed to start. Check ", logPath
      quit(1)
  else:
    echo "Error: fork failed"
    quit(1)

proc writeConfigPointer*(dir: string) =
  ## Write the active config dir to ~/.nimclawd/config_dir.
  let rtDir = runtimeDir()
  if not dirExists(rtDir):
    try: createDir(rtDir) except: return
  writeFile(configDirPointer(), dir & "\n")

proc serviceUse(path: string, asJson: bool = false): string =
  let pointerPath = configDirPointer()
  if path == "":
    # Show current
    var dir: string
    var fromPointer = false
    if fileExists(pointerPath):
      dir = readFile(pointerPath).strip()
      fromPointer = true
    else:
      dir = getNimClawDir()
    if asJson:
      return $ %*{"config_dir": dir, "from_pointer": fromPointer,
                   "service": serviceRuntimeName()}
    if fromPointer:
      return "Active config dir: " & dir
    return "Active config dir: " & dir & " (default — no pointer set)"
  # Resolve to absolute path
  var absPath: string
  if path.startsWith("~"):
    absPath = expandHome(path)
  elif path.startsWith("/"):
    absPath = path
  else:
    absPath = getCurrentDir() / path
  absPath = absPath.normalizedPath()
  if not dirExists(absPath):
    if asJson: return $ %*{"error": "directory does not exist", "path": absPath}
    return "Error: directory does not exist: " & absPath
  writeConfigPointer(absPath)
  resetNimClawDir()
  if asJson:
    return $ %*{"config_dir": absPath, "service": serviceRuntimeName()}
  return "Active config dir set: " & absPath

# ── Lifecycle commands ───────────────────────────────────────────

proc serviceNew(name: string): string =
  # If NIMCLAW_DIR is set (nimble dev), create locally. Otherwise create in ~/ (production).
  let dir = if getEnv("NIMCLAW_DIR") != "":
    if name == "": localServiceDir("") else: localServiceDir(name)
  else:
    if name == "": serviceDir("") else: serviceDir(name)
  let label = if name == "": "(default)" else: name

  if dirExists(dir):
    return "Service already exists: " & dir

  echo "Creating service: ", label
  echo "  Directory: ", dir

  let tplDir = getTemplateDir()

  createDir(dir)
  createDir(dir / "workspace")
  createDir(dir / "logs")
  createDir(dir / "channels")
  createDir(dir / "support")
  createDir(dir / "foundation")
  createDir(dir / "foundation" / "skills")

  # Seed workspace from templates
  seedWorkspace(tplDir, dir / "workspace")

  echo ""
  echo "Service created: ", label
  echo ""
  echo "Next steps:"
  if name != "":
    echo "  nimclaw service ", name, " onboard    # guided setup"
    echo "  nimclaw service run ", name, "         # start gateway"
  else:
    echo "  nimclaw service onboard               # guided setup"
    echo "  nimclaw service run                    # start gateway"
  return ""

proc serviceRun(name: string): ServiceResult =
  let dir = setServiceEnv(name)
  if dir == "":
    let label = if name == "": "(default)" else: name
    return (saOutput, "Service '" & label & "' not found.\nRun: nimclaw service new " & name)
  # Persist the resolved config dir so nimclawd can find it without env vars
  writeConfigPointer(dir)
  echo "Starting gateway from: ", dir
  return (saGatewayRun, "")

proc serviceStop(name: string): ServiceResult =
  let dir = setServiceEnv(name)
  if dir == "":
    let label = if name == "": "(default)" else: name
    return (saOutput, "Service '" & label & "' not found.")
  discard killGateway()
  return (saOutput, "")

proc serviceRestart(name: string): ServiceResult =
  let dir = setServiceEnv(name)
  if dir == "":
    let label = if name == "": "(default)" else: name
    return (saOutput, "Service '" & label & "' not found.")
  discard killGateway()
  echo "Restarting..."
  return (saGatewayRun, "")

proc serviceStatusJson(name: string): JsonNode =
  let dir = resolveServiceDir(name)
  let label = if name == "": "default" else: name
  if dir == "":
    return %*{"name": label, "error": "not found"}

  let rtName = if name == "": "default" else: name.toLowerAscii()
  putEnv("NIMCLAW_SERVICE", rtName)

  var running = false
  var pid = 0
  let pidPath = pidFilePath()
  if fileExists(pidPath):
    try:
      pid = readFile(pidPath).strip().parseInt()
      running = isProcessAlive(pid)
    except: discard

  var provider = ""
  var model = ""
  var agents = newJArray()
  let configPath = dir / "BASE.json"
  if fileExists(configPath):
    try:
      let base = parseFile(configPath)
      # Post-Phase-4: derive "company default" from providers list[0]
      # rather than the removed `default_provider`/`agents.defaults.model`.
      if base.hasKey("providers") and base["providers"].kind == JObject:
        for k, pNode in base["providers"].fields:
          provider = k
          model = pNode{"defaultModel"}.getStr("")
          break
      if base{"config", "agents"}.hasKey("named"):
        for a in base{"config", "agents", "named"}:
          agents.add(%*{
            "name": a{"name"}.getStr(""),
            "provider": a{"provider"}.getStr(""),
            "model": a{"model"}.getStr(""),
            "role": a{"role"}.getStr(""),
            "entity": a{"entity"}.getStr("")
          })
    except: discard

  return %*{
    "name": label,
    "config_dir": dir,
    "runtime_dir": runtimeDir(),
    "running": running,
    "pid": pid,
    "provider": provider,
    "model": model,
    "agents": agents
  }

proc serviceStatus(name: string, asJson: bool = false): string =
  let j = serviceStatusJson(name)
  if asJson: return $j
  if j.hasKey("error"):
    return "Service '" & j["name"].getStr() & "' not found."
  let label = j["name"].getStr()
  let running = j["running"].getBool()
  let pid = j["pid"].getInt()
  var status = "Service: " & label &
    "\n  Config: " & j["config_dir"].getStr() &
    "\n  Runtime: " & j["runtime_dir"].getStr()
  if running:
    status &= "\n  Status: running (PID " & $pid & ")"
  elif pid > 0:
    status &= "\n  Status: stopped (stale PID file)"
  else:
    status &= "\n  Status: stopped"
  let provider = j["provider"].getStr("")
  let model = j["model"].getStr("")
  if provider.len > 0: status &= "\n  Provider: " & provider
  if model.len > 0: status &= "\n  Model: " & model
  return status

proc serviceDeploy(name: string): string =
  let dir = resolveServiceDir(name)
  if dir == "":
    let label = if name == "": "(default)" else: name
    return "Service '" & label & "' not found.\nRun: nimclaw service new " & name
  putEnv("NIMCLAW_DIR", dir)
  resetNimClawDir()
  let cfg = loadConfig(getConfigPath())
  return runDaemonCommand(cfg, name, @["install"])

proc serviceRemove(name: string): string =
  let dir = resolveServiceDir(name)
  let label = if name == "": "(default)" else: name
  if dir == "":
    return "Service '" & label & "' not found."

  # Check if running via namespaced runtime dir
  let rtName = if name == "": "default" else: name.toLowerAscii()
  let pidPath = expandTilde(RuntimeBaseDir) / rtName / PidFileName
  if fileExists(pidPath):
    try:
      let pid = readFile(pidPath).strip().parseInt()
      if isProcessAlive(pid):
        return "Service '" & label & "' is running (PID " & $pid & ").\nStop it first: nimclaw service stop " & name
    except: discard

  removeDir(dir)
  return "Removed service: " & label

proc scanServiceDirs(baseDir, location: string, services: var seq[tuple[name, dir, status: string]]) =
  if dirExists(baseDir / ".nimclaw"):
    var found = false
    for s in services:
      if s.name == "(default)": found = true
    if not found:
      services.add(("(default)", baseDir / ".nimclaw", location))
  for kind, path in walkDir(baseDir):
    if kind != pcDir: continue
    let dirName = path.lastPathPart()
    if dirName.startsWith(".nimclaw-"):
      let name = dirName[".nimclaw-".len..^1]
      var found = false
      for s in services:
        if s.name == name: found = true
      if not found:
        services.add((name, path, location))

proc serviceListJson(): JsonNode =
  var services: seq[tuple[name, dir, status: string]] = @[]
  scanServiceDirs(getCurrentDir(), "local", services)
  scanServiceDirs(expandHome("~"), "deployed", services)

  var arr = newJArray()
  for s in services:
    let rtName = if s.name == "(default)": "default" else: s.name.toLowerAscii()
    let pidPath = expandTilde(RuntimeBaseDir) / rtName / PidFileName
    var running = false
    var pid = 0
    if fileExists(pidPath):
      try:
        pid = readFile(pidPath).strip().parseInt()
        running = isProcessAlive(pid)
      except: discard
    let label = if s.name == "(default)": "default" else: s.name
    arr.add(%*{
      "name": label,
      "dir": s.dir,
      "location": s.status,
      "running": running,
      "pid": pid
    })
  return arr

proc serviceList(asJson: bool = false): string =
  if asJson:
    return $serviceListJson()

  var services: seq[tuple[name, dir, status: string]] = @[]
  scanServiceDirs(getCurrentDir(), "local", services)
  scanServiceDirs(expandHome("~"), "deployed", services)

  if services.len == 0:
    return "No services found.\nRun: nimclaw service new MyCompany"

  var output = "Services:\n"
  for s in services:
    let rtName = if s.name == "(default)": "default" else: s.name.toLowerAscii()
    let pidPath = expandTilde(RuntimeBaseDir) / rtName / PidFileName
    var running = false
    if fileExists(pidPath):
      try:
        let pid = readFile(pidPath).strip().parseInt()
        running = isProcessAlive(pid)
      except: discard
    let state = if running: "running" else: "stopped"
    output &= "  " & s.name & "  " & state & "  (" & s.status & ") " & s.dir & "\n"
  return output.strip()

# ── Per-service commands ─────────────────────────────────────────

proc serviceOnboard(name: string): string =
  let dir = setServiceEnv(name)
  let label = if name == "": "(default)" else: name
  if dir == "":
    return "Service '" & label & "' not found.\nRun: nimclaw service new " & name

  echo "Onboarding service: ", label
  echo "  Directory: ", dir
  echo ""

  # 1. Check deps
  echo "=== Checking dependencies ==="
  let curl = findExe("curl")
  if curl == "": echo "  curl: MISSING (required)" else: echo "  curl: ok"
  let git = findExe("git")
  if git == "": echo "  git: not found (optional)" else: echo "  git: ok"
  let node = findExe("node")
  if node == "": echo "  node: not found (optional, for playwright)" else: echo "  node: ok"
  let python = findExe("python3")
  if python == "": echo "  python3: not found (optional)" else: echo "  python3: ok"
  echo ""

  if curl == "":
    return "Error: curl is required. Install it and try again."

  # 2. Provider setup (reuse existing onboard which handles provider interactively)
  echo "=== Provider Setup ==="
  let onboardResult = runOnboardCommand(dir, interactive = true)
  if onboardResult.contains("Cancelled"):
    return onboardResult
  echo onboardResult
  echo ""

  # 3. Channel setup
  echo "=== Channel Setup ==="
  var cfg = loadConfig(getConfigPath())
  echo runChannelCommand(cfg, @["add"])
  echo ""

  # 4. Agent setup
  echo "=== Agent Setup ==="
  echo runAgentsCommand(cfg, @["add"])
  echo ""

  echo "=== Onboarding Complete ==="
  echo ""
  if name != "":
    echo "Start your service:"
    echo "  nimclaw service run ", name
  else:
    echo "Start your service:"
    echo "  nimclaw service run"
  return ""

# ── Main dispatcher ──────────────────────────────────────────────

proc dispatchConfigCmd(name, cmd: string, rest: seq[string], asJson: bool): ServiceResult =
  var cfg = loadConfig(getConfigPath())
  case cmd
  of "onboard":
    return (saOutput, serviceOnboard(name))
  of "provider":
    return (saOutput, runProviderCommand(cfg, rest, asJson = asJson))
  of "channel":
    return (saOutput, runChannelCommand(cfg, rest, asJson))
  of "agent":
    return (saOutput, runAgentsCommand(cfg, rest, asJson))
  of "plugin", "skill":
    return (saOutput, runCompetenciesCommand(cfg.workspacePath(), getNimClawDir(), rest))
  of "auth":
    return (saOutput, runAuthCommand(rest, asJson))
  else:
    return (saOutput, "Unknown command: " & cmd)

proc serviceExport(name: string): string =
  ## Reverse-engineer a .nims file from an existing service's BASE.json.
  let dir = resolveServiceDir(name)
  if dir == "":
    return "Error: service '" & (if name == "": "default" else: name) & "' not found."
  let graphFile = dir / "BASE.json"
  if not fileExists(graphFile):
    return "Error: no BASE.json found at " & dir

  let root = parseFile(graphFile)
  let config = root{"config"}
  let providers = root{"providers"}
  let graph = root{"@graph"}

  var lines: seq[string] = @[]
  lines.add("import claw/clawdsl")
  lines.add("")

  # Organization
  if not graph.isNil:
    for ent in graph:
      if ent{"kind"}.getStr() == "Corporate":
        lines.add("org " & ent{"name"}.getStr().escape() & ":")
        let desc = ent{"description"}.getStr()
        if desc != "":
          lines.add("  description " & desc.escape())
        lines.add("")

  # Persons
  if not graph.isNil:
    for ent in graph:
      if ent{"kind"}.getStr() == "Person":
        lines.add("person " & ent{"name"}.getStr().escape() & ":")
        let perm = ent{"permission-group"}.getStr()
        if perm != "":
          lines.add("  permission " & perm.escape())
        let ids = ent{"identifiers"}
        if not ids.isNil and ids.kind == JObject:
          for k, v in ids:
            lines.add("  identifier " & k.escape() & ", " & v.getStr().escape())
        lines.add("")

  # Providers
  if not providers.isNil and providers.kind == JObject:
    for key, p in providers:
      lines.add("provider " & key.escape() & ":")
      let base = p{"apiBase"}.getStr()
      if base != "": lines.add("  apiBase " & base.escape())
      let apiKey = p{"apiKey"}.getStr()
      if apiKey != "": lines.add("  apiKey " & apiKey.escape())
      let defModel = p{"defaultModel"}.getStr()
      if defModel != "": lines.add("  defaultModel " & defModel.escape())
      let models = p{"models"}
      if not models.isNil and models.len > 0:
        var modelStrs: seq[string] = @[]
        for m in models:
          if m.kind == JString: modelStrs.add(m.getStr().escape())
          elif m.kind == JObject: modelStrs.add(m{"name"}.getStr().escape())
        if modelStrs.len > 0:
          lines.add("  models " & modelStrs.join(", "))
      lines.add("")

  # Agents
  if not graph.isNil:
    let named = config{"agents"}{"named"}
    for ent in graph:
      if ent{"kind"}.getStr() != "AI": continue
      let agentName = ent{"name"}.getStr()
      lines.add("agent " & agentName.escape() & ":")
      # Find matching named config
      if not named.isNil:
        for nc in named:
          if nc{"name"}.getStr() == agentName:
            let model = nc{"model"}.getStr()
            if model != "": lines.add("  model " & model.escape())
            let prov = nc{"provider"}.getStr()
            if prov != "": lines.add("  provider " & prov.escape())
            let role = nc{"role"}.getStr()
            if role != "": lines.add("  role " & role.escape())
            let ident = nc{"identity"}.getStr()
            if ident != "": lines.add("  identity " & ident.escape())
            let md = nc{"max_depth"}.getInt()
            if md > 0: lines.add("  maxDepth " & $md)
            break
      let jt = ent{"jobTitle"}.getStr()
      if jt != "": lines.add("  jobTitle " & jt.escape())
      # Relationships
      let rTo = ent{"reportsTo"}
      if not rTo.isNil:
        for rel in rTo:
          let targetId = rel{"id"}.getStr()
          # Resolve target name from graph
          var targetName = targetId
          for e in graph:
            if e{"id"}.getStr() == targetId:
              targetName = e{"name"}.getStr()
              break
          lines.add("  reportsTo " & targetName.escape() & ":")
          let ann = rel{"@annotation"}
          if not ann.isNil:
            let r = ann{"role"}.getStr()
            if r != "": lines.add("    role " & r.escape())
            let tl = ann{"trustLevel"}.getInt()
            if tl > 0: lines.add("    trustLevel " & $tl)
            let et = ann{"etiquette"}.getStr()
            if et != "": lines.add("    etiquette " & et.escape())
      lines.add("")

  # Channels
  let channels = config{"channels"}
  if not channels.isNil and channels.kind == JObject:
    for chName, chCfg in channels:
      if not chCfg{"enabled"}.getBool(): continue
      lines.add("channel " & chName.escape() & ":")
      case chName
      of "feishu":
        let apps = chCfg{"apps"}
        if not apps.isNil:
          for app in apps:
            let appId = app{"app_id"}.getStr()
            if appId != "": lines.add("  app " & appId.escape())
        let rm = chCfg{"require_mention"}
        if not rm.isNil: lines.add("  requireMention " & $rm.getBool())
      of "telegram":
        let tok = chCfg{"token"}.getStr()
        if tok != "": lines.add("  token " & tok.escape())
      of "discord":
        let tok = chCfg{"token"}.getStr()
        if tok != "": lines.add("  token " & tok.escape())
      of "dingtalk":
        let cid = chCfg{"client_id"}.getStr()
        if cid != "": lines.add("  clientId " & cid.escape())
        let cs = chCfg{"client_secret"}.getStr()
        if cs != "": lines.add("  clientSecret " & cs.escape())
      of "qq":
        let aid = chCfg{"app_id"}.getStr()
        if aid != "": lines.add("  appId " & aid.escape())
        let asec = chCfg{"app_secret"}.getStr()
        if asec != "": lines.add("  appSecret " & asec.escape())
      of "whatsapp":
        let bu = chCfg{"bridge_url"}.getStr()
        if bu != "": lines.add("  bridgeUrl " & bu.escape())
      of "maixcam":
        let h = chCfg{"host"}.getStr()
        if h != "": lines.add("  host " & h.escape())
        let p = chCfg{"port"}.getInt()
        if p > 0: lines.add("  port " & $p)
      else: discard
      lines.add("")

  # Defaults
  let defs = config{"agents"}{"defaults"}
  if not defs.isNil:
    lines.add("defaults:")
    lines.add("  maxTokens " & $defs{"max_tokens"}.getInt(4096))
    lines.add("  temperature " & $defs{"temperature"}.getFloat(0.7))
    lines.add("  maxToolIterations " & $defs{"max_tool_iterations"}.getInt(20))
    lines.add("")

  # Security
  let sec = config{"agents"}{"security"}{"policies"}
  if not sec.isNil and sec.kind == JObject and sec.len > 0:
    lines.add("security:")
    for k, v in sec:
      lines.add("  policy " & k.escape() & ", " & v.getStr().escape())
    lines.add("")

  # Gateway
  let gw = config{"gateway"}
  if not gw.isNil:
    lines.add("gateway:")
    lines.add("  host " & gw{"host"}.getStr("0.0.0.0").escape())
    lines.add("  port " & $gw{"port"}.getInt(18790))
    lines.add("")

  # Tools
  let ws = config{"tools"}{"web"}{"search"}
  if not ws.isNil:
    let ak = ws{"api_key"}.getStr()
    if ak != "":
      lines.add("tools:")
      lines.add("  webSearchKey " & ak.escape())
      let wp = ws{"provider"}.getStr()
      if wp != "": lines.add("  webSearchProvider " & wp.escape())
      lines.add("")

  # Skills
  let skillsDir = dir / "skills"
  if dirExists(skillsDir):
    for kind, path in walkDir(skillsDir):
      if kind == pcDir:
        lines.add("skill " & path.lastPathPart().escape())

  lines.add("")
  lines.add("build()")
  return lines.join("\n")

proc showUsage(): string =
  return """Usage: nimclaw service <command>

Lifecycle:
  new [Name]              Create a new service
  run [Name]              Start the gateway
  stop [Name]             Stop the gateway
  restart [Name]          Restart the gateway
  status [Name]           Show service status
  deploy [Name]           Install as system daemon
  remove [Name]           Delete a service
  list                    Show all services
  use [Path]              Show/set active config directory
  export [Name]           Generate .nims from existing service

Per-service:
  [Name] onboard          Guided setup (provider, channel, agent)
  [Name] provider <cmd>   Manage providers (list, add, remove, health)
  [Name] channel <cmd>    Manage channels (list, add, remove)
  [Name] agent <cmd>      Manage agents (list, add, remove)
  [Name] plugin <cmd>     Manage plugins (list, add, remove)
  [Name] skill <cmd>      Manage skills (list, install, remove, show)
  [Name] auth <cmd>       Manage API keys (list, set, remove)

Examples:
  nimclaw service new MyCompany
  nimclaw service MyCompany onboard
  nimclaw service auth set BRAVE_API_KEY
  nimclaw service MyCompany provider add deepseek
  nimclaw service run MyCompany"""

proc runServiceCli*(args: seq[string], asJson: bool = false): ServiceResult =
  if args.len == 0:
    return (saOutput, showUsage())

  # Parse: lifecycle cmd or per-service cmd?
  if args[0].isLifecycleCmd():
    let cmd = args[0]
    let name = if args.len > 1 and not args[1].startsWith("-"): args[1] else: ""

    case cmd
    of "new":
      return (saOutput, serviceNew(name))
    of "run", "start":
      return serviceRun(name)
    of "stop":
      return serviceStop(name)
    of "restart":
      return serviceRestart(name)
    of "status":
      return (saOutput, serviceStatus(name, asJson))
    of "deploy":
      return (saOutput, serviceDeploy(name))
    of "remove":
      return (saOutput, serviceRemove(name))
    of "list":
      return (saOutput, serviceList(asJson))
    of "use":
      return (saOutput, serviceUse(name, asJson))
    of "export":
      return (saOutput, serviceExport(name))
    else:
      return (saOutput, "Unknown command: " & cmd)

  elif args[0].isConfigCmd():
    # No name — use default service
    let dir = setServiceEnv("")
    if dir == "":
      return (saOutput, "No default service found.\nRun: nimclaw service new")
    return dispatchConfigCmd("", args[0], if args.len > 1: args[1..^1] else: @[], asJson)

  else:
    # First arg is the service name
    let name = args[0]
    if args.len < 2:
      return (saOutput, serviceStatus(name, asJson))

    let cmd = args[1]
    if not cmd.isConfigCmd():
      return (saOutput, "Unknown command: " & cmd & "\n" & showUsage())

    let dir = setServiceEnv(name)
    if dir == "":
      return (saOutput, "Service '" & name & "' not found.\nRun: nimclaw service new " & name)
    return dispatchConfigCmd(name, cmd, if args.len > 2: args[2..^1] else: @[], asJson)
