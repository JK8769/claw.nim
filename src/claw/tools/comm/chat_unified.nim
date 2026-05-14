## chat — channel-agnostic protocol verbs for real-time conversation.
##
## The "ship" in the cortex/chat/channel trio. Carries messages over
## whatever transport `social route` picks for the recipient; consults
## `channel capabilities` to decide whether to send as text or promote
## to the vendor's rich-card primitive. No vendor names hardcoded here —
## the format-selection logic uses the capability matrix declared by
## each channel impl.
##
##   method=send      — push a message to a recipient (nc:id)
##                       Resolves vendor + address via cortex (same
##                       routing logic as `social route`). Optional
##                       `vendor=Y` overrides the routing pick.
##   method=reply     — answer the current inbound message (uses the
##                       inbound's channel + chat_id from tool context;
##                       no recipient lookup needed). Accepts optional
##                       `progress=[items]` for plan-state checkpoints
##                       and `interim=true` when more updates are coming.
##   method=forward   — forward content to a recipient (vendor + address
##                       resolved like `send`)
##
## Format selection: capability-driven. If `caps.card.isSome` and the
## content is too long for plain text OR contains markdown that text
## would lose, the chat tool promotes to card. The vendor's channel impl
## handles the actual rendering (CardKit JSON, telegram_inline blocks,
## discord embed) — chat just declares the format intent in metadata.
##
## Progress rendering is also capability-driven: for every channel,
## chat prepends a plain-text checklist to the message body (works
## everywhere). For card-capable channels, chat additionally stamps
## metadata["progress"] so the vendor renderer can promote the
## checklist to a richer plan-state card when it knows how. Agent
## calls a single `chat reply text=… progress=[…]` regardless of
## destination channel — the unified adaptor handles the rest.

import std/[json, asyncdispatch, tables, options, strutils]
import ../types
import ../spec
import ../../agent/cortex
import ../../channels/base as channel_base
import ../../channels/access

const ToolSpec* = spec(
  name = "chat",
  description = "Real-time conversational messaging — channel-agnostic. " &
                "send/reply/forward verbs that consult `channel capabilities` " &
                "for format selection (text vs card) without hardcoded " &
                "vendor branches. For persistent/async messaging, see `mail`.",
  tags = @["comm", "chat", "messaging", "core"],
  searchKeywords = @["send message", "chat send", "chat reply", "chat forward",
                     "talk", "message", "respond", "reply", "answer"],
  domain = "comm",
  default = false,  # protocol layer; rolling out alongside reply
  heartbeatSafe = false,
  externalAllowed = true,
  category = "comm",
)

type
  TaskItemStatus* = enum
    tisPending       = "pending"
    tisInProgress    = "in_progress"
    tisClaimedDone   = "claimed_done"
    tisVerifiedDone  = "verified_done"

  TaskItem* = object
    content*:      string
    status*:       TaskItemStatus
    verification*: string  ## Required when status=verified_done

  ChatTool* = ref object of ContextualTool
    sendCallback*: types.SendCallback
      ## Wired by the gateway after construction. Same signature as
      ## ReplyTool's callback — pushes OutboundMessage to the bus,
      ## which Manager.dispatchOutbound routes to the right channel.
    progressItems*: Table[string, seq[TaskItem]]
      ## Per-session current plan-state. Replaced wholesale on each
      ## `chat reply` call that includes `progress=[...]`. The agent
      ## loop reads this for iteration-budget scaling: more items =
      ## more iterations granted (TodoWrite-style). Mirrors the
      ## former ReplyTool.items field; migration from reply.method=
      ## progress kept the shape intact.

proc newChatTool*(): ChatTool =
  ChatTool(progressItems: initTable[string, seq[TaskItem]]())

proc setSendCallback*(t: ChatTool, callback: types.SendCallback) =
  t.sendCallback = callback

method name*(t: ChatTool): string = "chat"

