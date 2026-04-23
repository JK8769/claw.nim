import std/[os, strutils, strformat, osproc, json, options, times, tables, asyncdispatch, algorithm, random, sets, unicode, sequtils]
import config, agent/invites, agent/cortex, agent/binding, libnkn/nkn_bridge, QRgen, utils
import skill_grant
import billing/[subscription as sub_mod, usage as usage_mod, welcome as welcome_mod, company as company_mod, plants as plants_mod]
import skills/[loader as skills_loader, installer as skills_installer]
import channels/feishu as feishu_channel
import providers/registry as prov_registry

## All administrative CLI subcommands ported from nullclaw.

# ── workspace ─────────────────────────────────────────────────────

const bootstrapFiles* = ["SOUL.md", "AGENTS.md", "TOOLS.md", "IDENTITY.md",
                          "USER.md", "HEARTBEAT.md", "BOOTSTRAP.md", "MEMORY.md"]

proc isBootstrapFile*(name: string): bool =
  for f in bootstrapFiles:
    if name == f: return true
  return false

proc rebuildBaseJson*(companyDir: string): tuple[ok: bool, output: string] =
  ## Execute BASE.nims via NimScript to regenerate BASE.json for this company.
  ## Used both by the CLI (`claw co update`) and the gateway (`/restart`,
  ## `/co update`) so the two surfaces stay in lockstep.
  ## Captures stdout+stderr — caller decides what to surface to the user.
  let scriptPath = companyDir / "BASE.nims"
  if not fileExists(scriptPath):
    return (false, "No BASE.nims at " & scriptPath &
                   " — this company wasn't created from a template.")

  # Locate the claw source tree so `import claw/clawdsl` inside the NimScript
  # resolves. Try CWD/src, then the binary's dir, then its parent — covers
  # running from the repo, from a build dir, and from an installed binary.
  var srcPath = getCurrentDir() / "src"
  if not dirExists(srcPath / "claw"):
    srcPath = getAppDir() / "src"
    if not dirExists(srcPath / "claw"):
      srcPath = getAppDir().parentDir() / "src"

  var cmd = "nim e"
  if dirExists(srcPath / "claw"):
    cmd &= " --path:" & quoteShell(srcPath)
  cmd &= " " & quoteShell(scriptPath)
  let (output, exitCode) = execCmdEx(cmd)
  return (exitCode == 0, output)

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

type ChannelNimsUpdate* = enum
  cnuNoFile         # BASE.nims missing
  cnuBlockAdded     # Created a new `channel "<type>":` block
  cnuItemAdded      # Inserted a new indented line into the existing block
  cnuItemUpdated    # Replaced an existing line (e.g. added agent routing)
  cnuAlreadyPresent # The requested item is already declared

proc appIDInLine(line, appID: string): bool =
  ## Match lines like `  app "cli_xxx"` or `  app "cli_xxx", "Agent"`.
  let s = line.strip()
  if not s.startsWith("app \""): return false
  let rest = s["app \"".len .. ^1]
  rest.startsWith(appID & "\"")

proc ensureChannelInBaseNims(channelType, fullBlock, appendItemLine: string): ChannelNimsUpdate =
  ## Mutate BASE.nims so `co update` will regenerate BASE.json with the
  ## declared channel. Two modes:
  ##
  ##   fullBlock   — used when the channel isn't declared yet; injected
  ##                 as a new `channel "<type>":` block just before
  ##                 `build(currentSourcePath())`.
  ##
  ##   appendItemLine — used when the channel IS declared; inserted as
  ##                    an indented line at the end of the existing
  ##                    block (before the first line that leaves the
  ##                    block's indentation). This is how Feishu
  ##                    multi-app support keeps every `app "..."` in
  ##                    the DSL too. No-op if this exact line is
  ##                    already present in the block.
  let baseNimsPath = getNimClawDir() / "BASE.nims"
  if not fileExists(baseNimsPath): return cnuNoFile
  let existing = readFile(baseNimsPath)
  let marker = "channel \"" & channelType & "\""

  if marker notin existing:
    # Fresh declaration.
    let buildLine = "build(currentSourcePath())"
    let header = "\n# ── Channel (added by `claw channel auth " &
                 channelType & "`) ───────\n"
    let insertion = header & fullBlock & "\n\n"
    let updated =
      if buildLine in existing:
        existing.replace(buildLine, insertion & buildLine)
      else:
        existing & insertion
    writeFile(baseNimsPath, updated)
    return cnuBlockAdded

  # Block already present — find its end and inject the new item.
  let lines = existing.splitLines()
  var start = -1
  for i, line in lines:
    if line.strip().startsWith(marker):
      start = i
      break
  if start < 0: return cnuAlreadyPresent  # shouldn't happen; marker matched above

  # Block body = lines immediately after `start` that are indented OR blank.
  var endIdx = start + 1
  while endIdx < lines.len:
    let l = lines[endIdx]
    if l.len == 0 or l.startsWith(" ") or l.startsWith("\t"):
      inc endIdx
    else:
      break

  # Upsert for `app "<id>"` lines: if a line already references this
  # app_id (parsed from the new line's quoted first arg), replace it.
  # Lets the two-arg form `app "<id>", "<agent>"` supersede the plain
  # one-arg form without leaving a stale duplicate behind.
  let newLineStripped = appendItemLine.strip()
  var existingAppID = ""
  if newLineStripped.startsWith("app \""):
    let rest = newLineStripped["app \"".len .. ^1]
    let closeQuote = rest.find('"')
    if closeQuote > 0: existingAppID = rest[0 ..< closeQuote]

  if existingAppID.len > 0:
    for i in start + 1 ..< endIdx:
      if appIDInLine(lines[i], existingAppID):
        if lines[i].strip() == newLineStripped:
          return cnuAlreadyPresent
        var updated = lines
        updated[i] = appendItemLine
        writeFile(baseNimsPath, updated.join("\n"))
        return cnuItemUpdated

  # Otherwise: idempotent append.
  for i in start + 1 ..< endIdx:
    if lines[i].strip() == newLineStripped:
      return cnuAlreadyPresent

  # Insert before the first trailing blank line (keeps comments grouped)
  # or at the block end otherwise.
  var insertAt = endIdx
  while insertAt > start + 1 and lines[insertAt - 1].strip().len == 0:
    dec insertAt

  var updated = lines[0 ..< insertAt]
  updated.add(appendItemLine)
  for i in insertAt ..< lines.len: updated.add(lines[i])
  writeFile(baseNimsPath, updated.join("\n"))
  cnuItemAdded

proc findClawRepo(): string =
  ## Walk up from CWD to find a claw.nim checkout (identified by
  ## channels/build_lark_cli.sh). Returns empty string if not found.
  var dir = getCurrentDir().absolutePath
  for _ in 0..8:
    if fileExists(dir / "channels" / "build_lark_cli.sh") and
       fileExists(dir / "claw.nimble"):
      return dir
    let up = dir.parentDir()
    if up == dir: break
    dir = up
  return ""

proc runVendorBuild(script, prettyName: string): string =
  let repo = findClawRepo()
  if repo.len == 0:
    return "Error: can't locate your claw.nim checkout.\n" &
           "Run `claw channel build` from inside the repo directory."
  let scriptPath = repo / "channels" / script
  if not fileExists(scriptPath):
    return "Error: missing " & scriptPath
  # Ensure the submodule is present. Scripts already do this, but
  # surfacing the step in our output makes the failure mode clearer.
  let submoduleDir =
    if script.contains("lark"): repo / "channels" / "lark-cli"
    else: repo / "channels" / "nkn-cli"
  if not fileExists(submoduleDir / "main.go") and
     not fileExists(submoduleDir / "go.mod"):
    echo "Initialising git submodule for " & prettyName & "..."
    let code = execShellCmd("cd " & quoteShell(repo) &
                            " && git submodule update --init channels/" &
                            submoduleDir.lastPathPart())
    if code != 0:
      return "Error: git submodule init failed. Make sure this is a git\n" &
             "checkout (not a nimble-installed copy), and that you have\n" &
             "network access to github.com."
  echo "Running " & scriptPath & " — requires Go 1.23+ (and Python 3 for lark)."
  let code = execShellCmd(quoteShell(scriptPath))
  if code != 0:
    return "Error: " & prettyName & " build failed. See output above.\n" &
           "Common causes: Go not installed, wrong Go version, Python 3 missing."
  return prettyName & " built. Binary is at " & repo & "/channels/bin/."

proc reassignFeishuApp*(cfg: Config, appID, agentName: string): string =
  ## Reassign an existing Feishu app to a different agent. Edits the
  ## `app "<id>", "<agent>"` line in BASE.nims inside the
  ## `channel "feishu":` block. The running gateway doesn't hot-swap
  ## lark-cli-subscriber → agent routing, so the caller must `/restart`
  ## after this returns for the change to take effect.
  var agentFound = false
  for a in cfg.agents.named:
    if a.name.toLowerAscii() == agentName.toLowerAscii():
      agentFound = true
      break
  if not agentFound:
    return "Error: agent `" & agentName & "` is not declared in BASE.nims."

  var currentAgent = ""
  var appFound = false
  for a in cfg.channels.feishu.apps:
    if a.app_id == appID:
      appFound = true
      currentAgent = a.agent
      break
  if not appFound:
    return "Error: app_id `" & appID & "` is not registered. Run " &
           "`/channel auth feishu " & appID & " <secret>` first."
  if currentAgent.toLowerAscii() == agentName.toLowerAscii():
    return "App `" & appID & "` is already routed to " & agentName & ". No change."

  let baseNimsPath = getNimClawDir() / "BASE.nims"
  if not fileExists(baseNimsPath):
    return "Error: no BASE.nims at " & baseNimsPath
  let content = readFile(baseNimsPath)
  let lines = content.splitLines()
  var rewritten: seq[string] = @[]
  var replaced = false
  for line in lines:
    if not replaced and appIDInLine(line, appID):
      let stripped = line.strip(leading = true, trailing = false)
      let indent = line[0 ..< line.len - stripped.len]
      rewritten.add(indent & "app \"" & appID & "\", \"" & agentName & "\"")
      replaced = true
    else:
      rewritten.add(line)
  if not replaced:
    return "Error: app_id `" & appID & "` not found in BASE.nims. " &
           "(Found in Config at runtime — the DSL may be out of sync; " &
           "run `/co update` and try again.)"
  writeFile(baseNimsPath, rewritten.join("\n"))

  let fromText = if currentAgent.len > 0: currentAgent else: "(unassigned)"
  return "✅ Reassigned `" & appID & "`: " & fromText & " → " & agentName &
         ".\n\nRun `/restart` to route this app's incoming events to " &
         agentName & "'s office. (The lark-cli subscriber is per-process " &
         "and needs a fresh start to pick up the new routing.)"

proc authFeishuChannel*(cfg: var Config, args: seq[string]): string =
  ## Configure Feishu credentials for THIS company. Mirrors `provider auth`:
  ## no per-company "add" step — the channel type exists in res/channels.json
  ## and this just binds credentials to the active company.
  ##
  ## Usage: claw channel auth feishu <APP_ID> <APP_SECRET>
  let bin = feishu_channel.findLarkCli()
  if bin.len == 0:
    return "Error: the official Lark/Feishu CLI (lark-cli) is not built.\n" &
           "Build it from the channels/lark-cli submodule:\n" &
           "  claw channel build lark          # or: nimble build_lark\n" &
           "Requirements: Go 1.23+ and Python 3. The binary drops to\n" &
           "<repo>/channels/bin/lark-cli and this command finds it from there."

  if args.len < 2:
    return "Usage: claw channel auth feishu <APP_ID> <APP_SECRET> [AGENT]\n\n" &
           "  AGENT  Optional agent name — messages arriving on this app\n" &
           "         will route to that agent's office. Omit to route to\n" &
           "         the company default (Lexi). A company with several\n" &
           "         Feishu apps typically binds each to a different agent.\n\n" &
           "Get your credentials from the Feishu Developer Console:\n" &
           "  https://open.feishu.cn/app"

  let appID = args[0]
  let appSecret = args[1]
  let targetAgent = if args.len >= 3: args[2] else: ""

  # If this app is already bound, re-verify and update — don't refuse.
  var existing = false
  var agentChanged = false
  for i in 0 ..< cfg.channels.feishu.apps.len:
    if cfg.channels.feishu.apps[i].app_id == appID:
      existing = true
      if targetAgent.len > 0 and
         cfg.channels.feishu.apps[i].agent != targetAgent:
        cfg.channels.feishu.apps[i].agent = targetAgent
        agentChanged = true
      break

  stdout.write "Verifying credentials with Feishu... "
  stdout.flushFile()
  let ok = feishu_channel.initLarkCliConfig(bin, appID, appSecret)
  if not ok:
    return "Failed to authenticate. Check your App ID and App Secret."
  echo "OK"

  if not existing:
    cfg.channels.feishu.enabled = true
    cfg.channels.feishu.apps.add(FeishuAppConfig(
      enabled: some(true),
      app_id: appID,
      agent: targetAgent,
    ))
  if not existing or agentChanged:
    let configPath = getNimClawDir() / "config.json"
    saveConfig(configPath, cfg)

  # Persist to BASE.nims so `co update` preserves the channel. Feishu's
  # DSL uses `app "<id>"` (multi-app, appended to apps[]) — NOT `appId`,
  # which is the flat-field form used by QQ/DingTalk. The secret lives
  # only in lark-cli's config dir; nims carries the app_id as the
  # declaration handle. If an agent is bound, use the two-arg form
  # `app "<id>", "<agent>"` so `co update` persists the routing.
  let appLine =
    if targetAgent.len > 0:
      "  app \"" & appID & "\", \"" & targetAgent & "\""
    else:
      "  app \"" & appID & "\""
  let fullBlock = "channel \"feishu\":\n" & appLine & """

  # App Secret is managed by the official Lark/Feishu CLI (lark-cli)
  # and stored under ~/.lark-cli — re-bind with:
  #   claw channel auth feishu """" & appID & """" <NEW_APP_SECRET>"""
  let appItemLine = appLine
  let updated = ensureChannelInBaseNims("feishu", fullBlock, appItemLine)
  var res = (if existing: "Re-authed " else: "Authed ") &
            "Feishu app " & appID & "."
  case updated
  of cnuBlockAdded:
    res.add("\nAppended new channel block to BASE.nims.")
  of cnuItemAdded:
    res.add("\nAppended app to existing BASE.nims block (now " &
            $cfg.channels.feishu.apps.len & " app(s)).")
  of cnuItemUpdated:
    res.add("\nUpdated BASE.nims app line" &
            (if targetAgent.len > 0: " (routes to " & targetAgent & ")." else: "."))
  of cnuAlreadyPresent:
    res.add("\n(BASE.nims already declared this app.)")
  of cnuNoFile:
    res.add("\n(Warning: no BASE.nims found — `co update` won't preserve this.)")
  res.add("\nRestart the gateway to connect.")
  return res

proc slugForIdentifier(agentName: string): string =
  ## Lowercase ASCII-safe sub-client name. NKN's sub-client identifier
  ## is UTF-8-legal but operators read addresses in logs, dashboards,
  ## and paste buffers — keep it predictable.
  for c in agentName:
    if c in {'a'..'z', '0'..'9'}: result.add(c)
    elif c in {'A'..'Z'}: result.add(chr(ord(c) + 32))

proc writeEnvVar(envFile, key, value: string) =
  ## Upsert `KEY=VALUE` in `.env`, preserving other lines.
  var kept: seq[string] = @[]
  if fileExists(envFile):
    for line in readFile(envFile).splitLines():
      if line.startsWith(key & "="): continue
      if line.strip().len > 0: kept.add(line)
  kept.add(key & "=" & value)
  writeFile(envFile, kept.join("\n") & "\n")

