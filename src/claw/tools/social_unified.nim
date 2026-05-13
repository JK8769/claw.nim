## social — single tool for read/write access to the social graph and
## customer onboarding flow. Backed by the cortex module (the framework's
## world-graph layer of people, agents, relationships, channel
## identifiers, and trust).
##
## Consolidates five previously-split tools:
##
##   action=query     — JSE graph query (replaces query_graph)
##   action=who       — convenience lookup of one entity by nc:id
##   action=update    — modify a Person's display name (replaces
##                       update_contact); routes to the graph for nc:id
##                       callers and to the per-agent guest ledger for
##                       guest callers
##   action=customers — list customers the caller has personally
##                       onboarded (replaces my_customers)
##   action=invite    — mint a customer invitation (CREATE a pin code);
##                       replaces create_customer_invite. Supports both
##                       share-the-code and auto-bind (Feishu @mention)
##                       modes
##   action=redeem    — redeem a customer invitation pin code (CONSUME);
##                       replaces the misnamed customer/invite.nim
##                       (RedeemInviteTool)
##
## Permission gating is preserved per-action:
##   • query     — admin-tagged; no in-tool gate (registry decides exposure)
##   • who       — same as query (read-only graph lookup)
##   • update    — caller can only rename themselves (derived from
##                 logicalUserID + senderID); internal-tier names are
##                 ClawDSL-owned and refused via chat
##   • customers — internal-tier callers only; external callers get
##                 the "internal-staff feature" explanation
##   • invite    — internal-tier callers only; external/guest refused
##   • redeem    — external-allowed (the entire point — pre-redeem the
##                 caller is necessarily a guest)
##
## Dependency surface (carried by SocialTool):
##   • officeDir          — per-agent office root (for guest ledger writes)
##   • workspace          — company workspace root (for invites, world)
##   • contextBuilder     — guest-ledger writes + graph reference for
##                          rename's Guest path
##
## Everything else (recipientID, senderID, channel, appID, chatID,
## logicalUserID, agentName, graph) is inherited from ContextualTool
## via setContext at dispatch time.

import std/[os, json, asyncdispatch, tables, strutils, times, options]
import ./types
import ./spec
import ../config
import ../cli_admin
import ../agent/cortex
import ../agent/binding
import ../agent/context as agent_context
import ../agent/invites
import ../billing/subscription as sub_mod
import ../billing/welcome as welcome_mod
import ../billing/company as company_mod
import ../billing/plants as plants_mod
import ../channels/feishu as feishu_channel

const ToolSpec* = spec(
  name = "social",
  description = "Social interactions over the world graph: query, look up, " &
                "rename, list onboarded customers, mint/redeem customer invites, " &
                "and route messages to recipients (route/discover/mark_unreachable)",
  tags = @["admin", "social", "graph", "customer", "invite", "core"],
  domain = "social",
  default = true,
  heartbeatSafe = false,
  externalAllowed = true,  # redeem flow is the only externally-callable
                           # action; other actions self-gate by tier inside
                           # the action handler. The blanket external gate
                           # at registry level is too coarse for this tool.
  category = "social",
)

type
  SocialTool* = ref object of ContextualTool
    officeDir*: string                 ## per-agent office root (guest ledger)
    workspace*: string                 ## company workspace root (graph, invites)
    contextBuilder*: ContextBuilder    ## for guest-ledger writes during rename

proc newSocialTool*(officeDir, workspace: string,
                    cb: ContextBuilder): SocialTool =
  SocialTool(officeDir: officeDir, workspace: workspace, contextBuilder: cb)

method name*(t: SocialTool): string = "social"

method description*(t: SocialTool): string =
  "Social interactions — read and update who you know, invite new contacts, " &
  "redeem invitations, list customers. Backed by the cortex module (the " &
  "framework's world-graph layer of people, agents, relationships, channel " &
  "identifiers, and trust).\n\n" &
  "Actions:\n" &
  "  query     — JSE graph query for complex traversal/filtering\n" &
  "  who       — convenience lookup of one entity by nc:id\n" &
  "  update    — modify a Person's fields (name, etc.)\n" &
  "  customers — list customers the caller serves\n" &
  "  invite    — issue a customer invitation (CREATE a pin code)\n" &
  "  redeem    — redeem a customer's invitation pin code (CONSUME)"

