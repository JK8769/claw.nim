## FallbackLLMProvider — wrap a primary + ordered fallbacks.
##
## Rolls over to the next provider when the primary throws a class of
## error we judge "the OTHER provider might succeed" — explicitly:
##   - 402 / "Insufficient Balance"   primary is out of credit
##   - 401                              primary's API key is invalid
##   - 429 (after the http_provider's   primary is rate-limit-exhausted
##     own retry exhaustion)
##   - 5xx                              primary's backend is down
##   - "Curly request failed"           network failure to primary
##
## Does NOT fall back on:
##   - 400 (validation)                 the fallback will reject too
##   - 4xx other than 401/402/429       likely caller-side
##
## Each provider is paired with a `model` to use when it's the active
## one — different vendors don't share model names (deepseek-v4-flash
## is not a thing on opencode-go), so the fallback runs with the
## fallback provider's own defaultModel rather than blindly forwarding
## the primary's model.
##
## ## Fallback scope: per-session sticky
##
## Once a session has fallen back from entry N to entry N+1, all
## subsequent calls FROM THAT SAME SESSION skip 0..N entirely and go
## straight to N+1. Sticks for the session's lifetime; resets only when
## the gateway restarts.
##
## The previous design re-probed the primary on every call. With a 2-
## provider chain and an "out-of-balance until human action" failure
## mode, that meant 100% of the workload was paying a wasted DeepSeek
## round-trip per turn just to confirm the same 402 — and getting
## thousands of doomed POSTs per long-running session.
##
## Per-session stickiness costs auto-recovery: when the primary comes
## back, existing sessions stay on the fallback. New sessions probe
## primary fresh. Operator does `/model X:Y` (which rebuilds the chain
## with a fresh sticky table) when they want every session to re-probe.
##
## Sticky state is **persisted to disk** at the configured `persistPath`
## (typically `$NIMCLAW_DIR/automation/sticky-fallback.json`). Without
## persistence, every gateway restart wipes the sticky table — so every
## session would pay one wasted DeepSeek probe just to re-discover the
## 402 right after a restart, surprising operators who reasoned about
## the system globally ("we already know DeepSeek is broken"). The
## persisted file uses the same `automation/` dir as cron jobs and
## maps sessionKey → entry index. Writes happen synchronously on every
## sticky advance — file is small (one JSON object), advances are
## infrequent, so the cost is negligible.
##
## The sticky key is a logical session id (e.g. `nc_5`,
## `system_heartbeat`). Callers pass it in `options["__session_key"]`
## as a JString. The key is consumed and removed before options is
## forwarded to the underlying provider, so vendor APIs never see it.
## A call without that option behaves exactly like the old per-call
## semantics — start at 0, no sticky update.

import std/[asyncdispatch, tables, strutils, json, locks, os]
import types as providers_types
import ./health
import ../logger

type
  FallbackEntry* = object
    provider*: providers_types.LLMProvider
    model*: string                    ## model id for THIS provider when active
    name*: string                     ## display name for logging

  FallbackLLMProvider* = ref object of providers_types.LLMProvider
    entries*: seq[FallbackEntry]      ## ordered: entries[0] is primary
    sessionEntry: TableRef[string, int]
                                      ## Session id → starting entry idx.
                                      ## A session never moves backward
                                      ## once it has fallen back. See module
                                      ## docstring for the rationale.
    sessionLock: Lock                 ## Guards sessionEntry — multiple
                                      ## agents may call concurrently for
                                      ## different (or the same) session.
    persistPath*: string              ## File path for sticky-state
                                      ## persistence. Empty = in-memory
                                      ## only (test mode). Writes happen
                                      ## synchronously on every advance.
    healthRegistry*: ProviderHealthRegistry
                                      ## Cross-session circuit breaker.
                                      ## Consulted before each chat()
                                      ## attempt — entries whose provider
                                      ## is unhealthy or cooling are
                                      ## skipped. Updated on every
                                      ## success/failure. Optional
                                      ## (nil disables the check, falls
                                      ## back to per-session sticky only).

const SessionKeyOption* = "__session_key"
  ## Option key callers use to opt into sticky behaviour. Stripped
  ## before options is forwarded to the underlying provider so the
  ## vendor API never sees it.

