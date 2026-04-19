## create_customer_invite — chat-driven one-shot customer onboarding.
##
## Flow:
##   SuperAdmin asks agent to issue an invite for a new customer.
##   Agent calls this tool → pre-allocates a Customer Person entity
##   AND an invite code, returns the bundled `nc:X/CODE` string.
##   SuperAdmin shares the string out-of-band (email, SMS, etc.).
##   Customer sends the string to the designated Feishu app as their
##   first message. The gateway's pre-LLM intercept parses, validates,
##   stamps the sender's identifiers onto the pre-allocated entity,
##   and burns the code — no LLM turn, no onboarding ceremony.
##
## Gate: SuperAdmin/Admin only. Creating persons + persisting invite
## codes is not something a guest should do mid-chat.

import std/[asyncdispatch, json, tables, strutils, times, random, options]
import types
import ../config
import ../agent/cortex
import ../agent/invites

type
  CreateCustomerInviteTool* = ref object of ContextualTool

proc newCreateCustomerInviteTool*(): CreateCustomerInviteTool =
  CreateCustomerInviteTool()

method name*(t: CreateCustomerInviteTool): string = "create_customer_invite"

method description*(t: CreateCustomerInviteTool): string =
  "Generate a one-shot customer-access string (`nc:X/CODE`) that a " &
  "customer can send as their first message to the designated Feishu " &
  "app (or any channel) to authenticate themselves as a Customer. " &
  "Pre-creates a Person entity with permission=Customer so the " &
  "SuperAdmin knows the customer's nc:id before they connect. " &
  "SuperAdmin only. When a user asks for an invite, confirm the " &
  "customer's name and which agent should serve them, then call this " &
  "tool and share the returned string with the customer."

method parameters*(t: CreateCustomerInviteTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "customer_name": {
        "type": "string",
        "description": "Display name for the customer (e.g. 'Acme Solar Ops'). Appears in user list + invite list and on the pre-allocated entity."
      },
      "agent": {
        "type": "string",
        "description": "Agent that should handle messages from this customer (e.g. 'Lexi'). Usually the same agent that the customer will DM from their Feishu app. Must be an existing declared agent."
      },
      "max_uses": {
        "type": "integer",
        "description": "How many distinct redemptions the code allows. Default 1 (one-shot). Use a small positive number for a shared-device group; -1 for unlimited (not recommended — per-redemption entity binding doesn't make sense)."
      }
    },
    "required": %*["customer_name", "agent"]
  }.toTable

method execute*(t: CreateCustomerInviteTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  # Permission axis — look up the requester's declared entity.role, not
  # their relationship-role (a "boss" annotation doesn't grant admin).
  var perm = ""
  if t.graph != nil and t.logicalUserID.startsWith("nc:"):
    let id = parseAlias(t.logicalUserID)
    if uint32(id) > 0 and t.graph.entities.hasKey(id):
      perm = t.graph.entities[id].role.toLowerAscii
  if perm notin ["superadmin", "admin"]:
    return "Error: creating customer invites requires SuperAdmin. " &
           "Current permission: " &
           (if perm.len > 0: perm else: "unknown") & "."

  if not args.hasKey("customer_name") or not args.hasKey("agent"):
    return "Error: customer_name and agent are both required."
  let customerName = args["customer_name"].getStr().strip()
  let agentName = args["agent"].getStr().strip()
  let maxUses = if args.hasKey("max_uses"): args["max_uses"].getInt(1) else: 1
  if customerName.len == 0 or agentName.len == 0:
    return "Error: customer_name and agent must be non-empty."
  if '"' in customerName:
    return "Error: customer_name cannot contain a double-quote."

  # Validate agent exists.
  var agentFound = false
  var agentID = WorldEntityID(0)
  if t.graph != nil:
    for id, ent in t.graph.entities.pairs:
      if ent.kind == ekAI and ent.name.toLowerAscii == agentName.toLowerAscii:
        agentFound = true; agentID = id
        break
  if not agentFound:
    var known: seq[string]
    if t.graph != nil:
      for id, ent in t.graph.entities.pairs:
        if ent.kind == ekAI: known.add(ent.name)
    return "Error: no agent named '" & agentName & "'. Known: " &
           known.join(", ") & "."

  # Pre-allocate the customer Person entity so we have a stable nc:id
  # to hand back to the SuperAdmin.
  var g = t.graph
  let newID = WorldEntityID(g.nextID)
  g.nextID += 1
  var ent = WorldEntity(
    id: newID,
    kind: ekPerson,
    name: customerName,
    role: "Customer",
    identifiers: initTable[string, string]()
  )
  # Connect the customer to the serving agent via a `serves` edge so
  # the relationship graph reflects the new customer's membership.
  g.entities[newID] = ent
  g.nameIndex[customerName] = newID
  if g.entities.hasKey(agentID):
    var agent = g.entities[agentID]
    let annot = RelationshipAnnotation(
      role: urCustomer,
      trustLevel: 40,
      etiquette: "")
    agent.serves.add(RelationshipLink(
      targetID: newID, annotation: some(annot)))
    g.entities[agentID] = agent
  g.saveWorld()

  # Mint the invite code, keyed to the pre-allocated nc:id.
  let workspace = t.graph.workspace
  var invMap = loadInvites(workspace)
  randomize()
  var code = generateInviteCode()
  while invMap.hasKey(code): code = generateInviteCode()
  let issuerAlias = t.logicalUserID
  let alias = toAlias(newID)
  invMap[code] = InviteConstraint(
    code: code,
    agentName: agentName,
    customerName: customerName,
    role: "customer",
    maxUses: maxUses,
    expiry: 0,
    pinless: false,
    issuedBy: issuerAlias,
    createdAt: getTime().toUnix(),
    usedBy: "",
    usedAt: 0,
    targetNcId: alias
  )
  saveInvites(workspace, invMap)

  return "Customer invite created.\n" &
         "  Share this string with the customer:  **" & alias & "/" & code & "**\n\n" &
         "  Customer: " & customerName & " (" & alias & ")\n" &
         "  Agent:    " & agentName & "\n" &
         "  Max uses: " & $maxUses & "\n\n" &
         "The customer sends the bundled string as their first " &
         "message to any channel routing to " & agentName &
         ". The gateway authenticates them before the LLM sees the " &
         "message; subsequent messages go through normally as a " &
         "Customer."
