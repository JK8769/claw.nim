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

  # Communication (unified)
  spec(name = "reply",
       description = "send a message to current conversation partner (action=final|progress; verified_done items require verification field)",
       tags = @["messaging", "core"], domain = "comm",
       default = true, heartbeatSafe = true, externalAllowed = true,
       category = "comm"),
  spec(name = "mail",
       description = "inter-agent mail (action=send to peers; action=archive your own processed inbox)",
       tags = @["agent", "core", "messaging"], domain = "comm",
       default = true, heartbeatSafe = true, category = "comm"),
  spec(name = "delegate",
       description = "delegate tasks to other named agents (sync or deferred)",
       tags = @["agent", "delegation"], domain = "comm",
       default = true, heartbeatSafe = true, externalAllowed = true,
       category = "comm"),
  spec(name = "forward", description = "forward messages between channels/identities",
       tags = @["messaging", "core"], domain = "comm",
       default = true, heartbeatSafe = true, externalAllowed = true,
       category = "comm"),

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

  # Web
  spec(name = "web",
       description = "HTTP-ish data fetching (action=search|fetch|request); SSRF-protected",
       tags = @["web", "search", "http", "data"],
       searchKeywords = @["fetch", "download", "url", "http", "search", "google",
                           "lookup", "api", "rest", "post", "get"],
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
  # enum (query | who | update | customers | invite | redeem). Backed
  # by the cortex module — the brain's social organ, hence the name.
  spec(name = "social",
       description = "social interactions over the world graph: " &
                     "query, look up, rename, list onboarded customers, " &
                     "mint/redeem customer invites",
       tags = @["admin", "social", "graph", "customer", "invite", "core"],
       searchKeywords = @["graph", "who", "lookup", "entity", "rename",
                           "contact", "customers", "onboard", "mint",
                           "redeem", "invite", "pin", "code"],
       domain = "social",
       default = true, heartbeatSafe = false, externalAllowed = true,
       category = "social"),

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
  spec(name = "provider_auth",
       description = "verify provider api key (deepseek, openai, anthropic, ...) reachable",
       tags = @["admin", "diagnostics", "providers"], domain = "admin",
       default = true, heartbeatSafe = false, category = "admin"),
  spec(name = "model_list",
       description = "list available LLM models with capabilities, context, pricing",
       tags = @["diagnostics", "providers", "models"], domain = "admin",
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
  spec(name = "lark_cli",
       description = "Feishu/Lark docs sheets calendar tasks via lark-cli",
       tags = @["feishu", "lark", "docs", "calendar", "platform"], domain = "comm",
       default = false, heartbeatSafe = false, category = "vendor"),
  spec(name = "pushover",
       description = "send push notifications via Pushover",
       tags = @["messaging", "notification"], domain = "comm",
       default = false, heartbeatSafe = false, category = "vendor"),
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

  # Fleet adapter — vendor-agnostic facade for multi-vendor solar deployments.
  # Implementations in `tools/fleet/fleet_adapter.nim`. Each tool scans the
  # runtime registry for `mcp_<vendor>_<contract-tool>` matches, fans out
  # for list operations, and routes per-plant operations via an in-memory
  # plant→vendor cache. Used by the solar-power-station template's workflow
  # skills (daily-yield-sync, monthly-report, alarm-response). Default off;
  # the template's `fleet-adapter` skill declares them in requires.tools so
  # agents that opt in receive the grant.
  spec(name = "fleet_plant_list",
       description = "List all plants across every installed inverter vendor",
       tags = @["fleet", "solar", "domain"],
       searchKeywords = @["plant list", "fleet", "all plants"],
       domain = "fleet",
       default = false, heartbeatSafe = false, category = "fleet"),
  spec(name = "fleet_plant_now",
       description = "Real-time state for one plant (current power, today yield, status)",
       tags = @["fleet", "solar", "domain"],
       searchKeywords = @["plant now", "current power", "real-time"],
       domain = "fleet",
       default = false, heartbeatSafe = false, category = "fleet"),
  spec(name = "fleet_plant_history",
       description = "Daily yield history for one plant over a date range",
       tags = @["fleet", "solar", "domain"],
       searchKeywords = @["plant history", "yield history", "kwh history"],
       domain = "fleet",
       default = false, heartbeatSafe = false, category = "fleet"),
  spec(name = "fleet_inverter_list",
       description = "List inverters under one plant",
       tags = @["fleet", "solar", "domain"],
       searchKeywords = @["inverter list", "equipment"],
       domain = "fleet",
       default = false, heartbeatSafe = false, category = "fleet"),
  spec(name = "fleet_inverter_alarms",
       description = "Active alarms on inverters under one plant",
       tags = @["fleet", "solar", "domain"],
       searchKeywords = @["alarm list", "alarms", "active faults"],
       domain = "fleet",
       default = false, heartbeatSafe = false, category = "fleet"),

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
