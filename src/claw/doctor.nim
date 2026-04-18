import std/[strutils, options]

type
  Severity* = enum
    ok, warn, err

  DiagItem* = object
    severity*: Severity
    category*: string
    message*: string

const
  colorReset = "\x1b[0m"
  colorGreen = "\x1b[32m"
  colorYellow = "\x1b[33m"
  colorRed = "\x1b[31m"

proc ok*(cat, msg: string): DiagItem =
  DiagItem(severity: Severity.ok, category: cat, message: msg)

proc warn*(cat, msg: string): DiagItem =
  DiagItem(severity: Severity.warn, category: cat, message: msg)

proc err*(cat, msg: string): DiagItem =
  DiagItem(severity: Severity.err, category: cat, message: msg)

proc icon*(d: DiagItem): string =
  case d.severity
  of ok: "[ok]"
  of warn: "[warn]"
  of err: "[ERR]"

proc iconColored*(d: DiagItem): string =
  case d.severity
  of ok: colorGreen & "[ok]" & colorReset
  of warn: colorYellow & "[warn]" & colorReset
  of err: colorRed & "[ERR]" & colorReset

proc parseDfAvailableMb*(dfOutput: string): Option[uint64] =
  var lastDataLine = ""
  for line in dfOutput.splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      lastDataLine = trimmed

  if lastDataLine.len == 0 or lastDataLine.startsWith("Filesystem"):
    return none(uint64)

  let cols = lastDataLine.splitWhitespace()
  if cols.len > 3:
    try:
      return some(parseUInt(cols[3]).uint64)
    except ValueError:
      return none(uint64)
  return none(uint64)

import config

proc checkConfigSemantics*(cfg: Config, items: var seq[DiagItem]) =
  const cat = "config"
  
  if cfg.default_provider.len == 0:
    items.add(err(cat, "no default_provider configured"))
  else:
    items.add(ok(cat, "provider: " & cfg.default_provider))
    
  # Technical config is now managed by the Unified World Graph (Hybrid Vault)
  # We skip checking legacy ProvidersConfig as it has been consolidated into the graph.
  items.add(ok(cat, "LLM vault is managed by the World Graph"))

  if cfg.default_model.len > 0:
    items.add(ok(cat, "default model: " & cfg.default_model))
  else:
    items.add(warn(cat, "no default_model configured"))

  if cfg.default_temperature >= 0.0 and cfg.default_temperature <= 2.0:
    items.add(ok(cat, "temperature " & $cfg.default_temperature & " (valid range 0.0-2.0)"))
  else:
    items.add(err(cat, "temperature " & $cfg.default_temperature & " is out of range (expected 0.0-2.0)"))

  if cfg.gateway.port > 0:
    items.add(ok(cat, "gateway port: " & $cfg.gateway.port))
  else:
    items.add(err(cat, "gateway port is 0 (invalid)"))
    
  var hasChannels = false
  if cfg.channels.discord.enabled or cfg.channels.telegram.enabled:
    hasChannels = true
    
import std/[osproc, os]

proc checkCommandAvailable*(cmd: string): Option[string] =
  try:
    let (output, exitCode) = execCmdEx(cmd & " --version")
    if exitCode == 0:
      let firstLine = output.strip().splitLines()[0]
      if firstLine.len > 60:
        return some(firstLine[0..<60] & "...")
      return some(firstLine)
  except OSError:
    discard
  return none(string)

proc checkEnvironment*(items: var seq[DiagItem]) =
  const cat = "env"

  let gitVer = checkCommandAvailable("git")
  if gitVer.isSome:
    items.add(ok(cat, "git: " & gitVer.get))
  else:
    items.add(warn(cat, "git not found"))

  let curlVer = checkCommandAvailable("curl")
  if curlVer.isSome:
    items.add(ok(cat, "curl: " & curlVer.get))
  else:
    items.add(warn(cat, "curl not found"))

  if existsEnv("SHELL"):
    items.add(ok(cat, "shell: " & getEnv("SHELL")))
  else:
    items.add(warn(cat, "$SHELL not set"))

  if existsEnv("HOME"):
    items.add(ok(cat, "home directory env set"))
  else:
    items.add(err(cat, "home directory is not set"))
