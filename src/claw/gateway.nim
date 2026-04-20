
## gateway — Long-running gateway process: agents, channels, cron.
## Supports --stdio (Zen) and --daemon (headless) modes.

import std/[os, strutils, asyncdispatch, tables, posix, exitprocs, json, algorithm, options, osproc, times, sets, random, unicode]
import curly, webby/httpheaders
import config, logger, bus, bus_types, session, agent/loop, agent/cortex, agent/binding, agent/invites, cli_admin, system_commands
import context as claw_context, utils
import tools/delegate as delegate_tool
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

# Forward declaration so askPeer closure can reference the office-lookup
# helper before it's defined.
proc ensureOffice(agentName: string): AgentLoop

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
  newAgentLoop(gCtx.cfg, gCtx.msgBus, gCtx.provider, agentName,
               gCtx.cronService, askPeer = askPeerImpl)

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
  debugCF("cronHandler", "Triggering job", {"id": job.id}.toTable)

  let agentName = if job.payload.agentName != "": job.payload.agentName else: "Lexi"
  let officeKey = agentName.toLowerAscii()

  if job.payload.deliver:
    gCtx.msgBus.publishOutbound(newOutbound(job.payload.channel, agentName, job.payload.to, job.payload.message))
  else:
    if not gCtx.offices.hasKey(officeKey):
      gCtx.offices[officeKey] = makeAgentLoop(agentName)
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
    let tech = resolveProviderTech(
      cfg[].agents.defaults.model, cfg[].default_provider,
      graph.providers, providerOverride = cfg[].default_provider)
    if tech.apiBase == "" or tech.apiKey == "": return src
    let provider = createProvider(tech.model, tech.apiKey, tech.apiBase)
    let sysPrompt = "You are a terse translator. Translate the user's " &
                    "English text into the target language. Keep inline " &
                    "code spans, URLs, and code blocks EXACTLY as-is. " &
                    "Output only the translation, no preamble."
    let userPrompt = "Target language: " & lang &
                     "\n\nEnglish text to translate:\n" & src
    let messages = @[
      providers_types.Message(role: "system", content: sysPrompt),
      providers_types.Message(role: "user", content: userPrompt)]
    var options = initTable[string, JsonNode]()
    options["temperature"] = %0.2
    let response = await provider.chat(messages, @[], tech.model, options)
    if response.content.len > 0:
      return src & "\n\n" & response.content
    return src
  except:
    return src

proc resolveCallerPermission(cfg: ref Config, msg: InboundMessage): Permission =
  ## Resolve the caller's declared entity permission. SuperAdmin/Admin
  ## return pmSuperAdmin; everyone else returns pmAny.
  let workspace = cfg[].workspacePath()
  let graph = loadWorld(workspace)
  if graph == nil: return pmAny
  let channelKey =
    if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
      msg.channel & ":" & msg.metadata["app_id"]
    else: msg.channel
  let (entID, _) = graph.resolveUserGraph(channelKey, msg.sender_id)
  if uint32(entID) == 0 or not graph.entities.hasKey(entID):
    return pmAny
  let p = graph.entities[entID].role.toLowerAscii
  if p in ["superadmin", "admin"]: return pmSuperAdmin
  pmAny

