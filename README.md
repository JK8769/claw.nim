# claw.nim

**An AI agent framework with the ergonomics of a package manager.** Native Nim. Single binary. Git-native sharing. Designed so companies, skills, providers, and models all move through the same clear lifecycle — declare, share, fork, pin, update.

```bash
nimble install claw
claw co create github:yourorg/solar-template --as=MySolar
claw gateway
```

That's it. You now have a fully-configured agent running.

---

## Why claw

Most agent frameworks give you a library and leave you to figure out operations. **claw is infrastructure**: companies are first-class, skills have versions and registries, providers and models have catalogs, and everything is reproducible from a lockfile.

**Three concrete pains claw solves**:

1. **"How do I deploy the same agent for 3 regions?"** → multi-company from one template, region-scoped credentials, zero code duplication
2. **"How do I share my skill without leaking credentials?"** → `claw:` and `github:` URL schemes, explicit `share` command, git is the distribution layer
3. **"Which model should this agent use?"** → one `claw model list` shows every model your configured providers offer, sorted by cost, with cross-provider canonical links

---

## Features

### Companies are git repos

```bash
claw co push git@github.com:myorg/my-company.git  # publish
claw co create <url> --as=MyClone                  # consume
claw co update                                     # pull + regenerate
claw co diverge                                    # fork point
```

Credentials (`.env`), runtime state, compiled binaries are automatically `.gitignore`d. Org identity (`org "Foo"`) is preserved on pull so forks keep their own names. Git history IS your version control — no separate version system to learn.

### Skills have multiple install forms

```nim
# In BASE.nims:
skill "sungrow"                                            # bundled with claw
skill "github:anthropics/skills/document-skills"           # mono-repo + subpath
skill "github:AnyGenIO/anygen-suite-skill/anygen-suite"    # single-repo skill
skill "claw:OtherCompany/sungrow-analytics"                # cross-company share
```

Each form installs from the authoritative source, captures a content hash in `claw.lock`, and inherits the skill author's changes via `claw co update`.

### Providers and models as live catalogs

```
$ claw model list
Available models for MyCompany (3 configured providers)

MODEL                       VENDOR      CONTEXT  CAPABILITIES                     CHEAPEST VIA  PRICE IN/OUT
gemma-2-27b-it              google      8K       multilingual                     nvidia        -
glm-5.1                     z-ai        131K     tool-use,reasoning,multilingual  OpenCode Go   -
llama-3.3-70b-instruct      meta        131K     tool-use,multilingual            nvidia        -
deepseek-chat               deepseek    65K      tool-use                         deepseek      $0.27/$1.10
```

Agents can call `model_list(refresh=true)` to hit every provider's API, update the catalog, and report **newly-seen models that aren't yet in the canonical catalog** — so you never miss a model release.

### Region-aware credentials, one skill

Same skill source, multiple regions, no code duplication:

```bash
claw co use SunGrowEU  &&  claw skill auth sungrow --region=eu
claw co use SunGrowCN  &&  claw skill auth sungrow --region=cn
claw co use SunGrowUS  &&  claw skill auth sungrow --region=us
```

Each company's `.env` holds region-scoped vars (`SUNGROW_CN_APPKEY`, `SUNGROW_EU_APPKEY`, ...) and `SUNGROW_REGION` selects the active set. The MCP server routes to the correct datacenter automatically.

### Skill `share` / `unshare` — explicit API

```bash
claw skill new trading-analytics   # adds `skill "trading-analytics"` (private)
# ... develop + test ...
claw skill share trading-analytics # → `skill "claw:MyCompany/trading-analytics"` (public)
claw co push                       # now downstreams can depend on it
```

Bare names mean "private to this company, don't depend on it". `claw:<co>/<name>` means "author-committed API". Diff of BASE.nims between companies shows exactly what's shared.

### MCP-native tool bridges

Skills can expose tools via the Model Context Protocol. Nim-compiled MCP servers run as subprocesses under the gateway with stdio transport. The `sungrow`, `docparse`, and `forge-tool` skills all ship as native MCP servers with no JavaScript runtime overhead.

### Bootstrap registry for complex skills

Some skills need more than file copies — they pull sub-skills, install npm packages, redirect application data. `res/skills.json` ships bootstrap recipes:

```bash
claw skill install github:AnyGenIO/anygen-suite-skill/anygen-suite
# → clones the skill
# → npm install -g @anygen/cli
# → anygen skill install --platform claude-code -y  (pulls 3 sub-skills)
# → copies sub-skills into this company's lab
# → writes ANYGEN_HOME=<company>/support/anygen to .env
# → agent's shell exec inherits the env — anygen's app data stays per-company
```

One command. Every side effect scoped to the active company.

### Three-tier capability model

```
foundation/                                     shipped with the claw distribution
workspace/skills/                               company-tier skills (shared across agents)
workspace/offices/<agent>/workstation/skills/   agent-personal
```

Agents can author their own skills at runtime via the `learn-skill` tool, pinned to that agent's workstation — without touching company-level skills that other agents depend on.

