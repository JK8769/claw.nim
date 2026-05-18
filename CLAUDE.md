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

### macOS: kill-then-rebuild discipline (or you wedge processes)

**Never run `nimble install -y` or `nimble build` while a previous `claw daemon` / `claw gateway` / any other claw or zen process is still alive.** macOS handles in-place executable replacement strictly: when `mv` overwrites a binary that's mmap'd by a running process, the next page fault that needs to read a not-yet-resident code page from disk hits a stale inode and the process enters `UE` (uninterruptible exit) — kernel cannot recover or reap it. The process is permanently stuck until reboot, even with `kill -9`. Linux survives this via `/proc/<pid>/exe`; macOS does not.

Symptom: `ps aux` shows processes with status `UE` or `UEs+`, age growing, can't be killed. Subsequent `claw daemon start` and `claw daemon status` invocations may also wedge for related reasons (dyld cache inconsistency).

Correct order for every rebuild cycle:

```bash
# 1. Stop and verify EVERYTHING gone first
pkill -TERM -f "claw"; pkill -TERM -f "^zen"
sleep 1
pkill -KILL -f "claw"; pkill -KILL -f "^zen"
sleep 1
ps aux | grep -E "claw|^owaf.*zen" | grep -v grep | grep -v claude   # must be empty

# 2. Clean up sockets / pid files
rm -f ~/.nimclawd/admin.sock ~/.nimclawd/admin.pid ~/.zen/zen.sock
rm -f ~/.nimclawd/*/nimclaw.sock 2>/dev/null

# 3. THEN rebuild
nimble install -y

# 4. THEN restart
claw daemon start
```

If you see UE processes accumulating, that's a sign the kill-then-rebuild order was violated somewhere. They'll sit there until reboot but don't block new processes (they hold no live sockets/locks).

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

### LLM as tool (multimodal via routing, not via primary model)

Rather than requiring the agent's primary model to handle every modality
natively (vision, audio, video), the framework treats **specialist models
as tools** that any agent can invoke regardless of their own model's
capabilities. The mechanism is the `capability` tool's `invoke` action:

```
capability action=invoke tag=vision input=/path/img.jpg prompt="what is this?"
```

The framework:
1. Finds a model with the requested tag (preferring the agent's primary
   if eligible — saves a round-trip and preserves context — else local
   models like Ollama+gemma4, else cheapest configured remote)
2. Reads the input file (with path-safety + IAM gates), base64-encodes
3. Constructs an OpenAI-multimodal request (`content` is an array of
   text + image_url blocks)
4. POSTs to the chosen provider, parses, returns TEXT to the calling
   agent

The agent's primary model stays text-in/text-out — no need for
multimodal `Message.content_blocks` plumbing in the primary conversation.
A reasoning model on `deepseek-v4-pro` (no vision) can still "see" an
image by calling `capability action=invoke tag=vision ...` and reasoning
on the returned description.

**Why this is the preferred design over native multimodal everywhere:**
- Not every agent's primary model supports every modality
- Models drift in their multimodal support across vendor releases —
  centralizing the routing isolates that churn
- Cost/latency tradeoffs differ per modality (vision often cheap on
  local Ollama; reasoning often warrants the big paid model). Routing
  by capability lets each modality pick its best-fit model independently
- Specialist routing composes: `tag=audio` can hit Whisper, `tag=vision`
  can hit gemma4 or mimo, all through one invocation pattern
- Tag-shaped feature gates work uniformly: a future `tag=code-exec`,
  `tag=image-gen`, `tag=embedding` extends the same primitive

The legacy `image_analyze` tool (hardcoded Ollama+gemma4 dispatch) is a
specific instance of this pattern — kept as a pass-through during the
transition but marked deprecated in its description, pointing at
`capability action=invoke tag=vision`.

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