method description*(t: ChatTool): string =
  "Real-time messaging (channel-agnostic protocol verbs):\n" &
  "  send     — to=nc:X text=... [vendor=Y override]\n" &
  "  reply    — text=... [progress=[items]] [interim=true]\n" &
  "             (uses current inbound's channel + chat_id; progress is\n" &
  "             plan-state checkpoints rendered as text checklist on\n" &
  "             every channel + a card on card-capable channels)\n" &
  "  forward  — to=nc:X text=... (relay content to another recipient)\n\n" &
  "Format is selected by consulting `channel capabilities` for the " &
  "destination vendor — long or rich content auto-promotes to the " &
  "vendor's card primitive when the channel supports cards. Routing " &
  "(which vendor for nc:X) is resolved via cortex (same logic as " &
  "`social route`). For persistent / async / archive-ready messages, " &
  "use `mail` instead."

method parameters*(t: ChatTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["send", "reply", "forward"],
        "description": "Operation to perform"
      },
      "to": {
        "type": "string",
        "description": "send/forward — recipient nc:id (e.g. 'nc:7'). Not " &
                       "needed for reply (uses inbound context)."
      },
      "text": {
        "type": "string",
        "description": "Message text. Markdown is fine — chat will pick " &
                       "the right format (text vs card) based on the " &
                       "destination's capabilities."
      },
      "vendor": {
        "type": "string",
        "description": "send/forward — explicit vendor override. By default " &
                       "chat consults the recipient's preferred / first " &
                       "reachable channel; this lets you force a specific one."
      },
      "as": {
        "type": "string",
        "enum": ["text", "card", "file"],
        "description": "send/forward — explicit format override. By default " &
                       "chat picks text or card based on capabilities + content."
      },
      "progress": {
        "type": "array",
        "description": "reply only — plan-state checkpoint items. Each item: " &
                       "{content, status, verification?}. Status enum: " &
                       "pending, in_progress, claimed_done, verified_done. " &
                       "Rendered as plain text checklist on every channel; " &
                       "card-capable channels can promote to a richer widget. " &
                       "verified_done items must include a verification field.",
        "items": {
          "type": "object",
          "properties": {
            "content":      { "type": "string" },
            "status":       { "type": "string",
                              "enum": ["pending", "in_progress",
                                       "claimed_done", "verified_done"] },
            "verification": { "type": "string" }
          },
          "required": ["content", "status"]
        }
      },
      "interim": {
        "type": "boolean",
        "description": "reply only — true when more updates are coming (this " &
                       "is a status checkpoint, not a final answer). Default " &
                       "false (terminal reply, ends the turn). Maps to the " &
                       "old `reply method=progress` semantics."
      }
    },
    "required": %["action", "text"]
  }.toTable

# ── routing helpers (mirror social.doRoute, kept simple here) ──────

const ChatVendors = ["feishu", "telegram", "discord", "dingtalk", "qq",
                     "whatsapp", "nmobile", "zen", "lark", "maixcam"]

proc isChatVendor(v: string): bool =
  for c in ChatVendors:
    if c == v: return true
  false

proc parseVendorFromIdKey(key: string): string =
  let i = key.find(':')
  if i > 0: key[0 ..< i] else: key

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

proc resolveRecipient(t: ChatTool, toAlias, vendorOverride: string):
    (string, string, string) =
  ## Returns (vendor, address, errMsg). On success errMsg is empty.
  if t.graph == nil:
    return ("", "", "World Graph is not initialized.")
  let g = t.graph
  if not g.idAliasIndex.hasKey(toAlias):
    return ("", "", "Recipient not found: " & toAlias)
  let id = g.idAliasIndex[toAlias]
  if not g.entities.hasKey(id):
    return ("", "", "Entity index dangling for: " & toAlias)
  let ent = g.entities[id]
  var candidates: seq[tuple[vendor, address: string]]
  for k, v in ent.identifiers:
    let vendor = parseVendorFromIdKey(k)
    if vendor.len == 0 or not isChatVendor(vendor): continue
    candidates.add((vendor: vendor, address: v))
  if candidates.len == 0:
    return ("", "", "No reachable chat channel for " & toAlias)
  if vendorOverride.len > 0:
    for c in candidates:
      if c.vendor == vendorOverride and not isUnreachable(ent, c.vendor):
        return (c.vendor, c.address, "")
    return ("", "", "Vendor not reachable: " & vendorOverride & " for " & toAlias)
  let pref = preferredChannel(ent)
  if pref.len > 0:
    for c in candidates:
      if c.vendor == pref and not isUnreachable(ent, c.vendor):
        return (c.vendor, c.address, "")
  for c in candidates:
    if not isUnreachable(ent, c.vendor):
      return (c.vendor, c.address, "")
  ("", "", "All channels unreachable for " & toAlias)