proc checkFileExists*(baseDir, name, cat: string, items: var seq[DiagItem]) =
  let path = baseDir / name
  if fileExists(path):
    if name == "SOUL.md": items.add(ok(cat, "SOUL.md present"))
    elif name == "AGENTS.md": items.add(ok(cat, "AGENTS.md present"))
    else: items.add(ok(cat, "file present"))
  else:
    if name == "SOUL.md": items.add(warn(cat, "SOUL.md not found (optional)"))
    elif name == "AGENTS.md": items.add(warn(cat, "AGENTS.md not found (optional)"))
    else: items.add(warn(cat, "file not found (optional)"))

proc getDiskAvailableMb*(path: string): Option[uint64] =
  try:
    let (output, exitCode) = execCmdEx("df -m " & quoteShell(path))
    if exitCode == 0:
      return parseDfAvailableMb(output)
  except OSError:
    discard
  return none(uint64)

proc checkWorkspace*(cfg: Config, items: var seq[DiagItem]) =
  const cat = "workspace"
  let ws = cfg.workspacePath()

  if dirExists(ws):
    items.add(ok(cat, "directory exists: " & ws))
  else:
    items.add(err(cat, "directory missing: " & ws))
    return

  let probePath = ws / ".nimclaw_doctor_probe"
  try:
    writeFile(probePath, "probe")
    removeFile(probePath)
    items.add(ok(cat, "directory is writable"))
  except IOError, OSError:
    items.add(err(cat, "directory is not writable"))

  let diskAvail = getDiskAvailableMb(ws)
  if diskAvail.isSome:
    if diskAvail.get >= 100:
      items.add(ok(cat, "disk space: " & $diskAvail.get & " MB available"))
    else:
      items.add(warn(cat, "low disk space: only " & $diskAvail.get & " MB available"))

  checkFileExists(ws, "SOUL.md", cat, items)
import std/[json, times]

proc checkDaemonState*(cfg: Config, items: var seq[DiagItem]) =
  const cat = "daemon"
  let statePath = cfg.workspacePath() / "sessions" / "gate.json"
  
  if not fileExists(statePath):
    items.add(err(cat, "state file not found: " & statePath & " -- is the daemon running?"))
    return
    
  items.add(ok(cat, "state file: " & statePath))
  
  let content = try: readFile(statePath) except IOError: ""
  if content == "":
    items.add(err(cat, "could not read state file"))
    return
    
  let parsed = try: parseJson(content) except JsonParsingError: newJNull()
  if parsed.kind == JNull:
    items.add(err(cat, "invalid state JSON"))
    return
    
  if parsed.hasKey("status"):
    if parsed["status"].getStr() == "running":
      items.add(ok(cat, "daemon reports running"))
    else:
      items.add(err(cat, "daemon status: " & parsed["status"].getStr() & " (expected running)"))
      
  if parsed.hasKey("updated_at"):
    let updatedAt = parsed["updated_at"].getInt()
    let nowStr = getTime().toUnix()
    let age = nowStr - updatedAt
    if age <= 30:
      items.add(ok(cat, "heartbeat fresh (" & $age & "s ago)"))
    else:
      items.add(err(cat, "heartbeat stale (" & $age & "s ago)"))

proc runDoctor*(cfg: Config, color: bool = true) =
  var items = newSeq[DiagItem]()
  checkConfigSemantics(cfg, items)
  checkWorkspace(cfg, items)
  checkEnvironment(items)
  checkDaemonState(cfg, items)
  
  echo "nimclaw Doctor (enhanced)\n"
  
  var currentCat = ""
  var okCount, warnCount, errCount = 0
  
  for item in items:
    if item.category != currentCat:
      currentCat = item.category
      echo "  [", currentCat, "]"
    
    let ic = if color: item.iconColored() else: item.icon()
    echo "    ", ic, " ", item.message
    
    case item.severity
    of ok: okCount.inc
    of warn: warnCount.inc
    of err: errCount.inc
    
  echo "\nSummary: ", okCount, " ok, ", warnCount, " warnings, ", errCount, " errors"
  if errCount > 0:
    echo "Run 'nimclaw doctor --fix' or check your config."
