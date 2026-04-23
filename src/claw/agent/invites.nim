import std/[os, json, tables, times, random, strutils]

type
  InviteConstraint* = object
    code*: string
    agentName*: string
    customerName*: string
    role*: string
    maxUses*: int # -1 means unlimited
    expiry*: int64 # Unix timestamp, 0 means no expiry
    pinless*: bool # If true, any user messaging the agent gets this invite auto-applied
    # Provenance (who invited who):
    issuedBy*: string    ## nc:id of the user that created this code
    createdAt*: int64    ## Unix timestamp when the code was minted
    usedBy*: string      ## nc:id that redeemed it (last redemption, if multi-use)
    usedAt*: int64       ## Unix timestamp of last redemption
    # Pre-allocated target (customer-invite flow):
    targetNcId*: string  ## If set, redemption stamps the sender's identifiers
                         ## onto THIS entity instead of minting a fresh one.
                         ## Lets `create_customer_invite` hand out an
                         ## `nc:X/CODE` string the SuperAdmin can pre-share.
    lang*: string        ## Customer's preferred language ("en", "zh", "zh-CN").
                         ## Stamped on the entity at redemption and used to
                         ## pick the localized welcome message. Empty =
                         ## operator didn't specify; redeem falls back to
                         ## entity's existing lang or "en".

proc loadInvites*(workspace: string): Table[string, InviteConstraint] =
  let path = workspace / "INVITES.json"
  if not fileExists(path): return initTable[string, InviteConstraint]()
  try:
    let node = parseFile(path)
    for entry in node:
      let inv = InviteConstraint(
        code: entry{"code"}.getStr(""),
        agentName: entry{"agentName"}.getStr(""),
        customerName: entry{"customerName"}.getStr("anonymous"),
        role: entry{"role"}.getStr("guest"),
        maxUses: entry{"maxUses"}.getInt(-1),
        expiry: entry{"expiry"}.getBiggestInt(0),
        pinless: entry{"pinless"}.getBool(false),
        issuedBy: entry{"issuedBy"}.getStr(""),
        createdAt: entry{"createdAt"}.getBiggestInt(0),
        usedBy: entry{"usedBy"}.getStr(""),
        usedAt: entry{"usedAt"}.getBiggestInt(0),
        targetNcId: entry{"targetNcId"}.getStr(""),
        lang: entry{"lang"}.getStr("")
      )
      if inv.code != "":
        result[inv.code] = inv
  except:
    echo "Warning: Failed to load INVITES.json: ", getCurrentExceptionMsg()

proc saveInvites*(workspace: string, invites: Table[string, InviteConstraint]) =
  let path = workspace / "INVITES.json"
  var node = newJArray()
  for inv in invites.values:
    node.add(%* {
      "code": inv.code,
      "agentName": inv.agentName,
      "customerName": inv.customerName,
      "role": inv.role,
      "maxUses": inv.maxUses,
      "expiry": inv.expiry,
      "pinless": inv.pinless,
      "issuedBy": inv.issuedBy,
      "createdAt": inv.createdAt,
      "usedBy": inv.usedBy,
      "usedAt": inv.usedAt,
      "targetNcId": inv.targetNcId,
      "lang": inv.lang
    })
  writeFile(path, node.pretty())

proc isValid*(inv: InviteConstraint): bool =
  if inv.expiry > 0 and getTime().toUnix() > inv.expiry:
    return false
  if inv.maxUses == 0:
    return false
  return true

proc generateInviteCode*(): string =
  # Generates a random 6-character alphanumeric code, e.g., A4B-9X2
  const charset = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" # Exclude confusing chars like 0,O,1,I
  var code = ""
  for i in 1..6:
    code &= charset[rand(charset.len - 1)]
    if i == 3: code &= "-"
  return code

proc getPublicCode*(agentName: string): string =
  "PUBLIC_" & agentName.toUpperAscii()

proc parseInviteString*(s: string): tuple[ncId, code: string] =
  ## Accepts either a bare code (e.g. `A4B-9X2`) or the bundled
  ## `nc:N/CODE` form. Returns (ncId, code); either may be empty.
  ## Whitespace-tolerant, case-preserving for the code (matching
  ## happens uppercase at the redemption site).
  let trimmed = s.strip()
  if trimmed.startsWith("nc:"):
    let slash = trimmed.find('/')
    if slash > 0:
      return (trimmed[0 ..< slash], trimmed[slash + 1 ..< trimmed.len].strip())
  ("", trimmed)
