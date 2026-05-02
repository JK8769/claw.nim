
## gateway — Long-running gateway process: agents, channels, cron.
## Supports --stdio (Zen) and --daemon (headless) modes.

import std/[os, strutils, asyncdispatch, tables, posix, exitprocs, json, algorithm, options, osproc, times, sets, random, unicode]
import curly, webby/httpheaders
import config, logger, bus, bus_types, session, agent/loop, agent/cortex, agent/binding, agent/invites, cli_admin, system_commands
import billing/[subscription as sub_mod, welcome as welcome_mod, company as company_mod, gate as gate_mod, gate_messages as gate_msgs, usage as usage_mod, plants as plants_mod]
import context as claw_context, utils, pricing
import tools/delegate as delegate_tool
import providers/http, providers/types as providers_types, protocol
import channels/[base as channel_base, manager as channel_manager, nmobile as nmobile_channel]
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
  ## Resolve per-agent model + provider overrides from the ClawDSL spec
  ## (e.g. Lexi on kimi-k2.5 @ opencode-go while Atlas stays on deepseek).
  ## Without this, every agent silently inherited `gCtx.provider` and the
  ## `cfg.agents.defaults.model` fallback — defeating BASE.nims's per-agent
  ## `model "…"` / `provider "…"` lines.
  var perAgentProvider = gCtx.provider
  var perAgentModel = ""
  for a in gCtx.cfg.agents.named:
    if a.name.toLowerAscii() != agentName.toLowerAscii(): continue
    if a.model.len > 0: perAgentModel = a.model
    if a.provider.len > 0 and a.provider != gCtx.cfg.default_provider:
      try:
        let graph = loadWorld(gCtx.cfg.workspacePath())
        let resolveModel = if perAgentModel.len > 0: perAgentModel
                           else: gCtx.cfg.agents.defaults.model
        let tech = resolveProviderTech(resolveModel, a.provider,
                                       graph.providers,
                                       providerOverride = a.provider)
        if tech.apiBase.len > 0 and tech.apiKey.len > 0:
          perAgentProvider = createProvider(tech.model, tech.apiKey, tech.apiBase)
          infoCF("gateway", "Per-agent provider override",
            {"agent": agentName, "provider": a.provider,
             "model": tech.model, "apiBase": tech.apiBase}.toTable)
        else:
          warnCF("gateway", "Per-agent provider override skipped — missing apiBase or apiKey",
            {"agent": agentName, "provider": a.provider}.toTable)
      except CatchableError as e:
        warnCF("gateway", "Per-agent provider resolve failed",
          {"agent": agentName, "provider": a.provider, "error": e.msg}.toTable)
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

