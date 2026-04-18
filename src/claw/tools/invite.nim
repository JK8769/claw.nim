import std/[os, json, strutils, tables, asyncdispatch]
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
    
  # It's valid! Add to relations.
  var relations = loadRelations(workspace)
  let (logicalUID, _) = relations.resolveUser(t.channel, t.senderID)
  
  # Create or update relationship entry
  var newID = logicalUID
  if logicalUID == t.senderID:
    # New user: generate a professional ID using their name and a snippet of the code
    let sanitizedName = inv.customerName.replace(" ", "_").toLowerAscii()
    let shortCode = if inv.code.len > 3: inv.code[0..2] else: inv.code
    newID = "customer_" & sanitizedName & "_" & shortCode

  
  var rel = Relationship(
    name: newID,
    identity: $parseEnum[UserRole](inv.role, urGuest),
    trustLevel: 50,
    etiquette: "",
    kind: ekPerson,
    identifiers: initTable[string, seq[string]]()
  )
  
  # Copy existing identifiers if we are updating an existing logical user
  if relations.hasKey(newID):
    rel = relations[newID]
    rel.identity = $parseEnum[UserRole](inv.role, urGuest)
  
  # Add this current channel/senderID to their identifiers
  if not rel.identifiers.hasKey(t.channel):
    rel.identifiers[t.channel] = @[]
  if t.senderID notin rel.identifiers[t.channel]:
    rel.identifiers[t.channel].add(t.senderID)
    
  relations[newID] = rel
  saveRelations(workspace, relations)
  
  # Update constraints
  if inv.maxUses > 0:
    inv.maxUses -= 1
    if inv.maxUses == 0:
      allInvites.del(code) # Exhausted
    else:
      allInvites[code] = inv
  saveInvites(workspace, allInvites)
  
  return "Successfully redeemed Pin Code! The user '" & inv.customerName & "' is now authenticated as a Customer for this Agent. You may now assist them normally."

proc newRedeemInviteTool*(): RedeemInviteTool =
  RedeemInviteTool()
