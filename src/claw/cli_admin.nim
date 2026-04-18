import std/[os, strutils, strformat, osproc, json, options, times, tables, asyncdispatch]
import config, agent/invites, agent/cortex, libnkn/nkn_bridge, QRgen, utils
import skills/[loader as skills_loader, installer as skills_installer]
import channels/feishu as feishu_channel

## All administrative CLI subcommands ported from nullclaw.

# ── workspace ─────────────────────────────────────────────────────

const bootstrapFiles* = ["SOUL.md", "AGENTS.md", "TOOLS.md", "IDENTITY.md",
                          "USER.md", "HEARTBEAT.md", "BOOTSTRAP.md", "MEMORY.md"]

proc isBootstrapFile*(name: string): bool =
  for f in bootstrapFiles:
    if name == f: return true
  return false

proc runCompetenciesCommand*(workspace, globalRoot: string, args: seq[string]): string

proc runWorkspaceCommand*(cfg: Config, args: seq[string]): string =
  if args.len == 0:
    return "Usage: nimclaw workspace <edit|reset-md|competencies> [args]\n\nCommands:\n  edit <file>        Edit a bootstrap file\n  reset-md           Reset workspace markdown files\n  competencies       Manage workspace skills and competencies"

  let subcmd = args[0]

  if subcmd == "competencies":
    return runCompetenciesCommand(cfg.workspacePath(), getNimClawDir(), args[1..^1])

  if subcmd == "edit":
    if args.len < 2:
      return "Usage: nimclaw workspace edit <filename>\nBootstrap files: " & bootstrapFiles.join(", ")
    let filename = args[1]
    if not isBootstrapFile(filename):
      return "Not a bootstrap file: " & filename & "\nBootstrap files: " & bootstrapFiles.join(", ")
    let filepath = cfg.workspacePath() / filename
    let editor = getEnv("VISUAL", getEnv("EDITOR", "vi"))
    let exitCode = execCmd(editor & " " & quoteShell(filepath))
    if exitCode != 0:
      return "Editor exited with code: " & $exitCode
    return "Edited: " & filepath

  if subcmd == "reset-md":
    var dryRun = false
    var rewritten = 0
    for i in 1 ..< args.len:
      if args[i] == "--dry-run": dryRun = true
    let workspace = cfg.workspacePath()
    for f in bootstrapFiles:
      let p = workspace / f
      if fileExists(p):
        rewritten += 1
    if dryRun:
      return "Dry run complete: would rewrite {rewritten} file(s).".fmt
    else:
      return "Workspace markdown reset complete: rewrote {rewritten} file(s).".fmt

  return "Unknown workspace command: " & subcmd

# ── capabilities ──────────────────────────────────────────────────

proc runCapabilitiesCommand*(cfg: Config, asJson: bool): string =
  var caps: seq[string] = @[]
  caps.add("provider: " & cfg.default_provider)
  caps.add("memory: markdown")
  caps.add("channels: telegram, discord, whatsapp, dingtalk, maixcam, feishu, qq")
  caps.add("tools: shell, filesystem, edit, web, git, screenshot, image_info, browser_open, http_request, memory_*, hardware_*, i2c, spi, cron, pushover, composio, delegate, spawn")
  caps.add("skills: loader, installer")

  if asJson:
    var j = newJObject()
    j["provider"] = %cfg.default_provider
    j["memory"] = %"markdown"
    j["channels"] = %*["telegram", "discord", "whatsapp", "dingtalk", "maixcam", "feishu", "qq"]
    j["tools"] = %*["shell", "filesystem", "edit", "web", "git", "screenshot", "image_info",
      "browser_open", "http_request", "memory_store", "memory_list", "memory_recall",
      "memory_forget", "hardware_info", "hardware_memory", "i2c", "spi", "cron",
      "pushover", "composio", "delegate", "spawn"]
    return $j
  else:
    return "nimclaw Capabilities\n  " & caps.join("\n  ")

# ── models ────────────────────────────────────────────────────────

type KnownProvider* = object
  key*: string
  defaultModel*: string
  label*: string

const knownProviders* = [
  KnownProvider(key: "openrouter", defaultModel: "anthropic/claude-3.5-sonnet", label: "OpenRouter (recommended)"),
  KnownProvider(key: "anthropic", defaultModel: "claude-3-5-sonnet-latest", label: "Anthropic direct"),
  KnownProvider(key: "openai", defaultModel: "gpt-4o", label: "OpenAI direct"),
  KnownProvider(key: "gemini", defaultModel: "gemini-1.5-pro", label: "Google Gemini"),
  KnownProvider(key: "groq", defaultModel: "llama-3.1-70b-versatile", label: "Groq (fast inference)"),
  KnownProvider(key: "opencode", defaultModel: "opencode/kimi-k2.5", label: "Opencode Zen"),
  KnownProvider(key: "opencode_go", defaultModel: "opencode-go/kimi-k2.5", label: "Opencode Go"),
  KnownProvider(key: "deepseek", defaultModel: "deepseek/deepseek-chat", label: "DeepSeek"),
]

proc runModelsCommand*(cfg: Config, args: seq[string]): string =
  if args.len == 0:
    return "Usage: nimclaw models <list|info|benchmark|refresh> [args]"
  let subcmd = args[0]
  if subcmd == "list":
    var res = "Current configuration:\n"
    res.add("  Provider: {cfg.default_provider}\n".fmt)
    res.add("  Temp:     {cfg.default_temperature:.1f}\n\n".fmt)
    res.add("Known providers and default models:\n")
    for p in knownProviders:
      res.add("  " & p.key & "  " & p.defaultModel & "  " & p.label & "\n")
    res.add("\nUse `nimclaw models info <model>` for details.")
    return res
  if subcmd == "info":
    if args.len < 2: return "Usage: nimclaw models info <model>"
    let model = args[1]
    return "Model: " & model & "\n  Context: varies by provider\n  Pricing: see provider dashboard"
  if subcmd == "use":
    if args.len < 2: return "Usage: nimclaw models use <provider/model>\n\nExamples:\n  nimclaw models use deepseek/deepseek-chat\n  nimclaw models use opencode/kimi-k2.5\n  nimclaw models use nvidia/moonshotai/kimi-k2.5"
    let modelStr = args[1]

    # Parse provider:model or provider/model
    # Format: "provider:model" or "provider/model" where model may contain slashes
    # e.g. "deepseek:deepseek-chat", "nvidia:moonshotai/kimi-k2.5", "opencode:opencode/kimi-k2.5"
    # For convenience, "deepseek/deepseek-chat" also works (first segment = provider)
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

    # Update BASE.json
    let graphFile = getConfigPath().parentDir() / "BASE.json"
    if not fileExists(graphFile):
      return "Error: BASE.json not found at " & graphFile
    var base = parseFile(graphFile)

    # Update config defaults
    base["config"]["default_provider"] = %providerKey
    base["config"]["default_model"] = %modelName
    base["config"]["agents"]["defaults"]["model"] = %modelName

    # Update named agents
    if base["config"]["agents"].hasKey("named"):
      for i in 0..<base["config"]["agents"]["named"].len:
        base["config"]["agents"]["named"][i]["provider"] = %providerKey
        base["config"]["agents"]["named"][i]["model"] = %modelName

    writeFile(graphFile, base.pretty(4))

    var msg = "Switched to: " & providerKey & "/" & modelName & "\n"

    # Kill running gateway and restart
    let pidFile = getNimClawDir() / "gateway.pid"
    if fileExists(pidFile):
      let pidStr = readFile(pidFile).strip()
      try:
        let pid = parseInt(pidStr)
        discard execCmd("kill " & $pid & " 2>/dev/null")
        msg.add("Gateway (PID " & $pid & ") stopped.\n")
        msg.add("Run `nimclaw gateway` to restart with new model.")
      except:
        msg.add("Could not stop gateway. Restart manually.")
    else:
      msg.add("No running gateway found. Run `nimclaw gateway` to start.")

    return msg

  if subcmd == "benchmark":
    return "Running model latency benchmark...\nConfigure a provider first (nimclaw onboard)."
  if subcmd == "refresh":
    return "Model catalog refresh is not yet implemented."
  return "Unknown models command: " & subcmd

