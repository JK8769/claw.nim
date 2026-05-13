import std/[os, strutils, options, json, times, tables]
import jsony
when defined(posix):
  import std/posix

type
  AgentDefaultsConfig* = object
    workspace*: string
    max_tokens*: int
    temperature*: float64
    max_tool_iterations*: int
    stream_intermediary*: bool

  NamedAgentConfig* = object
    name*: string
    api_key*: Option[string]
    job_title*: string         ## Operator-set role label ("Customer Support",
                               ## "Performance Analyst", "Software Engineer").
                               ## Distinct from `role` (which is the trust
                               ## tier — Admin/Staff/Member). Surfaced from
                               ## the DSL `jobTitle` field so runtime tools
                               ## (e.g. collaborate's route action) can score
                               ## peer fitness for a task by job title match.
    provider*: string          ## DEPRECATED — see provider-config-refactor.
                               ## Derived from `models[0]`'s serving
                               ## provider; kept for back-compat readers.
    model*: string             ## DEPRECATED — kept for back-compat readers.
                               ## Same as `models[0]` when set, else the
                               ## company default model.
    models*: seq[string]       ## Phase 2: agent's ordered list of preferred
                               ## models. models[0] is primary, rest are
                               ## fallbacks. Empty → agent inherits company
                               ## default chain.
    max_depth*: int
    system_prompt*: Option[string]
    temperature*: Option[float64]
    thinking*: Option[bool]   ## DeepSeek-V4 (and similar) thinking-mode
                              ## toggle. None = use the model's default
                              ## (currently `enabled` for v4-flash and
                              ## v4-pro). Some(false) = disable thinking
                              ## for faster, cheaper, deterministic
                              ## responses on quick lookups.
    role*: Option[string]
    entity*: string # "AI", "Human", "Corporate"
    identity*: string # "User", "Staff", "Agent", "Customer", "Guest"
    # ClawDSL-resolved capability scoping
    skills*: seq[string]
    practices*: seq[string]  ## competency names — drives team/handbook context injection
    tools*: seq[string]
    deny*: seq[string]
    workstation*: bool
    external*: bool          ## true = identity exists in cortex graph but
                             ## gateway runs no loop. Cognition lives in an
                             ## external runtime (other Claude instance,
                             ## federated peer, etc.) that puppeteers via
                             ## `claw agent send --from <name>` and reads
                             ## the office's mail/ directly.
    heartbeat_seconds*: int  ## 0 = no heartbeat. Positive = cadence in
                             ## seconds for autonomous stateless ticks
                             ## fired by the heartbeat orchestrator.
                             ## See clawdsl.nim's `heartbeat <s>` agent
                             ## directive and
                             ## `services/heartbeat_orchestrator.nim`.

  AgentsSecurityConfig* = object
    allowed_paths*: seq[string]

  AgentsConfig* = object
    defaults*: AgentDefaultsConfig
    security*: AgentsSecurityConfig
    named*: seq[NamedAgentConfig]

  WhatsAppConfig* = object
    enabled*: bool
    bridge_url*: string
    allow_from*: seq[string]

  TelegramConfig* = object
    enabled*: bool
    token*: string
    allow_from*: seq[string]
    notification_only*: bool

  FeishuAppConfig* = object
    enabled*: Option[bool]
    app_id*: string
    # Which agent in this company handles messages from this app.
    # Empty = fall through to the company default (Lexi). Routing
    # happens at channel-receive time: the feishu channel sets
    # InboundMessage.recipient_id = this agent before publishing to
    # the bus, so the gateway dispatches to the right office.
    agent*: string

  FeishuConfig* = object
    enabled*: bool
    stream_intermediary*: bool
    apps*: seq[FeishuAppConfig]
    allow_from*: seq[string]
    require_mention*: bool

  DiscordConfig* = object
    enabled*: bool
    token*: string
    allow_from*: seq[string]

  MaixCamConfig* = object
    enabled*: bool
    host*: string
    port*: int
    allow_from*: seq[string]

  QQConfig* = object
    enabled*: bool
    app_id*: string
    app_secret*: string
    allow_from*: seq[string]

  DingTalkConfig* = object
    enabled*: bool
    client_id*: string
    client_secret*: string
    allow_from*: seq[string]

  NMobileIdentifierConfig* = object
    ## One NKN sub-client slot — `<identifier>.<pubkey>` routes inbound
    ## to the named agent's office. Mirrors `FeishuAppConfig`.
    enabled*: Option[bool]
    identifier*: string
    agent*: string

  NMobileConfig* = object
    enabled*: bool
    stream_intermediary*: bool
    # Legacy fields — kept for back-compat with existing encrypted-wallet
    # deployments. New configs use `seed` (via NKN_WALLET_SEED in .env)
    # plus the `identifiers` list below.
    wallet_json*: string
    password*: string
    identifier*: string
    # New seed-centric model: one seed powers many identifier sub-clients.
    seed*: string                              ## NKN_WALLET_SEED env expansion
    identifiers*: seq[NMobileIdentifierConfig] ## sub-client → agent mapping
    allow_from*: seq[string]
    fcm_key*: string
    push_proxy*: string
    decrypt_ipfs_cache*: Option[bool]
    enable_offline_queue*: bool
    message_ttl_hours*: int
    num_sub_clients*: int
    original_client*: bool
    telegram_push_chat_id*: Option[string]

  ChannelsConfig* = object
    whatsapp*: WhatsAppConfig
    telegram*: TelegramConfig
    feishu*: FeishuConfig
    discord*: DiscordConfig
    maixcam*: MaixCamConfig
    qq*: QQConfig
    dingtalk*: DingTalkConfig
    nmobile*: NMobileConfig


  GatewayConfig* = object
    host*: string
    port*: int

  WebSearchConfig* = object
    api_key*: string
    max_results*: int
    provider*: string
    fallback_providers*: seq[string]

  WebToolsConfig* = object
    search*: WebSearchConfig

  ToolsConfig* = object
    web*: WebToolsConfig

  PeripheralsConfig* = object
    boards*: seq[string]
    datasheet_dir*: string

  TrustRoleConfig* = object
    ## Role definition: trust range + tier + capability grants + prompt.
    ## `tier` classifies the role as internal (company's own people/agents)
    ## or external (customers through guests). New members of a role enter
    ## at `trustMin`; trust drifts within [trustMin, trustMax] thereafter.
    ## Pinned roles use zero-width range (e.g. SuperAdmin = trust 100,100).
    name*: string            ## lower-case role name
    tier*: string            ## "internal" | "external"
    trustMin*: int
    trustMax*: int
    grant*: seq[string]      ## "*" means all tools
    prompt*: string

  TrustConfig* = object
    roles*: seq[TrustRoleConfig]

  FocusMode* = object
    ## Focus-mode declaration loaded from BASE.json. Same canonical
    ## name as the DSL keyword (`focus_mode "Plan":`) and the spawn
    ## tool parameter (`focus_mode: "Plan"`) — one word, one concept,
    ## one place each consumer reads it from.
    name*: string
    description*: string
    uses*: seq[string]
    deny*: seq[string]
    model*: string
    promptAddendum*: string

  UpdatesConfig* = object
    ## Phase 9 — auto-update from upstream claw repo. Default off.
    enabled*: bool                ## false = no scheduled checks (manual `claw co upgrade` still works)
    repo*: string                 ## upstream URL (informational)
    branch*: string               ## default "main"
    check_interval_hours*: int    ## poll cadence in hours
    auto_apply*: bool             ## true = pull+build+restart; false = mail operator
    notify_agent*: string         ## which agent gets the notification

  Config* = object
    default_temperature*: float64
    agents*: AgentsConfig
    channels*: ChannelsConfig
    peripherals*: PeripheralsConfig
    gateway*: GatewayConfig
    tools*: ToolsConfig
    trust*: TrustConfig
    focus_modes*: seq[FocusMode]
    updates*: UpdatesConfig
    refusal*: Table[string, string]
      ## Per-language refusal-message overrides. Keys are BCP-47 lang
      ## tags ("zh", "en", "ja", "ko", ...). Empty if BASE.nims has no
      ## refusal: block. The gateway's refusal lookup consults this
      ## after env CLAW_REFUSAL_<LANG> but before framework defaults.