---

## ClawDSL — the config language

Everything about a company — its agents, providers, skills, permissions, security policies, gateway settings — is declared in **one `.nims` file** using ClawDSL, a Nim-embedded DSL. It's not YAML. It's not JSON. It's real code that runs through Nim's interpreter at `claw co create` / `claw co update` time.

Here's a full working example:

```nim
import claw/clawdsl

# ── Organization ──────────────────────────────────────
org "SunGrow":
  description "Solar and energy-storage fleet monitoring."

# ── People ────────────────────────────────────────────
person "Owner":
  permission "SuperAdmin"

# ── Providers ─────────────────────────────────────────
provider "deepseek":
  apiKey "${DEEPSEEK_API_KEY}"
  defaultModel "deepseek-chat"
  models "deepseek-chat", "deepseek-reasoner"

# ── Agents ────────────────────────────────────────────
agent "Lexi":
  model "deepseek-chat"
  provider "deepseek"
  role "Admin"
  identity "Staff"
  jobTitle "Solar Ops Analyst"
  maxDepth 10
  uses "sungrow", "doc-parse", "anygen", "forge-tool"
  workstation true

  reportsTo "Owner":
    role "boss"
    trustLevel 100
    etiquette "Primary lead. Prefers concise reports with kWh and SOC numbers stated clearly."

# ── Company rules ─────────────────────────────────────
defaults:
  maxTokens 4096
  temperature 0.5
  maxToolIterations 20

security:
  policy "rate_limit",
    "Sungrow iSolarCloud recommends >=5 minutes between realtime queries. Do not poll in loops."
  policy "no_control",
    "This company is READ-ONLY. Never attempt parameter writes via the Sungrow API."

gateway:
  host "127.0.0.1"
  port 18791

# ── Skills ────────────────────────────────────────────
skill "claw:SunGrow/sungrow"                              # cross-company share
skill "doc-parse"                                         # bundled
skill "anygen", "github:AnyGenIO/anygen-suite-skill/anygen-suite"  # external

build(currentSourcePath())
```

**What `claw co update` does with this file**:

1. **Runs it through Nim's interpreter** — syntax errors, typos, and bad types are caught here, not at gateway startup
2. **Resolves every skill** to a specific source + content hash (written to `claw.lock`)
3. **Walks each skill's `SKILL.md` frontmatter** to compute the agent's total `resolved_tools`, `resolved_deps`, `resolved_envs`
4. **Warns** on each env var that's declared but not yet set in `.env`
5. **Emits `BASE.json`** — the final, fully-resolved snapshot the gateway reads

At runtime the gateway never re-parses ClawDSL. It reads `BASE.json`. The DSL is for developers; the daemon is for production.

### Why Nim-as-DSL beats YAML-as-config

| Aspect | YAML/JSON config | ClawDSL (this) |
|--------|------------------|----------------|
| Typos in keys (`agnt` vs `agent`) | Silent | Compile-time error |
| Missing required fields | Runtime crash | Compile-time error |
| Circular references | Silent | Caught by interpreter |
| Env var substitution (`${FOO}`) | Needs separate templating tool | Native Nim strings |
| Conditional logic (region-based agents) | Separate Helm/Jinja pass | `when defined(eu): ...` inline |
| Cross-company composition | Copy-paste-modify | `import common/base_template.nims` |
| Refactoring (rename "SunGrow" → "SolarOps") | Find-and-replace across files | Rename a const, re-run |
| Tool autocomplete in editor | None | Nim LSP works |
| Compile-time skill-tool validation | Impossible | Reads SKILL.md, fails if a declared tool doesn't exist |

**ClawDSL isn't a config format. It's a build script that happens to describe a company.** When `claw.lock` is produced, every dep, every tool, every env var has been mechanically verified against the skills and providers it references. A broken config can't start a gateway.

### Composition at scale

When you have 4 regional clones (SunGrow, SunGrowEU, SunGrowCN, SunGrowUS), the common parts live in one place:

```nim
# common/solar_base.nims — shared across all regional companies
import claw/clawdsl
export clawdsl

template solarAgent*(name: string) =
  agent name:
    model "deepseek-reasoner"
    provider "deepseek"
    role "Admin"
    identity "Staff"
    uses "sungrow", "doc-parse"
    workstation true

template solarRules*() =
  defaults:
    maxTokens 4096
    temperature 0.5
  security:
    policy "no_control",
      "Read-only. No parameter writes or firmware ops via Sungrow API."
```

```nim
# ~/.nimclaw-SunGrowEU/BASE.nims
import common/solar_base

org "SunGrowEU":
  description "Solar fleet monitoring — EU region."

provider "deepseek":
  apiKey "${DEEPSEEK_API_KEY}"
  defaultModel "deepseek-reasoner"

solarAgent "Lexi"     # generated from the template
solarRules()          # same rules as every other region

skill "claw:SunGrow/sungrow"

build(currentSourcePath())
```

