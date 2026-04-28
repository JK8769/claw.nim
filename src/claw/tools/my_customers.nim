## my_customers — show the caller's own onboarding history.
##
## Lets an internal-tier user ask the agent "how many customers have I
## invited?" or "show me my customers" without dropping to a slash
## command. The tool reads the caller's nc:id from the tool context
## (`logicalUserID`) and walks INVITES.json for entries where
## `issuedBy == nc:X` AND the pre-allocated `targetNcId` entity has
## at least one identifier (i.e. the customer actually claimed the
## code — `usedBy` isn't reliable, see `cli_admin` cleanup hook).
##
## Privacy: the tool returns ONLY the caller's own invitees. There's
## no `nc_id` parameter — looking at someone else's onboarding history
## is a privileged operation that goes through `/user list` (Admin+).
## External-tier callers get an empty list with an explanatory note.

import std/[asyncdispatch, json, tables, strutils, times]
import types
import ../agent/cortex
import ../agent/invites
import ../cli_admin

type
  MyCustomersTool* = ref object of ContextualTool
    workspace*: string

proc newMyCustomersTool*(workspace: string): MyCustomersTool =
  MyCustomersTool(workspace: workspace)

method name*(t: MyCustomersTool): string = "my_customers"

method description*(t: MyCustomersTool): string =
  "Returns the list of customers the CALLER (the user currently " &
  "talking to you) has personally invited and onboarded. Use this " &
  "when an internal user asks 'how many customers have I invited', " &
  "'show me my customers', 'who did I onboard', or similar. The " &
  "caller's nc:id is read automatically from the conversation " &
  "context — the user does not need to supply it. Only counts " &
  "customers who actually claimed their invite code (i.e. real " &
  "onboarded users, not pending placeholders). External-tier callers " &
  "get an empty result."

method parameters*(t: MyCustomersTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{},
    "required": %*[]
  }.toTable

method execute*(t: MyCustomersTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.logicalUserID.len == 0 or not t.logicalUserID.startsWith("nc:"):
    return "I don't know who you are yet — your account isn't bound to " &
           "this channel. Contact a SuperAdmin to get a binding code."
  if t.graph == nil:
    return "Error: world graph unavailable."
  let id = parseAlias(t.logicalUserID)
  if uint32(id) == 0 or not t.graph.entities.hasKey(id):
    return "Error: caller " & t.logicalUserID & " not found in graph."
  let caller = t.graph.entities[id]
  if not isInternalRole(caller.role):
    return "Customer onboarding is an internal-staff feature. " &
           "You're currently registered as `" & caller.role &
           "`. If you should have invite privileges, ask an admin."
  let invites = loadInvites(t.workspace)
  type CustomerRow = tuple[name, ncId, channels: string; onboardedAt: int64]
  var rows: seq[CustomerRow]
  var seen: Table[string, bool]
  for inv in invites.values:
    if inv.issuedBy != t.logicalUserID: continue
    if inv.targetNcId.len == 0 or not inv.targetNcId.startsWith("nc:"): continue
    let cid = parseAlias(inv.targetNcId)
    if uint32(cid) == 0 or not t.graph.entities.hasKey(cid): continue
    let target = t.graph.entities[cid]
    if target.identifiers.len == 0: continue
    # Drop entities that have been promoted to internal-tier — they
    # joined the team, so they're no longer "customers I invited".
    if isInternalRole(target.role): continue
    if seen.hasKey(inv.targetNcId): continue
    seen[inv.targetNcId] = true
    var chans: seq[string]
    for chan, _ in target.identifiers.pairs:
      let kind = chan.split(':', 1)[0]
      if kind.len > 0 and kind notin chans: chans.add(kind)
    rows.add((
      name: target.name,
      ncId: inv.targetNcId,
      channels: chans.join(", "),
      onboardedAt: inv.usedAt
    ))
  if rows.len == 0:
    return "You haven't onboarded any customers yet, " &
           caller.name & ". Use `/user invite <name>` (or ask me " &
           "to invite a customer for you) to get started."
  var out_lines = @[
    "You (" & caller.name & ", " & t.logicalUserID & ") have " &
    "personally onboarded **" & $rows.len & "** customer" &
    (if rows.len > 1: "s" else: "") & ":\n"
  ]
  for r in rows:
    let when_str =
      if r.onboardedAt > 0:
        let d = fromUnix(r.onboardedAt)
        " (joined " & d.format("yyyy-MM-dd") & ")"
      else: ""
    out_lines.add("  • " & r.name & " — " & r.ncId &
                  " via " & r.channels & when_str)
  out_lines.join("\n")