proc expandHome*(path: string): string =
  if path == "": return path
  if path[0] == '~':
    let home = getHomeDir()
    if path.len > 1 and path[1] == '/':
      return home / path[2..^1]
    return home
  return path

var cachedNimClawDir {.threadvar.}: string

proc resetNimClawDir*() =
  ## Clear the cached NimClaw directory so it's re-resolved on next call.
  cachedNimClawDir = ""

proc getNimClawDir*(): string =
  ## Returns the company directory for the current context. Cached after first call.
  ##
  ## Resolution priority:
  ##   1. $NIMCLAW_DIR env var         — one-off override (scripts, CI, tests)
  ##   2. ~/.config/claw/active        — the "active company" pointer set by
  ##                                     `claw company use <name>`
  ##   3. ~/.nimclawd/<service>/config_dir — legacy pointer file (old layout)
  ##   4. ./.nimclaw                   — dev mode (if CWD has it)
  ##   5. ~/.nimclaw                   — default fallback
  if cachedNimClawDir != "": return cachedNimClawDir

  let envDir = getEnv("NIMCLAW_DIR")
  if envDir != "":
    cachedNimClawDir = envDir
    return cachedNimClawDir

  # 2. Active-context pointer
  let xdgHome = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  let activePath = xdgHome / "claw" / "active"
  if fileExists(activePath):
    try:
      let name = readFile(activePath).strip()
      if name.len > 0:
        # Resolve: bare name → ~/.nimclaw-<name>; already a path → use as-is
        let dir = if name.startsWith("/") or name.startsWith("~"):
          expandHome(name)
        else:
          getHomeDir() / (".nimclaw-" & name)
        if dirExists(dir):
          cachedNimClawDir = dir
          return cachedNimClawDir
    except: discard

  # 3. Legacy pointer file
  let service = getEnv("NIMCLAW_SERVICE", "default")
  let pointerPath = expandHome("~/.nimclawd") / service / "config_dir"
  if fileExists(pointerPath):
    try:
      let dir = readFile(pointerPath).strip()
      if dir.len > 0 and dirExists(dir):
        cachedNimClawDir = dir
        return cachedNimClawDir
    except: discard

  # 4-5. Local or home fallback
  if dirExists("./.nimclaw"):
    cachedNimClawDir = getCurrentDir() / ".nimclaw"
  else:
    cachedNimClawDir = expandHome("~/.nimclaw")
  return cachedNimClawDir
  
