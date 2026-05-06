## ProviderHealthRegistry — cross-session health tracking for providers
## in a FallbackLLMProvider chain.
##
## ## Why provider-level (not session-level)
##
## Earlier per-session sticky-fallback (see fallback.nim's
## `sessionEntry`) had each session independently discover that a
## provider was broken. With many sessions and a long-lived 402
## (Insufficient Balance), that meant N wasted probes — one per
## session — to re-confirm what the system already knew. Health is a
## property of the provider, not the session: one failed call should
## benefit every other session immediately.
##
## ## States
##
## - **healthy** — recent success, or never tried. Use freely.
## - **coolingDown** — transient failure (429 rate limit, 5xx server
##   error, Curly network drop). Skipped until `cooldownUntil`; then
##   re-probed on the next call (success → healthy; failure → cool
##   again or escalate to unhealthy).
## - **unhealthy** — persistent failure (402 Insufficient Balance, 401
##   bad API key). Skipped indefinitely; only manual reset clears it.
##   The error class implies operator action is needed (top up
##   balance, fix the API key in `.env`) — auto-retrying just burns
##   throughput.
##
## ## Persistence
##
## State is serialised to a JSON file (typically
## `$NIMCLAW_DIR/automation/provider-health.json`). Loaded at gateway
## startup; written on every state transition. Surviving restart is
## the whole point — operators reason globally ("we know DeepSeek is
## broken"), so the registry has to remember across reboots.
##
## ## Manual reset
##
## Operators clear health when they've topped up balance / fixed a
## key. Two paths:
##   - `/provider reset <name>` — mark one provider healthy
##   - `/model X:Y` — rebuilds the chain (creates a fresh provider
##     instance pointing at a fresh registry path), implicitly
##     resetting all health
##
## A pure cooldown is intentionally not used for 402/401 because
## "wait 1 hour and retry" produces a worse operator experience than
## "tell me when you've fixed it" — fewer surprise auto-retries that
## the operator didn't ask for.

import std/[json, locks, os, strutils, tables, times, options]
import ../logger

type
  HealthState* = enum
    hsHealthy = "healthy"
    hsCoolingDown = "cooling_down"
    hsUnhealthy = "unhealthy"

  ProviderHealth* = object
    state*: HealthState
    lastError*: string
    lastFailureTime*: int64    ## Unix epoch seconds. 0 = never failed.
    lastSuccessTime*: int64    ## Unix epoch seconds. 0 = never succeeded.
    cooldownUntil*: int64      ## Unix epoch seconds. Only meaningful when
                                ## state == hsCoolingDown.

  ProviderHealthRegistry* = ref object
    health: TableRef[string, ProviderHealth]
    persistPath: string
    lock: Lock

const
  CooldownRateLimitSec*  = 60   ## 429 — typical rate-limit window
  CooldownTransientSec*  = 30   ## 5xx, Curly network — transient backend

proc errorClass*(errMsg: string): tuple[
                  state: HealthState, cooldownSec: int] =
  ## Classify a provider error into a health state. Returns the state
  ## the provider should transition to and (for cooling) how long
  ## until re-probe.
  ##
  ## Categorisation rationale:
  ##   - 402 / "Insufficient Balance" → operator must top up; no
  ##     amount of waiting helps. Mark unhealthy.
  ##   - 401 → API key is invalid; needs operator to fix `.env` and
  ##     restart. Mark unhealthy.
  ##   - 429 → rate-limit window typically clears in under a minute.
  ##   - 5xx → transient backend hiccup; usually clears in seconds.
  ##   - Curly request failed → network drop or upstream cut the
  ##     connection mid-stream; same shape as 5xx.
  if "Insufficient Balance" in errMsg or "(402)" in errMsg:
    return (hsUnhealthy, 0)
  if "(401)" in errMsg:
    return (hsUnhealthy, 0)
  if "(429)" in errMsg:
    return (hsCoolingDown, CooldownRateLimitSec)
  for code in ["(500)", "(502)", "(503)", "(504)"]:
    if code in errMsg:
      return (hsCoolingDown, CooldownTransientSec)
  if "Curly request failed" in errMsg:
    return (hsCoolingDown, CooldownTransientSec)
  # Anything else: don't change health (probably a caller-side bug
  # like 400; see fallback.nim's shouldFallback for the same intent).
  (hsHealthy, 0)

# ── Persistence ────────────────────────────────────────────────────

proc serializeHealth(h: ProviderHealth): JsonNode =
  result = %*{
    "state": $h.state,
    "lastError": h.lastError,
    "lastFailureTime": h.lastFailureTime,
    "lastSuccessTime": h.lastSuccessTime,
    "cooldownUntil": h.cooldownUntil,
  }

proc parseHealth(j: JsonNode): ProviderHealth =
  let stateStr = j{"state"}.getStr("healthy")
  result.state = case stateStr
    of "cooling_down": hsCoolingDown
    of "unhealthy":    hsUnhealthy
    else:              hsHealthy
  result.lastError = j{"lastError"}.getStr("")
  result.lastFailureTime = j{"lastFailureTime"}.getBiggestInt(0)
  result.lastSuccessTime = j{"lastSuccessTime"}.getBiggestInt(0)
  result.cooldownUntil = j{"cooldownUntil"}.getBiggestInt(0)

