## billing/usage — UTC daily token counter per customer.
##
## Why separate from the world graph: the counter changes on every
## agent message, graph writes are broad serializations; keeping usage
## in its own file-per-customer avoids churning BASE.json on hot paths.
##
## File layout: $NIMCLAW_DIR/support/billing/usage/<nc_id>.json
## Shape:
##   { "day": "2026-04-22", "tokens_in": 12500, "tokens_out": 3200 }
##
## Day boundary is UTC. Reset is lazy: on read/increment, if the stored
## day differs from today's UTC date, counts go to zero before the new
## increment. No cron job, no background sweeper.

import std/[json, os, times, strutils]
import ../config

type
  UsageCounter* = object
    day*:            string    ## "YYYY-MM-DD" (UTC)
    tokensIn*:       int
    tokensOut*:      int
    lastWarnedDay*:  string    ## Last UTC day a grace banner was shown to
                                ## this customer. Used for once-per-day
                                ## cadence — if this differs from today's
                                ## date, the gate emits a fresh warning.
                                ## Reset-implicit: when `day` flips, the
                                ## counter is re-initialized with empty
                                ## lastWarnedDay, so the next message of
                                ## a new day always warns during grace.

proc todayUtc*(): string =
  ## Current UTC date in YYYY-MM-DD. Chosen over local time to avoid
  ## timezone drift — SunGrowCN operators are UTC+8, but customers might
  ## be anywhere; UTC gives everyone the same reset moment.
  now().utc.format("yyyy-MM-dd")

proc usageDir*(): string = getNimClawDir() / "support" / "billing" / "usage"

proc usagePath*(ncId: string): string =
  ## Path for a specific customer's counter. `ncId` is "nc:7"-shaped;
  ## replace `:` with `_` to keep filenames portable.
  usageDir() / (ncId.replace(":", "_") & ".json")

proc loadUsage*(ncId: string): UsageCounter =
  ## Read the counter off disk, or return a zero for today if none exists
  ## or if the stored day is stale. Never raises — corrupted/missing
  ## file resets to zero.
  result = UsageCounter(day: todayUtc(), tokensIn: 0, tokensOut: 0,
                         lastWarnedDay: "")
  let path = usagePath(ncId)
  if not fileExists(path): return
  try:
    let node = parseJson(readFile(path))
    let storedDay = node{"day"}.getStr("")
    if storedDay == result.day:
      result.tokensIn = node{"tokens_in"}.getInt(0)
      result.tokensOut = node{"tokens_out"}.getInt(0)
      result.lastWarnedDay = node{"last_warned_day"}.getStr("")
  except CatchableError:
    discard  # corrupted file → zero counter

proc saveUsage*(ncId: string, u: UsageCounter) =
  let dir = usageDir()
  createDir(dir)
  var payload = %*{
    "day": u.day,
    "tokens_in": u.tokensIn,
    "tokens_out": u.tokensOut
  }
  if u.lastWarnedDay.len > 0:
    payload["last_warned_day"] = %u.lastWarnedDay
  writeFile(usagePath(ncId), $payload)

proc markWarned*(ncId: string) =
  ## Stamp today's UTC date as the last-warned day for this customer.
  ## Called by the gate after emitting a grace-period banner to ensure
  ## we only warn once per UTC calendar day.
  var u = loadUsage(ncId)
  u.lastWarnedDay = u.day
  saveUsage(ncId, u)

proc addTokens*(ncId: string, inTokens, outTokens: int): UsageCounter =
  ## Accumulate token usage into today's counter and persist. Returns
  ## the post-increment snapshot. Day-reset happens automatically via
  ## loadUsage when the stored day ≠ today.
  ##
  ## 0-delta calls skip the disk write (the agent loop invokes this
  ## every iteration; provider errors / empty completions would
  ## otherwise cause a needless write per iteration).
  result = loadUsage(ncId)
  if inTokens == 0 and outTokens == 0 and
     fileExists(usagePath(ncId)):
    return
  result.tokensIn += inTokens
  result.tokensOut += outTokens
  saveUsage(ncId, result)

proc tokensToday*(u: UsageCounter): int = u.tokensIn + u.tokensOut

proc clearUsage*(ncId: string) =
  ## Wipe the counter file — used by `claw user remove` for symmetry
  ## with the other per-customer state (member records).
  let path = usagePath(ncId)
  if fileExists(path):
    try: removeFile(path) except CatchableError: discard