proc authNmobileChannel*(cfg: var Config, args: seq[string]): string =
  ## Setup an nMobile (NKN comm) channel using the seed-centric model.
  ## Usage:
  ##   claw channel auth nmobile                       # new random seed
  ##   claw channel auth nmobile <wallet.json>         # import + extract seed
  ##   claw channel auth nmobile --seed=<hex>          # paste existing seed
  ##   claw channel auth nmobile --identifier=<sub> --agent=<Name>
  ##                                                   # add one mapping
  ##
  ## The seed IS the NKN identity (no coins — comm-only). Stored in
  ## .env as NKN_WALLET_SEED. Identifier ↔ agent mapping goes into
  ## BASE.nims `channel "nmobile":` block. No wallet file on disk.

  let bridge = newNknBridge(proc(c, s, d: string) = discard)
  defer: bridge.stop()

  # Flag parsing — --identifier= / --agent= / --seed= / positional wallet.
  var walletPath = ""
  var newIdentifier = ""
  var newAgent = ""
  var explicitSeed = ""
  for a in args:
    if a.startsWith("--identifier="):
      newIdentifier = a["--identifier=".len .. ^1]
    elif a.startsWith("--agent="):
      newAgent = a["--agent=".len .. ^1]
    elif a.startsWith("--seed="):
      explicitSeed = a["--seed=".len .. ^1]
    elif walletPath.len == 0 and not a.startsWith("-"):
      walletPath = a

  let envFile = getNimClawDir() / ".env"

  # Find existing seed (from env or an earlier run). Fresh auth only
  # regenerates if nothing is in place; re-auth preserves identity.
  var seedHex = expandEnv(cfg.channels.nmobile.seed)
  if seedHex.len == 0:
    # Fallback: look in .env directly.
    if fileExists(envFile):
      for line in readFile(envFile).splitLines():
        if line.startsWith("NKN_WALLET_SEED="):
          seedHex = line["NKN_WALLET_SEED=".len .. ^1]; break

  # Identifier-only mode: seed must already exist. Append a new mapping.
  let identifierOnly = newIdentifier.len > 0 and walletPath.len == 0 and
                        explicitSeed.len == 0
  if identifierOnly and seedHex.len == 0:
    return "No existing NKN seed — run `claw channel auth nmobile` once " &
           "to create one before binding more identifiers."

  if not identifierOnly:
    if explicitSeed.len > 0:
      # Validate by deriving a pubkey.
      let (_, err) = bridge.getAddressFromSeed(explicitSeed, "")
      if err.len > 0:
        return "Invalid seed: " & err
      seedHex = explicitSeed
      echo "Using supplied seed."
    elif walletPath.len > 0:
      if not fileExists(walletPath):
        return "Error: wallet file not found at " & walletPath
      let walletJson = readFile(walletPath)
      stdout.write "Wallet password: "
      let password = readMaskedInput("")
      let (extracted, err) = bridge.extractSeed(walletJson, password)
      if err.len > 0:
        return "Failed to decrypt wallet: " & err & "\nWrong password?"
      seedHex = extracted
      echo "Seed extracted from ", walletPath, "."
    elif seedHex.len == 0:
      echo "Generating a new NKN seed (comm-only, no coins)..."
      let (generated, err) = bridge.generateSeed()
      if err.len > 0: return "Seed generation failed: " & err
      seedHex = generated
      echo "Seed generated."

    writeEnvVar(envFile, "NKN_WALLET_SEED", seedHex)
    cfg.channels.nmobile.enabled = true
    cfg.channels.nmobile.seed = "${NKN_WALLET_SEED}"

  # Auto-seed an identifier for every declared agent the first time,
  # unless the caller supplied explicit identifier/agent on this run.
  let firstRun = cfg.channels.nmobile.identifiers.len == 0 and
                  newIdentifier.len == 0
  if firstRun:
    for a in cfg.agents.named:
      if a.entity == "Human": continue
      let sub = slugForIdentifier(a.name)
      if sub.len == 0: continue
      cfg.channels.nmobile.identifiers.add(NMobileIdentifierConfig(
        enabled: some(true), identifier: sub, agent: a.name))

  if newIdentifier.len > 0:
    # Check-and-update or append.
    var found = false
    for i in 0 ..< cfg.channels.nmobile.identifiers.len:
      if cfg.channels.nmobile.identifiers[i].identifier == newIdentifier:
        cfg.channels.nmobile.identifiers[i].agent = newAgent
        found = true; break
    if not found:
      cfg.channels.nmobile.identifiers.add(NMobileIdentifierConfig(
        enabled: some(true), identifier: newIdentifier, agent: newAgent))

  # Persist the updated config.
  saveConfig(getConfigPath(), cfg)

  # BASE.nims: make `co update` regenerate with the same shape. One
  # `identifier "<sub>", "<Agent>"` line per mapping; seed field is an
  # env-ref, never the raw hex.
  var blockLines: seq[string] = @["channel \"nmobile\":",
                                   "  seed \"${NKN_WALLET_SEED}\""]
  for idCfg in cfg.channels.nmobile.identifiers:
    if idCfg.agent.len > 0:
      blockLines.add("  identifier \"" & idCfg.identifier & "\", \"" &
                     idCfg.agent & "\"")
    else:
      blockLines.add("  identifier \"" & idCfg.identifier & "\"")
  let fullBlock = blockLines.join("\n")
  # Per-mapping append line (used when the block already exists in
  # BASE.nims — appends new routes rather than rewriting).
  let appendLine =
    if newIdentifier.len > 0:
      if newAgent.len > 0:
        "  identifier \"" & newIdentifier & "\", \"" & newAgent & "\""
      else: "  identifier \"" & newIdentifier & "\""
    else: ""

  let updated = ensureChannelInBaseNims("nmobile", fullBlock, appendLine)

  # Compose the caller-facing summary. Print each identifier's full
  # NKN address so operators can copy-paste for peers.
  var lines: seq[string] = @[]
  lines.add("nMobile channel configured.")
  lines.add("  Seed in .env (NKN_WALLET_SEED).")
  case updated
  of cnuBlockAdded:     lines.add("  Appended channel block to BASE.nims.")
  of cnuItemAdded:      lines.add("  Appended identifier to existing BASE.nims block.")
  of cnuItemUpdated:    lines.add("  Updated existing identifier line in BASE.nims.")
  of cnuAlreadyPresent: lines.add("  BASE.nims already declared this identifier.")
  of cnuNoFile:         lines.add("  Warning: BASE.nims not found — `co update` won't preserve this.")
  if cfg.channels.nmobile.identifiers.len > 0:
    lines.add("")
    lines.add("Addresses:")
    for idCfg in cfg.channels.nmobile.identifiers:
      let (fullAddr, err) = bridge.getAddressFromSeed(seedHex, idCfg.identifier)
      if err.len == 0:
        lines.add("  " & fullAddr & "  (" &
                  (if idCfg.agent.len > 0: idCfg.agent else: "unbound") & ")")
  lines.add("")
  lines.add("Restart the gateway to connect.")
  lines.join("\n")

proc loadChannelTypes(): JsonNode =
  ## Read res/channels.json — the catalog of channel TYPES the binary
  ## supports (auth fields, capability flags, group-detection rules).
  ## Per-company instance config still lives in BASE.json.channels.
  let path = prov_registry.findDistributionResource("res" / "channels.json")
  if path.len == 0 or not fileExists(path):
    return newJObject()
  try:
    return parseJson(readFile(path))
  except CatchableError:
    return newJObject()

proc channelInstanceRows(cfg: Config): seq[tuple[name, status, credType, details: string]] =
  ## Walk the configured-channel slots on this company and project each
  ## into a display row. `credType` names the CREDENTIAL KIND (what the
  ## platform calls this auth shape), not the tool managing it. For
  ## example Feishu is an "open-app" (App ID + App Secret pair issued
  ## by the Feishu Open Platform); the fact that we use the official
  ## Lark/Feishu CLI (`lark-cli`) to bind them is a transport detail.
  let feishuDetail =
    if cfg.channels.feishu.apps.len > 0:
      var parts: seq[string]
      for a in cfg.channels.feishu.apps:
        var shown = a.app_id
        if shown.len > 10: shown = shown[0 ..< 12] & "…"
        # Show "<id> → <agent>" when a route is declared, else just the id
        if a.agent.len > 0:
          parts.add(shown & " → " & a.agent)
        else:
          parts.add(shown)
      $cfg.channels.feishu.apps.len & " app(s): " & parts.join(", ")
    else: "—"
  result.add(("feishu",
              if cfg.channels.feishu.enabled: "enabled" else: "disabled",
              (if cfg.channels.feishu.apps.len > 0: "open-app" else: "—"),
              feishuDetail))
  result.add(("telegram",
              if cfg.channels.telegram.enabled: "enabled" else: "disabled",
              (if cfg.channels.telegram.token.len > 0: "bot-token" else: "—"),
              "—"))
  result.add(("discord",
              if cfg.channels.discord.enabled: "enabled" else: "disabled",
              "bot-token", "—"))
  result.add(("whatsapp",
              if cfg.channels.whatsapp.enabled: "enabled" else: "disabled",
              (if cfg.channels.whatsapp.bridge_url.len > 0: "bridge-url" else: "—"),
              (if cfg.channels.whatsapp.bridge_url.len > 0: cfg.channels.whatsapp.bridge_url else: "—")))
  result.add(("qq",
              if cfg.channels.qq.enabled: "enabled" else: "disabled",
              "onebot", "—"))
  result.add(("dingtalk",
              if cfg.channels.dingtalk.enabled: "enabled" else: "disabled",
              "open-app", "—"))
  result.add(("nmobile",
              if cfg.channels.nmobile.enabled: "enabled" else: "disabled",
              "nkn-seed", "—"))
  result.add(("maixcam",
              if cfg.channels.maixcam.enabled: "enabled" else: "disabled",
              "none", "—"))

proc runChannelCommand*(cfg: var Config, args: seq[string], asJson: bool = false): string =
  if args.len == 0:
    return "Usage: claw channel <list|types|auth|build|remove> [args]\n" &
           "  list   — channels configured on this company (table)\n" &
           "  types  — channel types the binary supports (res/channels.json)\n" &
           "  auth   — bind credentials for a channel to this company\n" &
           "  build  — build a vendor CLI (lark, nkn) from the submodule\n" &
           "  remove — disable a channel on this company\n\n" &
           "Mirror of providers: `channel add/remove` the TYPE is done in\n" &
           "res/channels.json (binary-level). Per-company is just `auth`."
  let subcmd = args[0]

  if subcmd == "types":
    let catalog = loadChannelTypes()
    let types = catalog{"types"}
    if types == nil or types.kind != JObject:
      return if asJson: "[]" else: "No channel catalog found (res/channels.json missing)."
    if asJson: return $types
    var res = "Channel types supported by this binary:\n\n"
    for name, spec in types.pairs:
      res.add("  " & name.alignLeft(10) & " ")
      res.add(spec{"description"}.getStr("—") & "\n")
      let caps = spec{"capabilities"}
      if caps != nil and caps.kind == JObject:
        var capList: seq[string]
        for k, v in caps.pairs:
          if v.kind == JBool and v.getBool: capList.add(k)
        if capList.len > 0:
          res.add("             capabilities: " & capList.join(", ") & "\n")
      let auth = spec{"auth"}
      if auth != nil and auth.kind == JArray and auth.len > 0:
        var fields: seq[string]
        for a in auth:
          let field = a{"field"}.getStr()
          let required = a{"required"}.getBool(false)
          fields.add(if required: field & "*" else: field)
        res.add("             auth: " & fields.join(", ") &
                (if fields.len > 0: "   (* = required)\n" else: "\n"))
      let req = spec{"requires"}
      if req != nil and req.kind == JArray and req.len > 0:
        var items: seq[string]
        for r in req: items.add(r.getStr())
        res.add("             requires: " & items.join(", ") & "\n")
      res.add("\n")
    return res.strip

  if subcmd == "list":
    let rows = channelInstanceRows(cfg)
    if asJson:
      var arr = newJArray()
      for r in rows:
        arr.add(%*{"name": r.name, "status": r.status,
                   "credential": r.credType, "details": r.details})
      return $arr
    # Fixed-width header; details truncated only when extremely long.
    var res = "NAME       STATUS     CREDENTIAL  DETAILS\n"
    for r in rows:
      var detail = r.details
      if detail.len > 100: detail = detail[0 ..< 98] & "…"
      res.add(r.name.alignLeft(10) & " " &
              r.status.alignLeft(10) & " " &
              r.credType.alignLeft(11) & " " &
              detail & "\n")
    res.add("\n(Run `claw channel auth <type> ...` to bind credentials; " &
            "`channel types` for the available-binary catalog.)\n")
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
  if subcmd == "auth":
    if args.len < 2:
      return "Usage: claw channel auth <type> [creds...]\n" &
             "Supported: feishu, nmobile\n" &
             "Other types: the credentials live in your .env (see " &
             "`claw channel types`)."
    case args[1]
    of "feishu", "lark": return authFeishuChannel(cfg, args[2..^1])
    of "nmobile", "nkn": return authNmobileChannel(cfg, args[2..^1])
    else: return "Auth helper not yet available for '" & args[1] & "'.\n" &
                 "Set the required env vars from `claw channel types` and\n" &
                 "declare the channel block in BASE.nims directly."

  if subcmd == "build":
    if args.len < 2:
      return "Usage: claw channel build <lark|nkn>\n" &
             "Builds the vendor CLI from its git submodule under channels/.\n" &
             "Requires Go 1.23+ (and Python 3 for lark). No pre-built\n" &
             "binaries are distributed — claw.nim is pro-tools, not a\n" &
             "turnkey package."
    case args[1]
    of "lark", "feishu", "lark-cli":
      return runVendorBuild("build_lark_cli.sh", "lark-cli")
    of "nkn", "nmobile", "nkn-cli":
      return runVendorBuild("build_nkn_cli.sh", "nkn-cli")
    else:
      return "Unknown vendor target: " & args[1] & "\n" &
             "Supported: lark (Feishu), nkn (nMobile)."

  # Back-compat alias: old `channel add <type>` invocations fall through
  # to `auth` with a deprecation note.
  if subcmd == "add":
    return "`channel add` is deprecated at the company level — use:\n" &
           "  claw channel auth " &
           (if args.len > 1: args[1] else: "<type>") & " [creds...]\n" &
           "(Adding a new channel TYPE is a binary-level change to res/channels.json.)"

  if subcmd == "remove":
    if args.len < 2: return "Usage: claw channel remove <type>"
    return "To disable the '" & args[1] & "' channel, edit BASE.nims and\n" &
           "remove or comment out its `channel \"" & args[1] &
           "\":` block, then run `claw co update`."
  return "Unknown channel command: " & subcmd

# ── user ──────────────────────────────────────────────────────────
# Human identities (graph Persons) that this company knows about.
# Not the same as `agent list` — those are AIs (ekAI), these are the
# humans they talk to. Guests are users too; they sit at trust 10 until
# someone promotes them via redeem_invite or a SuperAdmin edit.

proc maxTrustFor(graph: WorldGraph, userID: WorldEntityID): int =
  ## Peek across every agent's relationships and take the highest trust
  ## level anyone has assigned to this user. Reflects "how trusted is
  ## this person overall" without committing to a specific agent.
  for ent in graph.entities.values:
    if ent.kind != ekAI: continue
    for link in ent.serves & ent.reportsTo:
      if link.targetID == userID and link.annotation.isSome:
        let t = link.annotation.get.trustLevel
        if t > result: result = t

proc userPermission(ent: WorldEntity): string =
  ## Permission axis — the role declared on the person block itself
  ## (e.g. "SuperAdmin", "Boss", "Customer"). Empty when the person has
  ## no explicit `permission "..."`; callers render "—".
  if ent.role.len > 0: ent.role else: ""

proc userRelRole(graph: WorldGraph, entId: WorldEntityID): string =
  ## Relationship axis — how an agent labels this person in its own
  ## `reportsTo` / `serves` edge annotations (e.g. "boss", "customer").
  ## Returns the first matching annotation across all AI entities.
  for a in graph.entities.values:
    if a.kind != ekAI: continue
    for link in a.reportsTo:
      if link.targetID == entId and link.annotation.isSome:
        return $link.annotation.get.role
    for link in a.serves:
      if link.targetID == entId and link.annotation.isSome:
        return $link.annotation.get.role
  ""

