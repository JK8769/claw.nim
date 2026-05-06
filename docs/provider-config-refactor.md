# Provider config refactor

**Status:** Phases 1–3 landed and pushed. Cleanup of `default_provider` /
`default_model` field readers remains as a follow-up.
**Scope landed:** ~410 lines across DSL, gateway, agent loop, CLI, and
the four bundled BASE.nims templates.
**Commits:** `a0f7ab0` (Phase 1), `ad94fc9` (Phase 2), `0fb26a8` (Phase 3).

## TL;DR

Three redundant concepts collapse into a clean two-layer model:

- **Company layer** (operational): ordered list of providers — credentials,
  endpoints, which models each serves. Position-0 has no special meaning
  beyond "first lookup target when several providers serve the same model."
- **Agent layer** (capability): each agent declares an ordered list of
  *models* it wants. First model is the agent's primary; subsequent
  models are fallbacks in order. The framework looks up the serving
  provider for each model on demand.

`default_provider`, `default_model`, and per-agent `provider` fields all
disappear — they're either derivatives of the above or vestigial.

## Current state (what gets cleaned up)

### Three places "default" lives today

1. `cfg.default_provider` (string) — set to `spec.providers[0].name` at
   `clawdsl.nim:1009`.
2. `cfg.default_model` (string) — set to `spec.providers[0].defaultModel`.
3. Each agent's `provider` and `model` fields (`clawdsl.nim:1017-1018`) —
   default to the above when not declared.

So the source-side IS already an ordered list (`spec.providers: seq[ClawProvider]`),
and "default" is always just `providers[0]`. The redundancy is on the
*output / runtime* side — BASE.json carries `default_provider` separately,
gateway code reads it, and `buildProviderChain` does the
"primary then everything else" dance instead of just iterating the list.

### Per-agent provider field is misleading

```nim
agent "Lexi":
  model "deepseek-v4-flash"
  provider "deepseek"   # ← does nothing useful
```

The `provider` line implies you can pick a different provider while
keeping a specific model. You can't — `deepseek-v4-flash` is only served
by `deepseek`, and a `kimi` endpoint won't recognize that model name.
Today the only effect of an agent's `provider` field is selecting which
key in `graph.providers` is used as the "primary" — but the *model*
already determines that uniquely (within the company's providers list).

### Fallback semantics are inverted

Today: "if THIS PROVIDER is down, switch to ANOTHER PROVIDER with whatever
model it happens to serve." So when DeepSeek 402's, every agent — Lexi,
Devon, Atlas — falls back to `opencode-go / kimi-k2.5` regardless of what
they actually wanted.

Cleaner: "if THIS MODEL is unavailable, try the NEXT MODEL on the agent's
declared list." Devon (who explicitly wants `deepseek-v4-pro`, with
`deepseek-v4-flash` as fallback) gets a chain that stays inside DeepSeek.
Lexi (who declared `kimi-k2.5` as her fallback) crosses providers cleanly.

## Proposed end state

### BASE.nims after migration

```nim
# Company layer — credentials, endpoints, what each provider serves.
# Order in the list matters only when multiple providers serve the same
# model name; the first match wins.
provider "deepseek":
  apiKey "${DEEPSEEK_API_KEY}"
  defaultModel "deepseek-v4-flash"
  models "deepseek-v4-flash", "deepseek-v4-pro"

provider "opencode-go":
  apiKey "${OPENCODE_GO_API_KEY}"
  defaultModel "kimi-k2.5"
  models "kimi-k2.5", "qwen3.5-plus", ...

# Agent layer — each agent declares its preferred model chain.
# First model = primary. Subsequent models = fallbacks (in order).
agent "Lexi":
  models "deepseek-v4-flash", "kimi-k2.5"
  # primary on DeepSeek, falls cross-provider to kimi if DS is down

agent "Devon":
  models "deepseek-v4-pro", "deepseek-v4-flash"
  # both on DeepSeek; thoroughness preferred, speed as fallback within
  # the same provider

agent "Atlas":
  # no `models` declared → inherits company default chain:
  #   [providers[0].defaultModel, providers[1].defaultModel, ...]
  # so Atlas gets `["deepseek-v4-flash", "kimi-k2.5"]` for free
```