proc loadFromDisk(path: string): TableRef[string, ProviderHealth] =
  result = newTable[string, ProviderHealth]()
  if path.len == 0 or not fileExists(path): return
  try:
    let j = parseFile(path)
    if j.kind != JObject: return
    for k, v in j.fields:
      result[k] = parseHealth(v)
  except CatchableError as e:
    warnCF("provider_health",
           "Failed to load health state — starting fresh",
           {"path": path, "error": e.msg}.toTable)

proc persistUnsafe(reg: ProviderHealthRegistry) =
  ## Caller must hold reg.lock.
  if reg.persistPath.len == 0: return
  try:
    let dir = parentDir(reg.persistPath)
    if dir.len > 0 and not dirExists(dir): createDir(dir)
    var j = newJObject()
    for k, v in reg.health.pairs:
      j[k] = serializeHealth(v)
    writeFile(reg.persistPath, $j)
  except CatchableError as e:
    warnCF("provider_health",
           "Failed to persist health state",
           {"path": reg.persistPath, "error": e.msg}.toTable)

# ── Public API ─────────────────────────────────────────────────────

proc newProviderHealthRegistry*(persistPath: string = ""):
                                ProviderHealthRegistry =
  result = ProviderHealthRegistry(
    health: loadFromDisk(persistPath),
    persistPath: persistPath)
  initLock(result.lock)

proc isUsable*(reg: ProviderHealthRegistry, providerName: string): bool =
  ## Should the chain attempt this provider on the next call?
  ## - healthy: yes
  ## - cooling_down with timer expired: yes (re-probe)
  ## - cooling_down with timer not yet expired: no
  ## - unhealthy: no (manual reset required)
  if reg == nil or providerName.len == 0: return true
  acquire(reg.lock)
  defer: release(reg.lock)
  if not reg.health.hasKey(providerName): return true
  let h = reg.health[providerName]
  case h.state
  of hsHealthy: true
  of hsCoolingDown:
    let now = getTime().toUnix
    now >= h.cooldownUntil
  of hsUnhealthy: false

proc recordSuccess*(reg: ProviderHealthRegistry, providerName: string) =
  ## Mark a provider healthy after a successful call. Resets any
  ## prior failure state — implicit recovery for cooling_down
  ## entries that re-probed and worked.
  if reg == nil or providerName.len == 0: return
  acquire(reg.lock)
  defer: release(reg.lock)
  let now = getTime().toUnix
  var h = reg.health.getOrDefault(providerName,
            ProviderHealth(state: hsHealthy))
  let wasBroken = h.state != hsHealthy
  h.state = hsHealthy
  h.lastSuccessTime = now
  h.lastError = ""
  h.cooldownUntil = 0
  reg.health[providerName] = h
  if wasBroken:
    infoCF("provider_health",
           "Provider recovered",
           {"provider": providerName}.toTable)
  reg.persistUnsafe()

proc recordFailure*(reg: ProviderHealthRegistry, providerName: string,
                     errMsg: string): HealthState =
  ## Update a provider's health from a failure. Returns the new state
  ## so the caller can react (e.g. log "skipping deepseek due to
  ## persistent 402"). Errors that don't match any known class
  ## (probably caller-side bugs like 400) leave health unchanged —
  ## we don't punish a provider for a request the caller mis-built.
  if reg == nil or providerName.len == 0: return hsHealthy
  let (newState, cooldownSec) = errorClass(errMsg)
  if newState == hsHealthy:
    # Unclassified error — don't touch health.
    return hsHealthy
  acquire(reg.lock)
  defer: release(reg.lock)
  let now = getTime().toUnix
  var h = reg.health.getOrDefault(providerName,
            ProviderHealth(state: hsHealthy))
  h.state = newState
  h.lastFailureTime = now
  h.lastError =
    if errMsg.len > 200: errMsg[0 ..< 200] & "…"
    else: errMsg
  h.cooldownUntil = (if cooldownSec > 0: now + cooldownSec else: 0)
  reg.health[providerName] = h
  case newState
  of hsCoolingDown:
    warnCF("provider_health",
           "Provider entering cooldown",
           {"provider": providerName,
            "cooldown_sec": $cooldownSec,
            "reason": h.lastError}.toTable)
  of hsUnhealthy:
    warnCF("provider_health",
           "Provider marked unhealthy — manual reset required",
           {"provider": providerName, "reason": h.lastError}.toTable)
  else: discard
  reg.persistUnsafe()
  newState

proc resetProvider*(reg: ProviderHealthRegistry, providerName: string): bool =
  ## Manual recovery — mark a provider healthy regardless of prior
  ## state. Returns true if the provider had non-healthy state to
  ## clear; false if it was already healthy or unknown.
  if reg == nil or providerName.len == 0: return false
  acquire(reg.lock)
  defer: release(reg.lock)
  if not reg.health.hasKey(providerName): return false
  let prev = reg.health[providerName].state
  if prev == hsHealthy: return false
  let now = getTime().toUnix
  reg.health[providerName] = ProviderHealth(
    state: hsHealthy,
    lastSuccessTime: now)
  reg.persistUnsafe()
  infoCF("provider_health",
         "Provider manually reset to healthy",
         {"provider": providerName,
          "previous_state": $prev}.toTable)
  true

proc snapshot*(reg: ProviderHealthRegistry): seq[tuple[
                  name: string, health: ProviderHealth]] =
  ## Read-only view of the entire registry. Used by `/provider` and
  ## `/model` to render health state to operators.
  if reg == nil: return @[]
  acquire(reg.lock)
  defer: release(reg.lock)
  for k, v in reg.health.pairs:
    result.add((name: k, health: v))
