## email — channel-agnostic protocol verbs for persistent / async messaging.
##
## The mail counterpart to `chat` in the comm trio. Chat carries real-time
## conversational messages (IM-style, presence-based); email carries
## persistent / archived messages (thread-based, addressable by message-id,
## with subject and optional attachments). Both consult `social route` for
## recipient routing and `channel capabilities` for format selection — so
## the protocol code itself names no vendors.
##
##   action=send     — push a new message to a recipient (nc:id). Required:
##                      to, subject, body. Optional: cc, bcc, attachments,
##                      vendor (override).
##   action=reply    — reply to an existing thread. Required: to_msg_id,
##                      body. The vendor + thread metadata come from the
##                      original message.
##   action=forward  — forward an existing thread to a new recipient.
##                      Required: to, from_msg_id. Optional: comment.
##
## Transport is owned by `email`-kind channel vendors (SMTP, IMAP, or a
## third-party provider like Postmark / SendGrid / SES). When no email
## vendor is enabled, every action returns a clear "no email channel
## configured" error — the protocol shape is established now so callers
## can plan against it; the transport lands when the operator chooses
## self-host vs third-party.
##
## Distinction from `mail`:
##   mail   — INTER-AGENT message queue (local file at <office>/mail/).
##            The recipient is another agent in the same company, and
##            delivery is a JSON envelope dropped into their inbox.
##   email  — EXTERNAL-RECIPIENT messaging (this tool). Recipient is any
##            entity in the social graph with an email-kind address;
##            delivery is via an enabled email channel vendor.
##
## A future operator may decide to fold them — until then they're
## genuinely different concerns (substrate, transport, lifecycle).

import std/[json, asyncdispatch, tables, options, strutils]
import ../types
import ../spec
import ../../agent/cortex
import ../../channels/base as channel_base
import ../../channels/access

const ToolSpec* = spec(
  name = "email",
  description = "Persistent / async messaging — channel-agnostic protocol " &
                "verbs (action=send|reply|forward). Capability-driven: " &
                "format (plain vs HTML), threading, and attachment handling " &
                "all read from the destination email channel's capabilities. " &
                "For real-time conversation, use chat. For inter-agent peer " &
                "notifications, use mail.",
  tags = @["comm", "email", "messaging", "core"],
  searchKeywords = @["email send", "email reply", "email forward",
                     "send mail", "email message", "smtp", "imap",
                     "subject", "thread", "attachment"],
  domain = "comm",
  default = false,  # only useful once an email vendor is enabled
  heartbeatSafe = false,
  externalAllowed = false,  # external sends are operator-gated
  category = "comm",
)

type
  EmailTool* = ref object of ContextualTool
    sendCallback*: types.SendCallback
      ## Same callback as chat: pushes OutboundMessage onto the bus,
      ## which Manager.dispatchOutbound routes to the email channel
      ## (SMTP / IMAP / Postmark / etc., once one is enabled).

proc newEmailTool*(): EmailTool = EmailTool()

proc setSendCallback*(t: EmailTool, callback: types.SendCallback) =
  t.sendCallback = callback

method name*(t: EmailTool): string = "email"

method description*(t: EmailTool): string =
  "Persistent / async messaging (channel-agnostic protocol verbs):\n" &
  "  send     — to=nc:X subject=... body=... [cc=... bcc=...]\n" &
  "  reply    — to_msg_id=... body=...  (vendor + thread auto)\n" &
  "  forward  — to=nc:X from_msg_id=... [comment=...]\n\n" &
  "Format (plain vs HTML), threading, and attachments are " &
  "capability-driven via the destination email channel. Routing " &
  "(which vendor for nc:X) is resolved via `social route to=nc:X kind=mail`. " &
  "For real-time conversational messages, use `chat`. For inter-agent " &
  "peer notifications (file-based local queue), use `mail`."