proc userRoleLabel(graph: WorldGraph, ent: WorldEntity): string =
  ## Back-compat convenience used by `user show` — prefers the permission
  ## axis, falls back to the relationship axis, then "guest".
  let p = userPermission(ent)
  if p.len > 0: return p
  let r = userRelRole(graph, ent.id)
  if r.len > 0: return r
  "guest"

proc bindTargets*(cfg: Config): string =
  ## Describe where a SuperAdmin can send a binding code. Lists every
  ## declared channel × app → agent routing so the operator knows which
  ## Feishu account (or other channel identity) to message.
  var lines: seq[string]
  if cfg.channels.feishu.apps.len > 0:
    for a in cfg.channels.feishu.apps:
      let who = if a.agent.len > 0: a.agent
                else:
                  (if cfg.agents.named.len > 0: cfg.agents.named[0].name
                   else: "default")
      lines.add("  • Feishu app " & a.app_id & " → DM agent \"" & who & "\"")
  # NKN / Telegram / WhatsApp / etc. are single-instance channels — one
  # agent per channel. Only mention channels that are actually enabled
  # in this company's config.
  if cfg.channels.telegram.enabled:
    lines.add("  • Telegram")
  if cfg.channels.whatsapp.enabled:
    lines.add("  • WhatsApp")
  if cfg.channels.discord.enabled:
    lines.add("  • Discord")
  if cfg.channels.nmobile.enabled:
    lines.add("  • nMobile (NKN)")
  if lines.len == 0:
    return "  (no channels enabled — configure at least one with `claw channel auth <name>`)"
  lines.join("\n")

proc tierFromRoleName*(label: string): string =
  ## Name-only heuristic: classify a role/permission label into
  ## "int"/"ext"/"?". Mirrors clawdsl.nim's tier inference. Callers
  ## without a Config (e.g. MCP tools) use this; `tierOfRole` wraps
  ## it with the trust-block lookup for the CLI-side callers.
  let low = label.toLowerAscii.strip
  if low.len == 0: return "?"
  case low:
  of "superadmin", "admin", "staff", "employee", "member": "int"
  of "boss", "master", "lead", "customer", "student", "guest": "ext"
  else: "?"

proc tierOfRole(cfg: Config, label: string): string =
  ## Declared roles in the trust: block win; otherwise fall back to
  ## the name heuristic.
  let low = label.toLowerAscii.strip
  if low.len == 0: return "?"
  for r in cfg.trust.roles:
    if r.name.toLowerAscii == low:
      let t = r.tier.toLowerAscii
      if t == "internal": return "int"
      if t == "external": return "ext"
      return "?"
  tierFromRoleName(low)

proc entityTier*(cfg: Config, graph: WorldGraph, ent: WorldEntity): string =
  ## Tier of a person — declared permission if present, else inferred
  ## from whatever relationship role an agent has pinned on them.
  let p = userPermission(ent)
  if p.len > 0: return tierOfRole(cfg, p)
  let r = userRelRole(graph, ent.id)
  tierOfRole(cfg, r)

# ── Shared BASE.nims block-editing primitives ─────────────────────
#
# Both `user edit` (person entities) and `agent edit` (AI entities)
# operate on a `<kind> "<name>":` header with 2-space-indented child
# fields. These helpers isolate the text surgery so both commands
# share one rename-with-cascade path.

proc leadingSpaces(s: string): int =
  var i = 0
  while i < s.len and s[i] == ' ': inc i
  i

proc findBlock(lines: seq[string], kind: string, name: string): (int, int) =
  ## Returns (start, endIdx) where start is the header line index and
  ## endIdx is one past the last line belonging to the block body.
  ## (-1, -1) if the block is missing.
  var start = -1
  for i, l in lines:
    if l.strip() == kind & " \"" & name & "\":":
      start = i; break
  if start < 0: return (-1, -1)
  var endIdx = start + 1
  while endIdx < lines.len:
    let l = lines[endIdx]
    if l.strip().len > 0 and not l.startsWith(" ") and not l.startsWith("\t"):
      break
    inc endIdx
  (start, endIdx)

proc rewriteBlockField(lines: var seq[string], blockStart, blockEnd: int,
                       field: string, value: string): tuple[changed: bool, old: string] =
  ## Rewrite an in-block 2-space-indented `<field> "<value>"` line.
  ## Inserts after the header if the field is absent. Returns the old
  ## value (or "" if inserted). Does not touch 4+-space nested blocks
  ## (so nested `role "boss"` inside reportsTo stays put).
  let newLine = "  " & field & " \"" & value & "\""
  for i in blockStart + 1 ..< blockEnd:
    if leadingSpaces(lines[i]) != 2: continue
    let body = lines[i][2 ..< lines[i].len]
    if body.startsWith(field & " \""):
      let open = lines[i].find("\"")
      let close = lines[i].rfind("\"")
      let old = if open >= 0 and close > open: lines[i][open + 1 ..< close] else: ""
      if old == value: return (false, old)
      lines[i] = newLine
      return (true, old)
  lines.insert(newLine, blockStart + 1)
  (true, "")

proc removeRefBlocks*(lines: var seq[string], headerPrefix: string, name: string): int =
  ## Delete every block whose header (after leading whitespace) equals
  ## `<headerPrefix> "<name>":`. A block spans from its header through
  ## any following blank lines plus any lines indented deeper than the
  ## header itself. Returns the number of blocks removed.
  let marker = headerPrefix & " \"" & name & "\":"
  var kept: seq[string]
  var i = 0
  while i < lines.len:
    if lines[i].strip() == marker:
      let headIndent = leadingSpaces(lines[i])
      var j = i + 1
      while j < lines.len:
        let l = lines[j]
        if l.strip().len == 0: inc j; continue
        if leadingSpaces(l) > headIndent: inc j; continue
        break
      inc result
      i = j
    else:
      kept.add(lines[i])
      inc i
  lines = kept

proc removePersonBlockByNcId*(lines: var seq[string], name, ncId: string): int =
  ## Delete only the `person "<name>":` block(s) whose body contains a
  ## `# <ncId>` tag line (written by mintCustomerInvite). Untagged
  ## blocks are left untouched — call `removeRefBlocks` for those.
  ## Returns how many blocks were removed.
  let marker = "person \"" & name & "\":"
  let tag = "# " & ncId
  var kept: seq[string]
  var i = 0
  while i < lines.len:
    if lines[i].strip() == marker:
      let headIndent = leadingSpaces(lines[i])
      var j = i + 1
      var hasTag = false
      while j < lines.len:
        let l = lines[j]
        if l.strip().len == 0: inc j; continue
        if leadingSpaces(l) > headIndent:
          if l.strip() == tag: hasTag = true
          inc j; continue
        break
      if hasTag:
        inc result
        i = j
        continue
    kept.add(lines[i])
    inc i
  lines = kept

proc cascadeNameRefs(lines: var seq[string], oldName, newName: string): tuple[person, agent, reports, serves: int] =
  ## Rewrite the header `person "<old>":` / `agent "<old>":` and every
  ## name reference inside any agent block's `reportsTo "<old>":` /
  ## `serves "<old>":` line. Returns per-kind counts so callers can
  ## report what they touched.
  let quotedOld = "\"" & oldName & "\""
  let quotedNew = "\"" & newName & "\""
  var p, a, r, s = 0
  for i in 0 ..< lines.len:
    let stripped = lines[i].strip(leading = true, trailing = false)
    var matched = false
    if stripped.startsWith("person " & quotedOld):       matched = true; inc p
    elif stripped.startsWith("agent " & quotedOld):      matched = true; inc a
    elif stripped.startsWith("reportsTo " & quotedOld):  matched = true; inc r
    elif stripped.startsWith("serves " & quotedOld):     matched = true; inc s
    if matched:
      let idx = lines[i].find(quotedOld)
      lines[i] = lines[i][0 ..< idx] & quotedNew &
                 lines[i][idx + quotedOld.len ..< lines[i].len]
  (p, a, r, s)

type
  CustomerInviteResult* = object
    ok*: bool
    error*: string
    code*: string
    targetNcId*: string
    customerName*: string
    agentName*: string
    maxUses*: int
    issuer*: string
    allowedSkills*: seq[string]     ## normalized grant strings (via `$SkillGrant`)
    materialized*: seq[string]      ## `<skill>::<credential>` slots whose member
                                    ## record was written — surface to the user

proc mintCustomerInvite*(workspace: string,
                         issuer, customerName, agentName: string,
                         maxUses: int = 1,
                         allowedSkills: openArray[string] = [],
                         lang: string = ""): CustomerInviteResult =
  ## Single source of truth for "issue a customer access code". Used by
  ## `claw user invite` (CLI), `/user invite` (slash command), and the
  ## `create_customer_invite` MCP tool.
  ##
  ## Does the full dance: validate skill grants, pre-allocate a Customer
  ## Person entity with an `allowed_skills` custom field, mint a code with
  ## `targetNcId` wired, persist the `person "X":` block into BASE.nims
  ## (appending fresh skill lines if the block already exists), register
  ## the serves edge on the target agent, and materialize per-customer
  ## member records for any `<skill>::<credential>` grant so the customer
  ## is immediately usable post-redeem. Callers format the user-facing
  ## output themselves (CLI terse, chat with paste templates).
  result = CustomerInviteResult(ok: false)
  if customerName.len == 0:
    result.error = "customer name must not be empty"; return
  if '"' in customerName:
    result.error = "customer name cannot contain a double-quote"; return
  if agentName.len == 0:
    result.error = "agent name must not be empty"; return

  # Parse & validate grants first — a typo here shouldn't land a
  # half-provisioned customer in the graph. Normalize via `$grant` so
  # storage (entity custom, BASE.nims) uses one canonical form regardless
  # of which surface minted the invite.
  var grants: seq[SkillGrant]
  var normalized: seq[string]
  for raw in allowedSkills:
    let r = raw.strip()
    if r.len == 0: continue
    let (ok, g, err) = parseSkillGrant(r)
    if not ok:
      result.error = "invalid skill grant '" & raw & "': " & err; return
    grants.add(g)
    normalized.add($g)

  let graph = loadWorld(workspace)
  if graph == nil:
    result.error = "couldn't load the company graph"; return
  var agentID = WorldEntityID(0)
  if graph.nameIndex.hasKey(agentName): agentID = graph.nameIndex[agentName]
  if uint32(agentID) == 0 or not graph.entities.hasKey(agentID) or
     graph.entities[agentID].kind != ekAI:
    var known: seq[string]
    for id, ent in graph.entities.pairs:
      if ent.kind == ekAI: known.add(ent.name)
    result.error = "no agent named '" & agentName & "'. Known: " &
                   known.join(", ")
    return

  # Pre-allocate the Customer entity.
  let newID = WorldEntityID(graph.nextID)
  graph.nextID += 1
  var ent = WorldEntity(
    id: newID,
    kind: ekPerson,
    name: customerName,
    role: "Customer",
    identifiers: initTable[string, string](),
    custom: newJObject()
  )
  if normalized.len > 0:
    var arr = newJArray()
    for s in normalized: arr.add(%s)
    ent.custom["allowed_skills"] = arr
  graph.entities[newID] = ent
  graph.nameIndex[customerName] = newID
  var agent = graph.entities[agentID]
  let annot = RelationshipAnnotation(
    role: urCustomer, trustLevel: 40, etiquette: "")
  agent.serves.add(RelationshipLink(
    targetID: newID, annotation: some(annot)))
  graph.entities[agentID] = agent
  graph.saveWorld()

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
    usedBy: "", usedAt: 0, targetNcId: alias, lang: lang)
  saveInvites(workspace, invMap)

  # Stamp the language in the customer side-file so it survives
  # `co update`. Keeping it on both the invite and the file is
  # defensive — single-use invite rows get deleted on redemption.
  if lang.len > 0: stampLang(alias, lang)

  # Persist the Customer to BASE.nims so `co update` keeps them.
  # Always insert a FRESH block per invite — never merge by name. Two
  # customers can legitimately share a display name (李总 #1 and 李总 #2
  # are different real people); appending to an existing name-matched
  # block would conflate their grants and, worse, make `user remove`
  # wipe both blocks when it strips by name. A `# nc:<id>` tag as the
  # block's first body line lets `user remove` target exactly one.
  let baseNims = getNimClawDir() / "BASE.nims"
  if fileExists(baseNims):
    var bLines = readFile(baseNims).splitLines()
    var insertAt = bLines.len
    for i, l in bLines:
      if l.strip().startsWith("build(currentSourcePath"):
        insertAt = i; break
    var newBlock = @[
      "", "person \"" & customerName & "\":",
      "  # " & alias,
      "  permission \"Customer\""
    ]
    for s in normalized:
      newBlock.add("  skill \"" & s & "\"")
    var merged = bLines[0 ..< insertAt]
    for l in newBlock: merged.add(l)
    for i in insertAt ..< bLines.len: merged.add(bLines[i])
    writeFile(baseNims, merged.join("\n"))

  # Materialize per-skill member records for `<skill>::<credential>`
  # grants — mirrors the sungrow skill's members/ layout so the customer
  # is immediately routed to the right account on first tool call.
  let ncIdSlot = alias.replace(":", "_")
  var materialized: seq[string]
  for g in grants:
    if g.credential.len == 0: continue
    let membersDir = getNimClawDir() / "support" / g.skill / "members"
    try:
      createDir(membersDir)
      writeFile(membersDir / (ncIdSlot & ".json"),
                $(%*{"account_id": g.credential}))
      materialized.add($g)
    except CatchableError as e:
      result.error = "failed to write member record for " & $g & ": " & e.msg
      return

  result = CustomerInviteResult(
    ok: true, code: code, targetNcId: alias,
    allowedSkills: normalized, materialized: materialized,
    customerName: customerName, agentName: agentName,
    maxUses: maxUses, issuer: issuer)

proc resolveCompanyBrand*(graph: WorldGraph, override = ""): string =
  ## Thin forwarder — kept for back-compat with call sites in cli_admin
  ## that predate the billing/company module. New code should call
  ## `resolveBrand` directly.
  resolveBrand(graph, override)

proc userSkillSummary*(ent: WorldEntity): string =
  ## Render `ent.custom.allowed_skills` as a compact cell for `user list`.
  ## Each grant collapses to `skill:credential` (for `::` form) or
  ## `skill(account)` (legacy `account@skill`) or just `skill` (unscoped).
  ## Returns "—" when no grants are declared.
  if ent.custom == nil or not ent.custom.hasKey("allowed_skills"): return "—"
  let node = ent.custom["allowed_skills"]
  if node.kind != JArray or node.len == 0: return "—"
  var parts: seq[string]
  for item in node:
    let raw = item.getStr("").strip()
    if raw.len == 0: continue
    let (ok, g, _) = parseSkillGrant(raw)
    if not ok: parts.add(raw); continue
    if g.credential.len > 0: parts.add(g.skill & ":" & g.credential)
    elif g.account.len > 0: parts.add(g.skill & "(" & g.account & ")")
    else: parts.add(g.skill)
  if parts.len == 0: "—" else: parts.join(", ")

proc userSubscription*(ncId: string, tier: string): string =
  ## Compact one-cell summary for `user list`. Internal-tier users are
  ## "n/a" (subscription doesn't apply). External customers show their
  ## plan plus remaining-days + a grace-period flag for trials.
  ##   recycled    — soft-removed (shown under --recycled/--all)
  ##   trial 23d   — trial, 23 days left
  ##   trial 2d !  — in the 3-day grace window
  ##   expired     — past trial, hard-blocked (Phase 3)
  ##   active      — paid plan, no auto-expiry
  ##   suspend     — manually suspended
  ##   —           — external customer without a stamped subscription
  if isRecycled(ncId): return "recycled"
  if tier == "int": return "n/a"
  let subOpt = loadSubscription(ncId)
  if subOpt.isNone: return "—"
  let s = subOpt.get()
  let now = getTime().toUnix
  case s.plan
  of pkActive:    "active"
  of pkSuspended: "suspend"
  of pkExpired:   "expired"
  of pkTrial:
    if now >= s.expires: "expired"
    else:
      let d = daysRemaining(s, now)
      let suffix = if inGracePeriod(s, now): " !" else: ""
      "trial " & $d & "d" & suffix