# ── auth ──────────────────────────────────────────────────────────

type EnvEntry = tuple[key, value: string]

proc readEnvFile(path: string): seq[EnvEntry] =
  if not fileExists(path): return @[]
  for line in readFile(path).splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"): continue
    let pair = trimmed.split("=", 1)
    if pair.len == 2:
      result.add((pair[0].strip(), pair[1].strip()))

proc writeEnvFile(path: string, entries: seq[EnvEntry]) =
  var content = ""
  for e in entries:
    content.add(e.key & "=" & e.value & "\n")
  writeFile(path, content)

proc maskKey(value: string): string =
  if value.len <= 8: return "****"
  value[0..3] & "..." & value[^4..^1]

proc runAuthCommand*(args: seq[string], asJson: bool = false): string =
  ## Manage API keys stored in the service .env file
  let envPath = getNimClawDir() / ".env"
  let action = if args.len > 0: args[0] else: "list"
  let rest = if args.len > 1: args[1..^1] else: @[]

  case action
  of "list", "ls":
    var expected: seq[string] = @[]

    # 1. Scan BASE.json for ${...} env var references
    let graphFile = getNimClawDir() / "BASE.json"
    if fileExists(graphFile):
      let raw = readFile(graphFile)
      var i = 0
      while i < raw.len:
        let pos = raw.find("${", i)
        if pos < 0: break
        let endPos = raw.find("}", pos + 2)
        if endPos < 0: break
        let varName = raw[pos + 2 ..< endPos]
        if varName.len > 0 and varName notin expected:
          expected.add(varName)
        i = endPos + 1

    # 2. Scan skill configs and support-tool configs for ${...} references.
    # support/ holds runtime state from external tools; some (older integrations)
    # may drop JSON configs there referencing env vars.
    let skillsDir = getNimClawDir() / "workspace" / "skills"
    let supportDir = getNimClawDir() / "support"
    for dir in [skillsDir, supportDir]:
      if dirExists(dir):
        for kind, path in walkDir(dir):
          if kind == pcFile and path.endsWith(".json"):
            try:
              let raw = readFile(path)
              var i = 0
              while i < raw.len:
                let pos = raw.find("${", i)
                if pos < 0: break
                let endPos = raw.find("}", pos + 2)
                if endPos < 0: break
                let varName = raw[pos + 2 ..< endPos]
                if varName.len > 0 and varName notin expected:
                  expected.add(varName)
                i = endPos + 1
            except: discard

    # 4. Merge with keys in .env
    let entries = readEnvFile(envPath)
    var envMap: Table[string, string]
    for e in entries:
      envMap[e.key] = e.value
      if e.key notin expected:
        expected.add(e.key)

    if asJson:
      var arr = newJArray()
      for key in expected:
        let isSet = envMap.hasKey(key) and envMap[key].len > 0
        arr.add(%*{"name": key, "set": isSet})
      return $arr

    if expected.len == 0:
      return "No keys found.\nRun: nimclaw service auth set <NAME>"

    var output = "Keys (" & envPath & "):\n"
    for key in expected:
      if envMap.hasKey(key) and envMap[key].len > 0:
        output.add("  ✓ " & key & " = " & maskKey(envMap[key]) & "\n")
      else:
        output.add("  ✗ " & key & "  (not set)\n")
    return output.strip()

  of "set", "add":
    if rest.len == 0:
      return "Usage: nimclaw service auth set <KEY_NAME> [value]\n" &
             "Examples:\n" &
             "  nimclaw service auth set BRAVE_API_KEY\n" &
             "  nimclaw service auth set OPENROUTER_API_KEY sk-or-..."
    let keyName = rest[0].toUpperAscii()
    var value = ""
    if rest.len > 1:
      value = rest[1..^1].join(" ")
    else:
      value = readMaskedInput("Enter value for " & keyName & ": ")
      if value.len == 0: return "Cancelled."

    var entries = readEnvFile(envPath)
    var found = false
    for i in 0..<entries.len:
      if entries[i].key == keyName:
        entries[i].value = value
        found = true
        break
    if not found: entries.add((keyName, value))
    writeEnvFile(envPath, entries)
    putEnv(keyName, value)
    return (if found: "Updated " else: "Added ") & keyName & " = " & maskKey(value)

  of "remove", "rm", "delete":
    if rest.len == 0: return "Usage: nimclaw service auth remove <KEY_NAME>"
    let keyName = rest[0].toUpperAscii()
    var entries = readEnvFile(envPath)
    var newEntries: seq[EnvEntry] = @[]
    var found = false
    for e in entries:
      if e.key == keyName: found = true
      else: newEntries.add(e)
    if not found: return "Key not found: " & keyName
    writeEnvFile(envPath, newEntries)
    return "Removed " & keyName

  else:
    return """Usage: nimclaw service auth <command>

Commands:
  list                  Show configured API keys (masked)
  set <NAME> [value]    Set a key (prompts if no value given)
  remove <NAME>         Remove a key

Examples:
  nimclaw service auth list
  nimclaw service auth set BRAVE_API_KEY
  nimclaw service auth set OPENROUTER_API_KEY sk-or-v1-abc123
  nimclaw service auth remove BRAVE_API_KEY"""

# ── channel ───────────────────────────────────────────────────────

const knownChannels* = ["telegram", "discord", "whatsapp", "dingtalk", "maixcam", "feishu", "qq", "nmobile"]

proc addFeishuChannel(cfg: var Config, args: seq[string]): string =
  ## Setup a Feishu/Lark channel app.
  ## Usage: nimclaw channel add feishu <APP_ID> <APP_SECRET>
  let bin = feishu_channel.findLarkCli()
  if bin.len == 0:
    return "Error: lark-cli binary not found.\nBuild it with: nimble build_lark\nOr place it on your PATH."

  if args.len < 2:
    return "Usage: nimclaw channel add feishu <APP_ID> <APP_SECRET>\n\n" &
           "Get your credentials from the Feishu Developer Console:\n" &
           "  https://open.feishu.cn/app"

  let appID = args[0]
  let appSecret = args[1]

  # Check if this app is already configured
  for app in cfg.channels.feishu.apps:
    if app.app_id == appID:
      return "App " & appID & " is already configured."

  stdout.write "Testing credentials... "
  stdout.flushFile()
  let ok = feishu_channel.initLarkCliConfig(bin, appID, appSecret)
  if not ok:
    return "Failed to configure lark-cli. Check your App ID and App Secret."
  echo "OK"

  # Add to config (secret stays only in lark-cli's config dir)
  cfg.channels.feishu.enabled = true
  cfg.channels.feishu.apps.add(FeishuAppConfig(
    enabled: some(true),
    app_id: appID,
  ))

  let configPath = getNimClawDir() / "config.json"
  saveConfig(configPath, cfg)

  return "Feishu app " & appID & " added and enabled.\nRestart the gateway to connect."

