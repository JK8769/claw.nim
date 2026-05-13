## Tool manifest — single source of truth for all framework tools.
##
## Every framework tool that's registered with the runtime registry
## (i.e. agent-callable, not internal sub-tools) MUST have an entry
## in `AllTools` below. The manifest aggregates the metadata that
## was previously scattered across:
##
##   1. Tool source files (`method name*` declares the canonical name)
##   2. `agent/loop.nim` (`regTagged(...)` declares tags + search hint)
##   3. `clawdsl.nim::defaultTools` (which tools every agent gets)
##   4. `tools/registry.nim::HeartbeatAllowedTools` (which tools fire
##      during heartbeat ticks, where the system sender has low trust)
##   5. `cli_admin.nim` capability display strings
##
## Now: ONE file. `defaultToolNames()` and `heartbeatSafeToolNames()`
## derive their lists from this. The manual constants in clawdsl.nim
## and registry.nim are replaced with calls to those procs.
##
## Boot-time validation (`validateAgainstRegistry`) checks that every
## entry here has a matching live registration, and every live tool
## has a manifest entry. Drift between source (`method name*`),
## registration (`regTagged`), and this manifest is caught at boot.
##
## Adding a new tool: (1) drop the source file, (2) regTagged in
## loop.nim, (3) add an entry here. Three places, all in the same PR.
## Eventually each tool source file will also carry a `ToolSpec*` const
## (the per-file SSoT design); for now the manifest is canonical and
## the optional per-file consts are a redundancy check.

import std/[options, tables]
import ../spec

# ── The canonical list of every framework-shipped tool ────────────