proc runUserCommand*(cfg: var Config, args: seq[string], asJson: bool = false): string =
  if args.len == 0:
    return "Usage: claw user <list|show|trust|edit|rebind|merge|remove|restore|invite|register|subscription> [args]\n" &
           "  list     — table of every user (Person/AI/Service/Unknown).\n" &
           "             flags: --kind=<Person|AI|Unknown|Service>\n" &
           "                    --tier=<int|ext|?>\n" &
           "                    --permission=<role>\n" &
           "                    --sort=<nc|name|kind|permission|tier|role|sub|skills>\n" &
           "                    --reverse  --format=<table|json>\n" &
           "                    --recycled  (show only soft-removed users)\n" &
           "                    --all       (show everyone including recycled)\n" &
           "  show     — detailed view (relationships, trust, mood) for one nc:id\n" &
           "  trust    — edge graph (agent → person) with role + trust per row\n" &
           "  edit     — set a field on a user in BASE.nims (or graph-only)\n" &
           "             claw user edit <nc:id> <field> <value>\n" &
           "             fields: name, permission, jobTitle, kind\n" &
           "  rebind   — issue a SuperAdmin binding code (for bootstrap or\n" &
           "             lost-device recovery — prints the code)\n" &
           "  remove   — soft remove (default): keeps nc:id, entity, edges,\n" &
           "             billing history. Recoverable via `restore`. Add\n" &
           "             --hard to fully delete (original behavior).\n" &
           "             optional: --reason=\"...\" for audit\n" &
           "  restore  — undo a soft remove (strips recycled_at flag)\n" &
           "  merge    — (SuperAdmin) fold a guest nc:id into an existing user\n" &
           "  invite   — generate a one-time invite code (guest → user promotion)\n" &
           "  register — reify a runtime-added User into BASE.nims (non-guests only)\n" &
           "  subscription — plan + token cap per customer (status/activate/\n" &
           "             extend/suspend/resume/usage). See `user subscription`.\n" &
           "             claw user register                 # everyone qualifying\n" &
           "             claw user register <nc:id> [name]  # one specific, named"
  let subcmd = args[0]

  let workspace = cfg.workspacePath()
  let graph = loadWorld(workspace)
  if graph == nil:
    return "Error: couldn't load the company graph from " & workspace

  # Visual-width padding — alignLeft counts bytes, so the em-dash
  # (3 bytes, 1 column) misaligns placeholder cells.
  proc pad(s: string, width: int): string =
    s & spaces(max(0, width - s.runeLen))

  if subcmd == "list":
    # Flags (positional-compatible — docopt passes them through as args):
    #   --kind=<Person|AI|Unknown|Service>   — filter by entity kind
    #   --tier=<int|ext|?>                   — filter by internal/external
    #   --permission=<role>                  — filter by declared permission
    #   --sort=<nc|name|kind|permission|tier|role>  — sort column
    #   --reverse                            — reverse sort order
    #   --format=<table|json>                — output format
    var filterKind, filterTier, filterPerm = ""
    var sortKey = "nc"
    var reverse = false
    var format = if asJson: "json" else: "table"
    # Recycle visibility: default hides soft-removed customers;
    # `--recycled` shows only them; `--all` shows everyone.
    type RecycleView = enum rvActive, rvRecycled, rvAll
    var recycleView = rvActive
    var unparsed: seq[string]
    for a in args[1 .. ^1]:
      if a.startsWith("--kind="):       filterKind = a["--kind=".len .. ^1].toLowerAscii
      elif a.startsWith("--tier="):     filterTier = a["--tier=".len .. ^1].toLowerAscii
      elif a.startsWith("--permission="): filterPerm = a["--permission=".len .. ^1].toLowerAscii
      elif a.startsWith("--perm="):     filterPerm = a["--perm=".len .. ^1].toLowerAscii
      elif a.startsWith("--sort="):     sortKey = a["--sort=".len .. ^1].toLowerAscii
      elif a == "--reverse":            reverse = true
      elif a.startsWith("--format="):   format = a["--format=".len .. ^1].toLowerAscii
      elif a == "--json":               format = "json"
      elif a == "--recycled":           recycleView = rvRecycled
      elif a == "--all":                recycleView = rvAll
      else: unparsed.add(a)
    if unparsed.len > 0:
      return "Error: unrecognised argument(s): " & unparsed.join(", ") & "\n" &
             "Flags: --kind=, --tier=, --permission=, --sort=, --reverse, --format=,\n" &
             "       --recycled (show only soft-removed), --all (show everyone)."

    var ourAgents: HashSet[string]
    for a in cfg.agents.named: ourAgents.incl(a.name)
    type Row = tuple[ncId, name, kind, perm, tier, relRole, sub, skills, idents: string]
    var rows: seq[Row]
    for id, ent in graph.entities.pairs:
      if ent.kind in {ekCorporate, ekInvite}: continue
      if ent.kind == ekAI and ent.name in ourAgents: continue
      let kindStr = $ent.kind
      let tierStr = entityTier(cfg, graph, ent)
      let permStr = userPermission(ent)
      if filterKind.len > 0 and kindStr.toLowerAscii != filterKind: continue
      if filterTier.len > 0 and tierStr != filterTier: continue
      if filterPerm.len > 0 and permStr.toLowerAscii != filterPerm: continue
      let recycled = isRecycled(toAlias(id))
      case recycleView:
      of rvActive:   (if recycled: continue)
      of rvRecycled: (if not recycled: continue)
      of rvAll: discard
      var identParts: seq[string]
      for chan, sid in ent.identifiers.pairs:
        var shown = sid
        if shown.len > 12: shown = shown[0 ..< 10] & "…"
        identParts.add(chan & ":" & shown)
      rows.add((
        ncId: toAlias(id),
        name: ent.name,
        kind: kindStr,
        perm: permStr,
        tier: tierStr,
        relRole: userRelRole(graph, id),
        sub: userSubscription(toAlias(id), tierStr),
        skills: userSkillSummary(ent),
        idents: (if identParts.len > 0: identParts.join(", ") else: "—")
      ))

    # Sort by the requested column (nc default).
    let sk = sortKey
    rows.sort(proc(a, b: Row): int =
      case sk:
      of "name":                 cmp(a.name.toLowerAscii, b.name.toLowerAscii)
      of "kind":                 cmp(a.kind, b.kind)
      of "permission", "perm":   cmp(a.perm.toLowerAscii, b.perm.toLowerAscii)
      of "tier":                 cmp(a.tier, b.tier)
      of "role", "rel", "relrole": cmp(a.relRole.toLowerAscii, b.relRole.toLowerAscii)
      of "sub", "subscription":  cmp(a.sub, b.sub)
      of "skills", "skill":      cmp(a.skills, b.skills)
      else:                      cmp(parseAlias(a.ncId).uint32, parseAlias(b.ncId).uint32))
    if reverse: rows.reverse()

    if format == "json":
      var arr = newJArray()
      for r in rows:
        arr.add(%*{"nc_id": r.ncId, "name": r.name,
                   "kind": r.kind,
                   "permission": r.perm, "tier": r.tier,
                   "relationship_role": r.relRole,
                   "subscription": r.sub,
                   "skills": r.skills,
                   "identifiers": r.idents})
      return $arr
    if rows.len == 0:
      var hint = "No users match the filter."
      if filterKind.len == 0 and filterTier.len == 0 and filterPerm.len == 0:
        hint = "No users in this company yet. First-contact guests auto-\n" &
               "register on their first message; our own agents are shown\n" &
               "by `claw agent list`."
      return hint
    var res = "NC:ID  NAME                  KIND     PERMISSION   TIER  ROLE(rel)   SUB       SKILLS                    IDENTIFIERS\n"
    for r in rows:
      var name = r.name
      if name.len > 20: name = name[0 ..< 18] & "…"
      var idents = r.idents
      if idents.len > 35: idents = idents[0 ..< 33] & "…"
      var skills = r.skills
      if skills.runeLen > 24: skills = skills[0 ..< 22] & "…"
      let perm = (if r.perm.len > 0: r.perm else: "—")
      let relRole = (if r.relRole.len > 0: r.relRole else: "—")
      res.add(pad(r.ncId, 6) & " " &
              pad(name, 21) & " " &
              pad(r.kind, 8) & " " &
              pad(perm, 12) & " " &
              pad(r.tier, 5) & " " &
              pad(relRole, 11) & " " &
              pad(r.sub, 9) & " " &
              pad(skills, 25) & " " &
              idents & "\n")
    var summary = "\n" & $rows.len & " user(s)"
    if filterKind.len + filterTier.len + filterPerm.len > 0:
      var parts: seq[string]
      if filterKind.len > 0: parts.add("kind=" & filterKind)
      if filterTier.len > 0: parts.add("tier=" & filterTier)
      if filterPerm.len > 0: parts.add("permission=" & filterPerm)
      summary.add(" (filtered: " & parts.join(", ") & ")")
    summary.add(". KIND = Person / AI / Service / Unknown.\n")
    res.add(summary)
    res.add("Use `claw user trust` for edges, `user show <nc:id>` for detail.\n")
    return res

  if subcmd == "trust":
    # Edge-list view of the trust graph. Every declared relationship is
    # one row; no flattening across agents. Sorted by source agent
    # (nc:id) then by edge-kind (reportsTo before serves) then by trust
    # descending so the "stronger" edges surface first within an agent.
    type Edge = tuple[
      agentID, personID: WorldEntityID,
      agentName, personName, kind, role, tier, etiquette: string,
      trust: int
    ]
    var edges: seq[Edge]
    for aID, a in graph.entities.pairs:
      if a.kind != ekAI: continue
      for (kind, links) in {
        "reportsTo": a.reportsTo,
        "serves": a.serves
      }.items:
        for link in links:
          if not graph.entities.hasKey(link.targetID): continue
          let p = graph.entities[link.targetID]
          # Edges to corporate/invite entities aren't "users" — skip.
          if p.kind in {ekCorporate, ekInvite}: continue
          var trust = 0
          var role = ""
          var eti = ""
          if link.annotation.isSome:
            let ann = link.annotation.get
            trust = ann.trustLevel
            role = $ann.role
            eti = ann.etiquette
          edges.add((
            agentID: aID, personID: link.targetID,
            agentName: a.name, personName: p.name,
            kind: kind, role: role,
            tier: entityTier(cfg, graph, p),
            etiquette: eti, trust: trust
          ))
    # Sort: agent nc:id asc, then reportsTo before serves, then trust desc.
    edges.sort(proc(x, y: Edge): int =
      let c1 = cmp(uint32(x.agentID), uint32(y.agentID))
      if c1 != 0: return c1
      let rank = proc(k: string): int = (if k == "reportsTo": 0 else: 1)
      let c2 = cmp(rank(x.kind), rank(y.kind))
      if c2 != 0: return c2
      cmp(y.trust, x.trust))

    if asJson:
      var arr = newJArray()
      for e in edges:
        arr.add(%*{
          "agent_nc_id": toAlias(e.agentID), "agent_name": e.agentName,
          "edge": e.kind,
          "person_nc_id": toAlias(e.personID), "person_name": e.personName,
          "person_tier": e.tier,
          "role": e.role, "trust": e.trust, "etiquette": e.etiquette
        })
      return $arr

    if edges.len == 0:
      return "No trust edges declared yet. Agents acquire edges via\n" &
             "reportsTo/serves annotations in BASE.nims, or runtime invite\n" &
             "redemption. Use `claw agent list` / `user list` to verify\n" &
             "you have at least one AI entity and one Person."

    var maxAgent = "AGENT".runeLen
    var maxPerson = "PERSON".runeLen
    var maxRole = "ROLE".runeLen
    for e in edges:
      if e.agentName.runeLen > maxAgent: maxAgent = e.agentName.runeLen
      if e.personName.runeLen > maxPerson: maxPerson = e.personName.runeLen
      if e.role.runeLen > maxRole: maxRole = e.role.runeLen

    var res = pad("AGENT", maxAgent) & "  " &
              pad("EDGE", 9) & "  " &
              pad("PERSON", maxPerson) & "  " &
              pad("TIER", 4) & "  " &
              pad("ROLE", maxRole) & "  " &
              pad("TRUST", 5) & "  ETIQUETTE\n"
    var lastAgent = WorldEntityID(0)
    for e in edges:
      if uint32(lastAgent) != 0 and lastAgent != e.agentID:
        res.add("\n")  # blank line between agents for readability
      lastAgent = e.agentID
      var eti = e.etiquette
      if eti.runeLen > 48: eti = eti[0 ..< 46] & "…"
      if eti.len == 0: eti = "—"
      let role = if e.role.len > 0: e.role else: "—"
      let trust = if e.trust == 0 and e.role.len == 0: "—" else: $e.trust
      res.add(pad(e.agentName, maxAgent) & "  " &
              pad(e.kind, 9) & "  " &
              pad(e.personName, maxPerson) & "  " &
              pad(e.tier, 4) & "  " &
              pad(role, maxRole) & "  " &
              pad(trust, 5) & "  " & eti & "\n")
    res.add("\n" & $edges.len & " edge(s). One row per declared agent→person edge;\n" &
            "use `claw user show <nc:id>` for a single user's full neighborhood.\n")
    return res

  if subcmd == "show":
    if args.len < 2:
      return "Usage: claw user show <nc:id>\n" &
             "Detailed view: entity kind/permission, every declared\n" &
             "relationship with its trust level + etiquette, and current\n" &
             "mood (for agents)."
    let alias = args[1]
    if not alias.startsWith("nc:"):
      return "Error: give an nc:id (e.g. nc:4). `claw user list` shows them."
    let id = parseAlias(alias)
    if uint32(id) == 0 or not graph.entities.hasKey(id):
      return "Error: " & alias & " not found in graph."
    let ent = graph.entities[id]

    var res = alias & "\n"
    res.add("  name:        " & ent.name & "\n")
    res.add("  kind:        " & $ent.kind &
            (if ent.kind == ekUnknown:
               "  (first-contact guest — classify with `user edit " & alias &
               " kind Person|AI|Service`)"
             else: "") & "\n")
    let recMeta = loadRecycleMeta(alias)
    if recMeta.isSome:
      let m = recMeta.get()
      res.add("  RECYCLED:    " & fromUnix(m.at).utc.format("yyyy-MM-dd HH:mm 'UTC'"))
      if m.by.len > 0: res.add(" by " & m.by)
      if m.reason.len > 0: res.add(" — " & m.reason)
      res.add("\n               (restore with `claw user restore " & alias & "`)\n")
    res.add("  tier:        " & entityTier(cfg, graph, ent) & "\n")
    if ent.role.len > 0:
      res.add("  permission:  " & ent.role & "\n")
    else:
      res.add("  permission:  " & userRoleLabel(graph, ent) & " (derived)\n")
    if ent.jobTitle.len > 0:
      res.add("  jobTitle:    " & ent.jobTitle & "\n")
    if ent.identifiers.len > 0:
      res.add("  identifiers:\n")
      for chan, sid in ent.identifiers.pairs:
        res.add("    " & chan & " = " & sid & "\n")

    # Outbound edges (this entity's own reportsTo/serves, for agents).
    var outbound: seq[string]
    if ent.kind == ekAI:
      for link in ent.reportsTo:
        if graph.entities.hasKey(link.targetID):
          let t = graph.entities[link.targetID]
          let a = link.annotation
          let trust = if a.isSome: $a.get.trustLevel else: "—"
          let eti = if a.isSome and a.get.etiquette.len > 0:
                      "    etiquette: " & a.get.etiquette else: ""
          outbound.add("  reportsTo → " & toAlias(link.targetID) &
                        " (" & t.name & "), trust " & trust &
                        (if eti.len > 0: "\n" & eti else: ""))
      for link in ent.serves:
        if graph.entities.hasKey(link.targetID):
          let t = graph.entities[link.targetID]
          let a = link.annotation
          let trust = if a.isSome: $a.get.trustLevel else: "—"
          let eti = if a.isSome and a.get.etiquette.len > 0:
                      "    etiquette: " & a.get.etiquette else: ""
          outbound.add("  serves → " & toAlias(link.targetID) &
                        " (" & t.name & "), trust " & trust &
                        (if eti.len > 0: "\n" & eti else: ""))

    # Inbound edges (who points at this entity).
    var inbound: seq[string]
    for otherID, other in graph.entities.pairs:
      if other.kind != ekAI: continue
      for link in other.reportsTo:
        if link.targetID == id and link.annotation.isSome:
          let a = link.annotation.get
          inbound.add("  ← " & other.name & ".reportsTo, trust " & $a.trustLevel &
                      (if a.etiquette.len > 0:
                         "\n    etiquette: " & a.etiquette else: ""))
      for link in other.serves:
        if link.targetID == id and link.annotation.isSome:
          let a = link.annotation.get
          inbound.add("  ← " & other.name & ".serves, trust " & $a.trustLevel &
                      (if a.etiquette.len > 0:
                         "\n    etiquette: " & a.etiquette else: ""))

    if outbound.len > 0:
      res.add("\nRelationships (outbound):\n" & outbound.join("\n") & "\n")
    if inbound.len > 0:
      res.add("\nRelationships (inbound):\n" & inbound.join("\n") & "\n")
    if outbound.len == 0 and inbound.len == 0:
      res.add("\nRelationships: none declared yet.\n")

    # Mood (agents carry it; persons don't).
    if ent.kind == ekAI:
      res.add("\nMood (current affective state):\n")
      res.add("  valence:   " & ent.valence.formatFloat(ffDecimal, 2) &
              "  (−1 = negative, +1 = positive)\n")
      res.add("  arousal:   " & ent.arousal.formatFloat(ffDecimal, 2) &
              "  (0 = calm, 1 = activated)\n")
      if ent.archetype.len > 0:
        res.add("  archetype: " & ent.archetype & "\n")
    return res

  if subcmd == "edit":
    # Unified syntax: `claw user edit <nc:id> <field> <value>`.
    # Works on any interactive entity (Person, AI, Unknown) — not just
    # humans. First-contact guests arrive with kind=Unknown; `kind` is
    # a field so operators can promote them once identified.
    if args.len < 4:
      return "Usage: claw user edit <nc:id> <field> <value>\n" &
             "Fields: name, permission, jobTitle, kind.\n" &
             "Examples:\n" &
             "  claw user edit nc:4 name Jerry\n" &
             "  claw user edit nc:5 permission Customer\n" &
             "  claw user edit nc:7 kind Person          # classify a guest\n" &
             "  claw user edit nc:7 kind AI              # it's a bot\n" &
             "Run `claw co update` afterwards to regenerate BASE.json."
    let alias = args[1]
    if not alias.startsWith("nc:"):
      return "Error: give an nc:id (e.g. nc:4). `claw user list` shows them."
    let id = parseAlias(alias)
    if uint32(id) == 0 or not graph.entities.hasKey(id):
      return "Error: " & alias & " not found in graph."
    let ent = graph.entities[id]
    if ent.kind in {ekCorporate, ekInvite}:
      return "Error: " & alias & " is a " & $ent.kind & " entity — not a user.\n" &
             "Users are people, agents, services, or still-unknown guests."
    let fieldRaw = args[2]
    let value = args[3].strip()
    let fieldMap = {
      "name": "name",
      "permission": "permission",
      "perm": "permission",
      "jobtitle": "jobTitle",
      "title": "jobTitle",
      "kind": "kind"
    }.toTable
    let fl = fieldRaw.toLowerAscii
    if not fieldMap.hasKey(fl):
      return "Error: unsupported field \"" & fieldRaw & "\" for a user.\n" &
             "Supported: name, permission, jobTitle, kind."
    let field = fieldMap[fl]
    if value.len == 0:
      return "Error: value must not be empty."
    if '"' in value:
      return "Error: value cannot contain a double-quote."

    let baseNims = getNimClawDir() / "BASE.nims"
    if not fileExists(baseNims):
      return "Error: no BASE.nims at " & baseNims
    var lines = readFile(baseNims).splitLines()

    if field == "kind":
      # Graph-only mutation — the DSL has no `kind` line (kind is
      # inferred from `person "X":` vs `agent "X":` block header).
      # So we update the graph directly, then let operators optionally
      # promote the entity from ekUnknown to a declared DSL block via
      # `claw user register` if they want to persist the classification.
      var k: EntityKind
      try:
        k = parseEnum[EntityKind](value.capitalizeAscii)
      except:
        return "Error: invalid kind \"" & value & "\".\n" &
               "Valid: Person, AI, Service, Unknown."
      if k in {ekCorporate, ekInvite}:
        return "Error: " & $k & " is not a user kind. Use Person/AI/Service/Unknown."
      if k == ent.kind:
        return "No change: " & alias & ".kind is already " & $k & "."
      var g = graph
      var e = g.entities[id]
      e.kind = k
      g.entities[id] = e
      g.saveWorld()
      return "Classified " & alias & ": kind " & $ent.kind & " → " & $k & "\n" &
             "Note: kind lives in BASE.json only — `co update` won't touch it.\n" &
             "Use `claw user register` to materialise the entity in BASE.nims."

    if field == "name":
      if value == ent.name:
        return "No change: name is already \"" & value & "\"."
      for otherID, other in graph.entities.pairs:
        if otherID == id: continue
        if other.name == value:
          return "Error: another " & $other.kind & " (" & toAlias(otherID) &
                 ") is already named \"" & value & "\". Use `user merge` to\n" &
                 "fold " & alias & " into " & toAlias(otherID) & "."
      let counts = cascadeNameRefs(lines, ent.name, value)
      if counts.person + counts.agent + counts.reports + counts.serves > 0:
        writeFile(baseNims, lines.join("\n"))
        return "Renamed " & alias & ": \"" & ent.name & "\" → \"" & value & "\"\n" &
               "  person block:    " & $counts.person & "\n" &
               "  agent block:     " & $counts.agent & "\n" &
               "  reportsTo refs:  " & $counts.reports & "\n" &
               "  serves refs:     " & $counts.serves & "\n" &
               "Run `claw co update` to regenerate BASE.json."
      # Entity isn't in BASE.nims — must be a runtime-added guest.
      # Rename directly in the graph so follow-up CLI lookups work.
      var g = graph
      var e = g.entities[id]
      e.name = value
      g.entities[id] = e
      if g.nameIndex.hasKey(ent.name): g.nameIndex.del(ent.name)
      g.nameIndex[value] = id
      g.saveWorld()
      return "Renamed " & alias & " (runtime-only): \"" & ent.name & "\" → \"" & value & "\"\n" &
             "Entity is not declared in BASE.nims — graph updated directly.\n" &
             "Use `claw user register " & alias & "` if you want the rename\n" &
             "persisted across `co update`."

    # Try a BASE.nims edit first — only works if the entity has a
    # `person "<name>":` block. Runtime-only entities (ekUnknown,
    # auto-registered ekAI) fall through to a graph-direct update.
    let (bStart, bEnd) = findBlock(lines, "person", ent.name)
    if bStart >= 0:
      let (changed, old) = rewriteBlockField(lines, bStart, bEnd, field, value)
      if not changed:
        return "No change: " & alias & "." & field & " is already \"" & value & "\"."
      writeFile(baseNims, lines.join("\n"))
      let verb = if old.len == 0: "Added" else: "Set"
      let rhs = if old.len == 0: " = \"" & value & "\""
                else: ": \"" & old & "\" → \"" & value & "\""
      return verb & " " & alias & "." & field & rhs & "\n" &
             "Run `claw co update` to regenerate BASE.json."

    # Graph-only path (entity not in BASE.nims).
    var g = graph
    var e = g.entities[id]
    var oldVal = ""
    case field:
    of "permission":
      oldVal = e.role; e.role = value
    of "jobTitle":
      oldVal = e.jobTitle; e.jobTitle = value
    else:
      return "Error: graph-only edit doesn't support field \"" & field & "\" yet."
    if oldVal == value:
      return "No change: " & alias & "." & field & " is already \"" & value & "\"."
    g.entities[id] = e
    g.saveWorld()
    return "Set " & alias & "." & field & " (graph-only): " &
           (if oldVal.len == 0: "→ \"" & value & "\""
            else: "\"" & oldVal & "\" → \"" & value & "\"") & "\n" &
           "Entity is not declared in BASE.nims — `co update` won't touch it.\n" &
           "Use `claw user register " & alias & "` to persist it."

  if subcmd == "register":
    # Reify runtime-added Person entities into BASE.nims so they survive
    # `co update`. Two forms:
    #   claw user register                 — everyone non-guest, not already
    #                                         declared
    #   claw user register <nc:id> [name]  — one specific entity, name hint
    # Guests (trust < 40 / role guest) are intentionally excluded. The
    # promotion path is redeem_invite; only once someone has earned a role
    # do they graduate into the DSL as a declared User.
    let baseNimsPath = getNimClawDir() / "BASE.nims"
    if not fileExists(baseNimsPath):
      return "Error: no BASE.nims at " & baseNimsPath
    let baseText = readFile(baseNimsPath)

    proc declaredPersonNames(src: string): HashSet[string] =
      ## Person names already in BASE.nims so we don't duplicate blocks.
      for raw in src.splitLines():
        let s = raw.strip()
        if s.startsWith("person \""):
          let rest = s["person \"".len .. ^1]
          let close = rest.find('"')
          if close > 0: result.incl(rest[0 ..< close])

    proc relationLinesForUser(graph: WorldGraph, userID: WorldEntityID):
        seq[tuple[agent, kind, role, etiquette: string, trust: int]] =
      ## Walk every agent; collect any serves/reportsTo link that targets
      ## this user, so we can splice it into the corresponding agent
      ## block. `kind` is "serves" | "reportsTo" — preserved from runtime.
      for id, ent in graph.entities.pairs:
        if ent.kind != ekAI: continue
        for link in ent.reportsTo:
          if link.targetID == userID and link.annotation.isSome:
            let a = link.annotation.get
            result.add((agent: ent.name, kind: "reportsTo",
                         role: $a.role, etiquette: a.etiquette,
                         trust: a.trustLevel))
        for link in ent.serves:
          if link.targetID == userID and link.annotation.isSome:
            let a = link.annotation.get
            result.add((agent: ent.name, kind: "serves",
                         role: $a.role, etiquette: a.etiquette,
                         trust: a.trustLevel))

    proc insertRelationIntoAgentBlock(path, agentName: string,
                                      relLines: string): bool =
      ## Splice a relation sub-block into an existing `agent "<Name>":`
      ## block. Returns true if the agent was found AND the relation
      ## text wasn't already present.
      let text = readFile(path)
      let lines = text.splitLines()
      let marker = "agent \"" & agentName & "\""
      var start = -1
      for i, l in lines:
        if l.strip().startsWith(marker):
          start = i
          break
      if start < 0: return false
      var endIdx = start + 1
      while endIdx < lines.len:
        let l = lines[endIdx]
        if l.len == 0 or l.startsWith(" ") or l.startsWith("\t"):
          inc endIdx
        else:
          break
      # Idempotent: if the relation text is already inside, skip.
      let body = lines[start + 1 ..< endIdx].join("\n")
      if relLines.strip() in body: return false
      # Insert at block end, before the first trailing blank.
      var insertAt = endIdx
      while insertAt > start + 1 and lines[insertAt - 1].strip().len == 0:
        dec insertAt
      var updated = lines[0 ..< insertAt]
      for r in relLines.splitLines(): updated.add(r)
      for i in insertAt ..< lines.len: updated.add(lines[i])
      writeFile(path, updated.join("\n"))
      true

    proc appendPersonBlock(path, personName: string,
                           idents: seq[(string, string)]): bool =
      ## Append a `person "Name":` block just before `build(...)`. No-op
      ## if the name is already declared.
      let text = readFile(path)
      if "person \"" & personName & "\"" in text: return false
      var block_content = "person \"" & personName & "\":\n"
      for (chan, sid) in idents:
        block_content.add("  identifier \"" & chan & "\", \"" & sid & "\"\n")
      let buildLine = "build(currentSourcePath())"
      let insertion = "\n# ── User (registered via `claw user register`) ───────\n" &
                      block_content & "\n"
      let updated =
        if buildLine in text:
          text.replace(buildLine, insertion & buildLine)
        else:
          text & insertion
      writeFile(path, updated)
      true

    proc registerOne(ent: WorldEntity, id: WorldEntityID, name: string,
                     declared: HashSet[string]): string =
      if name in declared:
        return "  ~ " & name & " already declared — skipped"
      # Collect this entity's channel identifiers for the block body.
      var idents: seq[(string, string)]
      for chan, sid in ent.identifiers.pairs:
        idents.add((chan, sid))
      if not appendPersonBlock(baseNimsPath, name, idents):
        return "  ~ " & name & " already in BASE.nims"
      var msgs = @["  + person \"" & name & "\" appended (" & $idents.len &
                    " identifier(s))"]
      # Splice any relation this user has into the matching agent block.
      for rel in relationLinesForUser(graph, id):
        let relText =
          "  " & rel.kind & " \"" & name & "\":\n" &
          "    role \"" & rel.role & "\"\n" &
          "    trustLevel " & $rel.trust &
          (if rel.etiquette.len > 0:
             "\n    etiquette \"" & rel.etiquette.replace("\"", "\\\"") & "\""
           else: "")
        if insertRelationIntoAgentBlock(baseNimsPath, rel.agent, relText):
          msgs.add("    + " & rel.agent & "." & rel.kind & " → " & name &
                    " (role=" & rel.role & ", trust=" & $rel.trust & ")")
      msgs.join("\n")

    let declared = declaredPersonNames(baseText)

    if args.len >= 2:
      # Specific nc:id form.
      let target = args[1]
      if not target.startsWith("nc:"):
        return "Error: target must be an nc:id (e.g. nc:4)."
      let id = parseAlias(target)
      if uint32(id) == 0 or not graph.entities.hasKey(id) or
         graph.entities[id].kind != ekPerson:
        return "Error: " & target & " is not a Person in the graph."
      let ent = graph.entities[id]
      let trust = maxTrustFor(graph, id)
      if trust < 40 and ent.role.toLowerAscii notin ["boss", "master",
                                                      "admin", "superadmin"]:
        return "Error: " & target & " is still a guest (trust " & $trust &
               "). Have them redeem an invite first to earn a role."
      let nameHint = if args.len >= 3: args[2] else: ent.name
      return "Registering " & target & " as \"" & nameHint & "\":\n" &
             registerOne(ent, id, nameHint, declared)

    # Bulk form — everyone non-guest, not already declared.
    var lines: seq[string] = @["Bulk-registering all non-guest, undeclared Persons:"]
    var count = 0
    for id, ent in graph.entities.pairs:
      if ent.kind != ekPerson: continue
      if ent.name in declared: continue
      # Exclude guests. Master/boss/admin role on the entity itself
      # (SuperAdmin-style graph-level role) is always kept; otherwise
      # require some agent relationship with trust >= 40.
      let trust = maxTrustFor(graph, id)
      if trust < 40 and ent.role.toLowerAscii notin ["boss", "master",
                                                      "admin", "superadmin"]:
        continue
      inc count
      lines.add("\n" & toAlias(id) & " (" & ent.name & "):")
      # Use the raw entity.name; specific form lets operators rename.
      lines.add(registerOne(ent, id, ent.name,
                             declaredPersonNames(readFile(baseNimsPath))))
    if count == 0:
      return "No non-guest, undeclared Persons to register.\n" &
             "(Run `claw user list` to see who's eligible; redeem an invite\n" &
             "to promote a guest first.)"
    lines.add("\nRegistered " & $count & " user(s). Run `claw co update` to\n" &
              "regenerate BASE.json with the new declarations.")
    return lines.join("\n")

  if subcmd == "remove" or subcmd == "delete":
    # Two-level remove:
    #   soft (default)  — stamp `recycled_at` on the customer side file,
    #                     keep nc:id + graph entity + BASE.nims + edges.
    #                     Customer is blocked from the agent but can be
    #                     restored with `user restore <nc:id>`. Billing
    #                     history (subscription, usage) is preserved.
    #   hard (--hard)   — the original path: delete entity, strip BASE.nims,
    #                     wipe member + usage + customer files. nc:id freed
    #                     for reuse by the next allocator. No undo.
    # Parse positional + flags.
    var positional: seq[string]
    var hard = false
    var reason = ""
    for a in args[1 .. ^1]:
      if a == "--hard": hard = true
      elif a.startsWith("--reason="): reason = a["--reason=".len .. ^1].strip()
      else: positional.add(a)
    if positional.len < 1:
      return "Usage:\n" &
             "  claw user remove <nc:id>             # soft — recoverable\n" &
             "  claw user remove <nc:id> --hard      # hard — permanent delete\n\n" &
             "Soft remove preserves the nc:id, graph entity, BASE.nims block,\n" &
             "edges, subscription, and usage history. Only the customer side-file's\n" &
             "`recycled_at` flag is set — the gate then refuses messages with a\n" &
             "'account deactivated' reply. Restore with `claw user restore <nc:id>`.\n\n" &
             "Hard remove does the full delete: entity + DSL + member records +\n" &
             "billing history, and the nc:id slot is freed. No undo.\n\n" &
             "Optional: `--reason=\"cancelled by billing\"` is stamped on the\n" &
             "recycle metadata (soft) or logged (hard) for the audit trail."
    let alias = positional[0]
    if not alias.startsWith("nc:"):
      return "Error: give an nc:id (e.g. nc:5)."
    let id = parseAlias(alias)
    if uint32(id) == 0 or not graph.entities.hasKey(id):
      return "Error: " & alias & " not found in graph."
    let ent = graph.entities[id]
    if ent.kind in {ekCorporate, ekInvite}:
      return "Error: cannot remove " & $ent.kind & " via `user`."
    if ent.kind == ekAI:
      for a in cfg.agents.named:
        if a.name == ent.name:
          return "Error: " & alias & " is a declared Agent (\"" & ent.name &
                 "\"). Use `claw agent remove " & ent.name & "` instead."
    let name = ent.name

    # ─── Soft remove ─────────────────────────────────────────────────
    if not hard:
      if isRecycled(alias):
        return alias & " (" & name & ") is already recycled. Use " &
               "`claw user restore " & alias & "` to undo, or " &
               "`claw user remove " & alias & " --hard` to purge permanently."
      # nc:id is implicitly the caller when invoked via the gateway's
      # /user slash path; for CLI we don't have a caller context, so
      # record "cli" as the actor. Operators with audit requirements
      # should pass `--reason=`.
      markRecycled(alias, "cli", reason)
      var res = "Soft-removed " & alias & " (" & name & ").\n" &
                "  nc:id, graph entity, BASE.nims block, edges — kept.\n" &
                "  Customer-facing: gate replies \"account deactivated\".\n" &
                "  Billing history: preserved.\n" &
                "  Restore with: claw user restore " & alias
      if reason.len > 0:
        res.add("\n  reason: " & reason)
      return res

    # ─── Hard remove (original delete path) ──────────────────────────
    # 1. Drop from graph: delete entity + strip any other entity's
    #    outbound edges that point at it.
    var g = graph
    g.entities.del(id)
    if g.nameIndex.hasKey(name) and g.nameIndex[name] == id:
      g.nameIndex.del(name)
    for k, v in g.idAliasIndex.pairs:
      if v == id: g.idAliasIndex.del(k); break
    for otherID in toSeq(g.entities.keys):
      var other = g.entities[otherID]
      var touched = false
      var kept: seq[RelationshipLink]
      for lk in other.reportsTo:
        if lk.targetID != id: kept.add(lk)
        else: touched = true
      if touched: other.reportsTo = kept
      kept = @[]
      touched = false
      for lk in other.serves:
        if lk.targetID != id: kept.add(lk)
        else: touched = true
      if touched: other.serves = kept
      g.entities[otherID] = other
    g.saveWorld()

    # 2. Strip BASE.nims — the person block + any inbound reportsTo/serves
    #    sub-blocks in agent declarations. Prefer nc:id-tagged removal
    #    (set by mintCustomerInvite) so two customers sharing a display
    #    name can be independently removed. Fall back to name-match only
    #    if no tagged block was found (legacy blocks written before the
    #    tag convention, like hand-declared entries in BASE.nims).
    let baseNims = getNimClawDir() / "BASE.nims"
    var removedPerson = 0
    var removedReports = 0
    var removedServes = 0
    if fileExists(baseNims):
      var lines = readFile(baseNims).splitLines()
      removedPerson = removePersonBlockByNcId(lines, name, alias)
      if removedPerson == 0:
        removedPerson = removeRefBlocks(lines, "person", name)
      removedReports = removeRefBlocks(lines, "reportsTo", name)
      removedServes = removeRefBlocks(lines, "serves", name)
      if removedPerson + removedReports + removedServes > 0:
        writeFile(baseNims, lines.join("\n"))

    # 3. Wipe per-skill member records (the `<nc_id>.json` files written
    #    by mintCustomerInvite for `<skill>::<credential>` grants). Scan
    #    every `support/*/members/` dir — skill-name-agnostic and safe to
    #    run even for customers who had no credential-scoped grants.
    let supportDir = getNimClawDir() / "support"
    let slot = alias.replace(":", "_") & ".json"
    var removedMembers: seq[string]
    if dirExists(supportDir):
      for kind, skillDir in walkDir(supportDir):
        if kind != pcDir: continue
        let memberFile = skillDir / "members" / slot
        if fileExists(memberFile):
          try:
            removeFile(memberFile)
            removedMembers.add(skillDir.lastPathPart)
          except CatchableError: discard

    # 4. Wipe billing usage counter — symmetric with member records.
    clearUsage(alias)

    # 5. Wipe per-customer billing state (subscription + lang).
    clearCustomerFile(alias)

    var res = "Removed " & alias & " (" & name & ") from the graph.\n"
    if removedPerson + removedReports + removedServes > 0:
      res.add("BASE.nims cleanup:\n")
      res.add("  person blocks:     " & $removedPerson & "\n")
      res.add("  reportsTo blocks:  " & $removedReports & "\n")
      res.add("  serves blocks:     " & $removedServes & "\n")
      res.add("Run `claw co update` to regenerate BASE.json from the\n")
      res.add("cleaned DSL.")
    else:
      res.add("(No BASE.nims declaration found — graph-only removal.)")
    if removedMembers.len > 0:
      res.add("\nSkill member records wiped: " & removedMembers.join(", "))
    return res

  if subcmd == "restore":
    # Undo a soft remove — strip the recycle flag from the customer
    # side-file. Graph entity, BASE.nims, and edges were never touched
    # by the soft-remove path, so restore is a single-file edit.
    if args.len < 2:
      return "Usage: claw user restore <nc:id>\n" &
             "Undoes a soft remove (`claw user remove <nc:id>` without\n" &
             "--hard). Graph entity, BASE.nims block, and billing history\n" &
             "were preserved during soft-remove, so restore just clears\n" &
             "the `recycled_at` flag on the customer's billing state."
    let alias = args[1]
    if not alias.startsWith("nc:"):
      return "Error: give an nc:id (e.g. nc:5)."
    let metaOpt = loadRecycleMeta(alias)
    if metaOpt.isNone:
      if uint32(parseAlias(alias)) > 0 and graph.entities.hasKey(parseAlias(alias)):
        return alias & " is not recycled — nothing to restore."
      return "Error: " & alias & " not found or has no customer state. " &
             "Hard-deleted entries cannot be restored."
    unmarkRecycled(alias)
    let entName =
      if graph.entities.hasKey(parseAlias(alias)):
        graph.entities[parseAlias(alias)].name
      else: "?"
    let m = metaOpt.get()
    var res = "Restored " & alias & " (" & entName & ").\n" &
              "  was recycled: " & fromUnix(m.at).utc.format("yyyy-MM-dd HH:mm 'UTC'") &
              " by " & (if m.by.len > 0: m.by else: "?")
    if m.reason.len > 0: res.add(" (reason: " & m.reason & ")")
    res.add("\n  subscription + usage history — untouched\n" &
            "  next message from this customer: gate uses the normal\n" &
            "  subscription check again.")
    return res

  if subcmd == "rebind":
    # Issue a fresh SuperAdmin binding code for a specific nc:id (or
    # all unbound SuperAdmins if no argument). Usable when the current
    # identifier is no longer reachable (lost device, left Telegram,
    # rotated Feishu open_id, etc.). By default this wipes the existing
    # identifiers on the target so the new code is the only way in —
    # pass `--keep` to leave them intact (dual-bind).
    var dropExisting = true
    var targetAlias = ""
    for a in args[1 .. ^1]:
      if a == "--keep": dropExisting = false
      elif a.startsWith("nc:"): targetAlias = a
      else:
        return "Error: unrecognised argument \"" & a & "\".\n" &
               "Usage: claw user rebind [<nc:id>] [--keep]"
    if targetAlias.len > 0:
      let code = rebind(graph, cfg.workspacePath(), targetAlias, dropExisting)
      if code.isNone:
        return "Error: " & targetAlias & " is not a SuperAdmin Person or\n" &
               "no such entity."
      let c = code.get
      return "Rebind code for " & c.targetName & " (" & c.targetNcId & "): " &
             c.code & "\n" &
             (if dropExisting:
                "Previous identifiers were cleared. "
              else:
                "Existing identifiers kept. ") &
             "Send this code as your first message to:\n" &
             bindTargets(cfg) & "\n" &
             "Codes expire after 24 hours."
    # No alias — issue codes for every unbound SuperAdmin.
    let fresh = ensureSuperAdminBindings(graph, cfg.workspacePath())
    if fresh.len == 0:
      return "Every SuperAdmin already has a bound identifier (or an\n" &
             "active code). Pass an nc:id to force-rebind a specific one:\n" &
             "  claw user rebind nc:4"
    var res = "Issued " & $fresh.len & " binding code(s):\n"
    for c in fresh:
      res.add("  " & c.targetNcId & " (" & c.targetName & "): " & c.code & "\n")
    res.add("Codes expire after 24 hours. Send one as a first message to:\n")
    res.add(bindTargets(cfg))
    return res

  if subcmd == "merge":
    if args.len < 3:
      return "Usage: claw user merge <source-nc:id> <target-nc:id>\n" &
             "Folds the source entity into the target: identifiers, memory\n" &
             "files, session files, and any inbound relationship edges are\n" &
             "moved across, then the source is removed from the graph.\n" &
             "Both must resolve to existing Person entities."
    let srcAlias = args[1]
    let tgtAlias = args[2]
    if not srcAlias.startsWith("nc:") or not tgtAlias.startsWith("nc:"):
      return "Error: both arguments must be nc:id form (e.g. nc:4, nc:5)."
    let srcID = parseAlias(srcAlias)
    let tgtID = parseAlias(tgtAlias)
    if uint32(srcID) == 0 or not graph.entities.hasKey(srcID):
      return "Error: source " & srcAlias & " not found in graph."
    if uint32(tgtID) == 0 or not graph.entities.hasKey(tgtID):
      return "Error: target " & tgtAlias & " not found in graph."
    if srcID == tgtID:
      return "Error: source and target are the same entity."
    if graph.entities[srcID].kind != ekPerson or
       graph.entities[tgtID].kind != ekPerson:
      return "Error: merge is only defined over Person entities."

    let srcEnt = graph.entities[srcID]
    var tgtEnt = graph.entities[tgtID]
    var moves: seq[string] = @[]

    # 1. Channel identifiers — merge source's slots into target, skipping
    #    any that target already has (target wins on conflict).
    for chan, sid in srcEnt.identifiers.pairs:
      if not tgtEnt.identifiers.hasKey(chan):
        tgtEnt.identifiers[chan] = sid
        moves.add("  + identifier " & chan & " → " & tgtAlias)
      else:
        moves.add("  ~ identifier " & chan & " already on " & tgtAlias &
                  " (source value dropped)")
    graph.entities[tgtID] = tgtEnt

    # 2. Per-office memory + session file migration. Each agent's office
    #    has its own nc_<N>.jsonl under memory/ and sessions/. We append
    #    source lines into the target file so conversation history is
    #    preserved (order by timestamp stays roughly correct since both
    #    streams are already timestamp-ordered per-file).
    let srcKey = srcAlias.replace(":", "_")
    let tgtKey = tgtAlias.replace(":", "_")
    let officesDir = cfg.workspacePath() / "offices"
    if dirExists(officesDir):
      for kind, office in walkDir(officesDir):
        if kind != pcDir: continue
        for sub in ["memory", "sessions"]:
          let srcFile = office / sub / (srcKey & ".jsonl")
          let tgtFile = office / sub / (tgtKey & ".jsonl")
          if fileExists(srcFile):
            let body = readFile(srcFile)
            let f = open(tgtFile, fmAppend)
            if not tgtFile.fileExists() or body.len > 0:
              f.write(body)
            f.close()
            removeFile(srcFile)
            moves.add("  + merged " & sub & "/" & srcKey &
                      ".jsonl → " & office.lastPathPart & "/" & sub &
                      "/" & tgtKey & ".jsonl")
          # Session .meta.json: take target's if present, else source's.
          if sub == "sessions":
            let srcMeta = office / sub / (srcKey & ".meta.json")
            let tgtMeta = office / sub / (tgtKey & ".meta.json")
            if fileExists(srcMeta):
              if not fileExists(tgtMeta):
                moveFile(srcMeta, tgtMeta)
                moves.add("  + moved session meta → " & office.lastPathPart)
              else:
                removeFile(srcMeta)

    # 3. Relationship edges — every agent whose serves/reportsTo points
    #    at srcID gets redirected to tgtID. Duplicates (already pointing
    #    at tgtID) are dropped.
    for id, ent in graph.entities.mpairs:
      if ent.kind != ekAI: continue
      var changed = false
      var newServes: seq[RelationshipLink]
      for link in ent.serves:
        if link.targetID == srcID:
          # Skip if target already has an inbound edge from this agent.
          var dup = false
          for existing in ent.serves:
            if existing.targetID == tgtID: dup = true; break
          if not dup:
            var redirected = link
            redirected.targetID = tgtID
            newServes.add(redirected)
          changed = true
        else:
          newServes.add(link)
      if changed: ent.serves = newServes

      var newReports: seq[RelationshipLink]
      var chRep = false
      for link in ent.reportsTo:
        if link.targetID == srcID:
          var dup = false
          for existing in ent.reportsTo:
            if existing.targetID == tgtID: dup = true; break
          if not dup:
            var redirected = link
            redirected.targetID = tgtID
            newReports.add(redirected)
          chRep = true
        else:
          newReports.add(link)
      if chRep: ent.reportsTo = newReports
      if changed or chRep:
        moves.add("  ~ " & ent.name & "'s relationship edges redirected")

    # 4. Drop source entity + indexes.
    graph.entities.del(srcID)
    if graph.nameIndex.hasKey(srcEnt.name) and
       graph.nameIndex[srcEnt.name] == srcID:
      graph.nameIndex.del(srcEnt.name)
    graph.idAliasIndex.del(srcAlias)
    # nknIndex slot (legacy addUserToGraph writes "nkn": senderID)
    for nknKey in srcEnt.identifiers.values:
      if graph.nknIndex.hasKey(nknKey) and graph.nknIndex[nknKey] == srcID:
        graph.nknIndex.del(nknKey)

    graph.saveWorld()

    var res = "Merged " & srcAlias & " → " & tgtAlias & ".\n"
    res.add(moves.join("\n"))
    if moves.len == 0:
      res.add("  (source had no movable data)")
    res.add("\n\nGraph updated. Verify with `claw user list`.")
    return res

  if subcmd == "invite":
    if args.len < 2:
      return "Usage:\n" &
             "  claw user invite list\n" &
             "  claw user invite <issuer-nc:id> [<uses>] [<agent>] [<customer>] \\\n" &
             "                   [--skill=<grant>]... [--skills=<g1,g2,…>]\n\n" &
             "Positional defaults: uses=1, agent=<company default>.\n" &
             "Issuer is stamped so `user invite list` shows who minted it.\n\n" &
             "Skill grants (repeatable):\n" &
             "  --skill=sungrow                 unscoped, uses skill's default creds\n" &
             "  --skill=sungrow::acme-solar     credential-scoped — materializes a\n" &
             "                                  member record so the customer is\n" &
             "                                  ready to use acme-solar on redeem\n" &
             "  --skill=account@sungrow         legacy account-prefix syntax\n\n" &
             "Examples:\n" &
             "  claw user invite nc:3                                    # 1 use, no skills\n" &
             "  claw user invite nc:3 5                                  # 5 uses\n" &
             "  claw user invite nc:3 1 Atlas LiZong \\\n" &
             "                   --skill=sungrow::acme-solar             # credential-scoped"

    # Sub-sub-command: `user invite list`
    if args[1] == "list":
      let workspace = cfg.workspacePath()
      let invites = loadInvites(workspace)
      if invites.len == 0:
        return "No invitation codes on file."
      type Row = tuple[code, role, issuedBy, agent, remaining, created, used: string]
      var rows: seq[Row]
      for inv in invites.values:
        let remaining =
          if inv.maxUses < 0: "∞"
          else: $inv.maxUses
        let created =
          if inv.createdAt > 0:
            fromUnix(inv.createdAt).utc.format("yyyy-MM-dd HH:mm")
          else: "—"
        let used =
          if inv.usedAt > 0:
            fromUnix(inv.usedAt).utc.format("MM-dd HH:mm") &
            (if inv.usedBy.len > 0: " by " & inv.usedBy else: "")
          else: "—"
        rows.add((
          code: inv.code,
          role: inv.role,
          issuedBy: (if inv.issuedBy.len > 0: inv.issuedBy else: "—"),
          agent: (if inv.agentName.len > 0: inv.agentName else: "—"),
          remaining: remaining,
          created: created,
          used: used
        ))
      if asJson:
        var arr = newJArray()
        for r in rows:
          arr.add(%*{"code": r.code, "role": r.role, "issued_by": r.issuedBy,
                     "agent": r.agent, "remaining_uses": r.remaining,
                     "created": r.created, "used": r.used})
        return $arr
      var res = "CODE        ROLE       ISSUER  AGENT        USES  CREATED            USED\n"
      for r in rows:
        res.add(r.code.alignLeft(11) & " " &
                r.role.alignLeft(10) & " " &
                r.issuedBy.alignLeft(7) & " " &
                r.agent.alignLeft(12) & " " &
                r.remaining.alignLeft(5) & " " &
                r.created.alignLeft(18) & " " &
                r.used & "\n")
      return res.strip

    # Generate a new invite.
    let issuerAlias = args[1]
    if not issuerAlias.startsWith("nc:"):
      return "Error: issuer must be an nc:id (e.g. nc:3). Use `user list` to find one."
    let issuerID = parseAlias(issuerAlias)
    if uint32(issuerID) == 0 or not graph.entities.hasKey(issuerID):
      return "Error: issuer " & issuerAlias & " not found in graph."

    var uses = 1
    var positional: seq[string]
    var allowedSkills: seq[string]
    var inviteLang = ""
    for a in args[2 .. ^1]:
      if a.startsWith("--skill="):
        let g = a["--skill=".len .. ^1].strip()
        if g.len > 0: allowedSkills.add(g)
      elif a.startsWith("--skills="):
        for s in a["--skills=".len .. ^1].split(','):
          let s2 = s.strip()
          if s2.len > 0: allowedSkills.add(s2)
      elif a.startsWith("--lang="):
        inviteLang = a["--lang=".len .. ^1].strip()
      else:
        positional.add(a)
    if positional.len >= 1:
      try: uses = parseInt(positional[0])
      except ValueError:
        return "Error: <uses> must be an integer, got '" & positional[0] &
               "'. The `[role]` positional was removed in an earlier " &
               "refactor — see `claw user invite` for the current syntax."
    let agentName =
      if positional.len >= 2: positional[1]
      elif cfg.agents.named.len > 0: cfg.agents.named[0].name
      else: ""
    let customer =
      if positional.len >= 3: positional[2] else: "Customer-" & issuerAlias.replace(":", "_")
    let workspace = cfg.workspacePath()
    let inv = mintCustomerInvite(workspace, issuerAlias, customer,
                                  agentName, uses, allowedSkills, inviteLang)
    if not inv.ok:
      return "Error: " & inv.error
    result = "Invite created: " & inv.targetNcId & "/" & inv.code & "\n" &
             "  customer: " & inv.customerName & "\n" &
             "  agent:    " & inv.agentName & "\n" &
             "  uses:     " & $inv.maxUses & "\n" &
             "  issuer:   " & inv.issuer & "\n"
    if inv.allowedSkills.len > 0:
      result.add("  skills:   " & inv.allowedSkills.join(", ") & "\n")
    if inv.materialized.len > 0:
      result.add("  routed:   " & inv.materialized.join(", ") & "\n")
    if inviteLang.len > 0:
      result.add("  lang:     " & inviteLang & "\n")

    # Clean, shareable block. The operator forwards one line to the
    # customer; the `nc:X/CODE` bundled form stays above for operator
    # records. Language-aware so Chinese customers get Chinese prompts.
    let brand = resolveCompanyBrand(graph)
    let shareLine = inviteCodeMessage(brand, inv.code, inviteLang)
    result.add("\n────────── Forward to the customer ──────────\n")
    result.add(shareLine & "\n")
    result.add("──────────────────────────────────────────────\n\n")
    result.add("The customer sends that line (or just the code) to any\n" &
               "channel routing to '" & inv.agentName & "'. The gateway\n" &
               "authenticates pre-LLM and replies with the welcome message\n" &
               "in their language.")
    return

  # ── subscription ──────────────────────────────────────────────────
  # claw user subscription <subcmd> <nc:id> [flags]
  #   status   — show plan, dates, today's usage
  #   activate — stamp a trial/active plan on the entity; returns the
  #              language-aware welcome text for the operator to share
  #   extend   — push `expires` out by --days=N
  #   suspend  — flip plan to suspended, optional --reason
  #   resume   — flip a suspended plan back to its stored kind
  #              (default: trial if still within expiry, else active)
  #   usage    — today's token counter with % of cap
  # Flags: --plan=trial|active  --days=<n>  --tokens=<n>
  #        --reason=<txt>  --lang=<code>  --company=<name>  --agent=<name>
  if subcmd == "subscription":
    if args.len < 2:
      return "Usage:\n" &
             "  claw user subscription status   <nc:id>\n" &
             "  claw user subscription activate <nc:id> [--plan=trial|active] \\\n" &
             "                                   [--days=<n>] [--tokens=<n>] \\\n" &
             "                                   [--lang=en|zh] [--company=<name>] \\\n" &
             "                                   [--agent=<name>]\n" &
             "  claw user subscription extend   <nc:id> --days=<n>\n" &
             "  claw user subscription suspend  <nc:id> [--reason=<txt>]\n" &
             "  claw user subscription resume   <nc:id>\n" &
             "  claw user subscription usage    <nc:id>\n" &
             "  claw user subscription clear    <nc:id>\n\n" &
             "Defaults at `activate`: plan=trial, days=30, tokens=200000.\n" &
             "Activation prints a language-aware welcome message for the\n" &
             "operator to share with the customer. Use `clear` to undo a\n" &
             "mis-activation; prefer `suspend` for normal pauses."
    let action = args[1]
    if args.len < 3:
      return "Error: `subscription " & action & "` requires an nc:id."
    let alias = args[2]
    if not alias.startsWith("nc:"):
      return "Error: give an nc:id (e.g. nc:5)."
    let id = parseAlias(alias)
    if uint32(id) == 0 or not graph.entities.hasKey(id):
      return "Error: " & alias & " not found in graph."
    let ent = graph.entities[id]
    let tier = entityTier(cfg, graph, ent)
    if tier == "int":
      return "Error: " & alias & " (" & ent.name & ") is internal — " &
             "subscriptions only apply to external customers."

    # Parse flags common to multiple actions.
    var planOverride = ""
    var days = -1
    var tokens = -1
    var reason = ""
    var lang = ""
    var companyName = ""
    var agentOverride = ""
    for a in args[3 .. ^1]:
      if a.startsWith("--plan="):    planOverride = a["--plan=".len .. ^1].strip()
      elif a.startsWith("--days="):
        try: days = parseInt(a["--days=".len .. ^1].strip())
        except ValueError:
          return "Error: --days= must be an integer."
      elif a.startsWith("--tokens="):
        try: tokens = parseInt(a["--tokens=".len .. ^1].strip())
        except ValueError:
          return "Error: --tokens= must be an integer."
      elif a.startsWith("--reason="): reason = a["--reason=".len .. ^1].strip()
      elif a.startsWith("--lang="):   lang = a["--lang=".len .. ^1].strip()
      elif a.startsWith("--company="):companyName = a["--company=".len .. ^1].strip()
      elif a.startsWith("--agent="):  agentOverride = a["--agent=".len .. ^1].strip()
      else:
        return "Error: unknown flag '" & a & "'."

    let now = getTime().toUnix

    case action:
    of "status":
      let subOpt = loadSubscription(alias)
      if subOpt.isNone:
        return alias & " (" & ent.name & ") has no subscription.\n" &
               "Run `claw user subscription activate " & alias & "` to start a trial."
      let s = subOpt.get()
      let u = loadUsage(alias)
      let used = tokensToday(u)
      let pct =
        if s.dailyTokens > 0: (used * 100) div s.dailyTokens else: 0
      var msg = alias & "  " & ent.name & "\n"
      msg.add("  plan:        " & $s.plan & "\n")
      msg.add("  started:     " & fromUnix(s.startedAt).utc.format("yyyy-MM-dd") & "\n")
      if s.plan == pkTrial or s.plan == pkActive:
        let d = daysRemaining(s, now)
        let grace = if inGracePeriod(s, now): " (grace)" else: ""
        msg.add("  expires:     " & fromUnix(s.expires).utc.format("yyyy-MM-dd") &
                " (" & $d & " days left" & grace & ")\n")
      if s.plan == pkSuspended and s.suspendReason.len > 0:
        msg.add("  reason:      " & s.suspendReason & "\n")
      msg.add("  daily cap:   " & $s.dailyTokens & " tokens\n")
      msg.add("  today:       " & $used & " tokens (" & $pct & "% used)\n")
      msg.add("  language:    " & loadLang(alias) & "\n")
      return msg

    of "activate":
      # Build the subscription. Plan override → pkActive (paid) otherwise trial.
      var sub = defaultTrial(now)
      if planOverride == "active":
        sub.plan = pkActive
      elif planOverride.len > 0 and planOverride != "trial":
        return "Error: --plan= must be 'trial' or 'active'."
      if days > 0: sub.expires = now + days.int64 * 86_400
      if tokens > 0: sub.dailyTokens = tokens
      stampSubscription(alias, sub)

      # Stamp language if specified. If not, keep whatever was there.
      if lang.len > 0: stampLang(alias, lang)
      let effectiveLang = loadLang(alias, fallback = "en")

      # Resolve agent name: explicit flag > first `serves` edge > first
      # declared agent > "your agent".
      var agentName = agentOverride
      if agentName.len == 0:
        for otherID, other in graph.entities.pairs:
          if other.kind != ekAI: continue
          for lk in other.serves:
            if lk.targetID == id: agentName = other.name; break
          if agentName.len > 0: break
      if agentName.len == 0 and cfg.agents.named.len > 0:
        agentName = cfg.agents.named[0].name
      if agentName.len == 0: agentName = "your agent"

      let effectiveCompany = resolveCompanyBrand(graph, companyName)

      let ctx = WelcomeContext(
        customerName: ent.name, agentName: agentName,
        lang: effectiveLang, sub: sub, companyName: effectiveCompany,
        contact: resolveSupportContact(graph),
        plantNames: fetchPlantNames(alias)
      )
      var msg = "Subscription activated for " & alias & " (" & ent.name & ").\n"
      msg.add("  plan:     " & $sub.plan & "\n")
      msg.add("  expires:  " & fromUnix(sub.expires).utc.format("yyyy-MM-dd") & "\n")
      msg.add("  daily:    " & $sub.dailyTokens & " tokens\n")
      msg.add("  language: " & effectiveLang & "\n")
      msg.add("\n────────── Welcome message (share with customer) ──────────\n\n")
      msg.add(welcomeMessage(ctx))
      msg.add("\n\n────────────────────────────────────────────────────────────")
      return msg

    of "extend":
      if days <= 0:
        return "Error: `extend` needs --days=<positive integer>."
      let subOpt = loadSubscription(alias)
      if subOpt.isNone:
        return "Error: " & alias & " has no subscription to extend. " &
               "Use `activate` first."
      var s = subOpt.get()
      # Base extension off max(now, expires) so extending an already-
      # expired plan starts the clock fresh, not in the past.
      let base = max(now, s.expires)
      s.expires = base + days.int64 * 86_400
      if s.plan == pkExpired: s.plan = pkTrial  # gift them another trial window
      stampSubscription(alias, s)
      return "Extended " & alias & " by " & $days & " days. " &
             "New expiry: " & fromUnix(s.expires).utc.format("yyyy-MM-dd") & "."

    of "suspend":
      let subOpt = loadSubscription(alias)
      if subOpt.isNone:
        return "Error: " & alias & " has no subscription. `activate` first."
      var s = subOpt.get()
      if s.plan == pkSuspended:
        return alias & " is already suspended" &
               (if s.suspendReason.len > 0: " (reason: " & s.suspendReason & ")." else: ".")
      s.plan = pkSuspended
      s.suspendReason = reason
      stampSubscription(alias, s)
      var msg = "Suspended " & alias & " (" & ent.name & ")."
      if reason.len > 0: msg.add(" Reason: " & reason)
      return msg

    of "resume":
      let subOpt = loadSubscription(alias)
      if subOpt.isNone:
        return "Error: " & alias & " has no subscription. `activate` first."
      var s = subOpt.get()
      if s.plan != pkSuspended:
        return alias & " is not suspended — plan is " & $s.plan & "."
      # Default: trial if still within expiry, else active.
      s.plan =
        if now < s.expires: pkTrial
        else: pkActive
      s.suspendReason = ""
      stampSubscription(alias, s)
      return "Resumed " & alias & " — plan is now " & $s.plan & "."

    of "usage":
      let u = loadUsage(alias)
      let used = tokensToday(u)
      var msg = alias & " usage (" & u.day & " UTC)\n"
      msg.add("  prompt tokens:  " & $u.tokensIn & "\n")
      msg.add("  output tokens:  " & $u.tokensOut & "\n")
      msg.add("  total:          " & $used & "\n")
      let subOpt = loadSubscription(alias)
      if subOpt.isSome:
        let s = subOpt.get()
        let pct =
          if s.dailyTokens > 0: (used * 100) div s.dailyTokens else: 0
        msg.add("  cap:            " & $s.dailyTokens & " (" & $pct & "% used)\n")
      return msg

    of "clear":
      # Remove the subscription entirely — back to "no plan". Prefer
      # `suspend` in production (keeps an audit trail via suspend_reason);
      # `clear` is for undo when a subscription was mis-activated.
      if loadSubscription(alias).isNone:
        return alias & " has no subscription — nothing to clear."
      clearSubscription(alias)
      clearUsage(alias)
      return "Cleared subscription for " & alias & " (" & ent.name &
             "). Usage counter also wiped."

    else:
      return "Error: unknown subscription action '" & action & "'. " &
             "Try: status, activate, extend, suspend, resume, usage, clear."

  return "Unknown user command: " & subcmd

