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
## primary fresh. Operator restarts the gateway when they want every
## session to re-probe — that's the manual-recovery contract.
##
## The sticky key is a logical session id (e.g. `nc_5`,
## `system_heartbeat`). Callers pass it in `options["__session_key"]`
## as a JString. The key is consumed and removed before options is
## forwarded to the underlying provider, so vendor APIs never see it.
## A call without that option behaves exactly like the old per-call
## semantics — start at 0, no sticky update.

import std/[asyncdispatch, tables, strutils, json, locks]
import types as providers_types
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

const SessionKeyOption* = "__session_key"
  ## Option key callers use to opt into sticky behaviour. Stripped
  ## before options is forwarded to the underlying provider so the
  ## vendor API never sees it.

proc newFallbackLLMProvider*(entries: seq[FallbackEntry]): FallbackLLMProvider =
  ## Construct a fallback chain. The first entry is the primary; subsequent
  ## entries are tried in order on fall-back-eligible errors.
  doAssert entries.len >= 1, "FallbackLLMProvider requires at least one provider"
  result = FallbackLLMProvider(
    entries: entries,
    sessionEntry: newTable[string, int]())
  initLock(result.sessionLock)

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

proc advanceSticky(p: FallbackLLMProvider, sessionKey: string, newIdx: int) =
  ## Ratchet the session forward to newIdx. Never moves backward — even
  ## if a transient probe somehow succeeds at a lower index, we keep
  ## the highest-seen failure point so behaviour stays predictable.
  if sessionKey.len == 0: return
  acquire(p.sessionLock)
  defer: release(p.sessionLock)
  let current = p.sessionEntry.getOrDefault(sessionKey, 0)
  if newIdx > current:
    p.sessionEntry[sessionKey] = newIdx

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

  let startIdx = p.getStickyStart(sessionKey)

  var lastErr: ref Exception = nil
  for i in startIdx ..< p.entries.len:
    let entry = p.entries[i]
    # Use the caller-supplied model only on the FIRST attempt of THIS
    # call (i.e. at startIdx, not necessarily 0); subsequent fallbacks
    # use each entry's configured model so we don't hand a deepseek
    # model name to a kimi backend.
    let callModel =
      if i == startIdx and model.len > 0: model
      else: entry.model
    try:
      return await entry.provider.chat(messages, tools, callModel, fwdOptions)
    except IOError as e:
      lastErr = e
      let isLast = i == p.entries.high
      if isLast or not shouldFallback(e.msg):
        # Even when re-raising, ratchet the session forward so a
        # follow-up call doesn't waste another round-trip on the
        # same broken entry. The next call will start at i+1 (or
        # immediately raise "chain exhausted" if there's no i+1).
        p.advanceSticky(sessionKey, i + 1)
        raise
      let preview =
        if e.msg.len > 120: e.msg[0 ..< 120] & "…"
        else: e.msg
      let nextEntry = p.entries[i + 1]
      p.advanceSticky(sessionKey, i + 1)
      warnCF("fallback_provider",
             "Sticky fallback to next provider",
             {"session": sessionKey,
              "failed": entry.name,
              "failed_model": callModel,
              "next": nextEntry.name,
              "next_model": nextEntry.model,
              "reason": preview}.toTable)
    except CatchableError as e:
      # Non-IOError (parse, type, etc.) — don't fall back, don't
      # ratchet (the entry isn't necessarily broken; the bug is on
      # the caller's side). Surface to caller.
      raise e
  if lastErr != nil:
    raise lastErr
  raise newException(IOError,
    "FallbackLLMProvider: chain exhausted for session '" &
    sessionKey & "' — primary and all fallbacks have failed in this " &
    "session. Restart the gateway to reset, or top up / fix the " &
    "broken provider.")
