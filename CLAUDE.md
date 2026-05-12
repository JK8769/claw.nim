# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is Claw

Claw is an AI agent framework written in Nim. Single binary, multi-channel, any LLM. Connects to chat channels (Telegram, Discord, QQ, Feishu, DingTalk, WhatsApp, nMobile) and routes messages through AI agents backed by configurable LLM providers. The default agent is named "Lexi".

## Build & Run

```bash
nimble install -y
nimble build

# Create a company
claw create templates/clawfiles/MyCompany.nims

# Run gateway (daemon mode)
claw gateway --service MyCompany

# Run gateway (Zen stdio mode)
claw gateway --stdio --service MyCompany

# Run tests
nimble test
```

Requires Nim 2.0+. Build flags `--define:ssl --define:release --threads:on` are set in `claw.nimble` and `config.nims`.

## Architecture

### Single Binary

`claw` is the only binary. It has two modes:
- `claw gateway` — long-running process with agents, channels, cron
- All other commands — one-shot CLI (reads/writes disk, exits)

### Zen Integration (stdio + mmap)

When `claw gateway --stdio` is spawned by Zen:
- **stdin**: JSONL commands from Zen (chat messages, clicks)
- **stdout**: JSONL events to Zen (dashboard mount, chat tokens, status)
- **mmap**: shared memory for real-time data (agent tables, activity log)

No sockets between Claw and Zen.

### 3-Tier Capability Model

- **System** — built-in tools compiled into `claw` (`src/claw/tools/`). Bundled skills shipped with the distribution at `skills/` are selected into Tier 2 by the company's ClawDSL.
- **Company** — declared in ClawDSL, installed at `~/.nimclaw-<Co>/workspace/skills/<name>/`. Each skill is a self-contained package — `SKILL.md`, `src/`, `scripts/`, `bin/` all under one folder. Per-agent access via `uses "skill-name"` in `.nims`. MCP servers compiled to `workspace/skills/<name>/bin/<name>` are auto-loaded for all agents.
- **Workstation** — agent-authored at runtime under `workspace/offices/<agent>/workstation/{skills,mcp,script}/`. Private to the authoring agent until a human graduates them to Tier 2.

### SKILL.md Schema

```yaml
---
name: skill-name
version: 1.0.0
description: "..."
operations: [op1, op2]          # optional: sub-playbooks
requires:
  tools: [http_request, shell]  # claw tools this skill uses
  deps:                          # system packages
    - {package: playwright, manager: npm}
  env: [API_KEY]                 # env vars needed
---
```

### ClawDSL Resolver

At `claw create` time, ClawDSL reads each skill's frontmatter and resolves the transitive
set of tools/deps/envs per agent. Output lands in `BASE.json` per agent and a `claw.lock`
file captures versions + content hashes for reproducibility.

### Framework Catalogs as Single Source of Truth (SSoT)

The framework ships JSON catalogs under `res/` that the ClawDSL auto-fills from
during BASE.nims evaluation. **BASE.nims should never duplicate what's in a
catalog — operators declare only the overrides they actually need.**

| Catalog | Holds | Auto-fills into BASE.nims |
|---|---|---|
| `res/providers.json` | `apiBase`, `envKey`, `authHeader`, `verifyPath`, `defaultModel`, `local` per provider | `provider "name":` blocks |
| `res/models.json` | per-provider model catalogs + canonical model registry (context_length, capabilities, pricing) | model metadata seen by `claw model list` |
| `res/channels.json` | channel types + their required auth fields | `channel "name":` discovery |
| `tools/registry/manifest.nim` | tool definitions compiled into the binary | tool discovery for agent grants |

Example — minimum provider declaration:
```nim
provider "opencode-go":
  models "mimo-v2.5", "mimo-v2.5-pro"
# apiBase + apiKey auto-fill from res/providers.json (envKey → ${OPENCODE_GO_API_KEY})
```

Operators add `apiBase "..."` / `apiKey "..."` lines only to override the catalog
default (custom endpoint, hardcoded key, etc.).

**Name normalization**: catalogs may use display names (`"OpenCode Go"`) while
BASE.nims tends to use slug form (`"opencode-go"`). Both sides are lowercased
and space→hyphen normalized before lookup. When adding a new resource type
that bridges catalog ↔ DSL, apply the same normalization or names will silently
mismatch.

**Implementation reference**: `getProviderDefault` + `normalizeProviderKey` in
`src/claw/clawdsl.nim`. When adding a new framework catalog, follow the same
pattern: data in `res/<type>.json`, DSL macro consults the catalog, BASE.nims
carries only overrides.