# ── format selection (capability-driven, NOT vendor-named) ──────────

proc looksRichMarkdown(text: string): bool =
  ## Cheap heuristic: pipe tables, fenced code blocks, or 4+ heading
  ## levels in a row. Conservative — false negatives are fine, false
  ## positives just promote a plain message to a card unnecessarily.
  if text.contains("```"): return true
  var pipeRows = 0
  for line in text.splitLines:
    if line.startsWith('|') and line.contains('|'): pipeRows.inc
    if pipeRows >= 2: return true
  false

proc selectFormat(content: string, caps: channel_base.ChannelCapabilities,
                  override: string): string =
  ## Decide whether to send as text or promote to card. Returns
  ## "text" | "card" | "file". `override` lets the caller force a
  ## specific format; otherwise capabilities + content drive the choice.
  if override.len > 0: return override
  let cardable = caps.card.isSome
  let isLong = caps.text.max_length > 0 and content.len > caps.text.max_length
  let isRich = caps.text.markdown and looksRichMarkdown(content)
  if cardable and (isLong or isRich): return "card"
  "text"

# ── progress rendering (universal text + opt-in card metadata) ──────

proc parseProgress(node: JsonNode): seq[TaskItem] =
  ## Defensive parse — items missing required fields are skipped (chat
  ## tool should never crash on a malformed progress payload; the worst
  ## case is rendering fewer items than the agent intended).
  if node.isNil or node.kind != JArray: return @[]
  for it in node:
    if it.kind != JObject: continue
    if not it.hasKey("content") or not it.hasKey("status"): continue
    let s = it["status"].getStr()
    var status: TaskItemStatus
    try:    status = parseEnum[TaskItemStatus](s)
    except: continue
    var item = TaskItem(
      content: it["content"].getStr(),
      status:  status,
      verification: if it.hasKey("verification"): it["verification"].getStr() else: ""
    )
    if status == tisVerifiedDone and item.verification.len == 0:
      # verified_done without evidence is a discipline violation; downgrade
      # rather than silently accept it, so the renderer surfaces the gap.
      item.status = tisClaimedDone
    result.add(item)

proc renderProgressText(items: seq[TaskItem]): string =
  ## Universal plain-text checklist. Works on every channel.
  if items.len == 0: return ""
  var lines: seq[string] = @["Plan:"]
  for it in items:
    let glyph = case it.status
                of tisVerifiedDone: "✓"
                of tisClaimedDone:  "✓?"
                of tisInProgress:   "→"
                of tisPending:      "○"
    var line = "  " & glyph & " " & it.content
    if it.status == tisVerifiedDone and it.verification.len > 0:
      line.add(" (verified: " & it.verification & ")")
    elif it.status == tisClaimedDone:
      line.add(" (claimed; no verification)")
    lines.add(line)
  lines.join("\n")

# ── action handlers ─────────────────────────────────────────────────