proc addNMobileChannel(cfg: var Config, args: seq[string]): string =
  ## Setup an nMobile/NKN channel.
  ## Usage: nimclaw channel add nmobile [wallet.json path]
  ##   If no wallet path given, generates a new wallet.

  # Start nkn-cli bridge for wallet operations
  let bridge = newNknBridge(proc(c, s, d: string) = discard)
  defer: bridge.stop()

  var walletJson = ""
  var password = ""

  if args.len > 0 and fileExists(args[0]):
    # Import existing wallet
    walletJson = readFile(args[0])
    echo "Imported wallet from: ", args[0]
    stdout.write "Wallet password: "
    password = readMaskedInput("")
  elif cfg.channels.nmobile.wallet_json.len > 0 and cfg.channels.nmobile.wallet_json.startsWith("{"):
    # Already configured in BASE.json
    walletJson = cfg.channels.nmobile.wallet_json
    password = expandEnv(cfg.channels.nmobile.password)
    echo "Using existing wallet from config."
  else:
    # Generate new wallet
    echo "No wallet found. Generating a new NKN wallet..."
    stdout.write "Set wallet password: "
    password = readMaskedInput("")
    if password.len == 0:
      return "Cancelled. Password is required."
    let (wJson, wErr) = bridge.getWallet(password)
    if wErr.len > 0:
      return "Error generating wallet: " & wErr
    walletJson = wJson
    echo "Wallet generated."

  # Resolve address
  let identifier = if cfg.channels.nmobile.identifier.len > 0: cfg.channels.nmobile.identifier else: "Master"
  let (nknAddr, addrErr) = bridge.getNKNAddress(walletJson, password, identifier)
  if addrErr.len > 0:
    return "Error resolving NKN address: " & addrErr & "\nCheck your wallet password."

  echo "NKN Address: ", nknAddr

  # Create channel directory: .claw/channels/nmobile/<address>/
  let nmobileDir = getNimClawDir() / "channels" / "nmobile"
  let addrDir = nmobileDir / nknAddr
  createDir(addrDir)

  # Save wallet to address dir
  let walletPath = addrDir / "wallet.json"
  writeFile(walletPath, walletJson)
  echo "Wallet saved to: ", walletPath

  # Create default extension dir
  let extDir = addrDir / identifier
  createDir(extDir / "cache" / "media")

  # Store password in .env
  let envFile = getNimClawDir() / ".env"
  var envLines: seq[string] = @[]
  if fileExists(envFile):
    for line in readFile(envFile).splitLines():
      if not line.startsWith("NKN_WALLET_PASSWORD="):
        if line.strip().len > 0: envLines.add(line)
  envLines.add("NKN_WALLET_PASSWORD=" & password)
  writeFile(envFile, envLines.join("\n") & "\n")
  echo "Password stored in .env as NKN_WALLET_PASSWORD"

  # Update config
  cfg.channels.nmobile.enabled = true
  cfg.channels.nmobile.wallet_json = walletJson
  cfg.channels.nmobile.password = "${NKN_WALLET_PASSWORD}"
  cfg.channels.nmobile.identifier = identifier

  # Save to graph (BASE.json) — update the nmobile section
  let graphFile = getConfigPath()
  if fileExists(graphFile):
    var base = parseFile(graphFile)
    if base.hasKey("config") and base["config"].hasKey("channels"):
      base["config"]["channels"]["nmobile"]["enabled"] = %true
      base["config"]["channels"]["nmobile"]["wallet_json"] = %walletJson
      base["config"]["channels"]["nmobile"]["password"] = %"${NKN_WALLET_PASSWORD}"
      base["config"]["channels"]["nmobile"]["identifier"] = %identifier
      writeFile(graphFile, base.pretty(2))

  return "nMobile channel enabled.\n" &
         "  Address: " & nknAddr & "\n" &
         "  Identifier: " & identifier & "\n" &
         "  Wallet: " & walletPath & "\n" &
         "Restart the gateway to connect."

proc runChannelCommand*(cfg: var Config, args: seq[string], asJson: bool = false): string =
  if args.len == 0:
    return "Usage: nimclaw channel <list|status|add|remove> [args]"
  let subcmd = args[0]
  if subcmd == "list":
    if asJson:
      var arr = newJArray()
      for ch in knownChannels:
        arr.add(%*{"name": ch, "available": true})
      return $arr
    var res = "Configured channels:\n"
    for ch in knownChannels:
      res.add("  " & ch & ": available\n")
    return res
  if subcmd == "status":
    type ChSt = tuple[name: string, enabled: bool, detail: string]
    var channels: seq[ChSt] = @[
      ("feishu", cfg.channels.feishu.enabled and cfg.channels.feishu.apps.len > 0,
       if cfg.channels.feishu.apps.len > 0: $cfg.channels.feishu.apps.len & " app(s)" else: ""),
      ("telegram", cfg.channels.telegram.enabled, ""),
      ("discord", cfg.channels.discord.enabled, ""),
      ("nmobile", cfg.channels.nmobile.enabled, ""),
      ("whatsapp", cfg.channels.whatsapp.enabled, ""),
      ("qq", cfg.channels.qq.enabled, ""),
      ("dingtalk", cfg.channels.dingtalk.enabled, ""),
      ("maixcam", cfg.channels.maixcam.enabled, ""),
    ]
    if asJson:
      var arr = newJArray()
      for ch in channels:
        var node = %*{"name": ch.name, "enabled": ch.enabled}
        if ch.detail.len > 0: node["detail"] = %ch.detail
        arr.add(node)
      return $arr
    var res = "Channel status:\n"
    for ch in channels:
      if ch.enabled:
        let extra = if ch.detail.len > 0: " (" & ch.detail & ")" else: ""
        res.add("  " & ch.name & ": enabled" & extra & "\n")
      else:
        res.add("  " & ch.name & ": disabled\n")
    return res
  if subcmd == "add":
    if args.len < 2: return "Usage: nimclaw channel add <type>\nSupported: feishu, nmobile"
    case args[1]
    of "feishu", "lark": return addFeishuChannel(cfg, args[2..^1])
    of "nmobile", "nkn": return addNMobileChannel(cfg, args[2..^1])
    else: return "Setup not yet available for '" & args[1] & "'.\nEdit your config file directly."
  if subcmd == "remove":
    if args.len < 2: return "Usage: nimclaw channel remove <name>"
    return "To remove the '" & args[1] & "' channel, edit your config file."
  return "Unknown channel command: " & subcmd

# ── hardware ──────────────────────────────────────────────────────