method parameters*(t: SocialTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["query", "who", "update", "customers", "invite", "redeem",
                 "route", "discover", "mark_unreachable"],
        "description": "Operation to perform"
      },
      # --- action=route / discover / mark_unreachable ---
      "to": {
        "type": "string",
        "description": "route/discover/mark_unreachable — recipient nc:id (e.g. 'nc:7')"
      },
      "vendor": {
        "type": "string",
        "description": "mark_unreachable — vendor name (feishu, telegram, ...) " &
                       "to flag as unreachable for this recipient. Also accepted on " &
                       "route as an explicit override of the preferred-channel pick."
      },
      "kind": {
        "type": "string",
        "enum": ["chat", "mail"],
        "description": "route/discover — filter by channel kind. Default: chat. " &
                       "(Mail vendors aren't wired yet; reserved for future.)"
      },
      "urgency": {
        "type": "string",
        "enum": ["normal", "urgent"],
        "description": "route — caller's urgency hint. Reserved for future " &
                       "routing-rule lookup; ignored in v1."
      },
      "reason": {
        "type": "string",
        "description": "mark_unreachable — short reason for the flag (e.g. " &
                       "'bounce', 'auth_failed', 'user_blocked'). Stored " &
                       "with a timestamp in entity.custom.unreachable[vendor]."
      },
      # --- action=query ---
      "expression": {
        "type": "array",
        "items": { "type": "string" },  # explicit item type for OpenAI compat
        "description": "query only — JSE array: [function, ...args]. " &
                       "Example: [\"filter\", \"Person\"] or " &
                       "[\"relationships\", \"nc:1\", \"serves\"]"
      },
      # --- action=who ---
      "id": {
        "type": "string",
        "description": "who only — nc:id of the entity to look up (e.g. 'nc:5')"
      },
      # --- action=update ---
      "name": {
        "type": "string",
        "description": "update only — the user's real/preferred display " &
                       "name (e.g. '杰瑞', 'Tom'). Must be non-empty, 1–80 " &
                       "characters, and contain no double-quote characters."
      },
      # --- action=invite ---
      "customer_name": {
        "type": "string",
        "description": "invite only — display name for the customer " &
                       "(e.g. '李工'). Appears in user list + invite list " &
                       "and on the pre-allocated entity."
      },
      "agent": {
        "type": "string",
        "description": "invite only — agent that should handle messages " &
                       "from this customer (e.g. 'Atlas'). Must be an " &
                       "existing declared agent."
      },
      "max_uses": {
        "type": "integer",
        "description": "invite only — how many redemptions the code allows. " &
                       "Default 1. Ignored when `bind_identifiers` is " &
                       "provided (auto-bind always single-use)."
      },
      "skills": {
        "type": "array",
        "description": "invite only — skill grants: '<skill>' (unscoped, " &
                       "default creds), '<skill>::<credential>' " &
                       "(credential-scoped — creates the member record for " &
                       "per-customer account routing), or '<account>@<skill>' " &
                       "(legacy). Example: ['sungrow::acme-solar'].",
        "items": { "type": "string" }
      },
      "lang": {
        "type": "string",
        "description": "invite only — customer's preferred language " &
                       "('zh', 'en', 'zh-CN'). Auto-detect from the " &
                       "operator's command text: if it contains CJK " &
                       "characters, use 'zh'; otherwise 'en'."
      },
      "bind_identifiers": {
        "type": "object",
        "description": "invite only — when the operator @mentions the " &
                       "customer in a group chat, pass the customer's " &
                       "Feishu identifiers here so we can stamp them " &
                       "immediately and skip the redemption step. The tool " &
                       "derives the channel key from the tool context (no " &
                       "need to pass it).",
        "properties": {
          "open_id": {
            "type": "string",
            "description": "Feishu open_id of the @mentioned customer " &
                           "(the `open_id` line from the Mentions block — " &
                           "the non-bot entry). This is the per-app " &
                           "identifier the customer uses on THIS Feishu app."
          },
          "union_id": {
            "type": "string",
            "description": "Feishu union_id of the @mentioned customer if " &
                           "present in the Mentions block. Tenant-stable " &
                           "cross-app identifier — stamping it lets the " &
                           "same customer be recognized on any other Feishu " &
                           "app in the same tenant."
          },
          "user_id": {
            "type": "string",
            "description": "Feishu tenant-internal user_id, if present. Optional."
          }
        }
      },
      # --- action=redeem ---
      "code": {
        "type": "string",
        "description": "redeem only — the 6-character Pin Code provided by " &
                       "the user (e.g., 'A4B-9X2')"
      }
    },
    "required": %["action"]
  }.toTable