const AllTools*: seq[ToolSpec] = @[
  # Files — sea / ship / navigator trio. fs is the substrate (structural
  # ops on the tree), file is the vessel (content I/O on one path), finder
  # is the instrument (discovery by path glob or content grep). Replaces
  # the read_file/write_file/edit_file/append_file/list_dir quintet.
  spec(name = "fs",
       description = "structural filesystem ops: list mkdir delete move copy exists info (action=list|exists|info|mkdir|delete|move|copy)",
       tags = @["filesystem", "data", "core"],
       searchKeywords = @["ls", "mkdir", "rm", "mv", "cp", "stat", "exists",
                           "directory", "folder", "delete", "move", "rename",
                           "copy", "create dir"],
       domain = "file",
       default = true, heartbeatSafe = true, category = "files"),
  spec(name = "file",
       description = "single-file content I/O: read write edit append (action=read|write|edit|append). read supports offset/limit for chunked windows.",
       tags = @["filesystem", "data", "core"],
       searchKeywords = @["read", "write", "edit", "append", "modify",
                           "change", "update", "rewrite", "replace", "patch",
                           "fix", "save", "cat", "open file"],
       domain = "file",
       default = true, heartbeatSafe = true, category = "files"),
  spec(name = "finder",
       description = "discover files and content: glob path search and ripgrep content search (action=files|content)",
       tags = @["filesystem", "search", "data", "core"],
       searchKeywords = @["glob", "grep", "find", "search", "pattern",
                           "ripgrep", "rg", "discover", "locate", "look up",
                           "where", "match", "regex"],
       domain = "file",
       default = true, heartbeatSafe = true, category = "files"),
  spec(name = "find_tools",
       description = "discover and activate hidden tools by keyword (meta-tool for tool surface introspection)",
       tags = @["utility", "core", "meta"], domain = "agent",
       default = true, heartbeatSafe = false, category = "discovery"),

  # Communication
  # `chat` is the channel-agnostic protocol layer — send/reply/forward
  # verbs with capability-driven format selection. Replaced the former
  # `reply` (action=final|progress) and `forward` tools, which were
  # vendor-aware (hardcoded Feishu branches) and split unnecessarily.
  # Iteration-budget plan-state lives on `chat reply ... progress=[...]`.
  spec(name = "chat",
       description = "real-time conversational messaging — channel-agnostic " &
                     "protocol verbs (action=send|reply|forward). Capability-" &
                     "driven format selection (text vs card) with no hardcoded " &
                     "vendor branches. Reply accepts optional progress=[items] " &
                     "+ interim=true for plan-state checkpoints. For " &
                     "persistent / async / shipment messaging, see mail.",
       tags = @["comm", "chat", "messaging", "core"], domain = "comm",
       searchKeywords = @["send message", "chat send", "chat reply",
                          "chat forward", "talk", "respond", "message",
                          "answer", "reply", "forward", "progress",
                          "interim", "checkpoint"],
       default = true, heartbeatSafe = true, externalAllowed = true,
       category = "comm"),
  # (email and shipment folded into mail kind=email / kind=shipment)
  # `mail` is the unified persistent / async messaging tool — three
  # transport kinds (internal | email | shipment) under one tool.
  # Internal: local file queue between agents (heartbeat MAILBOX ALERT
  # integration unchanged). Email: SMTP/IMAP/Postmark/SendGrid/SES via
  # the channel manager. Shipment: FedEx/UPS/USPS/DHL via the channel
  # manager (transport TBD per operator's carrier choice).
  spec(name = "mail",
       description = "persistent / async messaging (action=send|reply|" &
                     "forward|archive|track, kind=internal|email|shipment). " &
                     "Internal kind = file queue between agents. Email + " &
                     "shipment kinds route via channel manager when their " &
                     "vendors are enabled. For real-time conversation, see chat.",
       tags = @["comm", "mail", "messaging", "core", "agent"],
       searchKeywords = @["mail send", "send mail", "memo", "email",
                          "ship", "shipment", "parcel", "smtp", "imap",
                          "postmark", "sendgrid", "ses", "fedex", "ups",
                          "usps", "dhl", "track", "archive", "MAILBOX"],
       domain = "comm",
       default = true, heartbeatSafe = true, category = "comm"),
  # Channel — vendor-level transport navigator (read-only). chat / mail
  # consult capabilities here for format-promotion decisions; no hardcoded
  # vendor branches in protocol layers. Bound to live channel manager at
  # gateway boot.
  spec(name = "channel",
       description = "channel transport navigator: list enabled vendors and " &
                     "their feature matrices (action=list|capabilities). " &
                     "Read-only. For routing to a recipient, use social. " &
                     "For sending, use chat / mail.",
       tags = @["comm", "channel", "transport", "core"], domain = "comm",
       searchKeywords = @["channel list", "channel capabilities",
                          "vendor list", "vendor features", "transport",
                          "feishu", "telegram", "discord", "nmobile",
                          "max length", "supports markdown",
                          "supports card", "supports file"],
       default = true, heartbeatSafe = true, category = "messaging"),
  spec(name = "delegate",
       description = "delegate tasks to other named agents (sync or deferred)",
       tags = @["agent", "delegation"], domain = "relationships",
       default = true, heartbeatSafe = true, externalAllowed = true,
       category = "relationships"),
  # The navigator of the social/delegate/collaborate trio. Multi-agent
  # orchestration on top of `delegate`: fan tasks out in parallel or
  # pipeline through agents sequentially. Internal-only (would amplify
  # external requests into N peer calls).
  spec(name = "collaborate",
       description = "multi-agent orchestration (action=fan_out|pipeline|" &
                     "consensus|route). fan_out: same task to N agents in " &
                     "parallel. pipeline: sequential A→B→C with stage_timeouts " &
                     "+ on_error=abort|skip|retry_once. consensus: fan_out + " &
                     "LLM synthesis (arbiter reconciles divergent replies). " &
                     "route: pick the best peer for a task by skills/role " &
                     "match (DRY-RUN — does not dispatch). Goes through the " &
                     "delegate primitive — peers run their own tools and " &
                     "trust gate.",
       tags = @["agent", "delegation", "orchestration", "core"],
       searchKeywords = @["fan-out", "fanout", "parallel", "pipeline",
                           "orchestrate", "coordinate", "multi-agent",
                           "broadcast", "chain", "sequential", "all agents",
                           "ensemble", "scatter-gather", "navigator",
                           "consensus", "synthesize", "vote", "reduce",
                           "arbiter", "route", "pick", "recommend",
                           "best-fit", "on-error", "skip", "retry",
                           "stage-timeout"],
       domain = "relationships",
       default = true, heartbeatSafe = false, category = "relationships"),
  # (forward folded into `chat action=forward`)

  # Self-management (the verify-triangle agent tools)
  spec(name = "memory",
       description = "cross-source memory: query past experiences, reflections, conversations, heartbeats, knowledge wiki (action=store|recall|list|forget|recent|verify; scope=sender|self|sessions|heart|knowledge|all)",
       tags = @["memory", "core"],
       searchKeywords = @["remember", "recall", "history", "past", "earlier",
                           "store", "save", "note", "what did i", "when did i",
                           "verify", "evidence", "claim", "prove"],
       domain = "agent",
       default = true, heartbeatSafe = false, category = "self-management"),
  spec(name = "todo",
       description = "manage your todo queue (defer/done) and time-scheduled TODOs (schedule/done_note); done verifies tombstone landed",
       tags = @["agent", "core"], domain = "agent",
       default = true, heartbeatSafe = true, category = "self-management"),
  spec(name = "workstation",
       description = "audit a project under workstation/active/ for README↔disk drift, broken symlinks, dirty git, empty scaffolds (action=verify_project)",
       tags = @["agent", "core", "workstation"], domain = "agent",
       default = true, heartbeatSafe = true, category = "self-management"),
  spec(name = "consolidate_knowledge",
       description = "promote a cross-project insight into your knowledge wiki at knowledge/<topic>.md",
       tags = @["agent", "core"], domain = "agent",
       default = true, heartbeatSafe = true, category = "self-management"),
  spec(name = "spawn",
       description = "spawn autonomous sub-agents for tasks (focus_modes)",
       tags = @["agent", "automation"], domain = "agent",
       default = true, heartbeatSafe = false, category = "self-management"),

  # Internet stack — sea / ship / navigator
  #   web    = the sea (HTTP fetch/raw request)
  #   browser= the ship (Playwright/Chromium)
  #   search = the navigator (Brave/DuckDuckGo)
  spec(name = "web",
       description = "HTTP fetching (action=fetch|request); SSRF-protected. " &
                     "The 'sea' of the internet trio — for raw HTTP. " &
                     "For search use the standalone `search` tool; " &
                     "for interactive pages use `browser`.",
       tags = @["web", "http", "data"],
       searchKeywords = @["fetch", "download", "url", "http",
                           "api", "rest", "post", "get"],
       domain = "web",
       default = true, heartbeatSafe = false, category = "web"),
  spec(name = "search",
       description = "Search the web — find pages by query, returns " &
                     "title/url/snippet for each. The 'navigator' of the " &
                     "internet trio. Brave when BRAVE_API_KEY set; " &
                     "DuckDuckGo fallback.",
       tags = @["web", "search", "discovery", "core"],
       searchKeywords = @["search", "query", "google", "bing", "duckduckgo",
                           "brave", "ddg", "find on web", "lookup",
                           "research"],
       domain = "web",
       default = true, heartbeatSafe = false, category = "web"),
  spec(name = "browser",
       description = "browser interaction (action=open URL or action=automate via Playwright CLI)",
       tags = @["browser", "web", "ui", "automation"],
       searchKeywords = @["click", "navigate", "page", "site", "form", "fill",
                           "automate", "screenshot of page", "javascript",
                           "interact", "select", "type"],
       domain = "web",
       default = true, heartbeatSafe = false, category = "web"),

  # Social — read/write world graph + customer onboarding flow.
  # Replaces the former query_graph + update_contact + my_customers +
  # create_customer_invite + redeem_invite tools. Single tool, action
  # enum (query | who | update | customers | invite | redeem | route |
  # discover | mark_unreachable). Backed by the cortex module — the
  # brain's social organ, hence the name. The route/discover/
  # mark_unreachable trio answers "how do I reach this recipient?";
  # `channel` answers the orthogonal "what can each transport carry?".
  spec(name = "social",
       description = "social interactions over the world graph: " &
                     "query, look up, rename, list onboarded customers, " &
                     "mint/redeem customer invites, and route messages " &
                     "to recipients (action=route|discover|mark_unreachable)",
       tags = @["admin", "social", "graph", "customer", "invite", "core",
                "comm", "routing"],
       searchKeywords = @["graph", "who", "lookup", "entity", "rename",
                           "contact", "customers", "onboard", "mint",
                           "redeem", "invite", "pin", "code",
                           "route", "discover", "unreachable",
                           "preferred channel", "address book",
                           "how to reach", "reach recipient"],
       domain = "relationships",
       default = true, heartbeatSafe = false, externalAllowed = true,
       category = "relationships"),

  # Time / scheduling / housekeeping
  spec(name = "clock", description = "get current date and time",
       tags = @["utility", "core"], domain = "system",
       default = true, heartbeatSafe = false, category = "system"),
  spec(name = "scheduler",
       description = "schedule one-time or recurring tasks (at_seconds | every_seconds | cron_expr)",
       tags = @["scheduling", "automation", "cron"],
       searchKeywords = @["remind", "later", "tomorrow", "timer", "delay",
                           "wake", "trigger", "alarm", "deadline", "cron",
                           "every", "interval", "fire at"],
       domain = "sched",
       default = true, heartbeatSafe = false, category = "scheduling"),
  # LLM stack — sea/ship/navigator trio. Replaces provider_auth +
  # model_list. `provider` shows accounts/endpoints, `model` shows
  # specific LLMs, `capability` lets the framework or agent ask
  # "which models can do X?" — used internally to feature-gate
  # (e.g., vision check before serving an image).
  spec(name = "provider",
       description = "LLM providers (the 'sea'): list/verify/info (action=list|verify|info). Read-only — keys stay on disk.",
       tags = @["admin", "providers", "diagnostics", "core"],
       searchKeywords = @["llm", "api", "key", "endpoint", "openai",
                           "anthropic", "deepseek", "ollama", "auth",
                           "verify", "credentials"],
       domain = "admin",
       default = true, heartbeatSafe = false, category = "admin"),
  spec(name = "model",
       description = "LLM models (the 'ship'): list/info/current (action=list|info|current). Includes capabilities, context, pricing; current = caller agent's primary.",
       tags = @["diagnostics", "providers", "models", "core"],
       searchKeywords = @["llm", "model", "vision", "tool-use", "reasoning",
                           "context", "pricing", "capability", "vendor",
                           "current", "primary"],
       domain = "admin",
       default = true, heartbeatSafe = false, category = "admin"),
  spec(name = "capability",
       description = "find or USE models by capability (action=list|find|has|route|invoke). " &
                     "`invoke` is the 'LLM as tool' primitive — give a tag (vision/audio/...) " &
                     "and an input (file path or text) and the framework routes to a capable " &
                     "model and returns text. Lets any agent 'see' an image without their " &
                     "primary model needing native multimodal support.",
       tags = @["diagnostics", "models", "capability", "multimodal", "core"],
       searchKeywords = @["tag", "feature", "vision", "tool-use",
                           "reasoning", "thinking", "multilingual", "audio",
                           "code", "supports", "gate", "invoke", "route",
                           "image", "see", "describe", "analyze", "llm as tool"],
       domain = "admin",
       default = true, heartbeatSafe = false, category = "admin"),

  # Dev / utilities
  spec(name = "git", description = "structured git operations (status, diff, log, branch, commit, add, checkout, stash)",
       tags = @["git", "devops", "vcs"],
       searchKeywords = @["commit", "push", "pull", "branch", "diff", "status",
                           "log", "checkout", "stash", "merge", "rebase",
                           "version control", "repository", "repo"],
       domain = "dev",
       default = true, heartbeatSafe = false, category = "dev"),
  spec(name = "json_query", description = "transform JSON data with jq expressions",
       tags = @["data", "utility"],
       searchKeywords = @["json", "jq", "parse", "filter", "extract", "transform",
                           "query", "select"],
       domain = "system",
       default = true, heartbeatSafe = false, category = "utility"),

  # ── Opt-in (not in defaults) ──────────────────────────────────

  # System
  spec(name = "exec",
       description = "run shell commands and scripts (broad system access; opt-in via skill)",
       tags = @["system", "dev", "automation", "core"],
       searchKeywords = @["shell", "bash", "command", "run", "execute", "script",
                           "terminal", "subprocess", "cli"],
       domain = "system",
       default = false, heartbeatSafe = true, category = "system"),

  # Visual
  spec(name = "screenshot", description = "capture screenshots of display",
       tags = @["visual", "utility"],
       searchKeywords = @["capture", "screen", "display", "snap", "picture of screen"],
       domain = "visual",
       default = false, heartbeatSafe = false, category = "visual"),
  spec(name = "image_info",
       description = "get image dimensions and metadata",
       tags = @["visual", "data"],
       searchKeywords = @["dimensions", "metadata", "exif", "width", "height", "format"],
       domain = "visual",
       default = false, heartbeatSafe = false, category = "visual"),
  spec(name = "image_analyze",
       description = "analyze image content using vision model",
       tags = @["visual", "vision", "image"],
       searchKeywords = @["describe image", "what is in", "photo", "picture",
                           "vision", "ocr", "see", "interpret image"],
       domain = "visual",
       default = false, heartbeatSafe = false, category = "visual"),

  # Hardware
  spec(name = "hardware",
       description = "I2C / SPI / board info / memory read+write hardware peripherals",
       tags = @["hardware", "sensors", "i2c", "spi"], domain = "hardware",
       default = false, heartbeatSafe = false, category = "hardware"),

  # Vendor / channel-specific
  # (lark_cli is no longer agent-facing — kept as a Nim API for the
  #  framework's auto-emit Lark Doc upload. Feishu-unique features
  #  for agents will land via `channel` vendor-action dispatch.)
  # (pushover folded into channels/pushover.nim — agents reach it via
  #  `chat send vendor=pushover` like any other channel vendor)

  # Payment — value-transfer protocol verbs. Phase 1: read-only
  # (balance, status, history). Vendor rails are payment-suite skills
  # (nkn-suite today, btc/lightning/usdc-* future). Send / transfer
  # actions deferred until the approval-flow design lands.
  spec(name = "payment",
       description = "value transfer (Phase 1: READ-ONLY — balance, " &
                     "status, history). Routes via vendor rails " &
                     "(nkn-suite today; btc/lightning/usdc-* future). " &
                     "Send/transfer ops require an approval flow that " &
                     "isn't shipped yet.",
       tags = @["payment", "finance", "wallet", "core"],
       searchKeywords = @["payment", "balance", "wallet", "transaction",
                          "tx", "status", "history", "nkn", "btc",
                          "lightning", "usdc", "money", "value"],
       domain = "payment",
       default = false, heartbeatSafe = false, externalAllowed = false,
       category = "finance"),
  spec(name = "feishu_add_app",
       description = "register new feishu/lark app (id, secret, route to agent) — SuperAdmin only",
       tags = @["admin", "channels", "feishu"], domain = "admin",
       default = false, heartbeatSafe = false, category = "vendor"),

  # (Customer onboarding — create_customer_invite, my_customers,
  # redeem_invite — all collapsed into the unified `social` tool above
  # as actions=invite, =customers, =redeem respectively.)

  # MCP forge (heavy — for agents that need to author tools)
  spec(name = "mcp",
       description = "forge / persist / purge MCP tool servers and skills",
       tags = @["admin", "mcp", "skills"], domain = "mcp",
       default = false, heartbeatSafe = false, category = "mcp"),

  # Solar — multi-vendor solar power station facade. One tool with five
  # actions (plant_list / plant_now / plant_history / inverter_list /
  # inverter_alarms). Substrate in `tools/solar/solar_adapter.nim` scans
  # the registry for `mcp_<vendor>_<contract-tool>` matches, fans out for
  # list ops, routes per-plant ops via plant→vendor cache. Used by
  # solar-power-station template skills (daily-yield-sync, monthly-report,
  # alarm-response). Default off; template's `solar-adapter` skill grants
  # via requires.tools.
  spec(name = "solar",
       description = "Solar power station fleet — multi-vendor facade " &
                     "(action=plant_list|plant_now|plant_history|" &
                     "inverter_list|inverter_alarms). Fans out for " &
                     "list ops, routes per-plant ops by " &
                     "plant→vendor cache.",
       tags = @["solar", "fleet", "domain"],
       searchKeywords = @["plant list", "all plants", "fleet",
                           "plant now", "current power", "real-time",
                           "today yield", "plant history", "yield",
                           "historical", "kwh", "inverter", "equipment",
                           "devices", "alarm", "fault", "alert",
                           "photovoltaic", "pv", "solar"],
       domain = "solar",
       default = false, heartbeatSafe = false, category = "solar"),

  # Skill management (heavy — install mutates system; learn requires workstation)
  spec(name = "skill",
       description = "skill management (action=list|load|unload session skills, install plugins, learn workstation skills)",
       tags = @["admin", "skills", "workstation"],
       searchKeywords = @["load skill", "unload skill", "list skills",
                           "playbook", "procedure", "consult skill",
                           "install plugin", "learn workflow"],
       domain = "skill",
       default = false, heartbeatSafe = false, category = "skills"),

  # Task board
  spec(name = "task",
       description = "assign claim submit tasks on the platform task board",
       tags = @["orchestration", "automation"], domain = "task",
       default = false, heartbeatSafe = false, category = "tasks"),

  # Admin / config
  spec(name = "set_api_key",
       description = "configure API keys and secrets",
       tags = @["admin", "config"], domain = "admin",
       default = false, heartbeatSafe = false, category = "admin"),
]

