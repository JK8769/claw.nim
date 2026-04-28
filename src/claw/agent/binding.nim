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

proc persistPersonIdentifiers*(baseNimsPath, personName: string,
                               idents: openArray[(string, string)]) =
  ## Append missing `identifier "chan", "val"` lines to the given
  ## `person "<name>":` block in BASE.nims. Idempotent — skips pairs
  ## already present on that channel key (same or different value, so
  ## a bind-then-rebind overwrites cleanly instead of appending dupes).
  ## No-op if the person block doesn't exist or the file is missing.
  if not fileExists(baseNimsPath): return
  var lines = readFile(baseNimsPath).splitLines()
  let marker = "person \"" & personName & "\":"
  var start = -1
  for i, l in lines:
    if l.strip() == marker: start = i; break
  if start < 0: return
  var endIdx = start + 1
  while endIdx < lines.len:
    let l = lines[endIdx]
    if l.strip().len > 0 and not l.startsWith(" ") and not l.startsWith("\t"):
      break
    inc endIdx
  # Build a set of existing channel keys inside the block — drop any
  # prior `identifier "K", ...` lines for channel keys we're writing
  # (an update replaces rather than duplicates).
  var wanted = initTable[string, string]()
  for (k, v) in idents:
    if k.len > 0 and v.len > 0: wanted[k] = v
  if wanted.len == 0: return
  var updated: seq[string]
  for i in 0 ..< lines.len:
    if i >= start + 1 and i < endIdx:
      let stripped = lines[i].strip(leading = true, trailing = false)
      var drop = false
      for k in wanted.keys:
        if stripped.startsWith("identifier \"" & k & "\","):
          drop = true; break
      if drop: continue
    updated.add(lines[i])
  # Recompute block bounds after any drops — we want to insert before
  # the block ends. Simplest: find the marker again in `updated`.
  var ns = -1
  for i, l in updated:
    if l.strip() == marker: ns = i; break
  var ne = ns + 1
  while ne < updated.len:
    let l = updated[ne]
    if l.strip().len > 0 and not l.startsWith(" ") and not l.startsWith("\t"):
      break
    inc ne
  # Insert new lines at the end of the block (before ne).
  var insertAt = ne
  # Skip trailing blanks — keep insertion inside the block body.
  while insertAt > ns + 1 and updated[insertAt - 1].strip().len == 0:
    dec insertAt
  var inserts: seq[string]
  for k, v in wanted.pairs:
    inserts.add("  identifier \"" & k & "\", \"" & v & "\"")
  var finalLines = updated[0 ..< insertAt]
  for l in inserts: finalLines.add(l)
  for i in insertAt ..< updated.len: finalLines.add(updated[i])
  writeFile(baseNimsPath, finalLines.join("\n"))

proc persistPersonName*(baseNimsPath, ncId, newName: string) =
  ## Rename a `person "OLD":` block in BASE.nims to `person "NEW":`,
  ## identified by its `# nc:<id>` tag comment (names aren't unique;
  ## the nc:id tag is the canonical anchor). No-op when the file or
  ## the tagged block doesn't exist. Caller validates `newName` —
  ## unescaped quotes or empty would break the DSL at `co update`.
  if not fileExists(baseNimsPath): return
  var lines = readFile(baseNimsPath).splitLines()
  # Find the `# nc:<id>` tag, then walk backward for the enclosing
  # `person "...":` header — the canonical layout for a Person block.
  let tag = "# " & ncId
  var tagIdx = -1
  for i, l in lines:
    if l.strip() == tag: tagIdx = i; break
  if tagIdx < 0: return
  var headerIdx = -1
  for j in countdown(tagIdx - 1, 0):
    let s = lines[j].strip()
    if s.startsWith("person \"") and s.endsWith("\":"):
      headerIdx = j; break
    # Stop if we hit another block header — the tag doesn't belong to
    # a person block, don't rewrite unrelated lines.
    if s.endsWith("\":") and not s.startsWith("person \""): return
  if headerIdx < 0: return
  # Preserve leading indentation on the header line (blocks declared at
  # column 0 vs. nested under a parent — be conservative and keep it).
  let orig = lines[headerIdx]
  var indent = ""
  for c in orig:
    if c == ' ' or c == '\t': indent.add(c) else: break
  lines[headerIdx] = indent & "person \"" & newName & "\":"
  writeFile(baseNimsPath, lines.join("\n"))

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
  # Persist the new identifiers into BASE.nims so `co update` doesn't
  # wipe them. Silent no-op if the person isn't declared there (which
  # would be odd for a SuperAdmin bind target but defensible).
  var pairs: seq[(string, string)] = @[(channelKey, senderID)]
  for (k, v) in extras:
    if k.len > 0 and v.len > 0: pairs.add((k, v))
  persistPersonIdentifiers(
    workspace.parentDir / "BASE.nims", ent.name, pairs)
  some(matched)

proc rebind*(graph: WorldGraph, workspace: string,
             alias: string, wipeExisting: bool = false): Option[BindingCode] =
  ## Force-issue a fresh binding code for an existing internal user.
  ## Default is **additive**: the new code, when consumed via tryBind
  ## from any channel, stamps just THAT channel's identifier and leaves
  ## others untouched (tryBind is already channel-scoped). Pass
  ## `wipeExisting = true` for the lost-device flow where every
  ## existing identifier must be revoked so the new code is the only
  ## way back in.
  if graph == nil: return none(BindingCode)
  if not alias.startsWith("nc:"): return none(BindingCode)
  let id = parseAlias(alias)
  if uint32(id) == 0 or not graph.entities.hasKey(id):
    return none(BindingCode)
  var ent = graph.entities[id]
  # Bind codes are only minted for trusted internal roles
  # (SuperAdmin / Admin / Staff / Member / Employee). Customer /
  # Guest / external people use the invite flow (claw user invite),
  # which has its own ledger and per-customer skill grants. The
  # role list lives in cortex.isInternalRole — single source of truth.
  if ent.kind != ekPerson or not isInternalRole(ent.role):
    return none(BindingCode)
  if wipeExisting and ent.identifiers.len > 0:
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
