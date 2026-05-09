# Tool System Architecture

Single source of truth for everything tool-related in claw.

## TL;DR for contributors

To **add a new framework tool**:

1. Create `src/claw/tools/<file>.nim` with the tool's `type`, `proc new<X>Tool*(...)`, and the four `Tool` methods (`name`, `description`, `parameters`, `execute`).
2. Add an entry to `AllTools` in [`src/claw/tools/registry/manifest.nim`](../src/claw/tools/registry/manifest.nim).
3. Add a `regTagged(...)` call in [`src/claw/agent/loop.nim`](../src/claw/agent/loop.nim) (the import list at the top + a registration call near the others).

That's it. No other files to edit. Boot validation will warn on the next gateway start if you missed step 2 or 3.

To **rename a tool**: change `method name*(t)` in the source file AND the `name` field in its manifest entry. Boot validation catches if they disagree. Every consumer (defaults list, heartbeat allowlist, external floor, comm category, CLI displays) auto-syncs.

To **delete a tool**: remove the source file + the manifest entry + the `regTagged` call. Boot validation flags any remaining references.

## The single source of truth

[`src/claw/tools/registry/manifest.nim`](../src/claw/tools/registry/manifest.nim) declares every framework-shipped tool as a `seq[ToolSpec]`. Each entry carries:

| Field | Purpose |
|---|---|
| `name` | Canonical tool name; **must equal** what `method name*(t)` returns. Boot validation enforces. |
| `description` | One-line description shown in `claw tools list` and (for some tools) the LLM tool listing. |
| `tags` | Categorization for `find_tools` discovery + search hints. |
| `domain` | Subdirectory the source lives in (denormalized for fast filter). |
| `default` | Auto-grant to every agent at config-resolve time. |
| `heartbeatSafe` | Allowed during heartbeat ticks (system sender, low trust). |
| `externalAllowed` | Callable by external (guest/customer) callers without explicit grant. |
| `category` | Human-readable bucket (`comm`, `self-management`, `system`, `web`, `admin`, `customer`, `vendor`, `mcp`, `skills`, `tasks`). Drives the `category == "comm"` filter for the TC-2 nudge counter. |
| `version` | Reserved for future compat checks. `"1.0.0"` for current. |

## Derived consumers

Every tool-name list in the codebase derives from the manifest:

```
src/claw/tools/registry/manifest.nim::AllTools   ← THE SoT
              ↓
              ├─→ defaultToolNames()             →  defaultTools (clawdsl)
              ├─→ heartbeatSafeToolNames()       →  HeartbeatAllowedTools (registry)
              ├─→ externalAllowedToolNames()     →  ExternalAllowedTools + Guest role grant
              ├─→ commToolNames()                →  CommTools (loop.nim TC-2 nudge)
              ├─→ AllTools.mapIt(it.name)        →  builtinTools (skill→tool fallback), cli_admin caps
              └─→ Boot validation guard          →  warns on manifest↔registry drift
```

**Zero hand-maintained tool-name lists exist anywhere in `src/claw/`.** Edit the manifest; everything downstream follows.

## Per-file ToolSpec consts

Each tool source file MAY also export a `const ToolSpec*` near the top:

```nim
import spec

const ToolSpec* = spec(
  name = "memory",
  description = "cross-source memory: query past experiences, ...",
  tags = @["memory", "core"],
  domain = "agent",
  default = true,
  heartbeatSafe = false,
  category = "self-management",
)

type UnifiedMemoryTool* = ref object of Tool ...
method name*(t: UnifiedMemoryTool): string = "memory"
```

These per-file consts are **redundant documentation** — the manifest is canonical. They exist so:
- Reading the source file in isolation tells you the tool's full metadata.
- Future work could derive the manifest from per-file consts (true distributed SoT) — currently the manifest hardcodes for simplicity.

If a per-file const drifts from the manifest entry, we currently don't catch it (only manifest↔registry mismatches are validated). Adding cross-validation is a future hardening.

## Operator surface (`claw tools` CLI)

```bash
# Inspect
claw tools list [--domain=<d>] [--default] [--heartbeat-safe] [--format=table|json]
claw tools show <name> [--format=text|json]

# Per-agent grant management (overlay; doesn't touch BASE.nims)
claw tools grant <name> --agent=<a>      # writes <service>/tool_grants.json
claw tools revoke <name> --agent=<a>     # subtractive — final word

# Static check (CI-friendly)
claw tools validate                       # exits 1 on manifest issues
```