# ── Derivation procs (used by clawdsl + registry to replace const lists) ──

proc defaultToolNames*(): seq[string] =
  ## Tools auto-granted to every agent at config-resolve time.
  ## Replaces the manual `const defaultTools` in clawdsl.nim.
  for s in AllTools:
    if s.default: result.add(s.name)

proc heartbeatSafeToolNames*(): seq[string] =
  ## Tools allowed during heartbeat ticks (system sender, low trust).
  ## Replaces the manual `const HeartbeatAllowedTools` in tools/registry.nim.
  for s in AllTools:
    if s.heartbeatSafe: result.add(s.name)

proc externalAllowedToolNames*(): seq[string] =
  ## Tools callable by external (low-trust: guest, customer) callers
  ## without an explicit grant. Replaces the manual
  ## `const ExternalAllowedTools` in tools/registry.nim AND the
  ## hardcoded `Guest` role grant in clawdsl resolver. Both consumers
  ## now derive from this — single source of truth.
  for s in AllTools:
    if s.externalAllowed: result.add(s.name)

proc commToolNames*(): seq[string] =
  ## Communication-category tools — what counts as "comm" for the
  ## TC-2 nudge counter in agent/loop.nim. Derives from category.
  for s in AllTools:
    if s.category == "comm": result.add(s.name)

