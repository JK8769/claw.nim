## billing/subscription — per-customer runtime state (subscription + lang).
##
## Stored in `$NIMCLAW_DIR/support/billing/customer/<nc_id>.json`, NOT
## on the world graph. `claw co update` regenerates `BASE.json` from
## `BASE.nims` and would wipe anything stamped in `ent.custom` that the
## DSL doesn't persist — subscriptions and the customer's lang stamp
## don't have DSL syntax (and shouldn't; they're operator-managed
## runtime state, not declarative fabric). Keeping them in a sibling
## file makes them naturally immune to `co update` rebuilds, same
## pattern we already use for the per-day token usage counter.
##
## File shape:
##   { "subscription": { plan, started_at, expires, daily_tokens,
##                       suspend_reason (optional) },
##     "lang": "zh" | "en" | ... }
##
## Both fields are optional; missing fields mean "not set" — callers
## fall back to sensible defaults (no subscription → block per Phase 3
## strict policy; no lang → "en").

import std/[json, options, os, strutils, tables, times]
import ../config

const
  TrialDays* = 30            ## Default trial length when auto/CLI activation doesn't override.
  TrialDailyTokens* = 1_000_000  ## Default daily token cap during trial.
                                  ## ~50 typical customer turns at ~20K tokens each
                                  ## (system prompt + handbook + tool schemas for
                                  ## deferred-mode agents can push per-iteration
                                  ## input to 10–15K). Previously 200K which was
                                  ## calibrated for bare-bones chat without the
                                  ## richer context-building of the current stack.
  GraceDays* = 3             ## Final N days of trial show a warning banner but still work.

type
  PlanKind* = enum
    pkTrial = "trial"
    pkActive = "active"
    pkExpired = "expired"
    pkSuspended = "suspended"

  Subscription* = object
    plan*:           PlanKind
    startedAt*:      int64
    expires*:        int64
    dailyTokens*:    int
    suspendReason*:  string

# ── Internal: read/write the customer file ──────────────────────────

proc customerPath*(ncId: string): string =
  ## `support/billing/customer/<nc_7>.json` (colons replaced for portability).
  getNimClawDir() / "support" / "billing" / "customer" /
    (ncId.replace(":", "_") & ".json")

proc loadCustomer(ncId: string): JsonNode =
  ## Returns a fresh empty JObject when the file is missing or unreadable,
  ## so callers can treat the result as a uniform object without nil checks.
  let path = customerPath(ncId)
  if not fileExists(path): return newJObject()
  try:
    let node = parseJson(readFile(path))
    if node.kind == JObject: node else: newJObject()
  except CatchableError: newJObject()

proc saveCustomer(ncId: string, data: JsonNode) =
  let path = customerPath(ncId)
  createDir(path.parentDir)
  writeFile(path, data.pretty(2))

# ── Subscription accessors ──────────────────────────────────────────

proc defaultTrial*(now: int64): Subscription =
  Subscription(
    plan: pkTrial,
    startedAt: now,
    expires: now + TrialDays * 86_400,
    dailyTokens: TrialDailyTokens,
    suspendReason: ""
  )

proc toJson*(s: Subscription): JsonNode =
  result = %*{
    "plan": $s.plan,
    "started_at": s.startedAt,
    "expires": s.expires,
    "daily_tokens": s.dailyTokens
  }
  if s.plan == pkSuspended and s.suspendReason.len > 0:
    result["suspend_reason"] = %s.suspendReason

proc parseSubscription*(node: JsonNode): Option[Subscription] =
  if node == nil or node.kind != JObject: return none(Subscription)
  var s = Subscription()
  try:
    s.plan = parseEnum[PlanKind](node{"plan"}.getStr(""))
    s.startedAt = node{"started_at"}.getBiggestInt(0).int64
    s.expires = node{"expires"}.getBiggestInt(0).int64
    s.dailyTokens = node{"daily_tokens"}.getInt(TrialDailyTokens)
    s.suspendReason = node{"suspend_reason"}.getStr("")
  except CatchableError:
    return none(Subscription)
  some(s)

proc loadSubscription*(ncId: string): Option[Subscription] =
  ## Reads the customer file and extracts the subscription sub-document.
  ## `ncId` is the string form ("nc:7"). No graph lookup.
  if not ncId.startsWith("nc:"): return none(Subscription)
  let data = loadCustomer(ncId)
  if not data.hasKey("subscription"): return none(Subscription)
  parseSubscription(data["subscription"])