Try doing that with YAML-plus-Jinja without hating your life.

---

## Quick start

```bash
# 1. Install (requires Nim 2.0+)
nimble install claw

# 2. Create a company
claw co create /path/to/MyCompany.nims

# 3. Authenticate an LLM provider
claw provider auth deepseek    # prompts for API key

# 4. Start the gateway
claw gateway

# 5. Send a message
claw agent send Lexi "hello, what can you do?"
```

For a real example, look at [templates/clawfiles/SunGrow.nims](templates/clawfiles/SunGrow.nims) — a solar-fleet monitoring company with MCP server, scheduled jobs, and multi-region support.

---

## Command reference

```
claw gateway [--stdio]                    Run the agent gateway

claw co create [<file|url|claw:co>] [--as=<name>]
claw co update [--restart] [--no-pull]    Regenerate BASE.json + optional git pull
claw co push [<url>]                      Publish as a git repo
claw co pull                              Fetch + merge upstream
claw co diverge [--remove-origin]         Fork point
claw co list                              All companies with status + token usage

claw provider auth <name>                 Verify + store an API key
claw provider list [--verify]             All providers + status + usage
claw provider add/set/remove              Manage the global catalog

claw model list [--owner=<v>] [--has=<cap>] [--latest] [--all-versions]
claw model refresh [<provider>]           Live-fetch model lists
claw model add/set/remove <prov> <id>     Manual catalog edits

claw skill list                           Installed skills + provenance
claw skill new <name>                     Scaffold a private skill
claw skill share/unshare <name>           Toggle private ↔ public API
claw skill install <ref>                  github: / claw: / URL / path
claw skill auth <name> [--region=<r>]     Populate required env vars
claw skill sync [<name>]                  Pull upstream bundled updates

claw agent list / caps <name> / send <name> <message>
```

---

## Architecture

```
Channel ── MessageBus ── Gateway ── AgentLoop ── Provider(LLM) ── Tool(MCP/Shell)
                                       │
                                   Cortex (world graph, RBAC)
                                       │
                              Session (JSON history per user)
```

- **Channels** (`src/claw/channels/`): Telegram, Discord, QQ, Feishu/Lark, DingTalk, WhatsApp, nMobile, MaixCam, plus stdio for CLI
- **Gateway** (`src/claw.nim`): the long-running process; routes messages, manages lifecycles
- **AgentLoop** (`src/claw/agent/loop.nim`): LLM conversation loop with tool-calling iterations
- **Cortex** (`src/claw/agent/cortex.nim`): world graph (People, AIs, Companies) with RBAC
- **Providers** (`src/claw/providers/`): HTTP client via curly (libcurl — reliable TLS across providers)
- **Tools** (`src/claw/tools/`): filesystem, shell, web, cron, git, MCP, hardware (i2c/spi), TTS, ...
- **Skills** (`src/claw/skills/`): SKILL.md parsers + loader + indexer
- **Services** (`src/claw/services/`): CronService, HeartbeatService
- **Daemon dashboard** (`src/claw/daemon_orch.nim`): the 🦞 nimclaw
  tab in Zen. Pure TTML producer — emits markup strings to Zen over a
  Unix socket and never imports any rendering code. See
  [`docs/dashboard-architecture.md`](./docs/dashboard-architecture.md)
  for the four-layer model (claw → ttml → tui → zen) and the
  HTMX/Web-Components analog it follows.

---

## Design principles

1. **Single source of truth** — provider endpoints, canonical model facts, skill bootstraps, and companies all live in one well-known place each. No overlay files, no reconciliation layer.
2. **Git is the distribution system** — no separate registry. Company dir → `.git`. Skill dir → `.git` (when independently sourced). `claw co push/pull` = `git push/pull` with ergonomics.
3. **Every lifecycle is symmetric** — `add/list/set/remove` for providers. `new/share/sync/install/remove` for skills. Same verbs across object types.
4. **Agents use skills; admins install them** — `install_skill` is not an agent tool. `shell` can install packages only if the skill's SKILL.md declares it and the admin runs `claw co install`.
5. **Isolation by default** — every company has its own `.env`, workspace, credentials, gateway PID. Cross-company access is explicit (`claw:<co>/...`).
6. **Explicit provenance** — every skill ref is scheme'd (`claw:`, `github:`, bundled by name). `skill list` shows REFERENCE for every row. Diff of two BASE.nims shows exactly what differs.

---

## Requirements

- Nim 2.0+
- Go 1.21+ (for the NKN + Lark channel bridges)
- `libcurl` (provided by system on most platforms)

---

## Status

Functional. Used daily. API stable for the commands documented above — breaking changes are called out in release notes. Active areas of evolution: multi-model routing heuristics, template registries, per-message budget caps. See [issues](https://github.com/JK8769/claw.nim/issues) for the roadmap.

---

## License

MIT. Contributions welcome — see [`CLAUDE.md`](CLAUDE.md) for the design pattern, or just open a PR with your own skill/template/provider.
