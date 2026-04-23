## billing/gate — pre-LLM subscription enforcement.
##
## Given a graph + nc:id + current time, returns a GateResult telling
## the gateway whether to let the message through, block it with a
## canned response, or let it pass with a prepended grace banner.
## Pure decision function — no I/O, no mutation (the caller persists
## `lastWarnedDay` after emitting a grace banner). Easy to unit test.
##
## Decision tree (external customers only — internal tier bypasses):
##
##   no subscription stamped          →  gdBlockNoPlan   (strict policy)
##   plan == suspended                →  gdBlockSuspended
##   plan == expired OR trial past expires
##                                    →  gdBlockExpired
##   today's tokens ≥ dailyTokens     →  gdBlockDailyLimit
##   plan == trial AND in grace       →  gdAllowWithWarning (once per day)
##   otherwise                        →  gdAllow

import std/[options, strutils, tables]
import ../agent/cortex
import subscription
import usage

type
  GateDecision* = enum
    gdAllow
    gdAllowWithWarning
    gdBlockNoPlan
    gdBlockRecycled
    gdBlockSuspended
    gdBlockExpired
    gdBlockDailyLimit

  GateResult* = object
    decision*:       GateDecision
    ## Subscription snapshot at decision time — callers that need plan,
    ## dailyTokens, expires, suspendReason for rendering grab them here.
    sub*:            Option[Subscription]
    ## Today's token total (tokens_in + tokens_out). Only meaningful
    ## for daily-limit decisions and for display.
    tokensToday*:    int
    ## For gdAllowWithWarning: days left in the trial (1..GraceDays).
    daysRemaining*:  int
    ## For gdAllowWithWarning: did the *same UTC day* already emit a
    ## banner? True means the gateway should render the banner and
    ## call `markWarned`; False means suppress (already warned today).
    shouldWarnNow*:  bool

proc subscriptionGate*(graph: WorldGraph, ncId: string,
                      now: int64): GateResult =
  ## Entry point. Caller provides a resolved ncId for an external-tier
  ## customer; internal users should skip calling this proc entirely.
  if graph == nil or not ncId.startsWith("nc:"):
    return GateResult(decision: gdAllow)
  let id = parseAlias(ncId)
  if uint32(id) == 0 or not graph.entities.hasKey(id):
    return GateResult(decision: gdAllow)   # defensive — unknown entity → don't block

  # Soft-deleted customers — blocked regardless of subscription state.
  # Operators restore via `claw user restore <nc:id>`.
  if isRecycled(ncId):
    return GateResult(decision: gdBlockRecycled)

  let subOpt = loadSubscription(ncId)

  # No subscription stamped → strict block. Operators can backfill via
  # `claw user subscription activate <nc:id>`. The SUB column makes
  # unstamped customers visible in `user list`.
  if subOpt.isNone:
    return GateResult(decision: gdBlockNoPlan)

  let s = subOpt.get()
  case s.plan
  of pkSuspended:
    return GateResult(decision: gdBlockSuspended, sub: some(s))
  of pkExpired:
    return GateResult(decision: gdBlockExpired, sub: some(s))
  of pkTrial:
    if now >= s.expires:
      return GateResult(decision: gdBlockExpired, sub: some(s))
  of pkActive:
    discard  # paid plans don't auto-expire

  # Daily-limit check. Pre-message: if today's total already met or
  # exceeded the cap, block. The message that *pushed* over the cap
  # was allowed to finish (Phase 4 accounting happens after the LLM
  # response); the NEXT message is what gets blocked here.
  let u = loadUsage(ncId)
  let tokensToday = u.tokensIn + u.tokensOut
  if s.dailyTokens > 0 and tokensToday >= s.dailyTokens:
    return GateResult(
      decision: gdBlockDailyLimit, sub: some(s), tokensToday: tokensToday)

  # Grace window — trial only, final N days. Warn once per UTC day.
  if s.plan == pkTrial and inGracePeriod(s, now):
    let daysLeft = daysRemaining(s, now)
    let alreadyWarnedToday = u.lastWarnedDay == u.day and u.lastWarnedDay.len > 0
    return GateResult(
      decision: gdAllowWithWarning, sub: some(s),
      tokensToday: tokensToday, daysRemaining: daysLeft,
      shouldWarnNow: not alreadyWarnedToday)

  GateResult(decision: gdAllow, sub: some(s), tokensToday: tokensToday)