The `tool_grants.json` file is git-tracked in the company repo. Grants are additive; revokes are the final word.

## Auto-update from upstream

```nims
# In BASE.nims (opt-in; default off)
updates:
  enabled true
  branch "main"
  check_interval_hours 4
  auto_apply false           # true = pull+build+restart automatically
  notify_agent "Lexi"        # who gets the heads-up mail
```

When enabled, the gateway registers a scheduled job (`auto-update-check`) that polls `git fetch origin/<branch>` every `check_interval_hours`. If `auto_apply` is true, runs the apply path automatically; otherwise drops a notification mail in `notify_agent`'s inbox.

Manual operator commands (work regardless of the `updates:` block):

```bash
claw upgrade --check           # see if update available
claw upgrade [--branch=<b>]    # pull + build + atomic binary swap (gateway must be restarted)
claw upgrade --rollback        # restore claw.previous
claw upgrade --no-restart      # stage only, don't stop gateway
```

Atomic safety: build outputs to `claw.new`; previous binary saved as `claw.previous`. If anything fails, the previous binary is preserved.

## Boot-time validation

Every `AgentLoop` creation runs:

```
for spec in AllTools:
  if not registry.has(spec.name):
    warn "Manifest declares unregistered tool"
for name in registry.list():
  if name.startsWith("mcp_"): continue          # MCP forge tools register dynamically
  if manifest.toolByName(name).isNone:
    warn "Tool registered with no manifest entry (drift)"
```

These warnings appear in gateway logs every time an AgentLoop is created. CI-friendly check: `claw tools validate`.

## Hot-reload semantics

| Change | Restart required? |
|---|---|
| Edit a tool source file | Yes (rebuild) |
| Edit a `ToolSpec` const | Yes (compile-time data) |
| Add/remove a tool from the manifest | Yes |
| `claw tools grant/revoke` (per-agent overlay) | No (resolver re-reads on next `claw co update`; gateway picks up on next prompt build for that agent) |
| Forge an MCP tool via `forge_mcp_tool` | No (MCP tools are separate process binaries, registered dynamically) |

True per-tool hot-reload of framework tools would require dynamic loading or MCP-style separate processes per tool — out of scope; covered partially by the auto-update flow (rebuild + restart with session preservation across the brief downtime).

## Background / why this exists

Before the SSoT refactor, tool names were declared in **6 separate places**:

- Tool source `method name*` declaration (canonical)
- `regTagged(...)` in loop.nim (registration)
- `clawdsl.nim::defaultTools` (auto-grant list, hand-maintained)
- `tools/registry.nim::HeartbeatAllowedTools` (hand-maintained)
- `tools/registry.nim::ExternalAllowedTools` (hand-maintained)
- `agent/loop.nim::CommTools` (hand-maintained)
- `clawdsl.nim::builtinTools` (hand-maintained skill→tool fallback)
- `clawdsl.nim` Guest role grant (hand-maintained)
- `cli_admin.nim` caps display strings (hand-maintained)
- Skill `requires.tools` frontmatter (per-skill)

We hit drift bugs in 5+ of these in a single day in May 2026 (e.g., new `workstation` tool not in defaults → Lexi reported "I don't have a workstation tool"; cli_admin advertising `memory_store/recall/list/forget` for weeks after they were dead).

The manifest collapses 5 of those into one. Every consumer derives. Adding a tool now requires editing exactly: source + `regTagged` + manifest entry. Boot validation catches inconsistency.

## File map

| File | Role |
|---|---|
| [`src/claw/tools/spec.nim`](../src/claw/tools/spec.nim) | `ToolSpec` type + `spec(...)` constructor helper |
| [`src/claw/tools/registry/manifest.nim`](../src/claw/tools/registry/manifest.nim) | `AllTools` SoT + derivation procs (`defaultToolNames`, `heartbeatSafeToolNames`, `externalAllowedToolNames`, `commToolNames`) |
| [`src/claw/cli_tools.nim`](../src/claw/cli_tools.nim) | `claw tools list/show/grant/revoke/validate` implementations |
| [`src/claw/cli_upgrade.nim`](../src/claw/cli_upgrade.nim) | `claw upgrade` — manual git-pull-build-restart with rollback |
| [`src/claw/services/auto_update.nim`](../src/claw/services/auto_update.nim) | Scheduled-job orchestrator for `updates:` block |
