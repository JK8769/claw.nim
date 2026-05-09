## create_customer_invite — chat-driven customer onboarding.
##
## Two modes, chosen by whether `bind_identifiers` is supplied:
##
##   1. Invite-to-share (the classic flow): mint a one-shot access code.
##      Agent returns the code; operator shares it with the customer out
##      of band. Customer sends the code as their first message; gateway
##      intercept burns the code, stamps their identifiers, auto-activates
##      the trial.
##
##   2. Auto-bind (group-chat @mention flow): the operator @mentions the
##      customer in a group chat; we already have the customer's Feishu
##      identifiers from the mentions array. Pass them as
##      `bind_identifiers` — this proc stamps them immediately, activates
##      the trial, and burns the code in one shot. Customer can DM the
##      bot right away with no redemption ceremony.
##
## Gate: any internal-tier user (SuperAdmin, Admin, Staff, etc.). Lets
## a support team share onboarding duty beyond just SuperAdmin. External
## customers still can't invoke — their `entityTier` is "ext" and
## creating customer entities is internal-only.
##
## Implementation: thin wrapper over `cli_admin.mintCustomerInvite` —
## the single source of truth for invite minting. CLI, slash command,
## this MCP tool, and the gateway /invite handler all route through one
## code path, so validation, BASE.nims persistence, and member-record
## materialization stay in lockstep.

import std/[asyncdispatch, json, tables, strutils, times, options, os]
import ../types
import ../spec
import ../../agent/cortex
import ../../agent/invites
import ../../agent/binding
import ../../config
import ../../cli_admin
import ../../billing/subscription as sub_mod

const ToolSpec* = spec(
  name = "create_customer_invite",
  description = "create customer invite code; returns nc:X/CODE bundled string — SuperAdmin only",
  tags = @["admin", "customer", "invite"],
  domain = "customer",
  default = false,
  heartbeatSafe = false,
  category = "customer",
)
import ../../billing/welcome as welcome_mod
import ../../billing/company as company_mod
import ../../billing/plants as plants_mod
import ../../channels/feishu as feishu_channel

type
  CreateCustomerInviteTool* = ref object of ContextualTool

proc newCreateCustomerInviteTool*(): CreateCustomerInviteTool =
  CreateCustomerInviteTool()

method name*(t: CreateCustomerInviteTool): string = "create_customer_invite"

method description*(t: CreateCustomerInviteTool): string =
  "Onboard a customer. Two modes:\n" &
  " 1) Without `bind_identifiers`: mint a one-shot `nc:X/CODE` invite " &
  "    string. Operator shares it out-of-band; customer redeems on " &
  "    first message.\n" &
  " 2) With `bind_identifiers` (typically from a Feishu @mention): " &
  "    skip the redemption ceremony — stamp the customer's identifiers " &
  "    immediately, activate the trial, and burn the code. Customer " &
  "    can DM the bot right away.\n" &
  "Callable by any internal staff (tier=int). External/guest callers " &
  "are refused. When an operator @mentions a customer in group chat " &
  "and asks you to invite them, pull the customer's open_id / union_id " &
  "from the `Mentions` block in the system prompt and pass them in " &
  "`bind_identifiers`."

method parameters*(t: CreateCustomerInviteTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "customer_name": {
        "type": "string",
        "description": "Display name for the customer (e.g. '李工'). Appears in user list + invite list and on the pre-allocated entity."
      },
      "agent": {
        "type": "string",
        "description": "Agent that should handle messages from this customer (e.g. 'Atlas'). Must be an existing declared agent."
      },
      "max_uses": {
        "type": "integer",
        "description": "How many redemptions the code allows. Default 1. Ignored when `bind_identifiers` is provided (auto-bind always single-use)."
      },
      "skills": {
        "type": "array",
        "description": "Skill grants: '<skill>' (unscoped, default creds), '<skill>::<credential>' (credential-scoped — creates the member record for per-customer account routing), or '<account>@<skill>' (legacy). Example: ['sungrow::acme-solar'].",
        "items": { "type": "string" }
      },
      "lang": {
        "type": "string",
        "description": "Customer's preferred language ('zh', 'en', 'zh-CN'). Auto-detect from the operator's command text: if it contains CJK characters, use 'zh'; otherwise 'en'."
      },
      "bind_identifiers": {
        "type": "object",
        "description": "When the operator @mentions the customer in a group chat, pass the customer's Feishu identifiers here so we can stamp them immediately and skip the redemption step. The tool derives the channel key from the tool context (no need to pass it).",
        "properties": {
          "open_id": {
            "type": "string",
            "description": "Feishu open_id of the @mentioned customer (the `open_id` line from the Mentions block — the non-bot entry). This is the per-app identifier the customer uses on THIS Feishu app."
          },
          "union_id": {
            "type": "string",
            "description": "Feishu union_id of the @mentioned customer if present in the Mentions block. Tenant-stable cross-app identifier — stamping it lets the same customer be recognized on any other Feishu app in the same tenant."
          },
          "user_id": {
            "type": "string",
            "description": "Feishu tenant-internal user_id, if present. Optional."
          }
        }
      }
    },
    "required": %*["customer_name", "agent"]
  }.toTable

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

method execute*(t: CreateCustomerInviteTool, args: Table[string, JsonNode]): Future[string] {.async.} =
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
    stderr.writeLine "create_customer_invite: BASE.nims persist failed for " &
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