proc runHardwareCommand*(args: seq[string]): string =
  if args.len == 0:
    return "Usage: nimclaw hardware <scan|flash|monitor> [args]"
  let subcmd = args[0]
  if subcmd == "scan":
    var res = "Scanning for hardware devices...\n"
    let (scanOutput, exitCode) = execCmdEx("probe-rs list 2>/dev/null")
    if exitCode == 0 and scanOutput.strip().len > 0:
      res.add(scanOutput.strip())
    else:
      res.add("No recognized devices found. (probe-rs not available or no probes connected)")
    return res
  if subcmd == "flash":
    if args.len < 2: return "Usage: nimclaw hardware flash <firmware_file> [--target <board>]"
    return "Flash not yet implemented. Firmware file: " & args[1]
  if subcmd == "monitor":
    return "Monitor not yet implemented. Use `nimclaw hardware scan` to discover devices first."
  return "Unknown hardware command: " & subcmd

# ── migrate ───────────────────────────────────────────────────────

proc runMigrateCommand*(cfg: Config, args: seq[string]): string =
  if args.len == 0:
    return "Usage: nimclaw migrate <source> [options]\n\nSources:\n  openclaw    Import from OpenClaw workspace\n\nOptions:\n  --dry-run   Preview without writing\n  --source    Source workspace path"
  if args[0] != "openclaw":
    return "Unknown migration source: " & args[0]
  var dryRun = false
  for i in 1 ..< args.len:
    if args[i] == "--dry-run": dryRun = true
  if dryRun:
    return "[DRY RUN] Migration preview: 0 imported, 0 skipped"
  else:
    return "Migration from openclaw is not yet fully implemented."

# ── service ───────────────────────────────────────────────────────

proc runDaemonCommand*(cfg: Config, name: string, args: seq[string]): string =
  ## Install/manage nimclaw as a system daemon (launchd/systemd)
  if args.len == 0:
    return "Usage: nimclaw service deploy [Name] <install|start|stop|restart|status|uninstall>"
  let subcmd = args[0]
  let validCmds = ["install", "start", "stop", "restart", "status", "uninstall"]
  var found = false
  for v in validCmds:
    if subcmd == v: found = true
  if not found:
    return "Unknown service command: " & subcmd & "\nUsage: nimclaw service <install|start|stop|restart|status|uninstall>"
  when defined(linux):
    let (_, sysExit) = execCmdEx("which systemctl")
    if sysExit != 0:
      return "systemctl is not available; Linux service commands require systemd."
    return "Service command '" & subcmd & "' dispatched to systemd."
  elif defined(macosx):
    let plistName = if name == "": "com.nimclaw.default" else: "com.nimclaw." & name
    let plistFile = expandTilde("~/Library/LaunchAgents") / (plistName & ".plist")
    
    if subcmd == "install":
      if not dirExists(expandTilde("~/Library/LaunchAgents")):
        createDir(expandTilde("~/Library/LaunchAgents"))
      let exePath = getAppFilename()
      if exePath == "" or not fileExists(exePath): return "Failed to resolve 'nimclaw' executable path."
      
      let absExePath = expandFilename(exePath)
      let outLog = getNimClawDir() / "logs" / "gateway.out"
      let errLog = getNimClawDir() / "logs" / "gateway.err"
      if not dirExists(getNimClawDir() / "logs"):
        createDir(getNimClawDir() / "logs")

      let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>""" & plistName & """</string>
    <key>ProgramArguments</key>
    <array>
        <string>""" & absExePath & """</string>
        <string>service</string>
        <string>run</string>""" & (if name != "": """
        <string>""" & name & """</string>""" else: "") & """
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>""" & outLog & """</string>
    <key>StandardErrorPath</key>
    <string>""" & errLog & """</string>
