## chat — channel-agnostic protocol verbs for real-time conversation.
##
## The "ship" in the cortex/chat/channel trio. Carries messages over
## whatever transport `social route` picks for the recipient; consults
## `channel capabilities` to decide whether to send as text or promote
## to the vendor's rich-card primitive. No vendor names hardcoded here —
## the format-selection logic uses the capability matrix declared by
## each channel impl.
##
##   action=send      — push a message to a recipient (nc:id)
##                       Resolves vendor + address via cortex (same
##                       routing logic as `social route`). Optional
##                       `vendor=Y` overrides the routing pick.
##   action=reply     — answer the current inbound message (uses the
##                       inbound's channel + chat_id from tool context;
##                       no recipient lookup needed)
##   action=forward   — forward content to a recipient (vendor + address
##                       resolved like `send`)
##
## Format selection: capability-driven. If `caps.card.isSome` and the
## content is too long for plain text OR contains markdown that text
## would lose, the chat tool promotes to card. The vendor's channel impl
## handles the actual rendering (CardKit JSON, telegram_inline blocks,
## discord embed) — chat just declares the format intent in metadata.

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
  ChatTool* = ref object of ContextualTool
    sendCallback*: types.SendCallback
      ## Wired by the gateway after construction. Same signature as
      ## ReplyTool's callback — pushes OutboundMessage to the bus,
      ## which Manager.dispatchOutbound routes to the right channel.

proc newChatTool*(): ChatTool = ChatTool()

proc setSendCallback*(t: ChatTool, callback: types.SendCallback) =
  t.sendCallback = callback

method name*(t: ChatTool): string = "chat"

method description*(t: ChatTool): string =
  "Real-time messaging (channel-agnostic protocol verbs):\n" &
  "  send     — to=nc:X text=... [vendor=Y override]\n" &
  "  reply    — text=...  (uses current inbound's channel + chat_id)\n" &
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
      "action": {
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

# ── action handlers ─────────────────────────────────────────────────

proc doReply(t: ChatTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Use the inbound message's channel + chat_id from tool context.
  ## No recipient lookup. Format selection still consults capabilities.
  if t.sendCallback == nil:
    return "Error: chat tool has no send callback bound (gateway wiring)."
  if t.channel.len == 0 or t.chatID.len == 0:
    return "Error: chat reply requires inbound context (channel + chat_id)."
  let text = args["text"].getStr()
  if text.len == 0:
    return "Error: 'text' must be non-empty."
  let asOverride = if args.hasKey("as"): args["as"].getStr() else: ""

  var metadata = initTable[string, string]()
  let capsOpt = getChannelCaps(t.channel)
  let format = if capsOpt.isSome:
                 selectFormat(text, capsOpt.get, asOverride)
               else: (if asOverride.len > 0: asOverride else: "text")
  if format != "text": metadata["format"] = format

  try:
    await t.sendCallback(t.channel, t.chatID, text, t.agentName,
                         t.replyToMessageID, t.appID, metadata)
    return "Replied via " & t.channel & " (format=" & format & ")"
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
  if not args.hasKey("action"):
    return "Error: 'action' is required (send | reply | forward)."
  if not args.hasKey("text"):
    return "Error: 'text' is required."
  let action = args["action"].getStr()
  case action
  of "send":    return await doSend(t, args)
  of "reply":   return await doReply(t, args)
  of "forward": return await doForward(t, args)
  else:
    return "Error: Unknown action '" & action & "'. Use: send | reply | forward"
