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
  # Files
  spec(name = "read_file", description = "read file contents from disk",
       tags = @["filesystem", "data", "core"], domain = "file",
       default = true, heartbeatSafe = true, category = "files"),
  spec(name = "write_file", description = "write or create files on disk",
       tags = @["filesystem", "data", "core"], domain = "file",
       default = true, heartbeatSafe = false, category = "files"),
  spec(name = "edit_file", description = "edit files with find and replace",
       tags = @["filesystem", "data", "core"],
       searchKeywords = @["modify", "change", "update", "rewrite", "replace", "patch", "fix"],
       domain = "file",
       default = true, heartbeatSafe = false, category = "files"),
  spec(name = "append_file", description = "append content to existing files",
       tags = @["filesystem", "data"], domain = "file",
       default = true, heartbeatSafe = false, category = "files"),
  spec(name = "list_dir", description = "list directory contents",
       tags = @["filesystem", "data", "core"], domain = "file",
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

  # Cortex / admin (granted by default — every agent might query the graph)
  spec(name = "query_graph", description = "query world graph entities and relations",
       tags = @["admin", "graph", "core"], domain = "admin",
       default = true, heartbeatSafe = false, category = "admin"),
  spec(name = "update_contact",
       description = "update contact information in graph or guest ledger",
       tags = @["admin", "contacts", "core"], domain = "admin",
       default = true, heartbeatSafe = true, externalAllowed = true,
       category = "admin"),

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

  # Customer onboarding
  spec(name = "create_customer_invite",
       description = "create customer invite code; returns nc:X/CODE bundled string — SuperAdmin only",
       tags = @["admin", "customer", "invite"], domain = "customer",
       default = false, heartbeatSafe = false, category = "customer"),
  spec(name = "my_customers",
       description = "my customers count, list, onboarded, invited, referrals",
       tags = @["customer", "invite", "stats"], domain = "customer",
       default = false, heartbeatSafe = false, category = "customer"),
  spec(name = "redeem_invite",
       description = "redeem an invite code to claim a pre-allocated entity identity",
       tags = @["admin", "core"], domain = "customer",
       default = false, heartbeatSafe = false, externalAllowed = true,
       category = "customer"),

  # MCP forge (heavy — for agents that need to author tools)
  spec(name = "mcp",
       description = "forge / persist / purge MCP tool servers and skills",
       tags = @["admin", "mcp", "skills"], domain = "mcp",
       default = false, heartbeatSafe = false, category = "mcp"),

  # Skill management (heavy — install mutates system; learn requires workstation)
  spec(name = "skill",
       description = "skill management: action=install plugins or action=learn workstation skills",
       tags = @["admin", "skills", "workstation"], domain = "skill",
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