var byNameCache {.threadvar.}: Table[string, ToolSpec]
var byNameCacheReady {.threadvar.}: bool

proc ensureByNameCache() =
  if byNameCacheReady: return
  byNameCache = initTable[string, ToolSpec]()
  for s in AllTools:
    byNameCache[s.name] = s
  byNameCacheReady = true

proc toolByName*(name: string): Option[ToolSpec] =
  ## O(1) lookup via cached `name → ToolSpec` table (built lazily once
  ## per thread, then reused). Replaces the prior O(N) linear scan.
  ## `searchTools` calls this once per registered tool, so without the
  ## cache that's O(N²) per find_tools invocation.
  ensureByNameCache()
  if byNameCache.hasKey(name): result = some(byNameCache[name])

proc toolsByDomain*(domain: string): seq[ToolSpec] =
  for s in AllTools:
    if s.domain == domain: result.add(s)

proc allDomains*(): seq[string] =
  var seen: seq[string] = @[]
  for s in AllTools:
    if s.domain notin seen: seen.add(s.domain)
  seen

proc allCategories*(): seq[string] =
  var seen: seq[string] = @[]
  for s in AllTools:
    if s.category.len > 0 and s.category notin seen: seen.add(s.category)
  seen

# ── Boot-time validation (Phase 8f) ────────────────────────────────
# `validateAgainstRegistry` lives in tools/registry.nim, which imports
# this manifest. Putting it here would create a cycle (manifest →
# base → registry → manifest). Manifest stays dependency-free.