proc loadStickyFromDisk(path: string): TableRef[string, int] =
  ## Read the persisted sticky table from disk if the file exists.
  ## Returns an empty table on first run, parse failure, or empty path
  ## (test mode). Failure cases are non-fatal — the provider behaves
  ## as if no sticky state existed yet.
  result = newTable[string, int]()
  if path.len == 0 or not fileExists(path): return
  try:
    let j = parseFile(path)
    if j.kind != JObject: return
    for k, v in j.fields:
      if v.kind == JInt:
        result[k] = v.getInt()
  except CatchableError as e:
    warnCF("fallback_provider",
           "Failed to load sticky state — starting fresh",
           {"path": path, "error": e.msg}.toTable)

proc newFallbackLLMProvider*(entries: seq[FallbackEntry],
                              persistPath: string = "",
                              healthRegistry: ProviderHealthRegistry = nil):
                              FallbackLLMProvider =
  ## Construct a fallback chain. The first entry is the primary; subsequent
  ## entries are tried in order on fall-back-eligible errors.
  ##
  ## `persistPath` is where sticky state is read/written. Empty means
  ## in-memory only (used by tests; production callers should pass a
  ## stable path under the company's automation dir).
  ##
  ## `healthRegistry` is the cross-session circuit breaker. When non-nil,
  ## the chain consults it before each entry — skipping providers that
  ## are unhealthy (402/401) or cooling down (429/5xx) without paying
  ## the round-trip. nil disables the check.
  doAssert entries.len >= 1, "FallbackLLMProvider requires at least one provider"
  result = FallbackLLMProvider(
    entries: entries,
    sessionEntry: loadStickyFromDisk(persistPath),
    persistPath: persistPath,
    healthRegistry: healthRegistry)
  initLock(result.sessionLock)
  if persistPath.len > 0 and result.sessionEntry.len > 0:
    infoCF("fallback_provider",
           "Loaded sticky state",
           {"path": persistPath,
            "sessions": $result.sessionEntry.len}.toTable)

method getDefaultModel*(p: FallbackLLMProvider): string =
  if p.entries.len > 0: p.entries[0].model else: ""

proc shouldFallback(errMsg: string): bool =
  ## Heuristic: does this error message indicate the OTHER provider might
  ## succeed? See module doc for the categorisation rationale.
  if errMsg.len == 0: return false
  if "Curly request failed" in errMsg: return true
  if "Insufficient Balance" in errMsg: return true
  # Status-code substrings appear as `API error (NNN):` per http.nim's
  # raise pattern. Match exact codes we've categorised as "other side
  # might be fine".
  for code in ["(402)", "(401)", "(429)", "(500)", "(502)", "(503)", "(504)"]:
    if "API error " & code in errMsg: return true
  false

proc getStickyStart(p: FallbackLLMProvider, sessionKey: string): int =
  ## Look up where THIS session should start in the chain. Returns 0
  ## if no sticky state exists or sessionKey is empty.
  if sessionKey.len == 0: return 0
  acquire(p.sessionLock)
  defer: release(p.sessionLock)
  result = p.sessionEntry.getOrDefault(sessionKey, 0)

proc currentEntryFor*(p: FallbackLLMProvider, sessionKey: string):
                     tuple[idx: int, name: string, model: string,
                           exhausted: bool] =
  ## Public introspection: which entry is THIS session currently sticky
  ## on? Used by `/model` (and any future status surface) to show the
  ## actually-active provider/model rather than just the configured
  ## primary — they diverge whenever the session has fallen back.
  ##
  ## Returns `exhausted=true` when the session has ratcheted past every
  ## entry (i.e. all providers have failed for this session and the
  ## next call would raise "chain exhausted"). Operators see this as
  ## a "restart gateway / fix provider" signal.
  let i = p.getStickyStart(sessionKey)
  if i >= p.entries.len:
    return (i, "exhausted", "", true)
  (i, p.entries[i].name, p.entries[i].model, false)

proc persistStickyUnsafe(p: FallbackLLMProvider) =
  ## Caller must hold sessionLock. Writes the table out to disk as JSON
  ## ({sessionKey: idx, …}). No-op when persistPath is empty.
  if p.persistPath.len == 0: return
  try:
    let dir = parentDir(p.persistPath)
    if dir.len > 0 and not dirExists(dir): createDir(dir)
    var j = newJObject()
    for k, v in p.sessionEntry.pairs: j[k] = %v
    writeFile(p.persistPath, $j)
  except CatchableError as e:
    warnCF("fallback_provider",
           "Failed to persist sticky state",
           {"path": p.persistPath, "error": e.msg}.toTable)