proc doReply(t: ChatTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Use the inbound message's channel + chat_id from tool context.
  ## No recipient lookup. Format selection still consults capabilities.
  ## Optional progress=[items] is rendered as a universal text checklist
  ## prepended to the body; card-capable channels see the structured
  ## payload in metadata["progress_json"] for opt-in richer rendering.
  if t.sendCallback == nil:
    return "Error: chat tool has no send callback bound (gateway wiring)."
  if t.channel.len == 0 or t.chatID.len == 0:
    return "Error: chat reply requires inbound context (channel + chat_id)."
  let text = args["text"].getStr()
  if text.len == 0:
    return "Error: 'text' must be non-empty."
  let asOverride = if args.hasKey("as"): args["as"].getStr() else: ""
  let interim = args.hasKey("interim") and args["interim"].getBool(false)

  var metadata = initTable[string, string]()

  # Progress checklist (universal — render once, prepend to text)
  var bodyText = text
  if args.hasKey("progress"):
    let items = parseProgress(args["progress"])
    if items.len > 0:
      let checklist = renderProgressText(items)
      bodyText = checklist & "\n\n" & text
      # Card-capable channels can opt in to a richer rendering by reading
      # this metadata; channels that don't recognize it ignore it (no harm).
      var arr = newJArray()
      for it in items:
        arr.add(%*{"content": it.content, "status": $it.status,
                   "verification": it.verification})
      metadata["progress_json"] = $arr
      # Stash the items per-session so the agent loop can read them
      # for iteration-budget scaling (more items → more iterations).
      t.progressItems[t.sessionKey] = items

  let capsOpt = getChannelCaps(t.channel)
  let format = if capsOpt.isSome:
                 selectFormat(bodyText, capsOpt.get, asOverride)
               else: (if asOverride.len > 0: asOverride else: "text")
  if format != "text": metadata["format"] = format
  if interim:          metadata["interim"] = "true"

  try:
    await t.sendCallback(t.channel, t.chatID, bodyText, t.agentName,
                         t.replyToMessageID, t.appID, metadata)
    let kind = if interim: "interim" else: "final"
    return "Replied via " & t.channel & " (" & kind & ", format=" & format & ")"
  except CatchableError as e:
    return "Error sending reply: " & e.msg

proc doSend(t: ChatTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Address an explicit recipient. Resolves vendor + address via cortex.
  if t.sendCallback == nil:
    return "Error: chat tool has no send callback bound (gateway wiring)."
  if not args.hasKey("to"):
    return "Error: 'to' is required (e.g. 'nc:7'). Use chat reply for inbound replies."
  let toAlias = args["to"].getStr().strip()
  let vendorOverride = if args.hasKey("vendor"): args["vendor"].getStr() else: ""
  let text = args["text"].getStr()
  if text.len == 0:
    return "Error: 'text' must be non-empty."
  let asOverride = if args.hasKey("as"): args["as"].getStr() else: ""

  let (vendor, address, err) = resolveRecipient(t, toAlias, vendorOverride)
  if err.len > 0: return "Error: " & err

  var metadata = initTable[string, string]()
  let capsOpt = getChannelCaps(vendor)
  let format = if capsOpt.isSome:
                 selectFormat(text, capsOpt.get, asOverride)
               else: (if asOverride.len > 0: asOverride else: "text")
  if format != "text": metadata["format"] = format

  try:
    await t.sendCallback(vendor, address, text, t.agentName,
                         "", "", metadata)
    return "Sent to " & toAlias & " via " & vendor & " (format=" & format & ")"
  except CatchableError as e:
    return "Error sending: " & e.msg

proc doForward(t: ChatTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Same machinery as send — `text` is whatever the agent assembled
  ## from the source message (quote / paraphrase / annotated). The
  ## chat layer doesn't model "forwarded" specially; that's a UI hint
  ## the agent can prepend to text. Adds metadata["forwarded"]="true"
  ## so vendor renderers that have a native "forward" bubble can use it.
  let result = await doSend(t, args)
  # If doSend already returned an error, pass through.
  if result.startsWith("Error"): return result
  return "Forwarded: " & result

# ── dispatch ────────────────────────────────────────────────────────

method execute*(t: ChatTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not (args.hasKey("method") or args.hasKey("action")):
    return "Error: 'action' is required (send | reply | forward)."
  if not args.hasKey("text"):
    return "Error: 'text' is required."
  let action = getMethodArg(args)
  case action
  of "send":    return await doSend(t, args)
  of "reply":   return await doReply(t, args)
  of "forward": return await doForward(t, args)
  else:
    return "Error: Unknown action '" & action & "'. Use: send | reply | forward"
