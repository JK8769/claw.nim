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
        pinless: entry{"pinless"}.getBool(false)
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
      "pinless": inv.pinless
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