proc handleSystemCommand(cfg: ref Config, msg: InboundMessage, al: AgentLoop): Future[string] {.async.} =
  let cmd = msg.content.strip()
  # Single gate at the entry: system commands are operator tools, not
  # a customer-facing API. Every `/…` goes through here, so one check
  # covers the entire slash surface. Non-admin callers get a polite
  # refusal that doesn't leak which commands exist.
  let callerPermGate = resolveCallerPermission(cfg, msg)
  if callerPermGate != pmSuperAdmin:
    return "System commands (`/status`, `/user …`, `/channel …`, etc.) " &
           "are restricted to operators. Ask a SuperAdmin if you need " &
           "something administrative done."
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
  elif cmd.startsWith("/user"):
    # Namespace for user management: `/user <subcmd> [<args>...]`.
    # Entry gate already confirmed SuperAdmin — dispatch through
    # runUserCommand / mintCustomerInvite so CLI and chat share the
    # same backend. `/user invite` rewrites to the `/invite` alias
    # below for presentation-layer formatting.
    let rawParts = strutils.splitWhitespace(cmd)
    let argv = if rawParts.len > 1: rawParts[1 .. ^1] else: @[]
    if argv.len == 0 or argv[0] == "help":
      return renderCommandDetail("/user")
    let pr = parseArgs("/user", cmd, argv)
    if not pr.ok: return pr.error
    let parts = rawParts
    if parts.len < 2 or parts[1] == "help":
      return "**`/user` — user management**\n\n" &
             "**Subcommands**\n\n" &
             "  `/user list` [filters]\n" &
             "    Roster of all users in this company. Filters:\n" &
             "      `--kind=<Person|AI|Unknown|Service>`\n" &
             "      `--tier=<int|ext|?>`\n" &
             "      `--permission=<role>`\n" &
             "      `--sort=<nc|name|kind|permission|tier|role>`\n" &
             "      `--reverse`  `--format=<table|json>`\n" &
             "    Example: `/user list --kind=Unknown` (guests to classify)\n\n" &
             "  `/user show <nc:id>`\n" &
             "    Detailed view of one user — declared permission, tier,\n" &
             "    job title, every identifier, outbound + inbound\n" &
             "    relationships (trust + etiquette), mood for agents.\n" &
             "    Example: `/user show nc:4`\n\n" &
             "  `/user trust`\n" &
             "    Edge list of the trust graph: one row per declared\n" &
             "    agent→person edge (agent, edge kind, person, tier,\n" &
             "    role, trust, etiquette). Shows per-agent divergence\n" &
             "    that `/user list` collapses.\n" &
             "    Example: `/user trust`\n\n" &
             "  `/user invite <customer-name> [<agent>] [<uses>]`   🔒 SuperAdmin\n" &
             "    Pre-allocates a Customer Person entity + mints a\n" &
             "    one-shot access code (`nc:X/CODE`). Returns three\n" &
             "    paste-ready sentence templates the customer can\n" &
             "    forward to their channel. On first message, the\n" &
             "    gateway authenticates them before the LLM.\n" &
             "    Examples:\n" &
             "      `/user invite Alice`          — Atlas, 1 use\n" &
             "      `/user invite Acme Atlas 3`   — Atlas, 3 redemptions\n\n" &
             "  `/user remove <nc:id>`   🔒 SuperAdmin\n" &
             "    Deletes an entity from the graph AND from BASE.nims\n" &
             "    (person block + any reportsTo/serves references\n" &
             "    cascaded). Prefer this over manual DSL edits for\n" &
             "    cleaning up stale Unknown auto-registers or dupes.\n" &
             "    Example: `/user remove nc:7`\n\n" &
             "All `/user` subcommands (and every `/` system command)\n" &
             "are restricted to SuperAdmin / Admin callers."
    let sub = parts[1]
    let subArgs = if parts.len > 2: parts[2 .. ^1] else: @[]
    # Entry gate has already confirmed SuperAdmin, so all subs are
    # permitted. Routes through the same runUserCommand / mintCustomer-
    # Invite paths the CLI uses — single source of truth. Output is
    # wrapped in a code block so column-aligned tables survive Feishu
    # markdown; JSON output opts out so machine use stays raw.
    if sub in ["list", "show", "trust", "remove"]:
      var cfgCopy = cfg[]
      let body = runUserCommand(cfgCopy, @[sub] & subArgs)
      let wantsJson = "--format=json" in subArgs or "--json" in subArgs
      if wantsJson: return body
      return codeBlock(body)
    if sub == "invite":
      # Rewrite to the legacy /invite alias below — same helper path,
      # chat-specific paste-template formatting.
      let cmdRewrite = "/invite " & subArgs.join(" ")
      var fakeMsg = msg
      fakeMsg.content = cmdRewrite
      return await handleSystemCommand(cfg, fakeMsg, al)
    return "Unknown /user subcommand: `" & sub & "`.\n" &
           "Try `/user list`, `/user show <nc:id>`, `/user trust`, " &
           "`/user remove <nc:id>`, or `/user invite <name>`."

  elif cmd.startsWith("/invite"):
    # Legacy alias for `/user invite`. Entry gate already confirmed
    # SuperAdmin; we only need the caller's nc:id here for invite
    # provenance (the `issuedBy` field on InviteConstraint).
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
      except: discard
    let inv = mintCustomerInvite(cfg[], workspace, issuer, customerName,
                                  agentName, maxUses, allowedSkills)
    if not inv.ok:
      return "Error: " & inv.error
    # Feishu spam filter tolerates natural sentences better than bare
    # codes; give the SuperAdmin three paste-ready options at different
    # verbosity levels — intercept matches on substring.
    var paste1 = "Hi — my access code is " & inv.code &
                 ", please activate. Thanks!"
    var paste2 = inv.customerName & " here. My invite code: " & inv.code & "."
    let paste3 = inv.targetNcId & "/" & inv.code   # never translate — structural
    # Translate the two natural-sentence templates into the customer's
    # language (when specified), so the SuperAdmin can copy-paste
    # directly. paste3 stays as-is — it's a machine string, not prose.
    # The code value must survive translation unchanged: use a
    # placeholder then swap back in.
    if targetLang.len > 0 and targetLang.toLowerAscii notin ["en", "en-us"]:
      let placeholder = "§§CODE§§"
      proc tr(src, lang: string): Future[string] {.async.} =
        let srcHidden = src.replace(inv.code, placeholder)
        let res = await maybeTranslate(cfg, srcHidden, "", lang)
        # maybeTranslate appends translation to src; keep only the
        # translated tail (after the first \n\n).
        let sep = res.find("\n\n")
        let tail = if sep >= 0: res[sep + 2 .. ^1] else: res
        return tail.replace(placeholder, inv.code)
      try:
        paste1 = await tr(paste1, targetLang)
        paste2 = await tr(paste2, targetLang)
      except: discard
    return "**Customer invite created**\n\n" &
           codeBlock("Customer: " & inv.customerName & " (" & inv.targetNcId & ")\n" &
                     "Agent:    " & inv.agentName & "\n" &
                     "Max uses: " & $inv.maxUses &
                     (if inv.allowedSkills.len > 0:
                        "\nSkills:   " & inv.allowedSkills.join(", ")
                      else: "") &
                     (if targetLang.len > 0: "\nLanguage: " & targetLang else: "")) & "\n\n" &
           "**Share one of these with the customer** (Feishu may block\n" &
           "bare codes — wrapping in a sentence usually passes):\n\n" &
           codeBlock(paste1) & "\n" &
           codeBlock(paste2) & "\n" &
           codeBlock(paste3) & "\n\n" &
           "The customer DMs their chosen text to any channel routing " &
           "to " & inv.agentName & ". Gateway authenticates pre-LLM — " &
           "substring match, so any message containing `" & inv.code &
           "` works."

  elif cmd == "/help" or cmd.startsWith("/help "):
    # Entry gate confirms SuperAdmin, so show everything (no 🔒 filter).
    let parts = strutils.splitWhitespace(cmd)
    if parts.len >= 2:
      return renderCommandDetail(parts[1])
    return renderHelp(pmSuperAdmin)

  elif cmd.startsWith("/channel"):
    # `/channel auth feishu <app_id> <app_secret> [<agent>]`
    # `/channel list`
    # Entry gate already confirmed SuperAdmin.
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
    # Currently one subcommand: `/co update` — rebuild BASE.json from
    # BASE.nims WITHOUT restarting. For the combined rebuild+restart
    # flow, use `/restart` (which now rebuilds first on its own).
    let parts = strutils.splitWhitespace(cmd)
    let sub = if parts.len > 1: parts[1] else: ""
    if sub != "update":
      return "Usage: `/co update` — rebuild BASE.json from BASE.nims.\n" &
             "For rebuild + restart in one step, use `/restart`."
    let (ok, output) = rebuildBaseJson(getNimClawDir())
    if ok:
      return "✅ BASE.json rebuilt from BASE.nims. Changes take effect on " &
             "next `/restart`.\n\n" &
             (if output.strip().len > 0: codeBlock(output) else: "")
    else:
      return "❌ BASE.nims rebuild failed — BASE.json NOT updated. Fix the " &
             "error below and retry:\n\n" & codeBlock(output)

  elif cmd == "/agent" or cmd == "/agents" or
       cmd.startsWith("/agent ") or cmd.startsWith("/agents "):
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
    if sub == "list":
      var rows: seq[string] = @["AGENT       STATE       ITER   ELAPSED     TOKENS      LAST TOOL            OUTCOME"]
      for a in cfg.agents.named:
        let key = a.name.toLowerAscii()
        let namePad = a.name.alignLeft(12)
        if not gCtx.offices.hasKey(key):
          rows.add(namePad & "OOO".alignLeft(12) & "-".alignLeft(7) & "-".alignLeft(12) &
                   "-".alignLeft(12) & "-".alignLeft(21) & "out-of-office")
          continue
        let al2 = gCtx.offices[key]
        let toolStr =
          if al2.liveLastTool.len > 0: al2.liveLastTool
          elif al2.liveStartedAt > 0.0: "(no tool yet)"
          else: "-"
        let tokStr = fmtTokens(al2.liveTokensTotal)
        let (state, iterStr, elStr, outcome) =
          if al2.liveStartedAt == 0.0:
            if al2.liveTurnCount == 0:
              ("In-Office", "-", "-", "never-ran")
            else:
              ("In-Office",
               $al2.liveIteration & "/" & $al2.maxIterations,
               fmtUptime(now - al2.liveFinishedAt) & " ago",
               (if al2.liveLastError.len > 0: "❌ " & shortErr(al2.liveLastError)
                else: "✓ ok (turn " & $al2.liveTurnCount & ")"))
          else:
            ("Working",
             $al2.liveIteration & "/" & $al2.maxIterations,
             fmtUptime(now - al2.liveStartedAt),
             (if al2.liveLastError.len > 0: "(last ❌ " & shortErr(al2.liveLastError) & ")"
              else: "running"))
        rows.add(namePad & state.alignLeft(12) & iterStr.alignLeft(7) &
                 elStr.alignLeft(12) & tokStr.alignLeft(12) &
                 toolStr.alignLeft(21) & outcome)
      return codeBlock(rows.join("\n"))
    let name = sub
    let key = name.toLowerAscii()
    if not gCtx.offices.hasKey(key):
      return "**Agent " & name & "** — Out-of-Office (office not opened this session)."
    let al2 = gCtx.offices[key]
    var lines: seq[string] = @[]
    if al2.liveStartedAt == 0.0:
      # In-Office — show last-turn post-mortem
      if al2.liveTurnCount == 0:
        return "**Agent " & name & "** — In-Office, hasn't taken a turn yet."
      let sinceStr = fmtUptime(now - al2.liveFinishedAt)
      lines.add("State:      In-Office (last turn " & sinceStr & " ago)")
      lines.add("Last msg:   " & al2.liveLastMessagePreview)
      lines.add("Iterations: " & $al2.liveIteration & "/" & $al2.maxIterations)
      if al2.liveLastTool.len > 0:
        lines.add("Last tool:  " & al2.liveLastTool)
      if al2.liveToolLog.len > 0:
        lines.add("Tool log:   " & al2.liveToolLog.join(" → "))
      if al2.liveLastError.len > 0:
        lines.add("Outcome:    ❌ " & al2.liveLastError)
      else:
        lines.add("Outcome:    ✓ ok")
      if al2.liveTokensTurn > 0:
        lines.add("Tokens:     " & $al2.liveTokensTurn & " (last turn)")
      lines.add("Total turns since boot:  " & $al2.liveTurnCount)
      lines.add("Total tokens since boot: " & $al2.liveTokensTotal)
    else:
      let elapsed = now - al2.liveStartedAt
      lines.add("State:      Working")
      lines.add("Session:    " & al2.liveSessionKey)
      lines.add("Sender:     " & al2.liveSenderID)
      lines.add("Message:    " & al2.liveMessagePreview)
      lines.add("Iteration:  " & $al2.liveIteration & "/" & $al2.maxIterations)
      lines.add("Elapsed:    " & fmtUptime(elapsed))
      if al2.liveLastTool.len > 0:
        lines.add("Last tool:  " & al2.liveLastTool)
      if al2.liveToolLog.len > 0:
        lines.add("Tool log:   " & al2.liveToolLog.join(" → "))
      if al2.liveLastError.len > 0:
        lines.add("Prev error: " & al2.liveLastError)
      if al2.liveTokensTurn > 0:
        lines.add("Tokens:     " & $al2.liveTokensTurn & " (this turn so far)")
      lines.add("Total turns since boot:  " & $al2.liveTurnCount)
      lines.add("Total tokens since boot: " & $al2.liveTokensTotal)
    return "**Agent " & name & "**\n\n" & codeBlock(lines.join("\n"))

  elif cmd == "/restart":
    # SuperAdmin-only: stop the current gateway and launch a fresh one
    # so config/DSL changes (e.g. a freshly added Feishu app) take
    # effect without dropping to a terminal. Entry gate confirmed
    # SuperAdmin already.
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
  if useStdio: logger.stdioMode = true
  if debug: setLevel(DEBUG)

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
    name: "/reset", summary: "Clear the current session's history.",
    usage: "/reset", group: "agent-control",
    menuHint: "New session", permission: pmAny,
    examples: @["/reset"]))
  register(SystemCommand(
    name: "/stream", summary: "Toggle intermediary thought streaming.",
    usage: "/stream <on|off>", group: "agent-control",
    permission: pmSuperAdmin,
    args: @[CmdArg(name: "value", description: "on or off", required: true)],
    examples: @["/stream on", "/stream off"]))
  register(SystemCommand(
    name: "/model", summary: "Switch model, or list known models.",
    usage: "/model [<provider:model> | list [<provider>]]",
    group: "agent-control", permission: pmSuperAdmin,
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
    group: "admin", menuHint: "Channels", permission: pmSuperAdmin,
    examples: @["/channel list",
                "/channel auth feishu cli_a93085a978781cd5 SECRET Atlas",
                "/channel assign cli_a948ea9ee5785cd3 Atlas"]))
  register(SystemCommand(
    name: "/user", summary: "User management (list, show, trust, invite, remove).",
    usage: "/user <list|show|trust|invite|remove> [<args>...]",
    doc: """User management.

Usage:
  /user list [--kind=<k>] [--tier=<t>] [--permission=<p>] [--sort=<s>] [--reverse] [--format=<f>]
  /user show <nc-id>
  /user trust
  /user invite <customer-name> [<agent>] [<uses>] [--lang=<l>] [--skill=<s>]... [--skills=<cs>]
  /user remove <nc-id>

Options:
  --kind=<k>        Person | AI | Unknown | Service
  --tier=<t>        int | ext | ?
  --permission=<p>  Filter by declared permission
  --sort=<s>        nc | name | kind | permission | tier | role
  --reverse         Reverse sort order
  --format=<f>      table | json  [default: table]
  --lang=<l>        Customer's language for paste templates (zh, en, ja, ko, ru, ar, ...)
  --skill=<s>       Allowed skill grant (repeatable) — `[user@]skill[/res,...]`
  --skills=<cs>     Comma-separated shorthand for --skill
""",
    group: "admin", menuHint: "Users", permission: pmAny,
    examples: @["/user list --kind=Unknown",
                "/user show nc:4",
                "/user trust",
                "/user invite Alice",
                "/user invite Acme Atlas 1",
                "/user invite Alice --lang=zh",
                "/user invite JK Atlas --skill=njmkuser@sungrow/627305",
                "/user invite Acme Atlas --skills=njmkuser@sungrow/627305,njmkuser@sungrow/627306",
                "/user remove nc:7"]))
  register(SystemCommand(
    name: "/agent",
    summary: "Live agent state — WORKING/idle, current iteration, last tool, elapsed time. `/agent list` for all, `/agent <name>` for detail.",
    usage: "/agent [<name>|list]", group: "admin",
    menuHint: "Agent state", permission: pmSuperAdmin,
    examples: @["/agent list", "/agent Atlas", "/agent Lexi"]))
  register(SystemCommand(
    name: "/restart",
    summary: "Rebuild BASE.json from BASE.nims AND restart the gateway. Fails safely if the rebuild errors — the running gateway stays up.",
    usage: "/restart", group: "admin",
    menuHint: "Restart gateway", permission: pmSuperAdmin,
    examples: @["/restart"]))
  register(SystemCommand(
    name: "/co",
    summary: "Company management. `/co update` rebuilds BASE.json from BASE.nims without restarting — changes take effect on the next `/restart`.",
    usage: "/co update", group: "admin",
    menuHint: "Company update", permission: pmSuperAdmin,
    examples: @["/co update"]))

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
    gCtx.offices["lexi"] = makeAgentLoop("Lexi")
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

  # Per-session task chain — prevents same-session message interleaving while
  # letting different sessions run in parallel. The main loop always spawns;
  # it never awaits processMessage inline. Keyed by session_key.
  var sessionTails = initTable[string, Future[void]]()

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
            let en = "\u{2713} Bound to " & b.targetName & " (" & b.targetNcId &
                     ", SuperAdmin). You're now authenticated on this channel."
            response = await maybeTranslate(cfg, en, plainContent)
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
                  let enReply = "\u{2713} Welcome, " & ent.name & ". You're " &
                                "authenticated as a Customer (" & inv.targetNcId &
                                "). Ask me anything — I'm here to help."
                  response = await maybeTranslate(cfg, enReply, plainContent)
                  stderr.writeLine "claw: customer-invite redeemed " &
                                   inv.targetNcId & " via " & channelKey &
                                   " ← " & msg.sender_id

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
          let workspace2 = cfg[].workspacePath()
          let g2 = loadWorld(workspace2)
          let channelKey2 =
            if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
              msg.channel & ":" & msg.metadata["app_id"]
            else: msg.channel
          var recognized = false
          if g2 != nil:
            let (entID, _) = g2.resolveUserGraph(channelKey2, msg.sender_id)
            if uint32(entID) > 0: recognized = true
            if not recognized and msg.channel == "feishu":
              let uid = msg.metadata.getOrDefault("union_id", "")
              if uid.len > 0:
                let (x, _) = g2.resolveUserGraph("feishu:union", uid)
                if uint32(x) > 0: recognized = true
              if not recognized:
                let usid = msg.metadata.getOrDefault("user_id", "")
                if usid.len > 0:
                  let (x, _) = g2.resolveUserGraph("feishu:user", usid)
                  if uint32(x) > 0: recognized = true
          if not recognized:
            stderr.writeLine "claw: refused unknown sender " & channelKey2 &
                             " ← " & msg.sender_id
            # Zero-LLM refusal: pick from a pre-translated catalog
            # based on detected script in the stranger's own message.
            # An English-ish message gets English; Chinese gets
            # Chinese; unsupported scripts fall back to a bilingual
            # EN+ZH template (SunGrow's primary customer base).
            let lang = detectLang(plainContent)
            response =
              if refusalByLang.hasKey(lang): refusalByLang[lang]
              else: refusalByLang["en"] & "\n\n" & refusalByLang["zh"]

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
            # Fast path: system commands run in a spawned task so they
            # don't block the main inbound loop behind a 10-60s agent
            # turn on an unrelated chat. These handlers are read-only
            # (or fork-and-forget like /restart), so concurrent execution
            # with an in-flight agent run is safe.
            let cMsg = msg
            let cPlain = plainContent
            let cRecipient = recipient
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
                  msgBus.publishOutbound(newOutbound(cMsg.channel, cRecipient,
                                                     cMsg.chat_id, r,
                                                     appID = appID,
                                                     metadata = fMeta))
                  statusEmitter.emitChannelMsg(cMsg.channel, "out", cRecipient)
              except Exception as e:
                errorCF("claw", "System-command fast-path error",
                        {"error": e.msg}.toTable)
            )()
            # Leave response = "" so the main path's publish is skipped;
            # the spawned task owns the reply. Main loop continues to
            # consume the next inbound immediately.
          else:
            # Chain-spawn processMessage so the main loop never awaits a
            # 10-60s agent turn. Per-session chaining preserves the
            # serialize-writes-to-one-session-file invariant while letting
            # different sessions (e.g. Atlas/nc_3 and Lexi/nc_7) run in
            # parallel. The new task's reply publishes on its own when done.
            let cMsg = msg
            let cRecipient = recipient
            let cOffice = officeKey
            let sessionKey = msg.session_key
            let prevTail =
              if sessionTails.hasKey(sessionKey): sessionTails[sessionKey]
              else: nil
            var newTail: Future[void]
            newTail = (proc() {.async.} =
              try:
                if prevTail != nil and not prevTail.finished:
                  try: await prevTail except: discard
                let r = await gCtx.offices[cOffice].processMessage(cMsg)
                if r != "":
                  var fMeta = initTable[string, string]()
                  fMeta["final"] = "true"
                  let appID = cMsg.metadata.getOrDefault("app_id", "")
                  msgBus.publishOutbound(newOutbound(cMsg.channel, cRecipient,
                                                     cMsg.chat_id, r,
                                                     appID = appID,
                                                     metadata = fMeta))
                  statusEmitter.emitChannelMsg(cMsg.channel, "out", cRecipient)
              except Exception as e:
                errorCF("claw", "Session task error",
                        {"error": e.msg, "session": cMsg.session_key}.toTable)
              # Drop our entry if we're still the tail — prevents the
              # Table from growing unbounded across many one-off chats.
              # Guarded by identity so a newer chained task isn't wiped.
              if sessionTails.getOrDefault(sessionKey) == newTail:
                sessionTails.del(sessionKey)
            )()
            sessionTails[sessionKey] = newTail

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
