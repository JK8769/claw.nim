## billing/plants — resolve a customer's real plant names for welcome examples.
##
## Currently sungrow-specific (the only solar-analytics skill the company
## ships). Could be generalized later into a skill-plugin hook that lets
## each skill provide its own "example queries" generator.
##
## Lookup chain, all file-based (no network calls — fast, welcome stays
## snappy even on a cold customer):
##
##   nc:7 → support/sungrow/members/nc_7.json
##        → {"account_id": "demo"}
##        → support/sungrow/accounts/demo.json
##        → {"region": "cn", "user_account": "njmkuser", ...}
##        → support/sungrow/cache/cn/njmkuser/plants.jsonl
##        → [{"ps_name": "荣鑫一期", ...}, {"ps_name": "荣鑫二期", ...}]
##
## Returns empty seq if any link in the chain is missing or corrupted;
## the welcome renderer falls back to generic phrasing ("your plants")
## so nobody sees a broken template.

import std/[json, os, strutils]
import ../config

proc fetchPlantNames*(ncId: string, maxNames: int = 3): seq[string] =
  ## Walks the sungrow member → account → cache chain for this customer
  ## and returns up to `maxNames` plant display names. Safe to call from
  ## the welcome path — no I/O beyond 2-3 local file reads.
  if not ncId.startsWith("nc:"): return @[]
  let support = getNimClawDir() / "support" / "sungrow"
  let memberFile = support / "members" / (ncId.replace(":", "_") & ".json")
  if not fileExists(memberFile): return @[]
  var accountId = ""
  try:
    accountId = parseJson(readFile(memberFile)){"account_id"}.getStr("").strip()
  except CatchableError: return @[]
  if accountId.len == 0: return @[]
  let accountFile = support / "accounts" / (accountId & ".json")
  if not fileExists(accountFile): return @[]
  var region = "cn"
  var userAccount = ""
  try:
    let acc = parseJson(readFile(accountFile))
    region = acc{"region"}.getStr("cn")
    userAccount = acc{"user_account"}.getStr("").strip()
  except CatchableError: return @[]
  if userAccount.len == 0: return @[]
  let plantsFile = support / "cache" / region / userAccount / "plants.jsonl"
  if not fileExists(plantsFile): return @[]
  for line in lines(plantsFile):
    if result.len >= maxNames: break
    let s = line.strip()
    if s.len == 0: continue
    try:
      let name = parseJson(s){"ps_name"}.getStr("").strip()
      if name.len > 0: result.add(name)
    except CatchableError: discard
