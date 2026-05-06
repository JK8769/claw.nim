# Fallback architecture

**Status:** stable. Reflects the design after sticky was removed (commit
`9b75251`). Earlier transitional designs are described in commit history
but no longer documented as canonical.

## Two-layer fallback

```
┌────────────────────────────────────────────────────────────────────┐
│ FallbackLLMProvider (chain)                                        │
│   entries: [deepseek/v4-flash, opencode-go/kimi-k2.5, …]          │
│                                                                    │
│ chat() walks entries from index 0 every call. For each entry:     │
│   1. registry.isUsable(entry.name)?                                │
│      → no  → skip silently (zero round-trip)                       │
│      → yes → try entry.provider.chat()                             │
│                                                                    │
│   2. on success → registry.recordSuccess(entry.name); return       │
│   3. on IOError matching shouldFallback() →                        │
│         registry.recordFailure(entry.name, err); try next entry    │
│   4. on IOError not matching shouldFallback() →                    │
│         registry.recordFailure(...); raise                         │
│   5. on other exception → raise (don't penalise the entry)         │
│                                                                    │
│ Chain exhausted (every entry skipped or failed) → raise            │
│ "every provider in the chain is currently unhealthy or cooling..."  │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│ ProviderHealthRegistry (cross-session state)                        │
│                                                                    │
│ Per-provider state, persisted to                                   │
│   $NIMCLAW_DIR/automation/provider-health.json                     │
│                                                                    │
│ States:                                                            │
│   healthy      — recent success or never tried                     │
│   coolingDown  — transient failure with timer (cooldownUntil)      │
│   unhealthy    — persistent failure (manual reset only)            │
│                                                                    │
│ Error → state mapping (errorClass):                                │
│   402 / "Insufficient Balance" → unhealthy (no auto-clear)         │
│   401                          → unhealthy (no auto-clear)         │
│   429                          → coolingDown 60s                   │
│   5xx, "Curly request failed"  → coolingDown 30s                   │
│   anything else (e.g. 400)     → no state change                   │
│                                                                    │
│ Recovery:                                                          │
│   coolingDown timer expires → isUsable returns true → next probe   │
│   probe succeeds            → recordSuccess flips state to healthy │
│   probe fails again         → recordFailure resets cooldown        │
│   unhealthy                 → only resetProvider() clears it       │
│                                                                    │
│ State transitions persist on every change. Surviving restart is    │
│ the whole point — operators reason globally ("we know X is broken")│
└────────────────────────────────────────────────────────────────────┘
```

## Decision: registry only (no per-session state)

Earlier designs had per-session sticky state — a monotonic ratchet that
tracked which entry each session had been routed to. That worked
adequately as a single mechanism but collided with the registry the
moment we added health: sessions got ratcheted past entries that
were merely *cooling down* (not permanently broken), locking them out
of automatic recovery.

The collision exposed the layering issue. Health is a property of the
**provider**, not the session. One session discovering a provider is
broken benefits every session. A monotonic per-session memory of past
failures has no value once the registry knows the same facts at the
better layer.

Sticky removed entirely:

- No `sessionEntry` table on FallbackLLMProvider
- No `sticky-fallback.json` persistence
- No `getStickyStart` / `advanceSticky` / `currentEntryFor` procs
- chat() walks from index 0 every call

## Operator interface

### Inspecting state

```
/provider                    # list every chain provider with health badge
/provider status             # alias for /provider
/model                       # show chain + which entry is "next" given health
```

`/model`'s "Next call will try" line shows the first entry the
registry considers usable. Diverges from the configured primary when
health flags broken upstream entries.

### Recovering from failures

```
/provider reset <name>       # mark <name> healthy; next call probes it
/model X:Y                   # rebuilds the chain (fresh registry-attached
                             # provider instance) — also resets any
                             # transitional state
```

For 402 / 401 (`unhealthy` — operator action required):

1. Fix the underlying issue (top up balance, rotate API key in `.env`)
2. `/provider reset deepseek`
3. Next call probes; success flips state to `healthy`

For 429 / 5xx (`coolingDown` — auto-recovers):

- No action needed. Cooldown expires (60s for 429, 30s for 5xx /
  network), next call probes, success flips state to `healthy`.
- `/provider reset` works too if you want to skip the wait.

## Data shape on disk

`provider-health.json`:

```json
{
  "deepseek": {
    "state": "unhealthy",
    "lastError": "API error (402): Insufficient Balance ...",
    "lastFailureTime": 1778081433,
    "lastSuccessTime": 0,
    "cooldownUntil": 0
  },
  "opencode-go": {
    "state": "healthy",
    "lastError": "",
    "lastFailureTime": 0,
    "lastSuccessTime": 1778081658,
    "cooldownUntil": 0
  }
}
```

Size scales with provider count, not session count or call volume.
Typically <1 KB.

## Trade-offs

**What this design optimises for:**

- Cross-session efficiency (one failed call benefits everyone)
- Auto-recovery for transient errors (cooldowns)
- Predictable behavior under restart (registry persists)
- Clear operator UX (one place to look, one command to reset)

**What it gives up:**

- Per-session preferences. If session A wants to stay on a fallback
  even after the primary recovers, the registry can't represent that
  — it's a single global health view. In practice, no observed
  workload wanted this; the original sticky design only existed to
  remember what each session had independently discovered.
- Fancy backoff (exponential, jittered). Cooldowns are fixed
  durations per error class. Add complexity if you ever observe
  thundering-herd recovery problems.

## Implementation pointers

- `src/claw/providers/fallback.nim` — the chain wrapper
- `src/claw/providers/health.nim` — the registry
- `src/claw/gateway.nim` — `buildProviderChain` /
  `buildProviderChainForAgent` instantiate the chain;
  `/provider`, `/model` slash handlers consult the registry
- Persistence: `$NIMCLAW_DIR/automation/provider-health.json`
