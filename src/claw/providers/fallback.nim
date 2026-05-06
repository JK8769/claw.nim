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

  FallbackLLMProvider* = ref object of providers_types.LLMProvider
    entries*: seq[FallbackEntry]      ## ordered: entries[0] is primary
    healthRegistry*: ProviderHealthRegistry
                                      ## Cross-session circuit breaker.
                                      ## nil disables the check.

const SessionKeyOption* = "__session_key"
  ## Option key callers use to pass their session id for log context.
  ## Stripped before options is forwarded to the underlying provider
  ## so vendor APIs never see it. Kept after sticky removal because
  ## the failure-fallback log lines still want to identify which
  ## session triggered the event.

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

proc nextUsableEntry*(p: FallbackLLMProvider):
                     tuple[idx: int, name: string, model: string,
                           exhausted: bool] =
  ## Public introspection: which entry would the chain try on its
  ## next call right now, given current health state? Used by
  ## `/model` (and any future status surface) to show what the
  ## chain will do without forcing an actual probe.
  ##
  ## Returns `exhausted=true` when every entry is unusable per the
  ## registry. Operators see this as a "fix a provider or wait for a
  ## cooldown to expire" signal.
  for i, entry in p.entries:
    if p.healthRegistry == nil or
       p.healthRegistry.isUsable(entry.name):
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