# ---------------------------------------------------------------------------
# query — JSE graph traversal
# ---------------------------------------------------------------------------

proc doQuery(t: SocialTool, args: Table[string, JsonNode]): string =
  ## Preserves logic verbatim from admin/query_graph.nim.
  if t.contextBuilder == nil or t.contextBuilder.graph == nil:
    return "Error: World Graph is not initialized."
  if not args.hasKey("expression"):
    return "Error: Missing 'expression' argument."
  let jse = args["expression"]
  try:
    let res = t.contextBuilder.graph.evalJSE(jse)
    return res.pretty()
  except:
    return "Error evaluating JSE: " & getCurrentExceptionMsg()

# ---------------------------------------------------------------------------
# who — convenience single-entity lookup
# ---------------------------------------------------------------------------

proc doWho(t: SocialTool, args: Table[string, JsonNode]): string =
  ## Wrap JSE so the LLM doesn't have to construct the array form for
  ## a trivial "tell me about nc:5" lookup. Same backing graph + same
  ## error semantics as `query`.
  if t.contextBuilder == nil or t.contextBuilder.graph == nil:
    return "Error: World Graph is not initialized."
  if not args.hasKey("id"):
    return "Error: Missing 'id' argument (e.g. 'nc:5')."
  let idStr = args["id"].getStr().strip()
  if idStr.len == 0:
    return "Error: 'id' must be non-empty."
  let jse = %*[%"get", %idStr]
  try:
    let res = t.contextBuilder.graph.evalJSE(jse)
    if res.kind == JNull:
      return "Entity not found: " & idStr
    return res.pretty()
  except:
    return "Error evaluating JSE: " & getCurrentExceptionMsg()

# ---------------------------------------------------------------------------
# update — rename (graph path + guest-ledger path)
# ---------------------------------------------------------------------------

proc renameGuest(t: SocialTool, newName: string): string =
  ## Guest-ledger branch for callers without an nc:id. Verbatim from
  ## admin/update_contact.nim.
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

proc doUpdate(t: SocialTool, args: Table[string, JsonNode]): string =
  ## Preserves logic verbatim from admin/update_contact.nim.
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
    if t.contextBuilder == nil:
      return "Error: guest-ledger writes require a ContextBuilder."
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
    stderr.writeLine "social.update: BASE.nims persist failed for " &
      t.logicalUserID & " (" & oldName & " → " & newName & "): " &
      err.msg & " — graph updated; rerun persistence before `co update`."

  return "Updated: '" & oldName & "' → '" & newName & "'. Every agent " &
         "will address you as '" & newName & "' from now on."

# ---------------------------------------------------------------------------
# customers — list onboarded customers for the calling internal user
# ---------------------------------------------------------------------------

proc doCustomers(t: SocialTool, args: Table[string, JsonNode]): string =
  ## Preserves logic verbatim from customer/my_customers.nim.
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
  let invMap = loadInvites(t.workspace)
  type CustomerRow = tuple[name, ncId, channels: string; onboardedAt: int64]
  var rows: seq[CustomerRow]
  var seen: Table[string, bool]
  for inv in invMap.values:
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

# ---------------------------------------------------------------------------
# invite — mint a customer invitation (share-the-code or auto-bind)
# ---------------------------------------------------------------------------