proc gatewayPidPath*(): string =
  ## Company-scoped gateway PID path. Each company's gateway writes here on
  ## startup and removes it on clean shutdown, making RUNNING state a simple
  ## per-company file check.
  getNimClawDir() / "logs" / "gateway.pid"

proc isGatewayRunning*(companyDir: string): bool =
  ## Returns true if this company has a live gateway — PID file exists AND
  ## the process is actually alive (not a stale PID).
  let path = companyDir / "logs" / "gateway.pid"
  if not fileExists(path): return false
  try:
    let pid = readFile(path).strip().parseInt()
    if pid <= 0: return false
    when defined(posix):
      # kill(pid, 0) returns 0 if the process exists and we have permission to signal it
      return kill(pid.Pid, 0) == 0
    else:
      return true  # fallback: assume alive if PID file exists
  except: return false

proc gatewayUptimeSeconds*(companyDir: string): int64 =
  ## Seconds since the gateway's PID file was written. Returns 0 if not running.
  ## Uses the PID file's mtime as the start-time proxy — good enough across
  ## macOS/Linux without /proc or proc_pidinfo dependencies.
  if not isGatewayRunning(companyDir): return 0
  let path = companyDir / "logs" / "gateway.pid"
  try:
    let mtime = getLastModificationTime(path)
    let now = now()
    return (now.toTime() - mtime).inSeconds
  except: return 0

proc formatUptime*(secs: int64): string =
  ## Compact uptime: "42s", "12m", "3h12m", "2d4h", "3w", "2mo".
  if secs < 60: return $secs & "s"
  if secs < 3600:
    return $(secs div 60) & "m"
  if secs < 86400:
    let h = secs div 3600
    let m = (secs mod 3600) div 60
    if m == 0: return $h & "h"
    return $h & "h" & $m & "m"
  if secs < 604800:
    let d = secs div 86400
    let h = (secs mod 86400) div 3600
    if h == 0: return $d & "d"
    return $d & "d" & $h & "h"
  if secs < 2592000:  # < 30 days → weeks
    return $(secs div 604800) & "w"
  if secs < 31536000:  # < 1 year → months
    return $(secs div 2592000) & "mo"
  return $(secs div 31536000) & "y"

