## update_contact — let a user set their display name. Two code paths
## depending on where the caller lives:
##
##   • Customer / Person (post-redeem, has an nc:id in the WorldGraph)
##     → updates `graph.entities[id].name`, `graph.nameIndex`, and the
##     BASE.nims `person "…":` header so `co update` preserves it. Every
##     agent sees the new name on the next turn.
##
##   • Guest (unknown contact, not yet invited, lives only in the per-
##     agent `guests.json` ledger)
##     → updates `cb.guests[logicalUserID].name` and saves the ledger.
##     Scoped to the agent the guest is talking to; another agent would
##     re-establish its own guest record on first contact.
##
## Permission:
##   • Caller can only rename themselves (derived from `t.logicalUserID`
##     and `t.senderID`; no `target` parameter is exposed).
##   • Internal-tier users (Staff/Admin/SuperAdmin) can't self-rename
##     via chat — their name lives in ClawDSL. Operators must edit
##     BASE.nims or use `claw user edit <nc:id> --name=<new>`.
##
## Does NOT touch:
##   • identity / role / permission (invite redemption owns those)
##   • other entities or other agents' guest ledgers

import std/[os, json, tables, asyncdispatch, strutils]
import types
import ../config
import ../agent/cortex
import ../agent/binding
import ../agent/context as agent_context
import ../cli_admin

type
  UpdateContactTool* = ref object of ContextualTool
    officeDir: string
    contextBuilder*: ContextBuilder  ## for Guest-ledger writes

proc newUpdateContactTool*(officeDir: string, cb: ContextBuilder): UpdateContactTool =
  UpdateContactTool(officeDir: officeDir, contextBuilder: cb)

method name*(t: UpdateContactTool): string = "update_contact"

method description*(t: UpdateContactTool): string =
  "Record the user's display name. Call when the user introduces " &
  "themselves or corrects how you address them (e.g. 'I'm 杰瑞', " &
  "'my name is Tom'). Updates the shared contact record so every " &
  "future turn — including other agents' turns — sees the right name. " &
  "Restricted: you can only update the speaker's own name, not " &
  "someone else's. Cannot change role or permission via this tool."

method parameters*(t: UpdateContactTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "name": {
        "type": "string",
        "description": "The user's real/preferred display name (e.g. '杰瑞', 'Tom'). Must be non-empty, 1–80 characters, and contain no double-quote characters."
      }
    },
    "required": %["name"]
  }.toTable

proc renameGuest(t: UpdateContactTool, newName: string): string =
  ## Guest-ledger branch for callers without an nc:id. Caller is
  ## guaranteed to have a ContextBuilder (required at construction).
  let id = t.logicalUserID
  if t.contextBuilder.guests.hasKey(id):
    var g = t.contextBuilder.guests[id]
    let oldName = g.name
    if oldName == newName:
      return "Noted — name is already '" & newName & "', no change."
    g.name = newName
    t.contextBuilder.guests[id] = g
    saveGuests(t.officeDir, t.contextBuilder.guests)
    return "Updated: '" & oldName & "' → '" & newName & "' (guest record)."
  # Unknown guest (no prior record) — create one with the given name.
  t.contextBuilder.guests[id] = newGuest(t.channel, t.senderID, name = newName)
  saveGuests(t.officeDir, t.contextBuilder.guests)
  "Recorded: you'll be addressed as '" & newName & "' from now on."

method execute*(t: UpdateContactTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("name") or args["name"].kind == JNull:
    return "Error: name is required."
  let newName = args["name"].getStr().strip()
  if newName.len == 0:
    return "Error: name must be non-empty."
  if newName.len > 80:
    return "Error: name too long (>80 chars). Use a shorter display name."
  if '"' in newName:
    return "Error: name cannot contain a double-quote character."

  # Guest path — no nc:id means the caller lives in the per-agent
  # guest ledger, not the graph.
  if not t.logicalUserID.startsWith("nc:"):
    return t.renameGuest(newName)

  if t.graph == nil:
    return "Error: graph not available on this tool context."
  let id = parseAlias(t.logicalUserID)
  if uint32(id) == 0 or not t.graph.entities.hasKey(id):
    return "Error: " & t.logicalUserID & " not found in the graph."
  var ent = t.graph.entities[id]
  if ent.kind != ekPerson:
    return "Error: only Person entities can be renamed via this tool."

  # Internal-tier names live in ClawDSL, not chat. Let operators
  # handle staff renames via `claw user edit`.
  if tierFromRoleName(ent.role) == "int":
    return "Error: internal-tier contacts (role=" & ent.role &
           ") can't self-rename via chat. Ask the operator to edit " &
           "BASE.nims or run `claw user edit " & t.logicalUserID &
           " --name=<new>`."

  let oldName = ent.name
  if not t.graph.rename(id, newName):
    return "Noted — name is already '" & newName & "', no change."
  t.graph.saveWorld()

  # Persist to BASE.nims so `co update` preserves the new name. The
  # nc:id tag comment inside the person block is the anchor (names
  # can collide, nc:ids can't).
  try:
    persistPersonName(getNimClawDir() / "BASE.nims", t.logicalUserID, newName)
  except CatchableError as err:
    stderr.writeLine "update_contact: BASE.nims persist failed for " &
      t.logicalUserID & " (" & oldName & " → " & newName & "): " &
      err.msg & " — graph updated; rerun persistence before `co update`."

  return "Updated: '" & oldName & "' → '" & newName & "'. Every agent " &
         "will address you as '" & newName & "' from now on."