proc coerceJsonKind(n: JsonNode, want: JsonNodeKind): JsonNode =
  ## Some LLMs (mimo, certain Chinese models) serialize nested fields
  ## as JSON-stringified strings rather than native containers — e.g.
  ## `"bind_identifiers": "{\"open_id\": \"ou_...\"}"` instead of
  ## `"bind_identifiers": {"open_id": "ou_..."}`. Accept both shapes
  ## for JObject / JArray args; return nil if `n` is neither the
  ## desired kind nor a parseable string encoding of it.
  if n == nil: return nil
  if n.kind == want: return n
  if n.kind == JString:
    let prefix = (if want == JObject: '{' elif want == JArray: '[' else: '\0')
    if prefix == '\0': return nil
    let s = n.getStr("").strip()
    if s.len == 0 or s[0] != prefix: return nil
    try:
      let parsed = parseJson(s)
      if parsed.kind == want: return parsed
    except CatchableError: discard
  nil

proc extractBindIdentifiers(args: Table[string, JsonNode],
                            channelKey: string): (bool, seq[(string, string)]) =
  ## Parse bind_identifiers arg into a stampable (channel_key, value) list.
  ## Returns (true, pairs) if auto-bind is requested and we have at least
  ## an open_id. Returns (false, @[]) otherwise (classic invite-to-share).
  ## channelKey is derived from the tool context (ContextualTool.channel
  ## + appID) so the LLM doesn't have to construct it — removes a class
  ## of tool-call errors we saw when the LLM passed bare "feishu".
  if not args.hasKey("bind_identifiers"): return (false, @[])
  let b = coerceJsonKind(args["bind_identifiers"], JObject)
  if b == nil: return (false, @[])
  let openID = b{"open_id"}.getStr("").strip()
  if channelKey.len == 0 or openID.len == 0:
    return (false, @[])
  var pairs: seq[(string, string)] = @[(channelKey, openID)]
  let unionID = b{"union_id"}.getStr("").strip()
  if unionID.len > 0: pairs.add(("feishu:union", unionID))
  let userID = b{"user_id"}.getStr("").strip()
  if userID.len > 0: pairs.add(("feishu:user", userID))
  (true, pairs)

proc findExistingByIdentifier(graph: WorldGraph,
                              channelKey, value: string): WorldEntityID =
  ## Scan all entities for an exact (channelKey, value) identifier match.
  ## Returns the first match or WorldEntityID(0) when nothing matches.
  ## Used to dedupe auto-bind invites — if the @mentioned open_id already
  ## belongs to an entity, don't mint a second one.
  if graph == nil or channelKey.len == 0 or value.len == 0:
    return WorldEntityID(0)
  for id, ent in graph.entities.pairs:
    if ent.identifiers.getOrDefault(channelKey) == value:
      return id
  WorldEntityID(0)