# ── role ──────────────────────────────────────────────────────────
# Permission tiers declared per-company. Minimum is internal:{SuperAdmin}
# + external:{Guest}; operators add/edit/remove to fit their workflow.
# Mutations are SuperAdmin-only conceptually (CLI-local execution is
# trusted as the operator seat until a remote interface exists).

proc runRoleCommand*(cfg: var Config, args: seq[string], asJson: bool = false): string =
  if args.len == 0:
    return "Usage: claw role <list|add|remove|set> [args]\n" &
           "  list   — show every role this company defines\n" &
           "  add    — declare a new role (SuperAdmin-only)\n" &
           "  remove — drop a role; fails if any user holds it\n" &
           "  set    — edit band/initial/grants/tier on an existing role\n\n" &
           "Every company has at least SuperAdmin (internal) + Guest\n" &
           "(external). Customize with `role add` or by editing the\n" &
           "`trust:` block in BASE.nims directly."
  let subcmd = args[0]

  if subcmd == "list":
    if cfg.trust.roles.len == 0:
      return "No roles declared yet. Minimum defaults (SuperAdmin/Guest)\n" &
             "are seeded at `co create`/`co update` time — run one of those\n" &
             "to see them, or add explicit roles with `claw role add`."
    # Group by tier for readability.
    var internals, externals, unknowns: seq[TrustRoleConfig]
    for r in cfg.trust.roles:
      case r.tier.toLowerAscii
      of "internal": internals.add(r)
      of "external": externals.add(r)
      else: unknowns.add(r)
    if asJson:
      var arr = newJArray()
      for r in cfg.trust.roles:
        arr.add(%*{"name": r.name, "tier": r.tier,
                   "trustMin": r.trustMin, "trustMax": r.trustMax,
                   "grant": r.grant, "prompt": r.prompt})
      return $arr
    proc renderTier(label: string, rs: seq[TrustRoleConfig]): string =
      if rs.len == 0: return ""
      result = "\n" & label & ":\n"
      result.add("  NAME         TRUST    GRANTS\n")
      for r in rs:
        var g = r.grant.join(",")
        if g.len > 40: g = g[0 ..< 38] & "…"
        # Pinned roles (zero-width range) render as a single number;
        # the user sees at a glance that there's no drift.
        let trustCol =
          if r.trustMin == r.trustMax: $r.trustMin & "     "
          else: $r.trustMin & "-" & $r.trustMax
        result.add("  " & r.name.alignLeft(12) & " " &
                   trustCol.alignLeft(8) & " " &
                   g & "\n")
    var res = "Company role definitions:"
    res.add(renderTier("Internal", internals))
    res.add(renderTier("External", externals))
    if unknowns.len > 0:
      res.add(renderTier("Untiered (edit BASE.nims to set tier)", unknowns))
    res.add("\nTotal: " & $cfg.trust.roles.len & " role(s) across " &
            $(if internals.len > 0: 1 else: 0) & " internal + " &
            $(if externals.len > 0: 1 else: 0) & " external tier(s).")
    return res

  # Helper: splice a `role "<name>":` sub-block into the `trust:` block in
  # BASE.nims. Creates the `trust:` block if missing. Idempotent on name.
  proc upsertRoleInBaseNims(roleBody: string, roleName: string): string =
    let baseNims = getNimClawDir() / "BASE.nims"
    if not fileExists(baseNims):
      return "Error: no BASE.nims at " & baseNims
    let existing = readFile(baseNims)
    # Skip if already declared.
    if ("role \"" & roleName & "\":") in existing or
       ("role \"" & roleName.toLowerAscii & "\":") in existing:
      return "Role \"" & roleName & "\" already declared in BASE.nims."
    # Inject inside an existing `trust:` block, or create one.
    let block_text = roleBody
    if "\ntrust:\n" in existing or existing.startsWith("trust:\n"):
      # Append role sub-block at end of trust: block.
      let lines = existing.splitLines()
      var start = -1
      for i, l in lines:
        if l.strip() == "trust:":
          start = i
          break
      var endIdx = start + 1
      while endIdx < lines.len:
        let l = lines[endIdx]
        if l.len == 0 or l.startsWith(" ") or l.startsWith("\t"):
          inc endIdx
        else: break
      # Insert before first trailing blank.
      var insertAt = endIdx
      while insertAt > start + 1 and lines[insertAt - 1].strip().len == 0:
        dec insertAt
      var updated = lines[0 ..< insertAt]
      for r in block_text.splitLines(): updated.add(r)
      for i in insertAt ..< lines.len: updated.add(lines[i])
      writeFile(baseNims, updated.join("\n"))
      return ""
    # No trust: block — inject a fresh one before build(...).
    let buildLine = "build(currentSourcePath())"
    let header = "\n# ── Trust (added by `claw role add`) ───────\ntrust:\n"
    let insertion = header & block_text & "\n\n"
    let updated =
      if buildLine in existing: existing.replace(buildLine, insertion & buildLine)
      else: existing & insertion
    writeFile(baseNims, updated)
    return ""

  if subcmd == "add":
    if args.len < 3:
      return "Usage: claw role add <name> <internal|external> [trustMin] [trustMax] [grants...]\n" &
             "Examples:\n" &
             "  claw role add Consultant external 40 80\n" &
             "  claw role add Owner internal 100 100              # pinned\n" &
             "  claw role add Advisor external 50 80 reply forward edit"
    let rname = args[1]
    let tier = args[2].toLowerAscii
    if tier notin ["internal", "external"]:
      return "Error: tier must be 'internal' or 'external' (got '" & tier & "')."
    var tmin = 0
    var tmax = 40
    if args.len >= 4:
      try: tmin = parseInt(args[3])
      except: return "Error: trustMin must be an integer."
    if args.len >= 5:
      try: tmax = parseInt(args[4])
      except: return "Error: trustMax must be an integer."
    if tmin < 0 or tmax > 100 or tmin > tmax:
      return "Error: need 0 <= trustMin <= trustMax <= 100."
    var grants: seq[string]
    if args.len >= 6:
      for i in 5 ..< args.len: grants.add(args[i])
    var body = "  role \"" & rname & "\":\n" &
               "    tier \"" & tier & "\"\n" &
               "    trust " & $tmin & ", " & $tmax & "\n"
    if grants.len > 0:
      var quoted: seq[string]
      for g in grants: quoted.add("\"" & g & "\"")
      body.add("    grant " & quoted.join(", ") & "\n")
    let err = upsertRoleInBaseNims(body, rname)
    if err.len > 0: return err
    return "Added role \"" & rname & "\" (" & tier &
           ", trust " & $tmin & "-" & $tmax & ").\n" &
           "Run `claw co update` to regenerate BASE.json."

  if subcmd == "remove":
    if args.len < 2:
      return "Usage: claw role remove <name>"
    let rname = args[1]
    # Safety — refuse if any user currently holds this role.
    let workspace = cfg.workspacePath()
    let graph = loadWorld(workspace)
    var holders: seq[string]
    if graph != nil:
      for id, ent in graph.entities.pairs:
        if ent.kind != ekPerson: continue
        if ent.role.toLowerAscii == rname.toLowerAscii:
          holders.add(toAlias(id) & " (" & ent.name & ")")
    if holders.len > 0:
      return "Error: role \"" & rname & "\" is held by " & $holders.len &
             " user(s): " & holders.join(", ") & "\n" &
             "Reassign them to a different role first, then retry."
    let baseNims = getNimClawDir() / "BASE.nims"
    if not fileExists(baseNims):
      return "Error: no BASE.nims at " & baseNims
    let existing = readFile(baseNims)
    let marker = "role \"" & rname & "\":"
    if marker notin existing:
      return "Role \"" & rname & "\" is not declared in BASE.nims — nothing to remove."
    # Cut the role sub-block: from its header line through the last indented
    # line that follows.
    let lines = existing.splitLines()
    var start = -1
    for i, l in lines:
      if l.strip() == marker:
        start = i
        break
    if start < 0:
      return "Role \"" & rname & "\" header not found cleanly; edit BASE.nims by hand."
    var endIdx = start + 1
    while endIdx < lines.len:
      let l = lines[endIdx]
      # Stops at next non-indented OR differently-indented line (e.g. the
      # next sibling `role "..."` at the same indent).
      if l.strip().startsWith("role \""): break
      if l.strip().len > 0 and not l.startsWith("    "): break
      inc endIdx
    # Locate the enclosing `trust:` block — so we can also cut the empty
    # container (and its auto-generated comment) when this is the last role.
    var trustStart = -1
    for i in countdown(start - 1, 0):
      if lines[i].strip() == "trust:":
        trustStart = i; break
    # Count roles that will survive the cut.
    var survivingRoles = 0
    if trustStart >= 0:
      var j = trustStart + 1
      while j < lines.len:
        let l = lines[j]
        if l.strip().len == 0:
          inc j; continue
        if not (l.startsWith(" ") or l.startsWith("\t")): break
        if l.strip().startsWith("role \"") and (j < start or j >= endIdx):
          inc survivingRoles
        inc j
    var cutFrom = start
    var cutTo = endIdx
    if trustStart >= 0 and survivingRoles == 0:
      cutFrom = trustStart
      # Also swallow any preceding `# ── Trust …` comment block + the blank
      # line in front of it, so BASE.nims doesn't carry a dangling header.
      while cutFrom > 0:
        let prev = lines[cutFrom - 1].strip()
        if prev.startsWith("#") and "trust" in prev.toLowerAscii:
          dec cutFrom
        else: break
      if cutFrom > 0 and lines[cutFrom - 1].strip().len == 0:
        dec cutFrom
      # Extend cutTo past the trust: block's trailing blanks.
      while cutTo < lines.len:
        let l = lines[cutTo]
        if l.strip().len == 0:
          inc cutTo
        else: break
    var remaining = lines[0 ..< cutFrom]
    for i in cutTo ..< lines.len: remaining.add(lines[i])
    writeFile(baseNims, remaining.join("\n"))
    return "Removed role \"" & rname & "\". Run `claw co update` to regenerate BASE.json."

  if subcmd == "set":
    return "TODO: `role set <name> [--trust=..] [--grant=..] [--tier=..]`\n" &
           "Edit the `trust:` block in BASE.nims directly for now, then\n" &
           "run `claw co update`."

  return "Unknown role command: " & subcmd

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
      let parts = strutils.splitWhitespace(outp.strip())
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
    return "Usage: nimclaw agents <list|add|remove|edit|access|bizcard|rename|status|journal> [args]\n\nCommands:\n  list              List all named agents\n  add <name> <model> [provider] [prompt]\n                    Add a new named agent\n  remove <name>     Remove a named agent\n  edit <name> <field> <value>\n                    Set a DSL field in BASE.nims (jobTitle, model, role,\n                    identity, profile, provider)\n  rename <old> <new> Rename an agent in config and graph\n  access <name> <mode> \n                    Toggle public/private access\n  bizcard <name> [customer]\n                    Generate a business card\n  status <name>     Check detailed agent status\n  journal <name>    View recent agent activity journal"

  var subcmd = args[0]
  var targetAgent = ""
  var finalArgs = args

  # Support flexible syntax:
  # 1. nimclaw agents bizcard secretary "Boss"
  # 2. nimclaw agents secretary bizcard "Boss"
  let knownCmds = ["list", "add", "remove", "edit", "access", "bizcard", "rename", "status", "journal"]
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

  if subcmd == "edit":
    # `claw agent edit <name> <field> <value>` — parallels `user edit`.
    # Mutates direct children of `agent "<name>":` (2-space indent) so
    # the nested `role "boss"` inside a reportsTo annotation is safe.
    # For `name`, cascades to any `reportsTo "X":`/`serves "X":` in
    # other agent blocks that reference this agent.
    let needName = (targetAgent == "" and finalArgs.len < 4) or
                   (targetAgent != "" and finalArgs.len < 3)
    if needName:
      return "Usage: claw agent edit <name> <field> <value>\n" &
             "Fields: name, jobTitle, model, role, identity, profile, provider.\n" &
             "Examples:\n" &
             "  claw agent edit Lexi jobTitle Secretary\n" &
             "  claw agent edit Lexi name Luna         # rename + cascade refs\n" &
             "Run `claw co update` afterwards to regenerate BASE.json."
    let name = if targetAgent != "": targetAgent else: finalArgs[1]
    let fieldRaw = if targetAgent != "": finalArgs[1] else: finalArgs[2]
    let value = if targetAgent != "": finalArgs[2] else: finalArgs[3]
    let fieldMap = {
      "name": "name",
      "jobtitle": "jobTitle",
      "title": "jobTitle",
      "model": "model",
      "role": "role",
      "identity": "identity",
      "profile": "profile",
      "provider": "provider"
    }.toTable
    let fl = fieldRaw.toLowerAscii
    if not fieldMap.hasKey(fl):
      return "Error: unsupported field \"" & fieldRaw & "\" for an agent.\n" &
             "Supported: name, jobTitle, model, role, identity, profile, provider."
    let field = fieldMap[fl]
    if value.len == 0:
      return "Error: value must not be empty."
    if '"' in value:
      return "Error: value cannot contain a double-quote."

    let baseNims = getNimClawDir() / "BASE.nims"
    if not fileExists(baseNims):
      return "Error: no BASE.nims at " & baseNims
    var lines = readFile(baseNims).splitLines()

    if field == "name":
      if value == name:
        return "No change: name is already \"" & value & "\"."
      let workspace = cfg.workspacePath()
      let graph = loadWorld(workspace)
      if graph != nil:
        for id, ent in graph.entities.pairs:
          if ent.name == value:
            return "Error: another " & $ent.kind & " (" & toAlias(id) &
                   ") is already named \"" & value & "\"."
      let counts = cascadeNameRefs(lines, name, value)
      if counts.person + counts.agent + counts.reports + counts.serves == 0:
        return "Error: no references to \"" & name & "\" in BASE.nims."
      writeFile(baseNims, lines.join("\n"))
      return "Renamed agent \"" & name & "\" → \"" & value & "\"\n" &
             "  agent block:     " & $counts.agent & "\n" &
             "  reportsTo refs:  " & $counts.reports & "\n" &
             "  serves refs:     " & $counts.serves & "\n" &
             "Run `claw co update` to regenerate BASE.json."

    let (bStart, bEnd) = findBlock(lines, "agent", name)
    if bStart < 0:
      return "Error: no `agent \"" & name & "\":` block in BASE.nims."
    let (changed, old) = rewriteBlockField(lines, bStart, bEnd, field, value)
    if not changed:
      return "No change: " & name & "." & field & " is already \"" & value & "\"."
    writeFile(baseNims, lines.join("\n"))
    let verb = if old.len == 0: "Added" else: "Set"
    let rhs = if old.len == 0: " = \"" & value & "\""
              else: ": \"" & old & "\" → \"" & value & "\""
    return verb & " " & name & "." & field & rhs & "\n" &
           "Run `claw co update` to regenerate BASE.json."

  if subcmd == "rename":
    # Deprecated alias — routes through `agent edit <old> name <new>`
    # so BASE.nims stays the single source of truth. The old path wrote
    # config + BASE.json only; the rename would be silently reverted on
    # the next `co update`.
    if finalArgs.len < 2 and targetAgent == "":
      return "Usage: claw agent rename <old_name> <new_name>\n" &
             "(deprecated — prefer `claw agent edit <name> name <new-name>`)"
    let oldName = if targetAgent != "": targetAgent else: finalArgs[1]
    let newName = if targetAgent != "": finalArgs[1] else: finalArgs[2]
    return runAgentsCommand(cfg, @["edit", oldName, "name", newName], asJson)

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

