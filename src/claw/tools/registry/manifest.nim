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
       description = "structural filesystem ops: list mkdir delete move copy exists info (method=list|exists|info|mkdir|delete|move|copy)",
       tags = @["filesystem", "data", "core"],
       searchKeywords = @["ls", "mkdir", "rm", "mv", "cp", "stat", "exists",
                           "directory", "folder", "delete", "move", "rename",
                           "copy", "create dir"],
       domain = "file",
       default = true, heartbeatSafe = true, category = "files"),
  spec(name = "file",
       description = "single-file content I/O: read write edit append (method=read|write|edit|append). read supports offset/limit for chunked windows.",
       tags = @["filesystem", "data", "core"],
       searchKeywords = @["read", "write", "edit", "append", "modify",
                           "change", "update", "rewrite", "replace", "patch",
                           "fix", "save", "cat", "open file"],
       domain = "file",
       default = true, heartbeatSafe = true, category = "files"),
  spec(name = "finder",
       description = "discover files and content: glob path search and ripgrep content search (method=files|content)",
       tags = @["filesystem", "search", "data", "core"],
       searchKeywords = @["glob", "grep", "find", "search", "pattern",
                           "ripgrep", "rg", "discover", "locate", "look up",
                           "where", "match", "regex"],
       domain = "file",
       default = true, heartbeatSafe = true, category = "files"),
  # ── tools / office / company trio ──────────────────────────────
  # tools     = sea  (workforce capabilities — agent's craft surface)
  # office    = ship (agent's vessel — clock/calendar/state/etc.)
  # company   = navigator (org-level direction — workforce/labs/business)
  spec(name = "tools",
       description = "Agent's craft surface for non-foundation tools. find = discover by keyword (Phase 1). forge / update / share / remove = author / modify / publish / delete authored tools (Phase 2 stubs).",
       tags = @["utility", "core", "meta", "tools"],
       searchKeywords = @["tools", "find tool", "discover", "search", "activate",
                          "forge", "author", "create tool", "share tool",
                          "remove tool", "update tool", "tool surface",
                          "find_tools"],
       domain = "agent",
       default = true, heartbeatSafe = false, category = "discovery"),

  # Communication
  # `chat` is the channel-agnostic protocol layer — send/reply/forward
  # verbs with capability-driven format selection. Replaced the former
  # `reply` (method=final|progress) and `forward` tools, which were
  # vendor-aware (hardcoded Feishu branches) and split unnecessarily.
  # Iteration-budget plan-state lives on `chat reply ... progress=[...]`.
  spec(name = "chat",
       description = "real-time conversational messaging — channel-agnostic " &
                     "protocol verbs (method=send|reply|forward). Capability-" &
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
       description = "persistent / async messaging (method=send|reply|" &
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
  # Channel — vendor-level transport navigator + vendor-feature gateway
  # + channel-admin surface. chat / mail consult capabilities here for
  # format-promotion decisions; no hardcoded vendor branches in protocol
  # layers. Bound to live channel manager at gateway boot.
  spec(name = "channel",
       description = "channel transport navigator + vendor-feature gateway " &
                     "+ admin (method=list|capabilities|docs|sheets|calendar|" &
                     "tasks|add_app). list/capabilities are read-only. " &
                     "docs/sheets/calendar/tasks dispatch to the named " &
                     "vendor's mcp_<vendor>_<action>_<op> tool. add_app is " &
                     "SuperAdmin-only — registers a new vendor app (today: " &
                     "feishu; folded in from set_api_key + feishu_add_app). " &
                     "For routing to a recipient, use social. For sending, " &
                     "use chat / mail.",
       tags = @["comm", "channel", "transport", "core"], domain = "comm",
       searchKeywords = @["channel list", "channel capabilities",
                          "vendor list", "vendor features", "transport",
                          "feishu", "telegram", "discord", "nmobile",
                          "max length", "supports markdown",
                          "add app", "register app", "channel admin",
                          "docs", "sheets", "calendar", "tasks",
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
       description = "multi-agent orchestration (method=fan_out|pipeline|" &
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
  # (forward folded into `chat method=forward`)

  # Self-management (the verify-triangle agent tools)
  spec(name = "memory",
       description = "cross-source memory: past experiences, reflections, " &
                     "conversations, heartbeats (method=store|recall|list|" &
                     "forget|recent|verify; scope=sender|self|sessions|" &
                     "heart|all). The 'sea' in the memory/knowledge/skill " &
                     "trio — raw past with source attribution. For TIMELESS " &
                     "FACTS use the knowledge tool (different epistemic category).",
       tags = @["memory", "core"],
       searchKeywords = @["remember", "recall", "history", "past", "earlier",
                           "store", "save", "note", "what did i", "when did i",
                           "verify", "evidence", "claim", "prove",
                           "experience", "reflection", "episodic"],
       domain = "agent",
       default = true, heartbeatSafe = false, category = "self-management"),
  # Self-temporal trio: focus (NOW) / schedule (TIMED) / todo (BATCHED).
  spec(name = "todo",
       description = "Untimed batch queue (defer/done). Heartbeat scans pending items. For time-anchored work use `schedule`; for immediate constrained work use `focus`.",
       tags = @["agent", "core"], domain = "agent",
       default = true, heartbeatSafe = true, category = "self-management"),
  # Navigator leg of the system / shell / workstation trio. Per-agent
  # GitHub-like local platform: overview / repo / project / item / audit.
  # Heartbeat-driven hygiene lives in the workstation-keeper competency.
  spec(name = "workstation",
       description = "Per-agent GitHub-like local platform. overview/repo/project/item/audit. Repos = code containers; projects = work trackers with schemaless items; audit = health check (project or workstation scope).",
       tags = @["agent", "core", "workstation"],
       searchKeywords = @["workstation", "project", "repo", "repository",
                          "kanban", "board", "tracker", "items",
                          "github", "audit", "verify", "drift", "overview"],
       domain = "agent",
       default = true, heartbeatSafe = true, category = "self-management"),
  # `knowledge` — the ship in memory/knowledge/skill trio. Surface:
  # consolidate (write/append) | lookup (read) | list | rank (agent
  # judgment 1-10 with reason) | top (sort by avg). Ranks are OPTIONAL —
  # facts surface in lookups regardless; rank refines order.
  spec(name = "knowledge",
       description = "cross-project semantic memory wiki — timeless facts. " &
                     "Actions: consolidate (write/append) | lookup (read + " &
                     "rank summary + deprecation banner + related topics) | " &
                     "list (enumerate) | rank (1-10 agent judgment with " &
                     "reason) | top (sort by avg) | update (append refinement " &
                     "tagged UPDATE) | deprecate (mark stale with reason; " &
                     "content preserved) | link (cross-reference topics). " &
                     "Vocabulary discipline: this is for 'is this true?' — " &
                     "for 'did this happen?' use memory. Ranks are " &
                     "agent-decided; aggregate displayed once ≥ 2 votes.",
       tags = @["agent", "core", "knowledge", "wiki"],
       searchKeywords = @["knowledge", "wiki", "fact", "lookup",
                          "consolidate", "promote insight", "rank",
                          "score", "topic", "semantic memory",
                          "update", "deprecate", "link", "related",
                          "cross-reference", "supersede"],
       domain = "agent",
       default = true, heartbeatSafe = true, category = "self-management"),
  spec(name = "focus",
       description = "concentrate on a subtask with a constrained tool surface (intra-agent; pick a mode like Plan / Implement / Review)",
       tags = @["agent", "automation"],
       searchKeywords = @["focus", "subtask", "subagent", "plan mode",
                           "implement mode", "review mode", "concentrate",
                           "narrow tools", "spawn"],
       domain = "agent",
       default = true, heartbeatSafe = false, category = "self-management"),

  # Internet stack — sea / ship / navigator
  #   web    = the sea (HTTP fetch/raw request)
  #   browser= the ship (Playwright/Chromium)
  #   search = the navigator (Brave/DuckDuckGo)
  spec(name = "web",
       description = "HTTP fetching (method=fetch|request); SSRF-protected. " &
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
       description = "browser interaction (method=open URL or method=automate via Playwright CLI)",
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
                     "to recipients (method=route|discover|mark_unreachable)",
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
  # `clock` folded into `office method=clock` (timezone-aware, office-bound).
  spec(name = "office",
       description = "The agent's vessel — clock/calendar/info/state/occupant/stats. Read-only, self-only. clock+calendar timezone-aware (office tz). info = admin-set vessel config; state = system-tracked dynamics (sessions/storage/health); occupant = agent dynamics (presence); stats = usage analytics for cost analysis.",
       tags = @["agent", "core", "office"],
       searchKeywords = @["office", "clock", "time", "now", "calendar", "date",
                          "today", "weekday", "week", "info", "state", "presence",
                          "storage", "stats", "tokens", "cost", "usage",
                          "vessel", "self", "my office"],
       domain = "agent",
       default = true, heartbeatSafe = true, category = "self-management"),
  spec(name = "company",
       description = "Org-level navigator. info (admin metadata) | memos (policy docs) | workforce (agents/offices/performance) | labs (team workspaces) | business (overview/revenue/performance/customers/payment). Reads gated by trust tier (Member+); writes by Staff+ or Admin+. Guest tier blocked entirely.",
       tags = @["agent", "core", "company", "org"],
       searchKeywords = @["company", "org", "organization", "info", "memos",
                          "workforce", "agents", "offices", "labs", "teams",
                          "business", "revenue", "performance", "customers",
                          "payment", "policy", "staff", "directory"],
       domain = "agent",
       default = true, heartbeatSafe = true, category = "self-management"),
  spec(name = "schedule",
       description = "Time-anchored work. CRON: at_seconds | every_seconds | cron_expr (active fire). NOTES.ORG: due (+ recur) for date-tagged TODOs (passive heartbeat scan). method=complete marks a notes.org TODO done.",
       tags = @["scheduling", "automation", "cron"],
       searchKeywords = @["remind", "later", "tomorrow", "timer", "delay",
                           "wake", "trigger", "alarm", "deadline", "cron",
                           "every", "interval", "fire at", "due", "calendar",
                           "date", "recur", "recurring", "scheduler",
                           "notes.org", "TODO date", "complete TODO"],
       domain = "sched",
       default = true, heartbeatSafe = false, category = "scheduling"),
  # LLM stack — sea/ship/navigator trio. Replaces provider_auth +
  # model_list. `provider` shows accounts/endpoints, `model` shows
  # specific LLMs, `capability` lets the framework or agent ask
  # "which models can do X?" — used internally to feature-gate
  # (e.g., vision check before serving an image).
  spec(name = "provider",
       description = "LLM providers (the 'sea'): list / verify / info / " &
                     "set_key (method=list|verify|info|set_key). list/verify/" &
                     "info are read-only diagnostics; set_key writes a new " &
                     "API key to ~/.claw/.env (folded in from set_api_key).",
       tags = @["admin", "providers", "diagnostics", "core"],
       searchKeywords = @["llm", "api", "key", "endpoint", "openai",
                           "anthropic", "deepseek", "ollama", "auth",
                           "verify", "credentials", "set api key",
                           "configure provider", "save key"],
       domain = "admin",
       default = true, heartbeatSafe = false, category = "admin"),
  spec(name = "model",
       description = "LLM models (the 'ship'): list/info/current (method=list|info|current). Includes capabilities, context, pricing; current = caller agent's primary.",
       tags = @["diagnostics", "providers", "models", "core"],
       searchKeywords = @["llm", "model", "vision", "tool-use", "reasoning",
                           "context", "pricing", "capability", "vendor",
                           "current", "primary"],
       domain = "admin",
       default = true, heartbeatSafe = false, category = "admin"),
  spec(name = "capability",
       description = "find or USE models by capability (method=list|find|has|route|invoke). " &
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

  # ── system / shell / workstation trio ─────────────────────────
  # system     = sea  (host machine substrate — capture, info, transports)
  # shell      = ship (process invocation primitive — run/read/kill/list)
  # workstation = navigator (GitHub-like local platform — declared above)
  #
  # Per Claude Code convention: tools are primitives, workflows live in
  # prompts/competencies. Dropped: separate `git` and `json_query` tools
  # (use `shell run cmd="git ..."` / `shell run cmd="jq ..."`); separate
  # `screenshot` (now `system method=capture`); separate `hardware`
  # i2c/spi/mem (option A: deleted entirely — host-focused tooling).

  spec(name = "system",
       description = "Host machine substrate. Display capture + host info today; transports (uart/bluetooth/usb), introspection (processes/metrics/services/signal/clipboard/notify) declared and stubbed for Phase 2. For embedded peripheral I/O (i2c/spi/gpio) install a separate skill.",
       tags = @["system", "host", "core"],
       searchKeywords = @["screenshot", "screen capture", "display", "host info",
                           "machine info", "hostname", "uname", "cpu",
                           "uart", "serial", "tty", "flash firmware", "console",
                           "bluetooth", "ble", "usb", "lsusb",
                           "processes", "ps", "top", "metrics",
                           "services", "systemd", "launchd",
                           "signal", "kill", "clipboard", "pasteboard",
                           "notify", "notification"],
       domain = "system",
       default = true, heartbeatSafe = false, category = "system"),

  spec(name = "shell",
       description = "Process invocation: run command (foreground or background via flag); manage background processes (read/kill/list). One primitive for sync + async execution. For typed git/jq, use shell run cmd=... per Claude Code convention (tools are primitives; workflows live in prompts).",
       tags = @["system", "dev", "automation", "core"],
       searchKeywords = @["shell", "exec", "run", "command", "bash", "sh",
                           "background", "bg", "process", "pid", "kill",
                           "git", "jq", "make", "build", "test", "deploy",
                           "subprocess", "spawn process"],
       domain = "shell",
       default = false, heartbeatSafe = true, category = "system"),

  # Vendor / channel-specific
  # (lark_cli is no longer agent-facing — kept as a Nim API for the
  #  framework's auto-emit Lark Doc upload. Feishu-unique features
  #  for agents will land via `channel` vendor-action dispatch.)
  # (pushover folded into channels/pushover.nim — agents reach it via
  #  `chat send vendor=pushover` like any other channel vendor)

  # `payment` folded under `company method=business.payment.<op>` (Phase 3).
  # PaymentTool stays as an internal handler registered with company.business;
  # no longer a standalone framework tool.

  # (feishu_add_app folded into `channel method=add_app vendor=feishu
  #  app_id=… app_secret=… agent=…` — SuperAdmin gate preserved.)

  # (Customer onboarding — create_customer_invite, my_customers,
  # redeem_invite — all collapsed into the unified `social` tool above
  # as methods=invite, =customers, =redeem respectively.)

  # `mcp` folded under `tools method=mcp.<op>` (Phase 3). UnifiedMcpTool
  # stays as an internal sub-tool registered with the tools tool;
  # no longer a standalone framework tool.

  # `solar` folded under `company method=business.solar.<op>` (Phase 3).
  # SolarTool stays as an internal handler registered with company.business;
  # no longer a standalone framework tool.

  # Skill management (heavy — install mutates system; learn requires workstation)
  spec(name = "skill",
       description = "skill management (method=list|load|unload session skills, install plugins, learn workstation skills)",
       tags = @["admin", "skills", "workstation"],
       searchKeywords = @["load skill", "unload skill", "list skills",
                           "playbook", "procedure", "consult skill",
                           "install plugin", "learn workflow"],
       domain = "skill",
       default = false, heartbeatSafe = false, category = "skills"),

  # (the former `task` tool — assign/claim/submit — is now `collaborate
  #  method=assign|claim|submit` (late-binding pool form). The team
  #  TASKS.md board is just another binding strategy for multi-agent
  #  coordination, alongside fan_out/pipeline/consensus/route.)

  # (set_api_key folded into `provider method=set_key name=… api_key=…`
  #  — provider IS the LLM-credentials manager; key-setting belongs there.)
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