proc doInvite(t: SocialTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Preserves logic verbatim from customer/create_customer_invite.nim.
  # Permission check — any internal-tier user can invite (D1 Option B:
  # lets staff share onboarding duty beyond SuperAdmin). External/guest
  # callers are refused because creating customer entities is internal
  # admin work.
  # Uses cli_admin.tierFromRoleName (name heuristic only — no Config
  # access from a ContextualTool, so declared trust roles in the
  # config block aren't honored here. Acceptable: the caller's
  # `entity.role` is the authoritative axis and the heuristic covers
  # the standard role names).
  var callerTier = "?"
  if t.graph != nil and t.logicalUserID.startsWith("nc:"):
    let id = parseAlias(t.logicalUserID)
    if uint32(id) > 0 and t.graph.entities.hasKey(id):
      callerTier = tierFromRoleName(t.graph.entities[id].role)
  if callerTier != "int":
    return "Error: invites can only be minted by internal staff. " &
           "Current caller: " & t.logicalUserID & " (tier=" & callerTier & ")."

  if not args.hasKey("customer_name") or not args.hasKey("agent"):
    return "Error: customer_name and agent are both required."
  let customerName = args["customer_name"].getStr().strip()
  let agentName = args["agent"].getStr().strip()

  var skills: seq[string]
  if args.hasKey("skills"):
    let arr = coerceJsonKind(args["skills"], JArray)
    if arr != nil:
      for item in arr:
        let s = item.getStr("").strip()
        if s.len > 0: skills.add(s)

  var lang =
    if args.hasKey("lang"): args["lang"].getStr("").strip()
    else: ""

  # Fallback: if skills + lang weren't in the command, try the Feishu
  # group description. Operator sets it once per customer group (e.g.
  # "SolarIQ customer group — sungrow::acme-solar lang=zh"), and future
  # invites in that chat auto-inherit the defaults. Quiet failure —
  # empty description or no recognized tokens just means "no default",
  # the tool errors back to the operator asking for explicit syntax.
  if t.channel == "feishu" and t.chatID.len > 0 and t.appID.len > 0 and
     (skills.len == 0 or lang.len == 0):
    let desc = fetchChatDescription(t.appID, t.chatID)
    if desc.len > 0:
      let defaults = parseGroupDefaults(desc)
      if skills.len == 0 and defaults.skills.len > 0:
        skills = defaults.skills
      if lang.len == 0 and defaults.lang.len > 0:
        lang = defaults.lang

  # Helpful error if the operator still hasn't specified a skill binding.
  # Suggest both the in-command syntax AND the group-description way.
  if skills.len == 0:
    return "Error: no skill binding specified and the group description " &
           "doesn't declare one. Either tell me in the command, e.g.\n" &
           "  `@Atlas 邀请 @<customer> 使用 sungrow::<account>`\n" &
           "  `@Atlas invite @<customer> use sungrow::<account>`\n" &
           "OR set the group description to include `sungrow::<account>` " &
           "(once per group; future invites inherit it)."

  # Derive the channel key from the tool context — the LLM doesn't need
  # to construct it. For Feishu we key per-app (two customers on two
  # different Atlas apps have distinct channel keys even with the same
  # open_id namespace), so it's `<channel>:<app_id>` when app_id present.
  let channelKey =
    if t.channel == "feishu" and t.appID.len > 0:
      t.channel & ":" & t.appID
    else: t.channel
  let (autoBind, identifierPairs) = extractBindIdentifiers(args, channelKey)

  # Dedupe — if the @mentioned open_id already belongs to a registered
  # entity, refuse and point at the existing record. Prevents creating
  # a "duplicate" entity when the operator @mentions someone whose
  # Feishu display name has drifted (e.g. Feishu placeholder names like
  # `用户255941` differ from what's in BASE.nims).
  if autoBind and t.graph != nil:
    for (k, v) in identifierPairs:
      if k.startsWith("feishu:union") or k.startsWith("feishu:user"):
        continue  # union_id / user_id match is looser; primary dedup is open_id
      let existingID = findExistingByIdentifier(t.graph, k, v)
      if uint32(existingID) > 0:
        let existing = t.graph.entities[existingID]
        return "Already registered: " & v & " is bound to " &
               toAlias(existingID) & " (" & existing.name & "). " &
               "No new invite minted. If this customer needs reactivation, " &
               "use `claw user restore " & toAlias(existingID) & "` (for " &
               "soft-removed) or `claw user subscription activate " &
               toAlias(existingID) & "` (if missing a plan)."

  # Auto-bind = single-use always; classic flow accepts caller override.
  let maxUses =
    if autoBind: 1
    elif args.hasKey("max_uses"): args["max_uses"].getInt(1)
    else: 1

  let workspace = t.graph.workspace
  let inv = mintCustomerInvite(workspace, t.logicalUserID,
                                customerName, agentName, maxUses, skills, lang)
  if not inv.ok:
    return "Error: " & inv.error

  # Re-sync our in-memory graph with disk. `mintCustomerInvite` loads
  # its own graph copy, mutates it, and saves — our pre-mint `t.graph`
  # doesn't have the newly-allocated entity. Stamping identifiers on
  # the stale copy would both miss the mint's changes AND stomp them
  # back to disk on our subsequent saveWorld. Reload first.
  let fresh = loadWorld(workspace)
  if fresh != nil: t.graph = fresh

  # Classic share-the-code path — done, return the code.
  if not autoBind:
    var skillLine = ""
    if inv.allowedSkills.len > 0:
      skillLine = "  Skills:   " & inv.allowedSkills.join(", ") & "\n"
      if inv.materialized.len > 0:
        skillLine.add("  Credentials routed: " & inv.materialized.join(", ") & "\n")
    let brand = resolveBrand(t.graph)
    let shareLine = inviteCodeMessage(brand, inv.code, lang)
    return "Customer invite minted (share-the-code mode).\n\n" &
           "Forward to the customer:\n  **" & shareLine & "**\n\n" &
           "  Customer: " & inv.customerName & " (" & inv.targetNcId & ")\n" &
           "  Agent:    " & inv.agentName & "\n" &
           "  Max uses: " & $inv.maxUses & "\n" &
           skillLine & "\n" &
           "They send that as their first DM to " & inv.agentName &
           ". Redeem burns the code, stamps their identifiers, " &
           "and activates the trial."

  # Auto-bind path — stamp identifiers, activate trial, burn code.
  let targetID = parseAlias(inv.targetNcId)
  if uint32(targetID) == 0 or not t.graph.entities.hasKey(targetID):
    return "Error: internal inconsistency — minted invite target " &
           inv.targetNcId & " not found in graph."
  var ent = t.graph.entities[targetID]
  for (k, v) in identifierPairs:
    ent.identifiers[k] = v
  t.graph.entities[targetID] = ent
  t.graph.saveWorld()

  # Persist identifiers to BASE.nims too — without this, `co update`
  # would regenerate BASE.json from the DSL and wipe them (classic
  # redeem flow uses the same helper; auto-bind wasn't calling it).
  # Failure is non-fatal (graph stamping above is the authoritative
  # source until the next `co update`), but log so the operator can
  # rerun persistence manually before regenerating.
  try:
    persistPersonIdentifiers(
      getNimClawDir() / "BASE.nims", ent.name, identifierPairs)
  except CatchableError as err:
    stderr.writeLine "social.invite: BASE.nims persist failed for " &
      ent.name & ": " & err.msg & " (graph stamped; rerun `claw user edit " &
      inv.targetNcId & "` before `co update` to avoid losing identifiers)"

  # Burn the invite — it's served its purpose (we have the identifiers).
  var invMap = loadInvites(workspace)
  if invMap.hasKey(inv.code):
    invMap.del(inv.code)
    saveInvites(workspace, invMap)

  # Auto-activate trial (same logic the gateway's invite-redeem intercept
  # uses for the classic path).
  let now = getTime().toUnix
  if loadSubscription(inv.targetNcId).isNone:
    stampSubscription(inv.targetNcId, defaultTrial(now))

  # Welcome message for the operator to paste/relay — in the customer's
  # language, branded with company + support contact.
  let brand = resolveBrand(t.graph)
  let contact = resolveSupportContact(t.graph)
  let freshSub = loadSubscription(inv.targetNcId)
  let welcomeSub =
    if freshSub.isSome: freshSub.get() else: defaultTrial(now)
  let ctx = WelcomeContext(
    customerName: ent.name,
    agentName: agentName,
    lang: lang,
    sub: welcomeSub,
    companyName: brand,
    contact: contact,
    plantNames: fetchPlantNames(inv.targetNcId)
  )

  var msg = "Customer auto-onboarded. No code exchange needed — " &
            inv.customerName & " (" & inv.targetNcId & ") is ready to DM " &
            agentName & " now.\n\n"
  msg.add("  Identifiers stamped:\n")
  for (k, v) in identifierPairs:
    msg.add("    " & k & " = " & v & "\n")
  if inv.allowedSkills.len > 0:
    msg.add("  Skills:   " & inv.allowedSkills.join(", ") & "\n")
    if inv.materialized.len > 0:
      msg.add("  Credentials routed: " & inv.materialized.join(", ") & "\n")
  msg.add("  Plan:     trial (" & $TrialDays & " days, " &
          $(welcomeSub.dailyTokens div 1000) & "k tokens/day)\n\n")
  msg.add("Welcome text for the group (paste after tagging the " &
          "customer):\n\n" & welcomeMessage(ctx))
  return msg

# ---------------------------------------------------------------------------
# redeem — consume a customer invitation pin code
# ---------------------------------------------------------------------------

proc doRedeem(t: SocialTool, args: Table[string, JsonNode]): string =
  ## Preserves logic verbatim from customer/invite.nim (the misnamed
  ## file — it actually REDEEMS, doesn't create).
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

# ---------------------------------------------------------------------------
# route / discover / mark_unreachable — recipient-centric channel routing
# ---------------------------------------------------------------------------
#
# Channel addresses live as entries in `WorldEntity.identifiers` (one row per
# vendor → opaque address). Routing preferences and learned-unreachability
# are tucked into `WorldEntity.custom`:
#
#   custom.preferred_channel : string         — vendor name to prefer
#   custom.unreachable       : object         — { vendor → { reason, ts } }
#
# Schema-light by design: cortex's existing identifiers + custom JsonNode
# carry everything routing needs without bloating the WorldEntity type.

const ChatVendors = ["feishu", "telegram", "discord", "dingtalk", "qq",
                     "whatsapp", "nmobile", "zen", "lark", "maixcam"]
const MailVendors = ["email", "smtp", "imap"]

proc isChatVendor(v: string): bool =
  for c in ChatVendors:
    if c == v: return true
  false

proc isMailVendor(v: string): bool =
  for m in MailVendors:
    if m == v: return true
  false

proc parseVendorFromIdKey(key: string): string =
  ## Identifier keys in cortex are typically `vendor:scope` (e.g.
  ## `feishu:cli_xxx`) or just `vendor`. Strip the scope to get the bare
  ## vendor name for capability lookup.
  let i = key.find(':')
  if i > 0: key[0 ..< i] else: key

proc getEntityForRoute(t: SocialTool, args: Table[string, JsonNode]):
    (Option[WorldEntity], string) =
  ## Resolve `to=nc:X` to a WorldEntity. Returns (some(entity), "") on
  ## success; (none, errMsg) on failure.
  if t.contextBuilder == nil or t.contextBuilder.graph == nil:
    return (none(WorldEntity), "Error: World Graph is not initialized.")
  if not args.hasKey("to"):
    return (none(WorldEntity), "Error: Missing 'to' (e.g. 'nc:7').")
  let alias = args["to"].getStr().strip()
  if alias.len == 0:
    return (none(WorldEntity), "Error: 'to' must be non-empty.")
  let g = t.contextBuilder.graph
  if not g.idAliasIndex.hasKey(alias):
    return (none(WorldEntity), "Entity not found: " & alias)
  let id = g.idAliasIndex[alias]
  if not g.entities.hasKey(id):
    return (none(WorldEntity), "Entity index points to a missing entry: " & alias)
  (some(g.entities[id]), "")

proc isUnreachable(ent: WorldEntity, vendor: string): bool =
  if ent.custom.isNil or ent.custom.kind != JObject: return false
  if not ent.custom.hasKey("unreachable"): return false
  let u = ent.custom["unreachable"]
  if u.kind != JObject: return false
  u.hasKey(vendor)

proc preferredChannel(ent: WorldEntity): string =
  if ent.custom.isNil or ent.custom.kind != JObject: return ""
  if not ent.custom.hasKey("preferred_channel"): return ""
  ent.custom["preferred_channel"].getStr("")

proc routeKind(args: Table[string, JsonNode]): string =
  if args.hasKey("kind"): args["kind"].getStr("chat") else: "chat"

proc kindMatches(vendor, kind: string): bool =
  case kind
  of "mail": isMailVendor(vendor)
  else:      isChatVendor(vendor)

proc doRoute(t: SocialTool, args: Table[string, JsonNode]): string =
  ## Pick a channel for a recipient. Order:
  ##   1. Explicit override: `vendor=X` if X is in the recipient's identifiers
  ##      and not flagged unreachable
  ##   2. `custom.preferred_channel` if it matches kind and isn't unreachable
  ##   3. First identifier whose vendor matches kind and isn't unreachable
  let (eOpt, err) = getEntityForRoute(t, args)
  if eOpt.isNone: return err
  let ent = eOpt.get
  let kind = routeKind(args)

  # Build the (vendor, address) candidate list from identifiers.
  var candidates: seq[tuple[vendor, address, key: string]]
  for k, v in ent.identifiers:
    let vendor = parseVendorFromIdKey(k)
    if vendor.len == 0: continue
    if not kindMatches(vendor, kind): continue
    candidates.add((vendor: vendor, address: v, key: k))
  if candidates.len == 0:
    return $(%*{"error": "no_reachable_address",
                "to": args["to"].getStr(),
                "kind": kind})

  # 1. Explicit override
  if args.hasKey("vendor"):
    let want = args["vendor"].getStr()
    for c in candidates:
      if c.vendor == want and not isUnreachable(ent, c.vendor):
        return $(%*{"vendor": c.vendor, "address": c.address,
                    "key": c.key, "reason": "explicit_override"})
    return $(%*{"error": "vendor_not_reachable", "vendor": want,
                "to": args["to"].getStr()})

  # 2. Stated preference
  let pref = preferredChannel(ent)
  if pref.len > 0:
    for c in candidates:
      if c.vendor == pref and not isUnreachable(ent, c.vendor):
        return $(%*{"vendor": c.vendor, "address": c.address,
                    "key": c.key, "reason": "preferred_channel"})

  # 3. First reachable
  for c in candidates:
    if not isUnreachable(ent, c.vendor):
      return $(%*{"vendor": c.vendor, "address": c.address,
                  "key": c.key, "reason": "first_available"})

  $(%*{"error": "all_unreachable", "to": args["to"].getStr(),
       "candidates": candidates.len})

proc doDiscover(t: SocialTool, args: Table[string, JsonNode]): string =
  ## List every channel address known for a recipient, with reachability
  ## flag. Useful for the agent to reason about which paths exist.
  let (eOpt, err) = getEntityForRoute(t, args)
  if eOpt.isNone: return err
  let ent = eOpt.get
  let kind = routeKind(args)
  let pref = preferredChannel(ent)
  var rows = newJArray()
  for k, v in ent.identifiers:
    let vendor = parseVendorFromIdKey(k)
    if vendor.len == 0: continue
    if not kindMatches(vendor, kind): continue
    rows.add(%*{
      "vendor": vendor,
      "address": v,
      "key": k,
      "preferred": vendor == pref,
      "unreachable": isUnreachable(ent, vendor)
    })
  $rows

proc doMarkUnreachable(t: SocialTool, args: Table[string, JsonNode]): string =
  ## Stamp `custom.unreachable[vendor] = { reason, ts }` and persist.
  if not args.hasKey("vendor"):
    return "Error: 'vendor' is required (the channel that bounced)."
  let vendor = args["vendor"].getStr().strip()
  if vendor.len == 0:
    return "Error: 'vendor' must be non-empty."
  let reason = if args.hasKey("reason"): args["reason"].getStr() else: ""
  let (eOpt, err) = getEntityForRoute(t, args)
  if eOpt.isNone: return err
  let ent = eOpt.get
  let g = t.contextBuilder.graph
  var mutated = ent
  if mutated.custom.isNil or mutated.custom.kind != JObject:
    mutated.custom = newJObject()
  if not mutated.custom.hasKey("unreachable") or
     mutated.custom["unreachable"].kind != JObject:
    mutated.custom["unreachable"] = newJObject()
  mutated.custom["unreachable"][vendor] = %*{
    "reason": reason,
    "ts": $now()
  }
  g.entities[mutated.id] = mutated
  saveWorld(g)
  $(%*{"to": args["to"].getStr(), "vendor": vendor,
       "marked_unreachable": true, "reason": reason})

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

method execute*(t: SocialTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (query | who | update | customers | invite | redeem | route | discover | mark_unreachable)"
  let action = args["action"].getStr()
  case action
  of "query":            return doQuery(t, args)
  of "who":              return doWho(t, args)
  of "update":           return doUpdate(t, args)
  of "customers":        return doCustomers(t, args)
  of "invite":           return await doInvite(t, args)
  of "redeem":           return doRedeem(t, args)
  of "route":            return doRoute(t, args)
  of "discover":         return doDiscover(t, args)
  of "mark_unreachable": return doMarkUnreachable(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: query | who | update | customers | invite | redeem | route | discover | mark_unreachable"
