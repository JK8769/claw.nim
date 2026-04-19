## SuperAdmin auto-binding.
##
## When a fresh company is scaffolded, the declared SuperAdmin(s) have
## no channel identifier yet — nobody has messaged the system as them.
## `user merge` can't fix this because there's no SuperAdmin on-site to
## run it. Instead, the gateway auto-generates a one-shot binding code
## at startup for every SuperAdmin without identifiers and prints it to
## stderr. The first inbound message carrying that code is intercepted
## *before the LLM*; the sender's (channel, id) is stamped onto the
## target entity's identifiers and the code is burned. Wrong code →
## falls through as a normal guest.

import std/[os, json, tables, times, monotimes, strutils, random, options]
import cortex

type
  BindingCode* = object
    code*: string         ## Displayed "Q7K-3MP" form (with dash)
    targetNcId*: string   ## e.g. "nc:4"
    targetName*: string   ## Display name at issue time (for logs)
    createdAt*: int64     ## Unix seconds

const bindingTTL = 3600 * 24  # 24 hours

proc bindingsPath(workspace: string): string =
  workspace / "bindings.json"

proc loadBindings*(workspace: string): seq[BindingCode] =
  let p = bindingsPath(workspace)
  if not fileExists(p): return @[]
  try:
    let node = parseFile(p)
    let now = getTime().toUnix()
    for n in node:
      let created = n{"createdAt"}.getInt()
      if now - created > bindingTTL: continue
      result.add(BindingCode(
        code: n{"code"}.getStr(""),
        targetNcId: n{"targetNcId"}.getStr(""),
        targetName: n{"targetName"}.getStr(""),
        createdAt: created
      ))
  except:
    discard

proc saveBindings*(workspace: string, codes: seq[BindingCode]) =
  var arr = newJArray()
  for c in codes:
    arr.add(%*{
      "code": c.code,
      "targetNcId": c.targetNcId,
      "targetName": c.targetName,
      "createdAt": c.createdAt
    })
  writeFile(bindingsPath(workspace), arr.pretty())

proc generateCode*(): string =
  ## 7-char "XXX-XXX" using a Crockford-like alphabet that skips
  ## visually ambiguous letters/digits (no 0/O, 1/I/L).
  const alpha = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  var rng = initRand(epochTime().int64 xor int64(getMonoTime().ticks))
  var buf = newStringOfCap(7)
  for i in 0 ..< 6:
    if i == 3: buf.add('-')
    buf.add(alpha[rng.rand(alpha.high)])
  buf

proc normalizeCode(s: string): string =
  ## Strip whitespace, uppercase, drop the optional dash — lets the user
  ## message "q7k3mp" or "Q7K-3MP" or "Q7K 3MP" and still match.
  s.toUpperAscii.replace("-", "").replace(" ", "").strip()

proc ensureSuperAdminBindings*(graph: WorldGraph, workspace: string): seq[BindingCode] =
  ## Generate a binding code for every SuperAdmin Person that lacks any
  ## channel identifier and doesn't already have an active code.
  ## Returns only the *newly created* codes so the caller can print them
  ## (existing unexpired codes stay silent). Persists the combined set.
  if graph == nil: return @[]
  var active = loadBindings(workspace)
  var newOnes: seq[BindingCode]
  let now = getTime().toUnix()
  for id, ent in graph.entities.pairs:
    if ent.kind != ekPerson: continue
    if ent.role.toLowerAscii != "superadmin": continue
    if ent.identifiers.len > 0: continue
    let alias = toAlias(id)
    var found = false
    for c in active:
      if c.targetNcId == alias: found = true; break
    if found: continue
    let code = BindingCode(
      code: generateCode(),
      targetNcId: alias,
      targetName: ent.name,
      createdAt: now
    )
    active.add(code)
    newOnes.add(code)
  if newOnes.len > 0:
    saveBindings(workspace, active)
  newOnes

proc tryBind*(graph: WorldGraph, workspace: string,
              channelKey, senderID, message: string,
              extras: openArray[(string, string)] = []): Option[BindingCode] =
  ## If the message contains a pending binding code, stamp the sender's
  ## (channelKey, senderID) onto the target's identifiers, burn the code,
  ## and return the consumed code. `extras` passes additional (key, value)
  ## identifiers to stamp alongside — e.g. `feishu:union` → the Feishu
  ## tenant-stable union_id, so the second app in the same tenant
  ## doesn't need another bind. Returns none() otherwise.
  if graph == nil: return none(BindingCode)
  var codes = loadBindings(workspace)
  let norm = normalizeCode(message)
  var matchedIdx = -1
  var matched: BindingCode
  for i, c in codes:
    if normalizeCode(c.code) in norm:
      matchedIdx = i
      matched = c
      break
  if matchedIdx < 0: return none(BindingCode)
  let id = parseAlias(matched.targetNcId)
  if uint32(id) == 0 or not graph.entities.hasKey(id):
    return none(BindingCode)
  var ent = graph.entities[id]
  ent.identifiers[channelKey] = senderID
  for (k, v) in extras:
    if k.len > 0 and v.len > 0:
      ent.identifiers[k] = v
  graph.entities[id] = ent
  graph.saveWorld()
  codes.delete(matchedIdx)
  saveBindings(workspace, codes)
  some(matched)

proc rebind*(graph: WorldGraph, workspace: string,
             alias: string, dropExisting: bool = true): Option[BindingCode] =
  ## Force-issue a fresh binding code for an existing SuperAdmin, even
  ## if they already have identifiers. If `dropExisting`, wipe the
  ## identifiers so the code is the only way back in (lost-device flow).
  if graph == nil: return none(BindingCode)
  if not alias.startsWith("nc:"): return none(BindingCode)
  let id = parseAlias(alias)
  if uint32(id) == 0 or not graph.entities.hasKey(id):
    return none(BindingCode)
  var ent = graph.entities[id]
  if ent.kind != ekPerson or ent.role.toLowerAscii != "superadmin":
    return none(BindingCode)
  if dropExisting and ent.identifiers.len > 0:
    ent.identifiers = initTable[string, string]()
    graph.entities[id] = ent
    graph.saveWorld()
  var codes = loadBindings(workspace)
  # Remove any existing code for this alias so only the fresh one is valid.
  var kept: seq[BindingCode]
  for c in codes:
    if c.targetNcId != alias: kept.add(c)
  let fresh = BindingCode(
    code: generateCode(),
    targetNcId: alias,
    targetName: ent.name,
    createdAt: getTime().toUnix()
  )
  kept.add(fresh)
  saveBindings(workspace, kept)
  some(fresh)