proc resolveCallerPermission(cfg: ref Config, msg: InboundMessage): Permission =
  ## Resolve the caller's declared entity permission into one of four
  ## tiers (pmSuperAdmin > pmAdmin > pmInternal > pmAny). The entry
  ## gate accepts pmInternal+; per-subcommand checks tighten further
  ## (e.g. /user bind needs pmSuperAdmin, /user add needs pmAdmin).
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
  # Admin/SuperAdmin get their own tier; defer the broader internal-vs-
  # external check to `tierFromRoleName` so the role-string list lives
  # in one place (cli_admin.nim, mirroring clawdsl.nim's tier inference).
  case p
  of "superadmin": pmSuperAdmin
  of "admin":      pmAdmin
  else:
    if tierFromRoleName(p) == "int": pmInternal
    else: pmAny

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
             "  `/session status <agent>`\n" &
             "    Regular user: show YOUR session's context utilisation\n" &
             "    with that agent — message count, token estimate,\n" &
             "    % of context window, threshold.\n" &
             "    🔒 Admin: show ALL of the agent's sessions across all\n" &
             "    users (operator overview, sorted by token weight).\n" &
             "    Example: `/session status lexi`\n\n" &
             "  `/session status <agent> <nc:id>`\n" &
             "    Detail view of a specific session. 🔒 Admin required\n" &
             "    if the nc:id isn't your own.\n" &
             "    Example: `/session status lexi nc:5`\n\n" &
             "  `/session clear <agent>`\n" &
             "    Clear YOUR session with that agent. The agent will\n" &
             "    forget your conversation history on next turn.\n" &
             "    Example: `/session clear lexi`\n\n" &
             "  `/session clear <agent> <nc:id>`   🔒 Admin\n" &
             "    Clear another user's session with that agent. Useful\n" &
             "    for resetting test conversations or recovering from\n" &
             "    corrupted state.\n" &
             "    Example: `/session clear lexi nc:7`\n\n" &
             "Note: clears the conversation, NOT the agent's `memory_store`\n" &
             "entries (those persist by design — that's their purpose)."
    let sub = parts[1]
    if sub == "status":
      if parts.len < 3:
        return "Usage: `/session status <agent>` (Admin+: all sessions; " &
               "regular: your own) or `/session status <agent> <nc:id>` " &
               "(specific session, Admin+ if not your own)."
      let agentName = parts[2]
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
        var callerNc = ""
        let workspace0 = cfg[].workspacePath()
        let g0 = loadWorld(workspace0)
        if g0 != nil:
          let channelKey0 =
            if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
              msg.channel & ":" & msg.metadata["app_id"]
            else: msg.channel
          let (entID0, _) = g0.resolveUserGraph(channelKey0, msg.sender_id)
          if uint32(entID0) > 0:
            callerNc = toAlias(entID0)
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
        var targetNc = ""
        let workspace = cfg[].workspacePath()
        let g = loadWorld(workspace)
        if g != nil:
          let channelKey =
            if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
              msg.channel & ":" & msg.metadata["app_id"]
            else: msg.channel
          let (entID, _) = g.resolveUserGraph(channelKey, msg.sender_id)
          if uint32(entID) > 0:
            targetNc = toAlias(entID)
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
      # Resolve target nc:id. With no arg, it's the caller's own.
      var targetNc = ""
      if parts.len >= 4:
        if callerPermGate < pmAdmin:
          return "Only Admin or SuperAdmin can clear another user's " &
                 "session. (Use `/session clear " & agentName &
                 "` to clear your own.)"
        if not parts[3].startsWith("nc:"):
          return "Error: third argument must be an `nc:id` " &
                 "(e.g. `nc:7`), got `" & parts[3] & "`."
        targetNc = parts[3]
      else:
        # Resolve caller to nc:id via the same path as resolveCallerPermission.
        let workspace = cfg[].workspacePath()
        let g = loadWorld(workspace)
        if g != nil:
          let channelKey =
            if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
              msg.channel & ":" & msg.metadata["app_id"]
            else: msg.channel
          let (entID, _) = g.resolveUserGraph(channelKey, msg.sender_id)
          if uint32(entID) > 0:
            targetNc = toAlias(entID)
        if targetNc == "":
          return "Couldn't resolve your own `nc:id` from this channel. " &
                 "If you're an Admin clearing someone else's session, " &
                 "pass their nc:id explicitly: " &
                 "`/session clear " & agentName & " nc:N`."
      # The session manager keys on `nc_<num>` (underscore form), not
      # `nc:<num>` (colon form used in display).
      let sessionKey = targetNc.replace(":", "_")
      al2.sessions.clearSession(sessionKey)
      return "Cleared **" & agentName & "**'s session with `" &
             targetNc & "` (key `" & sessionKey & "`).\n\n" &
             "On the next message, the agent starts a fresh thread — " &
             "no prior history, no carried-over summary. " &
             "`memory_store` entries are untouched."
    return "Unknown /session subcommand: `" & sub & "`.\n" &
           "Try `/session clear <agent>` or `/session help`."

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
    name: "/reset", summary: "Clear the current session's history.",
    usage: "/reset", group: "agent-control",
    menuHint: "New session", permission: pmAny,
    examples: @["/reset"]))
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
    name: "/user", summary: "User management (list, show, trust, add, edit, bind, invite, remove).",
    usage: "/user <list|show|trust|add|edit|bind|invite|remove> [<args>...]",
    doc: """User management.

Usage:
  /user list [--kind=<k>] [--tier=<t>] [--permission=<p>] [--sort=<s>] [--reverse] [--format=<f>]
  /user show <nc-id>
  /user trust
  /user add <name> [--permission=<p>]
  /user edit <nc-id> <field> <value>
  /user bind <nc-id> [--wipe]
  /user rebind <nc-id> [--wipe]
  /user invite <customer-name> [<agent>] [<uses>] [--lang=<l>] [--skill=<s>]... [--skills=<cs>]
  /user remove <nc-id>

Options:
  --kind=<k>        Person | AI | Unknown | Service
  --tier=<t>        int | ext | ?
  --permission=<p>  Filter (`list`) or assign (`add`) a permission/role
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
                "/user add Anna --permission=Member",
                "/user edit nc:7 permission Member",
                "/user bind nc:7",
                "/user rebind nc:7",
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
    summary: "Clear conversation state with an agent. Wipes session JSONL + meta on disk; `memory_store` entries are untouched.",
    usage: "/session clear <agent> [<nc:id>]",
    group: "admin", menuHint: "Clear session",
    permission: pmInternal,
    examples: @["/session clear lexi", "/session clear lexi nc:7"]))
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
            let channelKey3 =
              if msg.metadata.hasKey("app_id") and msg.metadata["app_id"].len > 0:
                msg.channel & ":" & msg.metadata["app_id"]
              else: msg.channel
            var entID = WorldEntityID(0)
            let (rid, _) = g3.resolveUserGraph(channelKey3, msg.sender_id)
            if uint32(rid) > 0:
              entID = rid
            elif msg.channel == "feishu":
              let uid = msg.metadata.getOrDefault("union_id", "")
              if uid.len > 0:
                let (x, _) = g3.resolveUserGraph("feishu:union", uid)
                if uint32(x) > 0: entID = x
              if uint32(entID) == 0:
                let usid = msg.metadata.getOrDefault("user_id", "")
                if usid.len > 0:
                  let (x, _) = g3.resolveUserGraph("feishu:user", usid)
                  if uint32(x) > 0: entID = x
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
            # control, not conversation. They're accepted ONLY when the
            # message is addressed to the company (corporate entity).
            # A customer DMing `atlas.<pubkey>` or `cli_<app>_agent` with
            # `/restart` gets silently dropped; the agent never sees it
            # and the gateway doesn't act on it. The company main-line
            # address is the single intended surface for these commands.
            # Slash commands accepted only when addressed to the
            # company surface — same `companyRoute` flag computed at
            # the top of the loop, no need to re-resolve.
            if not companyRoute:
              infoCF("claw", "Dropped slash command — not routed to company",
                     {"sender": msg.sender_id,
                      "recipient": msg.recipient_id,
                      "channel": msg.channel,
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