proc getOpenClawDir*(): string =
  ## Returns the base directory for OpenClaw.
  ## Priority: 
  ## 1. OPENCLAW_DIR environment variable
  ## 2. ~/.openclaw
  let envDir = getEnv("OPENCLAW_DIR")
  if envDir != "": return envDir
  return expandHome("~/.openclaw")

proc getTemplateDir*(): string =
  ## Finds the best source for templates
  # 1. Local project dir (highest priority for development)
  let local = getCurrentDir() / "templates"
  if dirExists(local): return local

  # 2. Next to the binary (release tarballs, nimble builds)
  let binDir = getAppDir() / "templates"
  if dirExists(binDir): return binDir

  # 3. Installed lib dir (curl|sh installs to ~/.local/lib/claw/)
  let libDir = expandHome("~/.local/lib/claw/templates")
  if dirExists(libDir): return libDir

  # 4. Last resort fallback
  return getNimClawDir() / "templates"

proc expandEnvTemplates*(value: string): string =
  ## Expand ${VARNAME} placeholders using the process environment.
  ##
  ## Lets .env values stay portable across machines and mount points:
  ##   ANYGEN_HOME=${NIMCLAW_DIR}/support/anygen
  ## works on internal SSD, on a USB-mounted deployment, on a fresh
  ## machine — no sed-rewrite at each boundary.
  ##
  ## Special-case ${NIMCLAW_DIR}: resolved via getNimClawDir() (which
  ## honors the env-var → active-context → default precedence chain),
  ## so it works even when NIMCLAW_DIR isn't literally in the env.
  ##
  ## Unrecognized variables are left as-is (no error, no warning) so
  ## downstream consumers can decide how to handle them. Fast-path
  ## skips entirely if there's no '${' in the value.
  if "${" notin value: return value
  result = ""
  var i = 0
  while i < value.len:
    if i + 1 < value.len and value[i] == '$' and value[i+1] == '{':
      let close = value.find('}', i + 2)
      if close > i + 2:
        let varName = value[i+2 ..< close]
        let expanded =
          if varName == "NIMCLAW_DIR": getNimClawDir()
          else:
            let v = getEnv(varName, "")
            if v.len > 0: v else: value[i .. close]
        result.add(expanded)
        i = close + 1
        continue
    result.add(value[i])
    inc i

proc loadDotEnv*() =
  ## Load .env files from CWD and NIMCLAW_DIR. Values may contain
  ## ${NIMCLAW_DIR}, ${HOME}, ${USER}, etc. — expanded at load time
  ## via expandEnvTemplates so consumers calling getEnv() see the
  ## resolved string. Cross-process safe: child processes inherit
  ## the expanded values via the OS env.
  let paths = [
    getCurrentDir() / ".env",
    getNimClawDir() / ".env"
  ]
  for envPath in paths:
    if fileExists(envPath):
      for line in readFile(envPath).splitLines():
        let pair = line.split("=", 1)
        if pair.len == 2:
          let key = pair[0].strip()
          let val = pair[1].strip()
          if key.len > 0: putEnv(key, expandEnvTemplates(val))

proc defaultConfig*(): Config =
  result = Config(
    default_temperature: 0.7,
    agents: AgentsConfig(
      defaults: AgentDefaultsConfig(
        workspace: getNimClawDir() / "workspace",
        max_tokens: 4096,
        temperature: 0.7,
        max_tool_iterations: 20,
        stream_intermediary: true
      ),
      security: AgentsSecurityConfig(
        allowed_paths: @[]
      )
    ),
    channels: ChannelsConfig(
      whatsapp: WhatsAppConfig(enabled: false, bridge_url: "ws://localhost:3001"),
      telegram: TelegramConfig(enabled: false, notification_only: false),
      feishu: FeishuConfig(enabled: false, stream_intermediary: false),
      discord: DiscordConfig(enabled: false),
      maixcam: MaixCamConfig(enabled: false, host: "0.0.0.0", port: 18790),
      qq: QQConfig(enabled: false),
      dingtalk: DingTalkConfig(enabled: false),
      nmobile: NMobileConfig(
        enabled: false,
        stream_intermediary: false,
        enable_offline_queue: true,
        message_ttl_hours: 24,
        num_sub_clients: 4,
        original_client: false
      )
    ),
    gateway: GatewayConfig(host: "0.0.0.0", port: 18790),
    tools: ToolsConfig(
      web: WebToolsConfig(
        search: WebSearchConfig(
          api_key: "${BRAVE_API_KEY}",
          max_results: 5,
          provider: "auto",
          fallback_providers: @["duckduckgo"]
        )
      )
    ),
    peripherals: PeripheralsConfig(
      boards: @[],
      datasheet_dir: ""
    )
  )