method parameters*(t: EmailTool): Table[string, JsonNode] =
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
        "description": "send/forward — recipient nc:id (e.g. 'nc:7'). " &
                       "Resolves to the entity's email-kind address via " &
                       "social route."
      },
      "subject": {
        "type": "string",
        "description": "send/forward — subject line. Required for new " &
                       "threads; for reply the original subject is used " &
                       "(prefixed with 'Re:' if not already)."
      },
      "body": {
        "type": "string",
        "description": "Message body. Plain text or markdown — the " &
                       "destination email channel decides whether to " &
                       "render as plain or convert to HTML (capability-driven)."
      },
      "to_msg_id": {
        "type": "string",
        "description": "reply only — message-id of the email being " &
                       "replied to. Vendor + thread metadata come from " &
                       "the original message."
      },
      "from_msg_id": {
        "type": "string",
        "description": "forward only — message-id of the email being " &
                       "forwarded. Vendor lookup picks up the original " &
                       "thread + body."
      },
      "comment": {
        "type": "string",
        "description": "forward only — optional comment from the forwarder " &
                       "prepended above the original message body."
      },
      "cc": {
        "type": "array",
        "items": { "type": "string" },
        "description": "send only — CC recipient nc:ids. Each resolved " &
                       "the same way as `to`."
      },
      "bcc": {
        "type": "array",
        "items": { "type": "string" },
        "description": "send only — BCC recipient nc:ids."
      },
      "vendor": {
        "type": "string",
        "description": "send/forward — explicit vendor override (smtp, " &
                       "postmark, sendgrid, ses, ...). By default email " &
                       "consults social route's preferred-channel pick."
      }
    },
    "required": %["action", "body"]
  }.toTable

# ── routing helpers (mirror chat.resolveRecipient but kind=mail) ───

const MailVendors = ["email", "smtp", "imap", "postmark", "sendgrid", "ses"]

proc isMailVendor(v: string): bool =
  for m in MailVendors:
    if m == v: return true
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

proc preferredMailChannel(ent: WorldEntity): string =
  ## Same field as `preferredChannel` but only considered when the
  ## value names a mail-kind vendor. Lets a person have BOTH a
  ## preferred chat channel AND a preferred email vendor without
  ## either masking the other.
  if ent.custom.isNil or ent.custom.kind != JObject: return ""
  if ent.custom.hasKey("preferred_email"):
    return ent.custom["preferred_email"].getStr("")
  if ent.custom.hasKey("preferred_channel"):
    let pc = ent.custom["preferred_channel"].getStr("")
    if isMailVendor(pc): return pc
  ""

proc resolveRecipient(t: EmailTool, toAlias, vendorOverride: string):
    (string, string, string) =
  ## Returns (vendor, address, errMsg). On success errMsg is empty.
  if t.graph == nil:
    return ("", "", "World Graph is not initialized.")
  if not t.graph.idAliasIndex.hasKey(toAlias):
    return ("", "", "Recipient not found: " & toAlias)
  let id = t.graph.idAliasIndex[toAlias]
  if not t.graph.entities.hasKey(id):
    return ("", "", "Entity index dangling for: " & toAlias)
  let ent = t.graph.entities[id]
  var candidates: seq[tuple[vendor, address: string]]
  for k, v in ent.identifiers:
    let vendor = parseVendorFromIdKey(k)
    if vendor.len == 0 or not isMailVendor(vendor): continue
    candidates.add((vendor: vendor, address: v))
  if candidates.len == 0:
    return ("", "", "No email-kind address recorded for " & toAlias &
                    ". Add via `social action=update id=" & toAlias &
                    " set:identifiers.email=…`.")
  if vendorOverride.len > 0:
    for c in candidates:
      if c.vendor == vendorOverride and not isUnreachable(ent, c.vendor):
        return (c.vendor, c.address, "")
    return ("", "", "Vendor not reachable: " & vendorOverride & " for " & toAlias)
  let pref = preferredMailChannel(ent)
  if pref.len > 0:
    for c in candidates:
      if c.vendor == pref and not isUnreachable(ent, c.vendor):
        return (c.vendor, c.address, "")
  for c in candidates:
    if not isUnreachable(ent, c.vendor):
      return (c.vendor, c.address, "")
  ("", "", "All email vendors unreachable for " & toAlias)

# ── format selection (capability-driven) ────────────────────────────

proc selectMailFormat(body: string, caps: channel_base.ChannelCapabilities): string =
  ## Decide plain-text vs HTML. Capability-driven — consult the
  ## destination channel's `formatting` list. Conservative: prefer
  ## plain unless markdown features benefit from HTML rendering.
  for f in caps.formatting:
    if f == "html":
      # Channel supports HTML; promote if body has markdown structure.
      if body.contains("```") or body.contains("|") or
         body.find('#') == 0:
        return "html"
      break
  "plain"

proc ensureMailVendorEnabled(): string =
  ## Returns "" when at least one mail-kind channel is enabled, else a
  ## helpful operator-facing error explaining how to wire one up.
  let names = listEnabledChannels()
  for n in names:
    if isMailVendor(n): return ""
  "No email channel is enabled. Add an SMTP / IMAP / third-party " &
  "(Postmark, SendGrid, SES) vendor channel — see " &
  "`channel list` once enabled and `res/channels.json` for the " &
  "configuration shape."

# ── action handlers ─────────────────────────────────────────────────

