import std/[os, json, tables, asyncdispatch, strutils]
import types
import ../agent/cortex
import ../agent/invites

type
  UpdateContactTool* = ref object of ContextualTool
    officeDir: string

proc newUpdateContactTool*(officeDir: string): UpdateContactTool =
  UpdateContactTool(officeDir: officeDir)

method name*(t: UpdateContactTool): string = "update_contact"

method description*(t: UpdateContactTool): string =
  "Updates the name for a contact in your relationship database. Use this when a user introduces themselves or corrects their name. Always use this to remember who someone is if they tell you their name."

method parameters*(t: UpdateContactTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "name": {
        "type": "string",
        "description": "The real name of the contact interacting with you (e.g. 'Tom')."
      },
      "identity": {
        "type": "string",
        "enum": ["Guest", "Customer"],
        "description": "Optional updated identity. ONLY 'Guest' or 'Customer' is allowed. Other identities must be registered by the admin in BASE.json."
      },
      "invitation_code": {
        "type": "string",
        "description": "REQUIRED if you are changing their identity to 'Customer'. Ask the user for their 6-character Pin Code invitation."
      }
    },
    "required": %["name"]
  }.toTable

method execute*(t: UpdateContactTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("name") or args["name"].kind == JNull:
    return "Error: name is required"
    
  let newName = args["name"].getStr().strip()
  let newIdentity = if args.hasKey("identity") and args["identity"].kind != JNull: args["identity"].getStr().strip() else: ""
  let inviteCode = if args.hasKey("invitation_code") and args["invitation_code"].kind != JNull: args["invitation_code"].getStr().strip() else: ""
  
  if newIdentity != "" and newIdentity notin ["Guest", "Customer"]:
    return "Error: You cannot change identity to '" & newIdentity & "'. In RELATIONS.json, identities are strictly restricted to 'Guest' or 'Customer'. Higher privileges must be registered by an Administrator in BASE.json."

  var relations = loadRelations(t.officeDir)
  var (legacyID, _) = relations.resolveUser(t.channel, t.senderID)
  
  if legacyID == "":
    var (graphUserID, _) = relations.resolveUser(t.channel, t.senderID)
    if graphUserID == "":
      # Last fallback: search directly
      for id, rel in relations.pairs:
        if rel.identifiers.hasKey(t.channel) and t.senderID in rel.identifiers[t.channel]:
          legacyID = id
          break
          
    if legacyID == "":
      return "Error: Could not find your contact record to update in RELATIONS.json"
    
  # Update relation
  var rel = relations[legacyID]
  rel.name = newName
  
  if newIdentity != "":
    if newIdentity == "Customer":
      if inviteCode == "":
        return "Error: You must ask the user to provide their invitation code (Pin Code) to upgrade to Customer."
      
      let workspace = t.officeDir.parentDir().parentDir()
      var allInvites = loadInvites(workspace)
      if not allInvites.hasKey(inviteCode):
        return "Error: Invalid invitation code. The system refused to change their identity."
        
      var inv = allInvites[inviteCode]
      if t.recipientID != "" and inv.agentName != t.recipientID:
        return "Error: The Pin Code belongs to a different Employee. You cannot redeem it."
      if not isValid(inv):
        return "Error: The Pin Code is expired or exhausted."
        
      # Update constraints
      if inv.maxUses > 0:
        inv.maxUses -= 1
        if inv.maxUses == 0:
          allInvites.del(inviteCode)
        else:
          allInvites[inviteCode] = inv
      saveInvites(workspace, allInvites)
      
    rel.identity = newIdentity
  
  relations[legacyID] = rel
  saveRelations(t.officeDir, relations)
  return "Successfully updated contact to Name: '" & newName & "'"
