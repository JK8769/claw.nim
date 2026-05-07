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
## ## Routing decisions: ProviderHealthRegistry only
##
## Earlier iterations had per-session sticky state (a monotonic
## ratchet that remembered which entry each session had been routed
## to). That collided with the cross-session circuit breaker: sessions
## got ratcheted past entries that were *cooling down*, locking them
## out even after the underlying provider recovered. With health doing
## the cross-session work at the better layer, sticky was net-negative
## — removed entirely.
##
## Every chat() call now walks entries from 0; the registry filters
## known-broken ones. Recovery is fully automatic for transient errors
## (cooldown expires → next probe → success → flip to healthy);
## persistent errors (402 / 401) require `/provider reset <name>`.

import std/[asyncdispatch, tables, strutils, json]
import types as providers_types
import ./health
import ../logger

type
  FallbackEntry* = object
    provider*: providers_types.LLMProvider
    model*: string                    ## model id for THIS provider when active
    name*: string                     ## display name for logging
    contextWindow*: int               ## input+output capacity from the model
                                      ## catalog. 0 = unknown (skip-on-size
                                      ## disabled for this entry — chain falls
                                      ## back to the old "always try" behaviour).
                                      ## Populated by chain builders in
                                      ## gateway.nim from `resolveContextWindow`.

  FallbackLLMProvider* = ref object of providers_types.LLMProvider
    entries*: seq[FallbackEntry]      ## ordered: entries[0] is primary
    healthRegistry*: ProviderHealthRegistry
                                      ## Cross-session circuit breaker.
                                      ## nil disables the check.

const
  SessionKeyOption* = "__session_key"
    ## Option key callers use to pass their session id for log context.
    ## Stripped before options is forwarded to the underlying provider
    ## so vendor APIs never see it. Kept after sticky removal because
    ## the failure-fallback log lines still want to identify which
    ## session triggered the event.

  ContextHeadroomPct* = 75
    ## Allow the request payload to consume at most 75% of an entry's
    ## contextWindow. Two reasons for the wide reserve:
    ##
    ## 1. Output budget — every model needs space for its response.
    ##    Most LLMs we use cap output at 8K-32K, but reasoning models
    ##    (DeepSeek V4 thinking, GPT-o1) can blow that out with
    ##    chain-of-thought tokens.
    ##
    ## 2. Estimator slop. `estimateRequestTokens` uses `bytes/4` as
    ##    a proxy. For ASCII / English / JSON that's accurate to
    ##    within ~10%. For Chinese / CJK content, UTF-8 encodes each
    ##    char as 3 bytes, while BPE tokenisers emit ~1 token/char —
    ##    so `bytes/4` UNDER-counts by 1.25-1.5×. A 200K estimate
    ##    can be 260K real on a Chinese-heavy thread.
    ##
    ## With 75% headroom: estimate=750K against a 1M model → cap=750K
    ## → real ~975K (worst case 1.3× slop) — still under 1M. For a
    ## 256K kimi-k2.5: cap=192K → real ~250K — under the 262K server
    ## ceiling we observed. Bumping above 80% risks Moonshot-style
    ## "exceeded model token limit" rejections; lowering below 70%
    ## starts wasting headroom unnecessarily on ASCII workloads.

proc newFallbackLLMProvider*(entries: seq[FallbackEntry],
                              healthRegistry: ProviderHealthRegistry = nil):
                              FallbackLLMProvider =
  ## Construct a fallback chain. The first entry is the primary; subsequent
  ## entries are tried in order on fall-back-eligible errors.
  ##
  ## `healthRegistry` is the cross-session circuit breaker. When non-nil,
  ## the chain consults it before each entry — skipping providers that
  ## are unhealthy (402/401) or cooling down (429/5xx) without paying
  ## the round-trip. nil disables the check (chain always probes every
  ## entry on each call — useful for tests).
  doAssert entries.len >= 1, "FallbackLLMProvider requires at least one provider"
  result = FallbackLLMProvider(
    entries: entries,
    healthRegistry: healthRegistry)