No `default_provider`. No `default_model`. No per-agent `provider`. The
intended deployment is expressible in the BASE.nims grammar without any
of those three fields.

### Resolution at chain-build time

For each agent (per-agent chain build, not company-wide):

```
chain = []
for model in agent.models:
  # find the FIRST provider in the company list that serves this model
  for provider in company.providers:
    if model in provider.models:
      chain.add(FallbackEntry(provider, model, name=provider.name))
      break
  # if no provider serves this model: warn + skip; agent's intent
  # can't be satisfied from current company config
return newFallbackLLMProvider(chain)
```

Each agent gets its own `FallbackLLMProvider` instance. Underlying
HTTPProvider instances can still be shared by reference — there's no
need to instantiate one per agent — but the *chain* (which entries, in
what order) is per-agent.

### `/model` semantics after refactor

| Command | Effect |
|---|---|
| `/model` (in Lexi's chat) | Show Lexi's current model chain + which entry is sticky for this session |
| `/model deepseek-v4-pro` (in Lexi's chat) | Move `deepseek-v4-pro` to position 0 in Lexi's `models` list (if it's already in the list) or insert at position 0 (if new) |
| `/model list` (in any agent chat) | Query Lexi's current primary provider's `/models` API |
| `/co model deepseek-v4-pro` | Company-wide: edit `providers` list ordering or `defaultModel` (rare) |

The "switch primary" gesture (`/model X`) is now per-agent and operates
on the agent's own model list. Company-wide changes go through `/co`.

### Sticky-fallback state

Already per-(provider-instance, sessionKey). Since each agent now has
its own provider instance, sticky state is naturally per-(agent, session)
without any extra plumbing. When `/model` reorders an agent's chain,
that agent's `FallbackLLMProvider` is rebuilt — fresh sticky table.

## Migration path

### Phase 1 — runtime aligns with source (smallest, ~80 lines)

Land this without touching DSL or templates. Pure runtime cleanup:

1. `gateway.nim` `buildProviderChain` iterates `graph.providers.getFields()`
   in declaration order. Drops the `if pName == cfg.default_provider:
   continue` skip. First provider in the dict IS primary.
2. `cfg.default_provider` becomes a derived value (read at boot from
   `providers[0].name`); writes are removed.
3. `/model X:Y` reorders `graph.providers` in BASE.json (move X to front)
   instead of setting a separate pointer.
4. Per-agent `provider` field still parsed; deprecated warning logged.

After phase 1, behavior is unchanged for existing deployments because
your BASE.nims already declares DeepSeek first.

### Phase 2 — agents declare models, not provider (~120 lines)

1. `clawdsl.nim` `ClawAgent` schema: add `models: seq[string]`.
   Keep `provider` and `model` (singular) parseable for back-compat;
   migrate them to `models = @[model]` if `models` not declared.
2. `gateway.nim` `buildProviderChain` becomes `buildProviderChainForAgent(
   agentName)`. Looks up `cfg.agents.named[agentName].models`, walks each
   model to find its serving provider, builds the chain.
3. Office init at startup: `office.provider = buildProviderChainForAgent(
   agentName)` — each office gets its own chain.
4. `/model X` in agent chat edits that agent's `models[0]` (writes to
   BASE.json's `agents.named[<agent>].models`).
5. Telemetry / billing / `/status` readers that consume `cfg.default_*`:
   audit and migrate to `office.model` per-agent.

### Phase 3 — BASE.nims template updates (~50 lines)

1. SunGrowCN's BASE.nims: drop `provider "X"` from each `agent` block.
   Replace `model "X"` with `models "X"` (singular → list).
2. Bundled templates in `templates/clawfiles/`: same migration.
3. Migration helper: a `claw co migrate` subcommand that reads an old-
   shape BASE.nims and emits the new shape — useful for existing
   companies that aren't editing by hand.

After phase 3, `default_provider` and `default_model` can be removed
from `Config`, ClawSpec, and BASE.json entirely.

## Trade-offs and open questions

**Q: When multiple providers serve the same model name, which wins?**

A: First match in the company providers list. This is the only place
provider declaration order matters operationally. Document clearly.

**Q: What if an agent's `models[0]` isn't served by any provider?**

A: Warn at chain-build time, skip that entry, fall back to position 1.
If NO entry resolves, the chain is empty and any LLM call raises a
clear "agent X has no resolvable models" error. Operator fixes the
mismatch by either declaring a provider that serves it or adjusting
the agent's models list.

**Q: How does the heartbeat session pick a model?**

A: Heartbeat is system-fired (sender = `system:heartbeat`). It runs
under a specific agent (Lexi, currently). Uses that agent's chain.

**Q: Per-agent or shared HTTPProvider instances?**

A: Share the underlying HTTPProvider per-(provider-name) — same auth,
same connection pool. Each agent's FallbackLLMProvider holds references
to the shared instances in its own ordered chain. Memory is bounded by
provider count (typically 2–5), not agent count.

**Q: Does `/model X` persist across gateway restart?**

A: Yes — writes to BASE.json (Phase 1) or agent's `models` field in
BASE.json (Phase 2). To make it survive `claw co update` (which
regenerates BASE.json from BASE.nims), the operator either edits
BASE.nims directly or uses `/co model` (Phase 3 — writes to BASE.nims).

## Order of work — DONE

1. ✅ Phase 1 (`a0f7ab0`) — runtime aligned with source. Providers list
   is the chain; `/model X:Y` reorders the list and overwrites the
   chosen provider's defaultModel. `cfg.default_provider` no longer
   consulted in chain build (still kept in sync for back-compat
   readers).
2. ✅ Phase 2 (`ad94fc9`) — agent layer collapses to `models seq`.
   `clawdsl.nim` ClawAgent gained `models`; `gateway.nim` got
   `buildProviderChainForAgent`; `makeAgentLoop` chooses per-agent
   chain when `models` is declared, falls back to company chain when
   only deprecated singular `model "X"` is set (preserves auto-fallback
   safety net for existing files).
3. ✅ Phase 3 (`0fb26a8`) — bundled templates demonstrate the new
   syntax; `claw co migrate` subcommand mechanically rewrites old
   files in-place with a `.bak` backup.

## Verified end-to-end

- Lexi declared `models "deepseek-v4-flash", "kimi-k2.5"` → log emitted
  `Per-agent: registered primary {model=deepseek-v4-flash}` and
  `Per-agent: registered fallback #1 {model=kimi-k2.5}` followed by
  `Per-agent chain built {agent=Lexi, models=deepseek-v4-flash,kimi-k2.5}`.
- Atlas/Devon retained singular `model "X"` → no per-agent firing,
  they share the company default chain.
- `claw co migrate --file=…` correctly:
   - rewrites `  model "X"  # comment` → `  models "X"  # comment`
   - drops `  provider "Y"` lines inside agent blocks
   - leaves provider blocks (with colon) and already-migrated agents
     (`models "X"`) alone
- `claw co migrate --apply` writes the new file + a `.bak` backup.

## Remaining cleanup (deferred — not blocking)

Several modules still read `cfg.default_provider` / `cfg.default_model`:

- `cli_admin.nim:155, 163, 198, 225, 238` — admin status output
- `doctor.nim:62-65` — config sanity check
- `context.nim:109, 118` — context rendering
- `cli_service.nim:267` — service-mode startup
- `tools/delegate.nim:177` — delegate fallback
- `gateway.nim:268-269` — translation helper
- `agent/cortex.nim:1021` — graph entity hint

These can be migrated to read `providers[0].name` / `providers[0].defaultModel`
in a follow-up pass. Once all readers are migrated, the fields can be
dropped from `Config`, `ClawSpec`, and BASE.json entirely.

## Pointers to current code

- `src/claw/clawdsl.nim:197` — `ClawSpec.providers: seq[ClawProvider]`
- `src/claw/clawdsl.nim:1009-1010` — where `defProvider`/`defModel` are computed (deletable in phase 2)
- `src/claw/clawdsl.nim:1017-1018` — agent's provider/model defaults to company (rewrite in phase 2)
- `src/claw/clawdsl.nim:1095-1106` — BASE.json writer (drop default_* fields in phase 2)
- `src/claw/gateway.nim:316-368` — `buildProviderChain` (rewrite in phase 1; per-agent in phase 2)
- `src/claw/gateway.nim:423-555` — `/model` slash handler (rewrite for per-agent semantics in phase 2)
- `src/claw/providers/fallback.nim` — sticky-fallback already in place; no schema change needed
