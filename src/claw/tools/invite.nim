import std/[os, json, strutils, tables, asyncdispatch, times, options]
import types
import ../config
import ../agent/[invites, cortex]

type
  RedeemInviteTool* = ref object of ContextualTool

method name*(t: RedeemInviteTool): string = "redeem_invite"

method description*(t: RedeemInviteTool): string = 
  "Redeem a Business Card Pin Code given by the customer. Use this to verify a customer and securely let them access this agent."

method parameters*(t: RedeemInviteTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "code": {
        "type": "string",
        "description": "The 6-character Pin Code provided by the user (e.g., 'A4B-9X2')"
      }
    },
    "required": %["code"]
  }.toTable

method execute*(t: RedeemInviteTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("code"):
    return "Error: Missing 'code' parameter."
    
  let code = args["code"].getStr().strip()
  let workspace = getNimClawDir() / "workspace"
  var allInvites = loadInvites(workspace)
  
  if not allInvites.hasKey(code):
    return "Error: Invalid Pin Code."
    
  var inv = allInvites[code]
  
  # Verify it belongs to this agent
  if t.recipientID != "" and inv.agentName != t.recipientID:
    return "Error: This Pin Code belongs to a different Employee. You cannot redeem it."
    
  # Verify constraint
  if not isValid(inv):
    return "Error: This Pin Code is expired or has reached its max uses."
    
  # It's valid! Add to guest ledger.
  var guests = loadGuests(workspace)
  let (logicalUID, _) = guests.resolveUser(t.channel, t.senderID)

  # Create or update guest entry
  var newID = logicalUID
  if logicalUID == t.senderID:
    # New user: generate a professional ID using their name and a snippet of the code
    let sanitizedName = inv.customerName.replace(" ", "_").toLowerAscii()
    let shortCode = if inv.code.len > 3: inv.code[0..2] else: inv.code
    newID = "customer_" & sanitizedName & "_" & shortCode

  # Entry trust when transitioning INTO a role is the role's `trustMin`
  # (the lower bound of its range). Falls back to 50 when the company
  # hasn't declared a trust block for this role — shouldn't happen
  # once the bootstrap minimum seeds SuperAdmin/Guest, but kept as a
  # safety net for legacy configs.
  let cfg = loadConfig(getConfigPath())
  let roleName = ($parseEnum[UserRole](inv.role, urGuest)).toLowerAscii
  var initTrust = 50
  for r in cfg.trust.roles:
    if r.name.toLowerAscii == roleName:
      initTrust = r.trustMin
      break

  var rel = GuestContact(
    name: newID,
    identity: $parseEnum[UserRole](inv.role, urGuest),
    trustLevel: initTrust,
    etiquette: "",
    kind: ekPerson,
    identifiers: initTable[string, seq[string]]()
  )
  
  # Copy existing identifiers if we are updating an existing logical user
  if guests.hasKey(newID):
    rel = guests[newID]
    rel.identity = $parseEnum[UserRole](inv.role, urGuest)
  
  # Add this current channel/senderID to their identifiers
  if not rel.identifiers.hasKey(t.channel):
    rel.identifiers[t.channel] = @[]
  if t.senderID notin rel.identifiers[t.channel]:
    rel.identifiers[t.channel].add(t.senderID)
    
  guests[newID] = rel
  saveGuests(workspace, guests)

  # Also promote the redeemer in the unified graph so `user list` and
  # the runtime trust-gate both reflect the new role/trust. Find the
  # sender's entity (via graph identifier lookup) and the target agent's
  # entity; rewrite the serves/reportsTo edge with the new annotation.
  var graph = loadWorld(workspace)
  if graph != nil:
    # Resolve sender → user entity. Match t.senderID against ANY of the
    # entity's identifier slots — handles both per-app Feishu keys
    # (feishu:<app_id>) and legacy channel keys.
    var userID = WorldEntityID(0)
    for id, ent in graph.entities.pairs:
      for key, value in ent.identifiers.pairs:
        if value == t.senderID and
           (key == t.channel or key.startsWith(t.channel & ":")):
          userID = id
          break
      if uint32(userID) > 0: break
    # Resolve agent — inv.agentName is the declared agent name.
    var agentID = WorldEntityID(0)
    if graph.nameIndex.hasKey(inv.agentName):
      agentID = graph.nameIndex[inv.agentName]
    if uint32(userID) > 0 and uint32(agentID) > 0:
      let newRole = parseEnum[UserRole](inv.role, urGuest)
      let newAnnot = RelationshipAnnotation(
        role: newRole, trustLevel: initTrust, etiquette: "")
      var agent = graph.entities[agentID]
      # Update an existing link, or add a new one — promote from
      # serves → reportsTo when the new role is boss/master.
      proc updateList(links: var seq[RelationshipLink]): bool =
        for i in 0 ..< links.len:
          if links[i].targetID == userID:
            links[i].annotation = some(newAnnot)
            return true
        false
      let inServes = updateList(agent.serves)
      let inReports = updateList(agent.reportsTo)
      let wantsLead = newRole in {urBoss, urMaster}
      if not inServes and not inReports:
        # Never-before-annotated — add to the correct list.
        let link = RelationshipLink(targetID: userID, annotation: some(newAnnot))
        if wantsLead: agent.reportsTo.add(link)
        else:         agent.serves.add(link)
      elif wantsLead and inServes and not inReports:
        # Promotion path: move from serves to reportsTo.
        var kept: seq[RelationshipLink]
        for link in agent.serves:
          if link.targetID != userID: kept.add(link)
        agent.serves = kept
        agent.reportsTo.add(RelationshipLink(
          targetID: userID, annotation: some(newAnnot)))
      elif not wantsLead and inReports and not inServes:
        # Demotion path: move from reportsTo to serves.
        var kept: seq[RelationshipLink]
        for link in agent.reportsTo:
          if link.targetID != userID: kept.add(link)
        agent.reportsTo = kept
        agent.serves.add(RelationshipLink(
          targetID: userID, annotation: some(newAnnot)))
      graph.entities[agentID] = agent
      graph.saveWorld()

  # Stamp provenance (who actually redeemed this, and when). t.senderID
  # is the channel-level ID of the speaker. For full nc:id provenance
  # we'd need the graph resolver wired here too — logging the channel
  # ID for now gives operators enough to trace.
  inv.usedBy = t.channel & ":" & t.senderID
  inv.usedAt = getTime().toUnix()

  # Update constraints
  if inv.maxUses > 0:
    inv.maxUses -= 1
    if inv.maxUses == 0:
      allInvites.del(code) # Exhausted
    else:
      allInvites[code] = inv
  elif inv.maxUses < 0:
    # Unlimited — keep the updated usedBy/usedAt.
    allInvites[code] = inv
  saveInvites(workspace, allInvites)

  # Sweep stale guests.json entries across offices. The redemption
  # path above wrote to guests.json (legacy behaviour), but since
  # the entity is now graph-resident with stable identifiers, those
  # per-agent ledger entries are stale by definition. Match by
  # identifier (not name — names aren't unique). The most relevant
  # identifier here is the entity in the graph that just got linked.
  if graph != nil:
    var resolvedID = WorldEntityID(0)
    for id, ent in graph.entities.pairs:
      for key, value in ent.identifiers.pairs:
        if value == t.senderID and
           (key == t.channel or key.startsWith(t.channel & ":")):
          resolvedID = id
          break
      if uint32(resolvedID) > 0: break
    if uint32(resolvedID) > 0:
      discard pruneGuestsAcrossOffices(
        workspace, graph.entities[resolvedID].identifiers)

  return "Successfully redeemed Pin Code! The user '" & inv.customerName & "' is now authenticated as a Customer for this Agent. You may now assist them normally."

proc newRedeemInviteTool*(): RedeemInviteTool =
  RedeemInviteTool()