method getDefaultModel*(p: FallbackLLMProvider): string =
  if p.entries.len > 0: p.entries[0].model else: ""

proc estimateRequestTokens*(messages: seq[providers_types.Message],
                             tools: seq[providers_types.ToolDefinition]): int =
  ## Heuristic char/4 estimator. Mirrors the one in `agent/loop.nim`
  ## (kept local so the chain doesn't need to import the loop). Counts
  ## every field that goes on the wire to the LLM:
  ##
  ##   - message content + reasoning_content + tool_call_id + name
  ##   - each `tool_calls` entry's id/type/function name+arguments
  ##   - tool definitions (name + description + JSON schema)
  ##
  ## The on-wire JSON has additional structural overhead (delimiters,
  ## key names) that this misses; in practice that's <10% across
  ## realistic request shapes, well within the 10% headroom we
  ## already reserve via `ContextHeadroomPct`.
  var totalChars = 0
  for m in messages:
    totalChars += m.content.len
    totalChars += m.reasoning_content.len
    totalChars += m.tool_call_id.len
    totalChars += m.name.len
    for tc in m.tool_calls:
      totalChars += tc.id.len
      totalChars += tc.`type`.len
      totalChars += tc.function.name.len
      totalChars += tc.function.arguments.len
      totalChars += tc.name.len
      for k, v in tc.arguments.pairs:
        totalChars += k.len
        totalChars += ($v).len
  for t in tools:
    totalChars += t.`type`.len
    totalChars += t.function.name.len
    totalChars += t.function.description.len
    if t.function.parameters != nil:
      totalChars += ($t.function.parameters).len
  totalChars div 4

proc fitsEntry(estTokens: int, entry: FallbackEntry): bool =
  ## True when the request payload is small enough for this entry, OR
  ## the entry's contextWindow is unknown (0). Caller should use this
  ## as a SKIP filter — entries that don't fit are silently passed
  ## over rather than tried-and-failed-with-400.
  if entry.contextWindow <= 0: return true
  let cap = (entry.contextWindow * ContextHeadroomPct) div 100
  estTokens <= cap

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

proc effectiveContextWindow*(p: FallbackLLMProvider): int =
  ## Which contextWindow should drive summarisation thresholds RIGHT
  ## NOW, given the chain's current health state?
  ##
  ## The goal: when the primary is healthy, the loop should get the
  ## primary's full headroom (no penalty for having a smaller
  ## fallback in the chain). When the primary is unhealthy and a
  ## smaller-window fallback would be the next attempt, the loop
  ## needs to summarise EARLIER so the thread fits the fallback —
  ## otherwise the chain size-skips every entry and exhausts.
  ##
  ## Resolution:
  ##   1. Primary (entries[0]) is healthy AND has a known window
  ##      → primary.contextWindow.
  ##   2. Otherwise → smallest contextWindow across currently-usable
  ##      entries. If primary is sad, this is the cap that any next
  ##      attempt will hit; summarising to fit it keeps the chain
  ##      operational.
  ##   3. No usable entries with known windows → 0. Caller falls
  ##      back to whatever static default it knows (typically the
  ##      AgentLoop's construction-time `contextWindow`).
  if p.entries.len == 0: return 0
  let primary = p.entries[0]
  let primaryHealthy =
    p.healthRegistry == nil or p.healthRegistry.isUsable(primary.name)
  if primaryHealthy and primary.contextWindow > 0:
    return primary.contextWindow
  # Primary sad → take the smallest usable fallback.
  for entry in p.entries:
    let healthy =
      p.healthRegistry == nil or p.healthRegistry.isUsable(entry.name)
    if not healthy: continue
    if entry.contextWindow <= 0: continue
    if result == 0 or entry.contextWindow < result:
      result = entry.contextWindow