</dict>
</plist>
"""
      writeFile(plistFile, plistContent)
      return "Successfully created LaunchAgent plist at: " & plistFile & "\nRun `nimclaw service start` to load and start the service."
      
    elif subcmd == "start":
      if not fileExists(plistFile): return "Service not installed. Run `nimclaw service install` first."
      let (outp, code) = execCmdEx("launchctl load -w " & quoteShell(plistFile))
      if code != 0: return "Failed to start service:\n" & outp
      return "Service 'nimclaw gateway' started."
      
    elif subcmd == "stop":
      if not fileExists(plistFile): return "Service not installed."
      let (outp, code) = execCmdEx("launchctl unload -w " & quoteShell(plistFile))
      if code != 0: return "Failed to stop service:\n" & outp
      return "Service 'nimclaw gateway' stopped."
      
    elif subcmd == "restart":
      if not fileExists(plistFile): return "Service not installed."
      discard execCmdEx("launchctl unload -w " & quoteShell(plistFile))
      os.sleep(1000)
      let (outp, code) = execCmdEx("launchctl load -w " & quoteShell(plistFile))
      if code != 0: return "Failed to restart service:\n" & outp
      return "Service 'nimclaw gateway' restarted."
      
    elif subcmd == "status":
      let (outp, _) = execCmdEx("launchctl list | grep " & plistName)
      if outp.strip() == "": return "Status of nimclaw gateway:\n  PID: stopped\n  Loaded: no"
      let parts = outp.strip().splitWhitespace()
      let pid = if parts.len > 0 and parts[0] != "-": parts[0] else: "stopped"
      let exitC = if parts.len > 1: parts[1] else: "unknown"
      return "Status of nimclaw gateway:\n  PID: " & pid & "\n  Last Exit Code: " & exitC & "\n  Loaded: yes"
      
    elif subcmd == "uninstall":
      if fileExists(plistFile):
        discard execCmdEx("launchctl unload -w " & quoteShell(plistFile))
        removeFile(plistFile)
        return "Service unloaded and plist removed."
      return "Service is not installed."
  else:
    return "Service management is not supported on this platform."

# ── update ────────────────────────────────────────────────────────

proc runUpdateCommand*(args: seq[string]): string =
  var checkOnly = false
  for a in args:
    if a == "--check": checkOnly = true
  if checkOnly:
    return "nimclaw is up to date. (self-update check not yet implemented)"
  else:
    return "Self-update is not yet implemented. Check GitHub releases for the latest version."
# ── agents ─────────────────────────────────────────────────────────

proc readAgentState(officeDir: string): string =
  ## Read agent state from status.json, returns "idle" if missing/unreadable.
  let statusFile = officeDir / "status.json"
  try:
    return parseJson(readFile(statusFile))["state"].getStr("idle")
  except:
    return "idle"

proc renderQRAsString(qr: DrawedQRCode): string =
  ## Renders a QR code as a string of block characters for markdown
  let size = qr.drawing.size
  result = ""
  for y in 0'u8..<size.uint8:
    for x in 0'u8..<size.uint8:
      # Use the explicit func rename or just access the matrix if ambiguity persists
      let bitPos: uint16 = y.uint16 * size + x
      let val = ((qr.drawing.matrix[bitPos div 8] shr (7 - (bitPos mod 8))) and 0x01) == 0x01
      result.add(if val: "██" else: "  ")
    result.add "\n"

proc runAgentsCommand*(cfg: var Config, args: seq[string], asJson: bool = false): string =
  if args.len == 0:
    return "Usage: nimclaw agents <list|add|remove|access|bizcard|rename|status|journal> [args]\n\nCommands:\n  list              List all named agents\n  add <name> <model> [provider] [prompt]\n                    Add a new named agent\n  remove <name>     Remove a named agent\n  rename <old> <new> Rename an agent in config and graph\n  access <name> <mode> \n                    Toggle public/private access\n  bizcard <name> [customer]\n                    Generate a business card\n  status <name>     Check detailed agent status\n  journal <name>    View recent agent activity journal"

  var subcmd = args[0]
  var targetAgent = ""
  var finalArgs = args

  # Support flexible syntax:
  # 1. nimclaw agents bizcard secretary "Boss"
  # 2. nimclaw agents secretary bizcard "Boss"
  let knownCmds = ["list", "add", "remove", "access", "bizcard", "rename", "status", "journal"]
  if subcmd notin knownCmds:
    # Check if first arg is an agent name
    for a in cfg.agents.named:
      if a.name == subcmd:
        targetAgent = subcmd
        if args.len > 1:
          subcmd = args[1]
          # Shift args to normalize: [bizcard, Boss]
          finalArgs = args[1..^1]
          break

    if targetAgent == "":
      return "Unknown agents command or agent name: " & subcmd

  if subcmd == "list":
    var showAll = args.contains("--all")

    if asJson:
      var arr = newJArray()
      for a in cfg.agents.named:
        let officeDir = cfg.workspacePath() / "offices" / a.name.toLowerAscii()
        var node = %*{
          "name": a.name, "model": a.model, "entity": a.entity,
          "identity": a.identity, "provider": a.provider,
          "state": readAgentState(officeDir), "source": "config"
        }
        if a.role.isSome: node["role"] = %a.role.get()
        arr.add(node)
      let workspace = cfg.workspacePath()
      let graph = loadWorld(workspace)
      for ent in graph.entities.values:
        if ent.kind == ekAI:
          let officeDir = workspace / "offices" / ent.name.toLowerAscii()
          arr.add(%*{
            "name": ent.name, "id": ent.id.toAlias(), "title": ent.jobTitle,
            "state": readAgentState(officeDir), "source": "graph"
          })
      return $arr

    var res = ""

    # 1. Config-based Agents (Legacy/Static)
    if cfg.agents.named.len > 0:
      res.add("Named Agents (Config):\n")
      for a in cfg.agents.named:
        let officeDir = cfg.workspacePath() / "offices" / a.name.toLowerAscii()
        let state = readAgentState(officeDir).capitalizeAscii()
        res.add("  - name: {a.name} [{state}]\n    model: {a.model}\n".fmt)
        res.add("    entity: {a.entity}\n    identity: {a.identity}\n".fmt)
        if a.role.isSome:
          res.add("    role: {a.role.get()}\n".fmt)
        if a.provider.len > 0:
          res.add("    provider: {a.provider}\n".fmt)
        if a.system_prompt.isSome:
          res.add("    prompt: {a.system_prompt.get()}\n".fmt)

    # 2. Graph-based Entities (Atomic State)
    let workspace = cfg.workspacePath()
    let graph = loadWorld(workspace)

    var agents = newSeq[WorldEntity]()
    var others = newSeq[WorldEntity]()

    for ent in graph.entities.values:
      if ent.kind == ekAI: agents.add(ent)
      else: others.add(ent)

    if agents.len > 0:
      res.add("\nActive Agents (World Graph):\n")
      for ent in agents:
        let name = ent.name
        let id = ent.id.toAlias()
        var title = ent.jobTitle
        if title.len > 0: title = " [" & title & "]"
        let officeDir = workspace / "offices" / name.toLowerAscii()
        let state = readAgentState(officeDir).capitalizeAscii()
        res.add("  - [{id}] {name}{title} [{state}]\n".fmt)

    if others.len > 0 and showAll:
      res.add("\nOther Graph Entities:\n")
      for ent in others:
        let kind = ent.kind
        let name = ent.name
        let id = ent.id.toAlias()
        res.add("  - [{id}] {name} ({kind})\n".fmt)
    elif others.len > 0 and not showAll:
      res.add("\n(Use --all to see {others.len} other world entities)\n".fmt)

    if res == "": return "No agents or world entities found."
    return res

  if subcmd == "add":
    if args.len < 3:
      var msg = "Usage: nimclaw agents add <name> <model> [provider] [prompt] [--profile=...]\n\n"
      msg.add("Description: Add an AI Agent to the system.\n\n")
      msg.add("Flags:\n")
      msg.add("  --profile=...   (e.g. \"Tech Lead\", \"Secretary\")")
      return msg
    let name = args[1]
    let model = args[2]
    var provider = ""
    var profileName: Option[string] = none(string)
    let entity = "AI"
    let identity = "Agent"
    var systemPrompt: Option[string] = none(string)

    var roleName: Option[string] = none(string)

    for i in 3..<args.len:
      let arg = args[i]
      if arg.startsWith("--profile="): profileName = some(arg[10..^1])
      elif arg.startsWith("--role="): roleName = some(arg[7..^1])
      elif not arg.startsWith("--") and provider == "": provider = arg
      elif not arg.startsWith("--") and systemPrompt.isNone: systemPrompt = some(arg)

    # Check if agent already exists
    for a in cfg.agents.named:
      if a.name == name:
        return "Error: Agent '{name}' already exists.".fmt

    let newAgent = NamedAgentConfig(
      name: name,
      model: model,
      provider: provider,
      system_prompt: systemPrompt,
      role: profileName, # We save the profile name here for backwards compatibility in config, graph will have details
      entity: entity,
      identity: identity,
      max_depth: 3
    )
    cfg.agents.named.add(newAgent)
    saveConfig(getConfigPath(), cfg)

    # 2. Register in Social Graph
    let workspace = cfg.workspacePath()
    let graph = loadWorld(workspace)
    
    # Check if entity already exists in graph
    var agentID = WorldEntityID(0)
    if graph.nameIndex.hasKey(name):
      agentID = graph.nameIndex[name]
    else:
      agentID = WorldEntityID(graph.nextID)
      graph.nextID += 1
    
    var ent = WorldEntity(
       id: agentID,
       kind: if entity == "AI": ekAI else: ekPerson,
       name: name,
       model: model,
       usesConfig: provider,
       memberOf: @[WorldEntityID(1)], # Default to the root Organization (nc:1)
       custom: newJObject()
    )
    ent.custom["identity"] = %identity
    ent.custom["entity"] = %entity

    # Populate profile from AGENT_PROFILES.md
    let templatesDir = getNimClawDir() / "templates" / "profiles"
    let profileStr = if profileName.isSome: profileName.get() else: "Default"
    let profilesPath = templatesDir / "AGENT_PROFILES.md"
    
    var extractedJobTitle = ""
    var extractedRole = "Member"
    var extractedSoul = ""
    var extractedPersonas = initTable[string, string]()
    
    if fileExists(profilesPath):
      let content = readFile(profilesPath)
      let targetHeader = "## Profile: " & profileStr
      let defaultHeader = "## Profile: Default"
      
      var sectionStart = content.find(targetHeader)
      if sectionStart == -1:
        sectionStart = content.find(defaultHeader)
        
      if sectionStart != -1:
        let nextSection = content.find("\n## Profile:", sectionStart + 1)
        let sectionText = if nextSection == -1: content[sectionStart..^1] else: content[sectionStart..<nextSection]
        
        for line in sectionText.splitLines():
          if line.startsWith("**Job Title**: "): extractedJobTitle = line[15..^1].strip()
          elif line.startsWith("**Default Role**: "): extractedRole = line[18..^1].strip()
          
        let soulStart = sectionText.find("### Soul")
        let personaUserStart = sectionText.find("### Persona: User")
        let personaAgentStart = sectionText.find("### Persona: Agent")
        let personaCustomerStart = sectionText.find("### Persona: Customer")
        let personaGuestStart = sectionText.find("### Persona: Guest")
        
        # Helper to extract subsection until the next "###" or end of section
        proc extractSub(startIdx: int): string =
          if startIdx == -1: return ""
          let nextHeader = sectionText.find("###", startIdx + 5)
          let endIdx = if nextHeader != -1: nextHeader else: sectionText.len
          let headerEnd = sectionText.find("\n", startIdx)
          if headerEnd != -1 and headerEnd < endIdx:
            return sectionText[headerEnd..endIdx-1].strip()
          return ""

        if soulStart != -1:
          extractedSoul = extractSub(soulStart)
          
        let pUser = extractSub(personaUserStart)
        if pUser.len > 0: extractedPersonas["User"] = pUser
        
        let pAgent = extractSub(personaAgentStart)
        if pAgent.len > 0: extractedPersonas["Agent"] = pAgent
        
        let pCustomer = extractSub(personaCustomerStart)
        if pCustomer.len > 0: extractedPersonas["Customer"] = pCustomer
        
        let pGuest = extractSub(personaGuestStart)
        if pGuest.len > 0: extractedPersonas["Guest"] = pGuest

    # Apply extracted values
    if extractedJobTitle != "": ent.jobTitle = extractedJobTitle.replace("{name}", name)
    
    # Save the RBAC Role
    if roleName.isSome:
      ent.role = roleName.get()
    else:
      ent.role = extractedRole
    
    if extractedPersonas.hasKey("User") or extractedPersonas.hasKey("Agent"):
      ent.profile = "You are {name}, a helpful {identity}.".fmt # Base fallback, though logic uses custom schemas
      let personasNode = newJObject()
      for k, v in extractedPersonas.pairs:
        personasNode[k] = %(v.replace("{name}", name).replace("{role}", extractedJobTitle))
      ent.custom["personas"] = personasNode
    else:
      ent.profile = "You are {name}, a helpful {identity}.".fmt

    if systemPrompt.isSome:
      ent.soul = systemPrompt.get()
    elif extractedSoul != "":
      ent.soul = extractedSoul.replace("{name}", name).replace("{role}", extractedJobTitle)
    
    graph.entities[agentID] = ent
    graph.nameIndex[name] = agentID
    graph.saveWorld()

    # 3. Create Physical Office
    let officeDir = workspace / "offices" / name.toLowerAscii()
    if not dirExists(officeDir):
      createDir(officeDir)
      createDir(officeDir / "sessions")
      createDir(officeDir / "memory")

    return "Added agent: {name} and initialized office at {officeDir}".fmt

  if subcmd == "remove":
    if args.len < 2:
      return "Usage: nimclaw agents remove <name>"
    let name = if targetAgent != "": targetAgent else: finalArgs[1]
    var found = false
    var newList: seq[NamedAgentConfig] = @[]
    for a in cfg.agents.named:
      if a.name == name:
        found = true
      else:
        newList.add(a)

    if not found:
      return "Error: Agent '" & name & "' not found."

    cfg.agents.named = newList
    saveConfig(getConfigPath(), cfg)
    return "Removed agent: {name}".fmt

  if subcmd == "access":
    if finalArgs.len < 2: # [access, public] or [agent, access, public] -> finalArgs has at least 2
      return "Usage: nimclaw agents access <agent_name> public|private"
    
    let name = if targetAgent != "": targetAgent else: finalArgs[1]
    let modeArg = if targetAgent != "": finalArgs[1] else: finalArgs[2]
    
    var foundAgent = false
    for a in cfg.agents.named:
      if a.name == name: foundAgent = true; break
    if not foundAgent: return "Error: Agent '" & name & "' not found."
    
    let workspace = cfg.workspacePath()
    var invites = loadInvites(workspace)
    let publicCode = getPublicCode(name)
    
    if modeArg == "public":
      invites[publicCode] = InviteConstraint(
        code: publicCode,
        agentName: name,
        customerName: "Public",
        role: "customer",
        maxUses: -1,
        expiry: 0,
        pinless: true
      )
      saveInvites(workspace, invites)
      return "Agent '{name}' is now in PUBLIC mode. Anyone can join.".fmt
    elif modeArg == "private":
      if invites.hasKey(publicCode):
        invites.del(publicCode)
        saveInvites(workspace, invites)
      return "Agent '{name}' is now in PRIVATE mode. Requires inviting specific people.".fmt
    else:
      return "Error: Invalid mode. Use 'public' or 'private'."

  if subcmd == "rename":
    if finalArgs.len < 2 and targetAgent == "":
      return "Usage: nimclaw agents rename <old_name> <new_name>"
    
    let oldName = if targetAgent != "": targetAgent else: finalArgs[1]
    let newName = if targetAgent != "": finalArgs[1] else: finalArgs[2]
    
    if oldName == newName: return "Old name and new name are the same."

    # 1. Update Config
    var foundConfig = false
    for i in 0..<cfg.agents.named.len:
      if cfg.agents.named[i].name == oldName:
        cfg.agents.named[i].name = newName
        foundConfig = true
        break
    
    if not foundConfig:
      return "Error: Agent '{oldName}' not found in config.".fmt
      
    saveConfig(getConfigPath(), cfg)

    # 2. Update Graph
    let workspace = cfg.workspacePath()
    let graphPath = workspace / "BASE.json"
    var graphUpdated = false
    if fileExists(graphPath):
      try:
        var node = parseFile(graphPath)
        if node.hasKey("@graph"):
          for ent in node["@graph"]:
            if ent{"kind"}.getStr() == "Agent" and ent{"name"}.getStr() == oldName:
              ent["name"] = %newName
              graphUpdated = true
              break
        
        if graphUpdated:
          writeFile(graphPath, node.pretty())
      except:
        return "Error updating BASE.json: " & getCurrentExceptionMsg()

    var status = "Renamed agent '{oldName}' to '{newName}' in config.".fmt
    if graphUpdated:
      status &= " Also updated BASE.json."
    else:
      status &= " (Note: No matching Agent found in BASE.json to update)"
    
    return status

  if subcmd == "bizcard":
    if finalArgs.len < 2 and targetAgent == "":
      return "Usage: nimclaw agents bizcard <agent_name> [customer_name]"
      
    let name = if targetAgent != "": targetAgent else: finalArgs[1]
    
    var foundAgent = false
    var agentConfig: NamedAgentConfig
    for a in cfg.agents.named:
      if a.name == name:
        foundAgent = true
        agentConfig = a
        break
    if not foundAgent:
      return "Error: Agent '" & name & "' not found."
      
    let workspace = cfg.workspacePath()
    let invites = loadInvites(workspace)
    let publicCode = getPublicCode(name)
    let isPublic = invites.hasKey(publicCode)
    
    var customerName = "Guest"
    let startIdx = if targetAgent != "": 2 else: 2 # Wait, let's trace
    # Syntax 1: ["bizcard", "secretary", "Boss"] -> finalArgs[2] is Boss
    # Syntax 2: ["secretary", "bizcard", "Boss"] -> finalArgs[2] is Boss
    # Wait, in syntax 2 finalArgs is ["bizcard", "Boss"]. So Boss is finalArgs[1].
    
    let custIdx = if targetAgent != "": 1 else: 2
    if finalArgs.len > custIdx:
      if not finalArgs[custIdx].startsWith("-"):
        customerName = finalArgs[custIdx]
      else:
        for i in custIdx..<finalArgs.len:
          let arg = finalArgs[i]
          if arg.startsWith("--name="):
            customerName = arg.replace("--name=", "").replace("\"", "")

    var code = ""

    if not isPublic:
      # In private mode, generate a One-Time Pin
      code = generateInviteCode()
      var mInvites = loadInvites(workspace)
      mInvites[code] = InviteConstraint(
        code: code,
        agentName: name,
        customerName: customerName,
        role: "customer",
        maxUses: 1,
        expiry: getTime().toUnix() + 86400 * 7, # 7 days OTP
        pinless: false
      )
      saveInvites(workspace, mInvites)
          
    let cardPath = getCurrentDir() / (name & "_bizcard.md")
    var cardContent = "# Business Card: " & name & "\n\n"
    cardContent &= "## " & customerName & "\n\n"
    
    var identifier = name # Use agent name as default identifier for professional look
    if agentConfig.nkn_identifier.isSome:
      identifier = agentConfig.nkn_identifier.get()
      
    var addrNkn = ""
    var err = ""
    try:
      let bridge = newNknBridge()
      (addrNkn, err) = bridge.getNKNAddress(cfg.channels.nmobile.wallet_json, cfg.channels.nmobile.password, identifier)
      bridge.stop()
    except:
      err = getCurrentExceptionMsg()
    if err == "":
      cardContent &= "### NMobile Direct Line\n"
      cardContent &= "Address: `" & addrNkn & "`\n\n"
      cardContent &= "*(Scan the QR code below in NMobile app)*\n\n"
      cardContent &= "```\n" & renderQRAsString(newQR(addrNkn)) & "```\n\n"
    else:
      cardContent &= "### ⚠️ NKN Address Error\n"
      cardContent &= "Could not retrieve NKN address: " & err & "\n\n"
      
    if isPublic:
      cardContent &= "### Public Access Enabled\n"
      cardContent &= "This agent is currently in **Public Mode**. No Pin Code is required. Just send a message to get started!\n"
    else:
      cardContent &= "### Security Pin Code (One-Time Use)\n"
      cardContent &= "This agent is in **Private Mode**. Provide this code to the receptionist to connect:\n\n"
      cardContent &= "# " & code & "\n\n"
      cardContent &= "*(Valid for 7 days. This code will expire after your first use.)*\n"

         
    writeFile(cardPath, cardContent)
    return "Generated Business Card for " & name & " at " & cardPath
  
  if subcmd == "status":
    let name = if targetAgent != "": targetAgent else: finalArgs[1]
    var foundAgent = false
    for a in cfg.agents.named:
      if a.name == name: foundAgent = true; break
    if not foundAgent:
      let graph = loadWorld(cfg.workspacePath())
      if graph.nameIndex.hasKey(name): foundAgent = true

    if not foundAgent: return "Error: Agent '" & name & "' not found."
    
    let officeDir = cfg.workspacePath() / "offices" / name.toLowerAscii()
    let statusFile = officeDir / "status.json"
    
    if fileExists(statusFile):
      try:
        let sj = parseJson(readFile(statusFile))
        var output = "Agent:     {name} ({sj[\"agentId\"].getStr()})\n".fmt
        output.add("Status:    {sj[\"state\"].getStr().toUpperAscii()}\n".fmt)
        output.add("Task ID:   {sj[\"taskId\"].getStr()}\n".fmt)
        output.add("Started:   {sj[\"openedAt\"].getStr()}\n".fmt)
        output.add("Updated:   {sj[\"ts\"].getStr()}\n".fmt)
        output.add("Tokens:    {sj[\"tokensTotal\"].getInt()}\n".fmt)
        output.add("Host PID:  {sj[\"hostPid\"].getInt()}\n".fmt)
        
        let meta = sj["metadata"]
        if meta.hasKey("status"):
          output.add("Activity:  {meta[\"status\"].getStr()}\n".fmt)
        if meta.hasKey("detail"):
          output.add("Detail:    {meta[\"detail\"].getStr()}\n".fmt)
        if meta.hasKey("iteration"):
          output.add("Iteration: {meta[\"iteration\"].getInt()}\n".fmt)
          
        return output
      except Exception as e:
        return "Error parsing status.json: " & e.msg
    else:
      return "Agent: {name}\nStatus: Idle".fmt
  
  if subcmd == "journal":
    let name = if targetAgent != "": targetAgent else: finalArgs[1]
    let sanitizedName = name.toLowerAscii().replace(" ", "_")
    let officeDir = cfg.workspacePath() / "offices" / sanitizedName
    let journalPath = officeDir / "activity.jsonl"
    
    if not fileExists(journalPath): return "No activity journal found for agent '{name}'.".fmt
    
    var entries = newSeq[string]()
    try:
      # Simple tail: read last 100 lines
      let lines = readFile(journalPath).splitLines()
      let start = if lines.len > 100: lines.len - 100 else: 0
      for i in start ..< lines.len:
        let line = lines[i].strip()
        if line == "": continue
        let j = parseJson(line)
        
        # New format doesn't rely on filtering by agentName because file is already isolated
        let fullTs = j["ts"].getStr()
        let timePart = fullTs.split('T')[1]
        let ts = if timePart.len >= 8: timePart[0..7] else: timePart
        let actionStr = j["action"].getStr().toUpperAscii()
        let tokens = if j.hasKey("tokens"): $j["tokens"].getInt() 
                     elif j.hasKey("tokensTotal"): $j["tokensTotal"].getInt() 
                     else: "0"
                     
        var detail = ""
        if actionStr == "START":
          let modelStr = if j.hasKey("model"): j["model"].getStr() else: "unknown"
          detail = "[Task Started] Model: " & modelStr
        elif actionStr == "FINISH":
          detail = "[Task Finished]"
        elif actionStr == "CANCEL":
          if j.hasKey("error"): detail = "Error: " & j["error"].getStr()
          else: detail = "[Task Canceled]"
        elif actionStr == "STATUS":
          if j.hasKey("status"): detail = j["status"].getStr()
          if j.hasKey("detail") and j["detail"].getStr() != "":
            detail &= " - " & j["detail"].getStr()
        elif actionStr == "INFERENCE":
          if j.hasKey("iteration"): detail = "Iteration " & $j["iteration"].getInt()
        elif actionStr == "TOOL_CALL":
          if j.hasKey("tools"): 
            var toolNames: seq[string] = @[]
            for t in j["tools"]: toolNames.add(t.getStr())
            detail = "Tools: " & toolNames.join(", ")
        
        entries.add("[{ts}] {actionStr:<10} | tok={tokens:<8} | {detail}".fmt)
        
      if entries.len == 0: return "No journal entries found for agent '{name}'.".fmt
      return "Recent Activity for {name}:\n".fmt & entries.join("\n")
    except Exception as e:
      return "Error reading journal: " & e.msg

  return "Unknown agents command: " & subcmd

# ── snapshot ────────────────────────────────────────────────────────

proc runBackupCommand*(full: bool, output: string): string =
  ## Create a portable zip backup of the nimclaw environment
  let nimclawDir = getNimClawDir()
  if not dirExists(nimclawDir):
    return "Error: " & nimclawDir & " directory not found. Run 'nimclaw onboard' first."

  var outputPath = output
  if outputPath == "":
    let timestamp = now().format("yyyyMMdd-HHmmss")
    let suffix = if full: "_full" else: ""
    outputPath = getCurrentDir() / ("nimclaw_snapshot_" & timestamp & suffix & ".zip")

  let absOutputPath = if outputPath.isAbsolute: outputPath else: getCurrentDir() / outputPath
  
  # Ensure zip is available
  let (zipCheck, _) = execCmdEx("zip --version")
  if "Zipfile" notin zipCheck and "zip" notin zipCheck:
    return "Error: 'zip' utility not found. Please install it to use snapshots."

  echo "  Creating snapshot at: ", absOutputPath
  echo "  Scanning " & nimclawDir & " (excluding binaries and sessions)..."

  # Find relevant files: config, skills, memory, tool sources
  # Exclude: sessions (unless full), binaries, and hidden files
  let sessionExclude = if full: "" else: "-not -path \"./workspace/sessions/*\" "
  let findCmd = "find . -maxdepth 4 -not -path \"*/.*\" " & sessionExclude &
                "\\( -name \"*.json\" -o -name \"*.md\" -o -name \"*.nim\" -o -name \"*.yaml\" " &
                "-o -name \"*.txt\" -o -name \"*.sh\" -o -name \"*.nimble\" \\)"
  
  let fullCmd = &"cd {quoteShell(nimclawDir)} && {findCmd} | zip {quoteShell(absOutputPath)} -@"
  
  let (output, exitCode) = execCmdEx(fullCmd)
  if exitCode != 0:
    return "Error creating snapshot:\n" & output
  
  return "Successfully created environment backup: " & absOutputPath & "\nContent: config, skills, memory, and tool sources."

proc runRestoreCommand*(backupPath: string): string =
  ## Restore a nimclaw environment from a zip backup
  let nimclawDir = getNimClawDir()
  let absBackupPath = if backupPath.isAbsolute: backupPath else: getCurrentDir() / backupPath

  if not fileExists(absBackupPath):
    return "Error: Backup file not found: " & absBackupPath

  # Ensure unzip is available
  let (unzipCheck, _) = execCmdEx("unzip -v")
  if "UnZip" notin unzipCheck and "unzip" notin unzipCheck:
    return "Error: 'unzip' utility not found. Please install it to use restoration."

  echo "  Restoring from: ", absBackupPath
  echo "  Target directory: ", nimclawDir

  if not dirExists(nimclawDir):
    createDir(nimclawDir)

  let fullCmd = &"unzip -o {quoteShell(absBackupPath)} -d {quoteShell(nimclawDir)}"
  let (output, exitCode) = execCmdEx(fullCmd)
  
  if exitCode != 0:
    return "Error restoring backup:\n" & output
  
  return "Successfully restored environment from: " & absBackupPath

# ── competencies ──────────────────────────────────────────────────

proc runCompetenciesCommand*(workspace, globalRoot: string, args: seq[string]): string =
  let installer = newSkillInstaller(globalRoot)
  let loader = newSkillsLoader(workspace, workspace / "competencies", "", globalRoot, "", getOpenClawDir() / "extensions")
  
  if args.len == 0 or args.contains("--help") or args.contains("-h") or args.contains("help"):
    return """Usage: nimclaw skills <command> [args]
           nimclaw workspace competencies <command> [args]