proc advanceSticky(p: FallbackLLMProvider, sessionKey: string, newIdx: int) =
  ## Ratchet the session forward to newIdx. Never moves backward — even
  ## if a transient probe somehow succeeds at a lower index, we keep
  ## the highest-seen failure point so behaviour stays predictable.
  ## Persists the updated table to disk on every advance (sync write,
  ## tiny file, infrequent — cost is negligible vs the LLM call that
  ## just failed).
  if sessionKey.len == 0: return
  acquire(p.sessionLock)
  defer: release(p.sessionLock)
  let current = p.sessionEntry.getOrDefault(sessionKey, 0)
  if newIdx > current:
    p.sessionEntry[sessionKey] = newIdx
    p.persistStickyUnsafe()

method chat*(p: FallbackLLMProvider,
             messages: seq[providers_types.Message],
             tools: seq[providers_types.ToolDefinition],
             model: string,
             options: Table[string, JsonNode]):
             Future[providers_types.LLMResponse] {.async.} =
  # Pull the session key out of options and strip it before forwarding,
  # so the underlying HTTP provider doesn't relay this internal field
  # into the vendor's chat-completions JSON body.
  var sessionKey = ""
  var fwdOptions = options
  if fwdOptions.hasKey(SessionKeyOption):
    let v = fwdOptions[SessionKeyOption]
    if v.kind == JString: sessionKey = v.getStr()
    fwdOptions.del(SessionKeyOption)

  # Per-session sticky state is DEPRECATED — the health registry
  # supersedes it (cross-session, transient-aware, auto-recovers on
  # cooldown). Routing decisions now come from the registry alone.
  # We always start the chain walk at 0 and let registry.isUsable()
  # filter; sessions that previously got ratcheted past every entry
  # by sticky-on-skip can now recover automatically once each
  # provider's health flips back to usable.
  #
  # The persistence file (sticky-fallback.json) is left untouched on
  # disk for debugging / audit. We just stop consulting it here.
  discard sessionKey  # kept in scope for log messages below

  var lastErr: ref Exception = nil
  for i in 0 ..< p.entries.len:
    let entry = p.entries[i]
    # Cross-session circuit breaker: skip without calling if the
    # registry says this provider is broken. Costs zero round-trips
    # for known-broken providers, even on the first session that
    # would have discovered them.
    if p.healthRegistry != nil and
       not p.healthRegistry.isUsable(entry.name):
      infoCF("fallback_provider",
             "Skipping provider — health registry says unusable",
             {"provider": entry.name,
              "session": sessionKey}.toTable)
      continue
    # Use the caller-supplied model only on the FIRST attempt of THIS
    # call; subsequent fallbacks use each entry's configured model
    # so we don't hand a deepseek model name to a kimi backend.
    let callModel =
      if i == 0 and model.len > 0: model
      else: entry.model
    try:
      let resp = await entry.provider.chat(messages, tools, callModel, fwdOptions)
      if p.healthRegistry != nil:
        p.healthRegistry.recordSuccess(entry.name)
      return resp
    except IOError as e:
      lastErr = e
      # Update health registry FIRST — even if this is the last entry
      # and we're about to re-raise, the next call (in this session
      # or any other) benefits from knowing this provider is broken.
      if p.healthRegistry != nil:
        discard p.healthRegistry.recordFailure(entry.name, e.msg)
      let isLast = i == p.entries.high
      if isLast or not shouldFallback(e.msg):
        raise
      let preview =
        if e.msg.len > 120: e.msg[0 ..< 120] & "…"
        else: e.msg
      let nextEntry = p.entries[i + 1]
      warnCF("fallback_provider",
             "Falling back to next provider",
             {"session": sessionKey,
              "failed": entry.name,
              "failed_model": callModel,
              "next": nextEntry.name,
              "next_model": nextEntry.model,
              "reason": preview}.toTable)
    except CatchableError as e:
      # Non-IOError (parse, type, etc.) — surface to caller.
      raise e
  if lastErr != nil:
    raise lastErr
  raise newException(IOError,
    "FallbackLLMProvider: chain exhausted — every provider in the " &
    "chain is currently unhealthy or cooling down. Use " &
    "`/provider` to inspect, `/provider reset <name>` after fixing " &
    "the underlying issue, or `/model X:Y` to switch primary.")