proc nextUsableEntry*(p: FallbackLLMProvider, estTokens: int = 0):
                     tuple[idx: int, name: string, model: string,
                           exhausted: bool] =
  ## Public introspection: which entry would the chain try on its
  ## next call right now, given current health state (and optionally,
  ## a request-size estimate)? Used by `/model` to show what the
  ## chain will do without forcing an actual probe.
  ##
  ## When `estTokens > 0`, also applies the context-window filter
  ## that `chat()` uses. Pass 0 (default) to inspect health-only —
  ## useful when you want to know "what's broken right now" without
  ## a specific payload in mind.
  ##
  ## Returns `exhausted=true` when every entry is unusable per the
  ## registry (or, with size-checking on, every entry that's healthy
  ## also can't fit). Operators see this as a "fix a provider, wait
  ## for cooldown, or shorten the prompt" signal.
  for i, entry in p.entries:
    let healthy =
      p.healthRegistry == nil or p.healthRegistry.isUsable(entry.name)
    if not healthy: continue
    if estTokens > 0 and not fitsEntry(estTokens, entry): continue
    return (i, entry.name, entry.model, false)
  (p.entries.len, "exhausted", "", true)

method chat*(p: FallbackLLMProvider,
             messages: seq[providers_types.Message],
             tools: seq[providers_types.ToolDefinition],
             model: string,
             options: Table[string, JsonNode]):
             Future[providers_types.LLMResponse] {.async.} =
  # Pull the session key out of options and strip it before forwarding,
  # so the underlying HTTP provider doesn't relay this internal field
  # into the vendor's chat-completions JSON body. Used for log context
  # only (not routing).
  var sessionKey = ""
  var fwdOptions = options
  if fwdOptions.hasKey(SessionKeyOption):
    let v = fwdOptions[SessionKeyOption]
    if v.kind == JString: sessionKey = v.getStr()
    fwdOptions.del(SessionKeyOption)

  # Estimate request size once before the entry loop — the same
  # payload is checked against every entry's window. This is an
  # input-size estimate; the response budget is reserved by
  # `ContextHeadroomPct`. Cost is O(messages + tools), runs once.
  let estTokens = estimateRequestTokens(messages, tools)

  var lastErr: ref Exception = nil
  var skippedForSize = 0    # for the "no entry fits" diagnostic message
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
    # Adaptive context-window filter: skip entries whose window
    # cannot accommodate this request. Without this, the chain would
    # forward a 600K-token request to a 200K-window fallback,
    # triggering a misleading 400 from the fallback even though the
    # primary handled the same payload fine. Skip-on-size is a
    # silent pass-over (not a failure recorded against the entry),
    # because the entry is fundamentally working — it just can't fit
    # this particular payload.
    if not fitsEntry(estTokens, entry):
      skippedForSize.inc
      let cap = (entry.contextWindow * ContextHeadroomPct) div 100
      infoCF("fallback_provider",
             "Skipping provider — request too large for context window",
             {"provider": entry.name,
              "model": entry.model,
              "session": sessionKey,
              "est_tokens": $estTokens,
              "ctx_window": $entry.contextWindow,
              "input_cap": $cap}.toTable)
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
  # Distinguish the two ways the chain can exhaust without ever
  # making a real call. "Health" exhaustion → wait/reset/topup.
  # "Size" exhaustion → summarise/shorten/route to a bigger-window
  # provider. Same surface, different remedy; the message has to
  # tell operators which one they're hit by.
  if skippedForSize > 0 and skippedForSize == p.entries.len:
    raise newException(IOError,
      "FallbackLLMProvider: chain exhausted — request payload " &
      "(~" & $estTokens & " tokens) exceeds every entry's context " &
      "window. Either summarise the session " &
      "(`/session reset` for a fresh thread), reduce the prompt, or " &
      "configure an entry with a larger context window. Run " &
      "`/model` to see each entry's window.")
  raise newException(IOError,
    "FallbackLLMProvider: chain exhausted — every provider in the " &
    "chain is currently unhealthy or cooling down. Use " &
    "`/provider` to inspect, `/provider reset <name>` after fixing " &
    "the underlying issue, or `/model X:Y` to switch primary.")