proc stampSubscription*(ncId: string, sub: Subscription) =
  ## Write (or overwrite) this customer's subscription. Preserves other
  ## fields in the customer file (lang, future additions).
  if not ncId.startsWith("nc:"): return
  var data = loadCustomer(ncId)
  data["subscription"] = sub.toJson
  saveCustomer(ncId, data)

proc clearSubscription*(ncId: string) =
  ## Remove the subscription field but keep the rest of the customer file.
  if not ncId.startsWith("nc:"): return
  var data = loadCustomer(ncId)
  if data.hasKey("subscription"):
    data.delete("subscription")
    saveCustomer(ncId, data)

proc clearCustomerFile*(ncId: string) =
  ## Called from `user remove` to nuke all per-customer runtime state
  ## for this nc:id (subscription, lang, anything else stored here).
  if not ncId.startsWith("nc:"): return
  let path = customerPath(ncId)
  if fileExists(path):
    try: removeFile(path) except CatchableError: discard

# ── Lang accessors (same file, separate field) ──────────────────────

proc loadLang*(ncId: string, fallback = "en"): string =
  ## Customer language stamp, used by welcome + gate messages.
  if not ncId.startsWith("nc:"): return fallback
  let data = loadCustomer(ncId)
  let l = data{"lang"}.getStr("").strip()
  if l.len > 0: l else: fallback

proc stampLang*(ncId: string, lang: string) =
  if not ncId.startsWith("nc:") or lang.len == 0: return
  var data = loadCustomer(ncId)
  data["lang"] = %lang
  saveCustomer(ncId, data)

# ── Recycle bin (soft delete) ────────────────────────────────────────
#
# `user remove` defaults to soft — stamps `recycled_at` on the customer
# side file but leaves the graph entity, BASE.nims block, and inbound
# relationship edges untouched. Restore is a one-field removal. Hard
# delete via `user remove --hard` does the historical full-delete path.
# See the proposal in the chat log for the full rationale.

type
  RecycleMeta* = object
    at*:     int64    ## Unix timestamp of the soft-remove
    by*:     string   ## nc:id of the operator who issued the remove
    reason*: string   ## Optional free-text reason for the audit trail

proc loadRecycleMeta*(ncId: string): Option[RecycleMeta] =
  ## Returns `some(meta)` when the customer has been soft-removed,
  ## `none` otherwise. Absence of `recycled_at` means "active".
  if not ncId.startsWith("nc:"): return none(RecycleMeta)
  let data = loadCustomer(ncId)
  if not data.hasKey("recycled_at"): return none(RecycleMeta)
  let at = data["recycled_at"].getBiggestInt(0).int64
  if at == 0: return none(RecycleMeta)
  some(RecycleMeta(
    at: at,
    by: data{"recycled_by"}.getStr(""),
    reason: data{"recycled_reason"}.getStr("")
  ))

proc isRecycled*(ncId: string): bool =
  loadRecycleMeta(ncId).isSome

proc markRecycled*(ncId, by, reason: string) =
  ## Flag this customer as soft-removed. Idempotent if already marked.
  if not ncId.startsWith("nc:"): return
  var data = loadCustomer(ncId)
  data["recycled_at"] = %getTime().toUnix
  if by.len > 0:     data["recycled_by"] = %by
  if reason.len > 0: data["recycled_reason"] = %reason
  saveCustomer(ncId, data)

proc unmarkRecycled*(ncId: string) =
  ## Restore a soft-removed customer: strip the recycle metadata but
  ## leave subscription / lang / usage intact (they carried through).
  if not ncId.startsWith("nc:"): return
  var data = loadCustomer(ncId)
  var touched = false
  for k in ["recycled_at", "recycled_by", "recycled_reason"]:
    if data.hasKey(k):
      data.delete(k)
      touched = true
  if touched: saveCustomer(ncId, data)

# ── Pure helpers on Subscription (no I/O) ────────────────────────────

proc daysRemaining*(sub: Subscription, now: int64): int =
  let secs = sub.expires - now
  if secs <= 0: int(secs div 86_400)
  else: int((secs + 86_399) div 86_400)

proc inGracePeriod*(sub: Subscription, now: int64): bool =
  sub.plan == pkTrial and now < sub.expires and
    daysRemaining(sub, now) <= GraceDays

proc isExpired*(sub: Subscription, now: int64): bool =
  case sub.plan
  of pkTrial: now >= sub.expires
  of pkExpired, pkSuspended: true
  of pkActive: false