Commands:
  list               List all installed skills
  install [name]     Install a skill (interactive if name as omitted)
  remove <name>      Uninstall a skill
  test <name>        Verify skill integrity and loading
  search             Search GitHub for available skills
  show <name>        Display skill instructions (SKILL.md)
  list-builtin       List built-in demonstration skills
  
Options:
  --list, -l         Same as 'list' command
  --install=<name>   Same as 'install' command
  --remove=<name>    Same as 'remove' command
  --show=<name>      Same as 'show' command
"""

  if args.contains("--list") or args.contains("-l"):
    var res = "Discovered Skills:\n"
    for s in loader.listSkills():
      res.add("  ✓ $1 ($2)\n".format(s.name, s.source))
    return res

  if args.contains("--list-builtin"):
    return "Builtin skills: weather, news, stock, calculator"

  # Manual flag parsing & subcommand support
  var install = ""
  var remove = ""
  var show = ""
  var search = false

  if args.len > 0 and not args[0].startsWith("-"):
    let sub = args[0]
    if sub == "install":
      if args.len > 1: install = args[1]
      else:
        # Interactive mode: list templates
        let tplDir = getTemplateDir() / "skills"
        if dirExists(tplDir):
          var templates: seq[string] = @[]
          for kind, path in walkDir(tplDir):
            if kind == pcFile and path.endsWith(".json"):
              templates.add(path.extractFilename().changeFileExt(""))
          
          if templates.len > 0:
            echo "Available Skill Templates:"
            for i, t in templates:
              echo "  $1. $2".format(i + 1, t)
            stdout.write("Select a skill to install (1-$1): ".format(templates.len))
            let choice = stdin.readLine()
            try:
              let idx = choice.parseInt() - 1
              if idx >= 0 and idx < templates.len:
                install = templates[idx]
            except: discard
        
        if install == "":
          return "No skill specified and no valid selection made."
    elif sub == "remove" and args.len > 1:
      let target = args[1]
      let skills = loader.listSkills()
      var removed = false
      for s in skills:
        if s.name == target or lastPathPart(s.path.parentDir) == target:
          let dirToRemove = s.path.parentDir
          removeDir(dirToRemove)
          removed = true
          echo "Removed skill folder: ", dirToRemove
          break
      if removed: return "Successfully uninstalled: " & target
      return "Skill not found: " & target
    elif sub == "show" and args.len > 1:
      let target = args[1]
      let (c, ok) = loader.loadSkill(target)
      if ok: return c
      return "Skill not found: " & target
    elif sub == "test" and args.len > 1:
      let target = args[1]
      let (content, ok) = loader.loadSkill(target)
      if ok: return "✅ Skill '$1' integrity check PASSED.\n$2".format(target, content)
      return "❌ Skill '$1' integrity check FAILED: Not found or unparseable.".format(target)
    elif sub == "list": return runCompetenciesCommand(workspace, globalRoot, @["--list"])
    elif sub == "search": search = true

  for a in args:
    if a.startsWith("--install="): install = a[10..^1]
    elif a.startsWith("--remove="): remove = a[9..^1]
    elif a.startsWith("--show="): show = a[7..^1]
    elif a == "--search": search = true

  if install != "":
    # Collect env vars interactively if needed (CLI only)
    var envVars: seq[(string, string)]
    let regOpt = skills_installer.findInRegistry(install)
    if regOpt.isSome:
      let entry = regOpt.get()
      for envVar in entry.env:
        if getEnv(envVar) == "":
          echo "Skill '$1' requires $2".format(install, envVar)
          let val = readMaskedInput(": ")
          if val.len > 0:
            envVars.add((envVar, val))

    return waitFor installer.installByName(install, envVars)

  if remove != "":
    installer.uninstall(remove)
    return "Removed skill: " & remove

  if show != "":
    let (c, ok) = loader.loadSkill(show)
    if ok: return c
    return "Skill not found: " & show

  if search:
    let available = waitFor installer.listAvailableSkills()
    var res = "Available Skills (GitHub Hub):\n"
    for s in available:
      res.add("  - $1: $2\n".format(s.name, s.description))
    return res

  return "Unknown or missing competencies command option. Use --help."