proc parseEnv*(cfg: var Config) =
  # Simple manual environment variable parsing to match Go's env library.
  # NIMCLAW_AGENTS_DEFAULTS_MODEL and NIMCLAW_MODEL were dropped post-
  # Phase 4 — there's no global default model anymore. Set the agent's
  # `models` list in BASE.nims instead, or use `/model X:Y` from chat.
  if existsEnv("NIMCLAW_AGENTS_DEFAULTS_WORKSPACE"): cfg.agents.defaults.workspace = getEnv("NIMCLAW_AGENTS_DEFAULTS_WORKSPACE")
  if existsEnv("NIMCLAW_AGENTS_DEFAULTS_STREAM_INTERMEDIARY"): cfg.agents.defaults.stream_intermediary = getEnv("NIMCLAW_AGENTS_DEFAULTS_STREAM_INTERMEDIARY") == "true"

  if existsEnv("NIMCLAW_TEMPERATURE"):
    try:
      let temp = parseFloat(getEnv("NIMCLAW_TEMPERATURE"))
      if temp >= 0.0 and temp <= 2.0:
        cfg.default_temperature = temp
    except ValueError:
      discard # ignore invalid floats
  if existsEnv("NIMCLAW_AGENT_MAX_ITERATIONS"):
    try: cfg.agents.defaults.max_tool_iterations = parseInt(getEnv("NIMCLAW_AGENT_MAX_ITERATIONS"))
    except ValueError: discard
    
  if existsEnv("NIMCLAW_ALLOWED_PATHS"):
    let pathsRaw = getEnv("NIMCLAW_ALLOWED_PATHS")
    if pathsRaw.len > 0:
      cfg.agents.security.allowed_paths = pathsRaw.split(";")
      
  if existsEnv("NIMCLAW_GATEWAY_PORT"):
    try:
      cfg.gateway.port = parseInt(getEnv("NIMCLAW_GATEWAY_PORT"))
    except ValueError:
      discard
  if existsEnv("NIMCLAW_GATEWAY_HOST"): cfg.gateway.host = getEnv("NIMCLAW_GATEWAY_HOST")
  if existsEnv("NIMCLAW_WORKSPACE"): cfg.agents.defaults.workspace = getEnv("NIMCLAW_WORKSPACE")

  
  # NKN Secrets
  if existsEnv("NKN_WALLET_PASSWORD"): cfg.channels.nmobile.password = getEnv("NKN_WALLET_PASSWORD")

proc getConfigPath*(): string =
  getNimClawDir() / "config.json"

proc loadConfig*(path: string): Config =
  result = defaultConfig()

  # 1. Try unified BASE.json first (Atomic Preference)
  let unifiedPath = parentDir(path) / "BASE.json"
  if fileExists(unifiedPath):
    try:
      let root = parseFile(unifiedPath)
      if root.hasKey("config"):
        let configNode = root["config"]
        result = ($configNode).fromJson(Config)
        parseEnv(result)
        return result
    except:
      discard

  # 2. Fallback to legacy config.json
  if fileExists(path):
    try:
      let data = readFile(path)
      result = data.fromJson(Config)
    except:
      discard

  parseEnv(result)

proc saveConfig*(path: string, cfg: Config) =
  let dir = parentDir(path)
  if not dirExists(dir):
    createDir(dir)
  
  # Priority: Update BASE.json if it exists
  let unifiedPath = dir / "BASE.json"
  if fileExists(unifiedPath):
    try:
      var root = parseFile(unifiedPath)
      root["config"] = parseJson(cfg.toJson())
      writeFile(unifiedPath, root.pretty())
      return
    except:
      discard
      
  writeFile(path, cfg.toJson())

proc workspacePath*(cfg: Config): string =
  expandHome(cfg.agents.defaults.workspace)