proc doSend(t: EmailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sendCallback == nil:
    return "Error: email tool has no send callback bound (gateway wiring)."
  let vendorErr = ensureMailVendorEnabled()
  if vendorErr.len > 0: return "Error: " & vendorErr
  if not args.hasKey("to"):
    return "Error: 'to' is required (e.g. 'nc:7')."
  if not args.hasKey("subject"):
    return "Error: 'subject' is required for a new message."
  let toAlias = args["to"].getStr().strip()
  let subject = args["subject"].getStr()
  let body = args["body"].getStr()
  if body.len == 0:
    return "Error: 'body' must be non-empty."
  let vendorOverride = if args.hasKey("vendor"): args["vendor"].getStr() else: ""

  let (vendor, address, err) = resolveRecipient(t, toAlias, vendorOverride)
  if err.len > 0: return "Error: " & err

  var metadata = initTable[string, string]()
  metadata["subject"] = subject
  let capsOpt = getChannelCaps(vendor)
  if capsOpt.isSome:
    metadata["format"] = selectMailFormat(body, capsOpt.get)
  if args.hasKey("cc"):
    metadata["cc"] = $args["cc"]
  if args.hasKey("bcc"):
    metadata["bcc"] = $args["bcc"]

  try:
    await t.sendCallback(vendor, address, body, t.agentName, "", "", metadata)
    return "Sent email to " & toAlias & " via " & vendor & " (subject: " & subject & ")"
  except CatchableError as e:
    return "Error sending email: " & e.msg

proc doReply(t: EmailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sendCallback == nil:
    return "Error: email tool has no send callback bound (gateway wiring)."
  let vendorErr = ensureMailVendorEnabled()
  if vendorErr.len > 0: return "Error: " & vendorErr
  if not args.hasKey("to_msg_id"):
    return "Error: 'to_msg_id' is required for reply (use action=send for fresh threads)."
  let body = args["body"].getStr()
  if body.len == 0:
    return "Error: 'body' must be non-empty."
  let toMsgId = args["to_msg_id"].getStr()

  # Vendor + recipient look-up via the message-id is vendor-specific —
  # punted to the channel adapter. We pass the in-reply-to header in
  # metadata and let the channel resolve the destination.
  var metadata = initTable[string, string]()
  metadata["in_reply_to"] = toMsgId

  # Without a vendor lookup we can't choose format here yet. Default
  # to plain; the channel adapter can promote based on its own caps.
  metadata["format"] = "plain"

  # The channel field is empty — the channel manager dispatches
  # message-id-keyed replies via vendor-side thread store. If no email
  # channel is enabled this errors out at dispatch time (manager logs
  # the unknown channel).
  try:
    await t.sendCallback("", "", body, t.agentName, toMsgId, "", metadata)
    return "Reply queued for thread " & toMsgId
  except CatchableError as e:
    return "Error sending reply: " & e.msg

proc doForward(t: EmailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sendCallback == nil:
    return "Error: email tool has no send callback bound (gateway wiring)."
  let vendorErr = ensureMailVendorEnabled()
  if vendorErr.len > 0: return "Error: " & vendorErr
  if not args.hasKey("to"):
    return "Error: 'to' is required (e.g. 'nc:7')."
  if not args.hasKey("from_msg_id"):
    return "Error: 'from_msg_id' is required for forward."
  let toAlias = args["to"].getStr().strip()
  let fromMsgId = args["from_msg_id"].getStr()
  let comment = if args.hasKey("comment"): args["comment"].getStr() else: ""
  let vendorOverride = if args.hasKey("vendor"): args["vendor"].getStr() else: ""

  let (vendor, address, err) = resolveRecipient(t, toAlias, vendorOverride)
  if err.len > 0: return "Error: " & err

  var metadata = initTable[string, string]()
  metadata["forwarded_from"] = fromMsgId
  if comment.len > 0:
    metadata["forward_comment"] = comment
  let body = args["body"].getStr()  # may be empty when only forwarding
  let capsOpt = getChannelCaps(vendor)
  if capsOpt.isSome:
    metadata["format"] = selectMailFormat(body, capsOpt.get)

  try:
    await t.sendCallback(vendor, address, body, t.agentName, "", "", metadata)
    return "Forwarded " & fromMsgId & " to " & toAlias & " via " & vendor
  except CatchableError as e:
    return "Error forwarding: " & e.msg

# ── dispatch ────────────────────────────────────────────────────────

method execute*(t: EmailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (send | reply | forward)."
  if not args.hasKey("body"):
    return "Error: 'body' is required."
  let action = args["action"].getStr()
  case action
  of "send":    return await doSend(t, args)
  of "reply":   return await doReply(t, args)
  of "forward": return await doForward(t, args)
  else:
    return "Error: Unknown action '" & action & "'. Use: send | reply | forward"