**Anti-pattern to avoid**: hardcoded `case` blocks that duplicate catalog data.
The DSL had one of these for providers (`case name.toLowerAscii of "deepseek":
...`) — it diverged from `res/providers.json` over time, silently missed
half the catalog (e.g. `opencode-go`), and forced operators to repeat
metadata that should have been auto-filled. If you find yourself writing one,
read from the catalog instead.

**NimScript constraint**: `BASE.nims` is evaluated by NimScript (via
`nim e BASE.nims` in `rebuildBaseJson`). Any module the DSL imports must work
in NimScript's sandboxed VM:
- Wrap `getAppDir`, `createDir`, and other forbidden procs in
  `when not defined(nimscript) and not defined(js):` blocks.
- Prefer `currentSourcePath()` over `getAppDir()` for path resolution —
  works in both compiled and NimScript contexts.
- File reads (`readFile`, `fileExists`, `parseJson`, `walkDir`) are allowed.

### Naming: code modules vs tool surface

Code modules are named after what they ARE (the substrate). Tools are named
after what they ENABLE (the capability the user invokes). The same data
layer can carry an anatomical/structural name internally and a functional
name in the tool surface — these should NOT be the same name.

| Code module (substrate) | Tool surface (capability) | Why |
|---|---|---|
| `cortex.nim` (world graph: people, agents, relations, RBAC) | `social` (query/who/update/invite/redeem/customers) | The cortex is the brain organ; "social ability" is what it enables. Operators read tool names thousands of times daily; surface should map to what they DO. |
| `bus.nim`, `mailbox.nim` (queues, JSON files) | `mail` (send persistent message) | Substrate vs capability |
| `reply_unified.nim` (Feishu format guards, CardKit promotion) | `reply` (respond to current partner) | Substrate name carries implementation detail; tool name is the user verb |
| `memory_unified.nim` + `agent/memory.nim` | `memory` (store / recall / verify) | Verb is the affordance |

Anti-pattern (caught in May 2026): a tool named `query_graph` exposed the
"graph" data-structure name to the agent surface — generic, didn't say
WHICH graph or WHAT lived in it. The agent (and the LLM reading the tool
list) had to infer the connection between "graph" and "the people/customers
my company knows about." Renaming the tool to `social` while keeping
`cortex.nim` as the implementation module fixed the operator/LLM UX
without losing any framework-internal precision.

**Rule of thumb when adding a new tool:**
1. Pick the name an operator would type into a help search: "How do I
   …?" The verb in their question is the right tool prefix.
2. If you find yourself naming a tool after a file path, a class, or a
   data structure, stop. Name it after the capability instead — and
   leave the file/class/structure name unchanged in code.

### Message Flow

`Channel → MessageBus → Gateway → AgentLoop → LLM Provider → MessageBus → Channel`

1. **Channels** (`src/claw/channels/`) — Each channel polls or listens for messages.
2. **MessageBus** (`src/claw/bus.nim`) — Thread-safe async queue.
3. **Gateway** (`src/claw/gateway.nim`) — Main loop. Routes messages to agents.
4. **AgentLoop** (`src/claw/agent/loop.nim`) — LLM conversation loop with tools.
5. **Cortex** (`src/claw/agent/cortex.nim`) — World graph with entities, relationships, RBAC.
6. **LLM Providers** (`src/claw/providers/`) — HTTP via `curly`. OpenAI-compatible APIs.
7. **Tools** (`src/claw/tools/`) — Filesystem, shell, web, cron, git, memory, MCP, hardware.
8. **Skills** (`src/claw/skills/`) — Loadable SKILL.md files and OpenClaw plugins.
9. **Services** (`src/claw/services/`) — CronService, HeartbeatService.
10. **Sessions** (`src/claw/session.nim`) — Conversation history as JSON files.
11. **ClawDSL** (`src/claw/clawdsl.nim`) — Declarative `.nims` scripts for company setup.

### Configuration

- Config lives in `~/.nimclaw/` (override with `NIMCLAW_DIR` env var).
- Config types in `src/claw/config.nim`. Serialized with `jsony`.
- `.env` files loaded from CWD and config dir.

### Key Dependencies

- `jsony` — JSON serialization
- `docopt` — CLI dispatch
- `curly` — HTTP client (libcurl)
- `ws` — WebSocket client
- `nimcrypto` — Cryptographic operations
- `nimsync` — Synchronization primitives
