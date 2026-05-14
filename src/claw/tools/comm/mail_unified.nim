## mail — unified persistent / async messaging across three transport kinds.
##
##   kind=internal — file-persisted memo to another agent in this company.
##                    Recipient is an agent name (or nc:id of an agent
##                    entity). Drops a JSON envelope into the recipient's
##                    `<office>/mail/`; triggers MAILBOX ALERT on their
##                    next prompt build / heartbeat tick.
##   kind=email     — electronic mail to any recipient with an email-kind
##                    address in the social graph. Routes via the
##                    enabled email channel vendor (SMTP / IMAP / Postmark
##                    / SendGrid / SES). Requires that an email-kind
##                    channel is enabled.
##   kind=shipment  — physical shipment to any recipient with a postal
##                    address. Routes via an enabled shipment channel
##                    vendor (FedEx / UPS / USPS / DHL). Requires a
##                    shipment-kind channel.
##
## Action × kind matrix:
##
##           internal  email   shipment
##   send       ✓        ✓        ✓
##   reply      —        ✓        —
##   forward    —        ✓        ✓ (re-route in transit)
##   archive    ✓        —        —
##   track      —        —        ✓
##
## For real-time conversational messaging, see `chat` (the synchronous
## counterpart). For SYNC tasks that return a result, see `delegate`.

import std/[os, json, asyncdispatch, tables, strutils, times, options]
import ../types
import ../spec
import ../../logger
import ../../agent/cortex
import ../../channels/base as channel_base
import ../../channels/access

const ToolSpec* = spec(
  name = "mail",
  description = "Persistent / async messaging — three transport kinds " &
                "(method=send|reply|forward|archive|track, " &
                "kind=internal|email|shipment). Capability-driven format " &
                "selection; routing per kind via cortex (internal=agent " &
                "name; email/shipment=social.route address lookup).",
  tags = @["comm", "mail", "messaging", "core"],
  searchKeywords = @["mail send", "send mail", "memo", "email", "ship",
                     "shipment", "parcel", "smtp", "imap", "postmark",
                     "fedex", "ups", "usps", "dhl", "track", "archive"],
  domain = "comm",
  default = true,
  heartbeatSafe = true,  # internal/archive only; email/shipment self-gate
  externalAllowed = false,
  category = "comm",
)

# Kind labels (single source of truth for both runtime + docs).
const KindInternal = "internal"
const KindEmail    = "email"
const KindShipment = "shipment"

# Vendor-name catalogs the email/shipment kinds recognize when picking
# a recipient address. Keep these tight — operators add a new vendor
# by enabling its channel impl and updating these lists here.
const EmailVendors    = ["email", "smtp", "imap", "postmark", "sendgrid", "ses"]
const ShipmentVendors = ["fedex", "ups", "usps", "dhl"]

type
  MailTool* = ref object of ContextualTool
    workspaceDir*: string       ## kind=internal: locate recipient's office
    officeDir*: string          ## kind=internal: locate own inbox for archive
    sendCallback*: types.SendCallback
                                ## kind=email + kind=shipment: bus dispatch

proc newMailTool*(workspaceDir, officeDir: string): MailTool =
  MailTool(workspaceDir: workspaceDir, officeDir: officeDir)

proc setSendCallback*(t: MailTool, callback: types.SendCallback) =
  t.sendCallback = callback

method name*(t: MailTool): string = "mail"

method description*(t: MailTool): string =
  "Persistent / async messaging — three transport kinds.\n\n" &
  "Actions × kinds:\n" &
  "  send     internal | email | shipment\n" &
  "  reply    email\n" &
  "  forward  email | shipment\n" &
  "  archive  internal\n" &
  "  track    shipment\n\n" &
  "Common args (all kinds): to (recipient), subject, body. Email adds " &
  "cc/bcc/vendor. Shipment adds weight_kg, dims, contents, vendor, " &
  "delivery_mode. Format / threading / attachments come from the " &
  "destination channel's capabilities — no hardcoded vendor branches.\n\n" &
  "For other comm needs:\n" &
  "  • respond to current partner       → use `chat reply`\n" &
  "  • SYNC task that returns a result  → use `delegate` (waits)\n" &
  "  • bridge guest ↔ internal staff    → use `chat forward`\n\n" &
  "Always call `mail method=archive` after acting on an internal mail, " &
  "otherwise the MAILBOX ALERT fires on every future heartbeat."

method parameters*(t: MailTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["send", "reply", "forward", "archive", "track"],
        "description": "Operation to perform"
      },
      "kind": {
        "type": "string",
        "enum": [KindInternal, KindEmail, KindShipment],
        "description": "Transport kind. Required for send / reply / " &
                       "forward. Defaults: archive→internal, track→shipment."
      },
      "to": {
        "type": "string",
        "description": "Recipient. kind=internal: agent name (e.g. " &
                       "'Analyst') or nc:id of an agent entity. " &
                       "kind=email/shipment: nc:id of any entity in the " &
                       "social graph (e.g. 'nc:7')."
      },
      "subject": {
        "type": "string",
        "description": "Subject line. Required for send (all kinds) and " &
                       "internal reply (kind=internal threads via subject). " &
                       "kind=email reply auto-prefixes 'Re:' if needed."
      },
      "body": {
        "type": "string",
        "description": "Message body. Plain text or markdown — destination " &
                       "channel decides whether to render as plain or " &
                       "convert to HTML (email/capability-driven)."
      },
      "to_msg_id": {
        "type": "string",
        "description": "reply only — message-id of the email being replied " &
                       "to. Vendor + thread metadata come from the original."
      },
      "from_msg_id": {
        "type": "string",
        "description": "forward only — id of the email/shipment being " &
                       "forwarded. For shipment, this is the tracking_id."
      },
      "comment": {
        "type": "string",
        "description": "forward only — optional comment from the forwarder."
      },
      "cc": {
        "type": "array",
        "items": { "type": "string" },
        "description": "send only, kind=email — CC recipient nc:ids."
      },
      "bcc": {
        "type": "array",
        "items": { "type": "string" },
        "description": "send only, kind=email — BCC recipient nc:ids."
      },
      "vendor": {
        "type": "string",
        "description": "send/forward, kind=email/shipment — explicit " &
                       "vendor override. Defaults to the recipient's " &
                       "preferred email/shipment vendor (or first reachable)."
      },
      "weight_kg": {
        "type": "number",
        "description": "send only, kind=shipment — package weight in kg."
      },
      "dims": {
        "type": "string",
        "description": "send only, kind=shipment — package dimensions in cm, " &
                       "format LxWxH (e.g. '40x30x20')."
      },
      "contents": {
        "type": "string",
        "description": "send only, kind=shipment — short description of the " &
                       "shipment contents (for customs / waybill)."
      },
      "delivery_mode": {
        "type": "string",
        "enum": ["standard", "express", "overnight"],
        "description": "send only, kind=shipment — delivery speed tier. " &
                       "Default 'standard'."
      },
      "tracking_id": {
        "type": "string",
        "description": "track only — carrier tracking number to query " &
                       "shipment status."
      },
      "filename": {
        "type": "string",
        "description": "archive only — bare filename of the internal mail " &
                       "to archive (basename only; path components stripped)."
      }
    },
    "required": %["method"]
  }.toTable

# ── shared address-resolution helpers ──────────────────────────────

proc parseVendorFromIdKey(key: string): string =
  let i = key.find(':')
  if i > 0: key[0 ..< i] else: key

proc isEmailVendor(v: string): bool =
  for e in EmailVendors:
    if e == v: return true
  false

proc isShipmentVendor(v: string): bool =
  for s in ShipmentVendors:
    if s == v: return true
  false

proc isUnreachable(ent: WorldEntity, vendor: string): bool =
  if ent.custom.isNil or ent.custom.kind != JObject: return false
  if not ent.custom.hasKey("unreachable"): return false
  let u = ent.custom["unreachable"]
  if u.kind != JObject: return false
  u.hasKey(vendor)

proc preferredVendorByKind(ent: WorldEntity, kind: string): string =
  ## Read entity's stated preference scoped to this kind. Falls back to
  ## the generic preferred_channel field when it names a vendor matching
  ## this kind.
  if ent.custom.isNil or ent.custom.kind != JObject: return ""
  let scopedKey = "preferred_" & kind  # preferred_email, preferred_shipment
  if ent.custom.hasKey(scopedKey):
    return ent.custom[scopedKey].getStr("")
  if ent.custom.hasKey("preferred_channel"):
    let pc = ent.custom["preferred_channel"].getStr("")
    if (kind == KindEmail and isEmailVendor(pc)) or
       (kind == KindShipment and isShipmentVendor(pc)):
      return pc
  ""

proc resolveExternalRecipient(t: MailTool, toAlias, vendorOverride, kind: string):
    (string, string, string) =
  ## Returns (vendor, address, errMsg). For kind=email | kind=shipment.
  if t.graph == nil:
    return ("", "", "World Graph is not initialized.")
  if not t.graph.idAliasIndex.hasKey(toAlias):
    return ("", "", "Recipient not found: " & toAlias)
  let id = t.graph.idAliasIndex[toAlias]
  if not t.graph.entities.hasKey(id):
    return ("", "", "Entity index dangling for: " & toAlias)
  let ent = t.graph.entities[id]
  let kindCheck: proc(v: string): bool =
    if kind == KindEmail: isEmailVendor else: isShipmentVendor
  var candidates: seq[tuple[vendor, address: string]]
  for k, v in ent.identifiers:
    let vendor = parseVendorFromIdKey(k)
    if vendor.len == 0 or not kindCheck(vendor): continue
    candidates.add((vendor: vendor, address: v))
  if candidates.len == 0:
    let kindName = if kind == KindEmail: "email-kind" else: "shipment-kind"
    return ("", "", "No " & kindName & " address recorded for " & toAlias &
                    ". Add via `social method=update id=" & toAlias & "`.")
  if vendorOverride.len > 0:
    for c in candidates:
      if c.vendor == vendorOverride and not isUnreachable(ent, c.vendor):
        return (c.vendor, c.address, "")
    return ("", "", "Vendor not reachable: " & vendorOverride & " for " & toAlias)
  let pref = preferredVendorByKind(ent, kind)
  if pref.len > 0:
    for c in candidates:
      if c.vendor == pref and not isUnreachable(ent, c.vendor):
        return (c.vendor, c.address, "")
  for c in candidates:
    if not isUnreachable(ent, c.vendor):
      return (c.vendor, c.address, "")
  ("", "", "All vendors unreachable for " & toAlias)

proc ensureVendorEnabled(kind: string): string =
  ## "" when at least one vendor of this kind is enabled in Manager.
  let names = listEnabledChannels()
  let check: proc(v: string): bool =
    if kind == KindEmail: isEmailVendor else: isShipmentVendor
  for n in names:
    if check(n): return ""
  if kind == KindEmail:
    return "No email channel is enabled. Add an SMTP / IMAP / third-party " &
           "(Postmark, SendGrid, SES) vendor channel."
  return "No shipment channel is enabled. Add a carrier vendor channel " &
         "(FedEx, UPS, USPS, DHL)."

# ── kind=internal: send + archive (file-persisted) ──────────────────

proc doSendInternal(t: MailTool, args: Table[string, JsonNode]): string =
  let recipientRaw = if args.hasKey("to"): args["to"].getStr()
                     elif args.hasKey("recipient"): args["recipient"].getStr()
                     else: ""
  if recipientRaw.len == 0:
    return "Error: 'to' is required for send (agent name or nc:id of an agent)"
  if not args.hasKey("subject"): return "Error: 'subject' is required for send"
  if not args.hasKey("body"): return "Error: 'body' is required for send"

  let recipient = recipientRaw.toLowerAscii().replace("nc:", "")
  let subject = args["subject"].getStr()
  let body = args["body"].getStr()

  let mailDir = t.workspaceDir / "offices" / recipient / "mail"
  if not dirExists(mailDir):
    return "Error: Recipient '" & recipient &
           "' mailbox not found at " & mailDir &
           " (kind=internal expects an agent in this company; for " &
           "external recipients use kind=email or kind=shipment)"

  let timestamp = now().format("yyyyMMdd'_'HHmmss")
  let mailFile = mailDir / "mail_" & timestamp & "_" &
                 t.agentName.toLowerAscii() & ".json"
  let mailData = %*{
    "sender": t.agentName,
    "recipient": recipient,
    "subject": subject,
    "body": body,
    "timestamp": $now()
  }
  try:
    writeFile(mailFile, mailData.pretty())
  except CatchableError as e:
    return "Error: " & e.msg
  if not fileExists(mailFile):
    return "Error: writeFile reported success but file not found at " &
           mailFile & " (recipient may not see this mail — check disk space, permissions)"
  infoCF("tool", "Mail sent (internal)",
         {"from": t.agentName, "to": recipient,
          "file": mailFile}.toTable)
  return "Mail sent to " & recipient & " (internal, verified at " & mailFile & ")"

proc doArchive(t: MailTool, args: Table[string, JsonNode]): string =
  if t.officeDir.len == 0:
    return "Error: tool not bound to an office workspace"
  if not args.hasKey("filename"):
    return "Error: 'filename' is required for archive"
  let raw = args["filename"].getStr().strip()
  if raw.len == 0:
    return "Error: 'filename' must not be empty"

  let basename = extractFilename(raw)
  if basename.len == 0 or basename == "." or basename == "..":
    return "Error: invalid filename '" & raw & "'"
  if basename == ".gitkeep":
    return "Error: refusing to archive .gitkeep"

  let mailDir = t.officeDir / "mail"
  let src = mailDir / basename
  if not fileExists(src):
    return "Error: mail file not found at " & src &
           " (already archived, or filename mistyped)"

  let processedDir = mailDir / "processed"
  try:
    createDir(processedDir)
  except CatchableError as e:
    return "Error: failed to create processed/ dir: " & e.msg

  let dst = processedDir / basename
  try:
    moveFile(src, dst)
  except CatchableError as e:
    return "Error: failed to move mail to processed/: " & e.msg

  return "Archived mail to " & dst &
         ". MAILBOX ALERT will no longer fire for this file."

# ── kind=email: send / reply / forward (channel-routed) ─────────────

proc selectMailFormat(body: string, caps: channel_base.ChannelCapabilities): string =
  ## Plain vs HTML. Promote when the channel supports HTML AND the body
  ## has markdown structure that would lose meaning as plain text.
  for f in caps.formatting:
    if f == "html":
      if body.contains("```") or body.contains("|") or body.find('#') == 0:
        return "html"
      break
  "plain"

proc doSendEmail(t: MailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sendCallback == nil:
    return "Error: mail tool has no send callback bound (gateway wiring)."
  let vendorErr = ensureVendorEnabled(KindEmail)
  if vendorErr.len > 0: return "Error: " & vendorErr
  if not args.hasKey("to"):
    return "Error: 'to' is required (e.g. 'nc:7')."
  if not args.hasKey("subject"):
    return "Error: 'subject' is required for a new email."
  let toAlias = args["to"].getStr().strip()
  let subject = args["subject"].getStr()
  let body = args["body"].getStr()
  if body.len == 0:
    return "Error: 'body' must be non-empty."
  let vendorOverride = if args.hasKey("vendor"): args["vendor"].getStr() else: ""

  let (vendor, address, err) = resolveExternalRecipient(t, toAlias, vendorOverride, KindEmail)
  if err.len > 0: return "Error: " & err

  var metadata = initTable[string, string]()
  metadata["subject"] = subject
  let capsOpt = getChannelCaps(vendor)
  if capsOpt.isSome:
    metadata["format"] = selectMailFormat(body, capsOpt.get)
  if args.hasKey("cc"):  metadata["cc"]  = $args["cc"]
  if args.hasKey("bcc"): metadata["bcc"] = $args["bcc"]

  try:
    await t.sendCallback(vendor, address, body, t.agentName, "", "", metadata)
    return "Sent email to " & toAlias & " via " & vendor & " (subject: " & subject & ")"
  except CatchableError as e:
    return "Error sending email: " & e.msg

proc doReplyEmail(t: MailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sendCallback == nil:
    return "Error: mail tool has no send callback bound."
  let vendorErr = ensureVendorEnabled(KindEmail)
  if vendorErr.len > 0: return "Error: " & vendorErr
  if not args.hasKey("to_msg_id"):
    return "Error: 'to_msg_id' is required for reply."
  let body = args["body"].getStr()
  if body.len == 0: return "Error: 'body' must be non-empty."
  let toMsgId = args["to_msg_id"].getStr()

  var metadata = initTable[string, string]()
  metadata["in_reply_to"] = toMsgId
  metadata["format"] = "plain"

  try:
    # Empty channel/address — vendor-side thread store dispatches by msg-id.
    await t.sendCallback("", "", body, t.agentName, toMsgId, "", metadata)
    return "Reply queued for thread " & toMsgId
  except CatchableError as e:
    return "Error sending reply: " & e.msg

proc doForwardEmail(t: MailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sendCallback == nil:
    return "Error: mail tool has no send callback bound."
  let vendorErr = ensureVendorEnabled(KindEmail)
  if vendorErr.len > 0: return "Error: " & vendorErr
  if not args.hasKey("to"):
    return "Error: 'to' is required."
  if not args.hasKey("from_msg_id"):
    return "Error: 'from_msg_id' is required for forward."
  let toAlias = args["to"].getStr().strip()
  let fromMsgId = args["from_msg_id"].getStr()
  let comment = if args.hasKey("comment"): args["comment"].getStr() else: ""
  let vendorOverride = if args.hasKey("vendor"): args["vendor"].getStr() else: ""

  let (vendor, address, err) = resolveExternalRecipient(t, toAlias, vendorOverride, KindEmail)
  if err.len > 0: return "Error: " & err

  var metadata = initTable[string, string]()
  metadata["forwarded_from"] = fromMsgId
  if comment.len > 0: metadata["forward_comment"] = comment
  let body = args["body"].getStr()
  let capsOpt = getChannelCaps(vendor)
  if capsOpt.isSome: metadata["format"] = selectMailFormat(body, capsOpt.get)

  try:
    await t.sendCallback(vendor, address, body, t.agentName, "", "", metadata)
    return "Forwarded " & fromMsgId & " to " & toAlias & " via " & vendor
  except CatchableError as e:
    return "Error forwarding: " & e.msg

# ── kind=shipment: send / forward / track (channel-routed) ──────────

proc doSendShipment(t: MailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sendCallback == nil:
    return "Error: mail tool has no send callback bound."
  let vendorErr = ensureVendorEnabled(KindShipment)
  if vendorErr.len > 0: return "Error: " & vendorErr
  if not args.hasKey("to"):
    return "Error: 'to' is required (recipient nc:id with a postal address)."
  if not args.hasKey("contents"):
    return "Error: 'contents' is required for shipment (customs / waybill)."
  if not args.hasKey("weight_kg"):
    return "Error: 'weight_kg' is required for shipment."
  let toAlias = args["to"].getStr().strip()
  let contents = args["contents"].getStr()
  let weightKg = args["weight_kg"].getFloat()
  let dims = if args.hasKey("dims"): args["dims"].getStr() else: ""
  let mode = if args.hasKey("delivery_mode"): args["delivery_mode"].getStr()
             else: "standard"
  let vendorOverride = if args.hasKey("vendor"): args["vendor"].getStr() else: ""

  let (vendor, address, err) = resolveExternalRecipient(t, toAlias, vendorOverride, KindShipment)
  if err.len > 0: return "Error: " & err

  var metadata = initTable[string, string]()
  metadata["contents"] = contents
  metadata["weight_kg"] = $weightKg
  if dims.len > 0: metadata["dims"] = dims
  metadata["delivery_mode"] = mode

  try:
    await t.sendCallback(vendor, address, contents, t.agentName, "", "", metadata)
    return "Shipment queued to " & toAlias & " via " & vendor &
           " (mode=" & mode & ", " & $weightKg & "kg)"
  except CatchableError as e:
    return "Error queuing shipment: " & e.msg

proc doForwardShipment(t: MailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Re-route an in-transit shipment to a new address. Carrier-specific:
  ## not all vendors support intercept-and-redirect. The channel returns
  ## a vendor-specific error if not supported.
  if t.sendCallback == nil:
    return "Error: mail tool has no send callback bound."
  let vendorErr = ensureVendorEnabled(KindShipment)
  if vendorErr.len > 0: return "Error: " & vendorErr
  if not args.hasKey("to"):
    return "Error: 'to' is required (new destination nc:id)."
  if not args.hasKey("from_msg_id"):
    return "Error: 'from_msg_id' is required (the original tracking_id)."
  let toAlias = args["to"].getStr().strip()
  let trackingId = args["from_msg_id"].getStr()
  let vendorOverride = if args.hasKey("vendor"): args["vendor"].getStr() else: ""

  let (vendor, address, err) = resolveExternalRecipient(t, toAlias, vendorOverride, KindShipment)
  if err.len > 0: return "Error: " & err

  var metadata = initTable[string, string]()
  metadata["redirect_from"] = trackingId
  if args.hasKey("comment"):
    metadata["redirect_reason"] = args["comment"].getStr()

  try:
    await t.sendCallback(vendor, address, "", t.agentName, "", "", metadata)
    return "Re-route requested for " & trackingId & " → " & toAlias & " (" & vendor & ")"
  except CatchableError as e:
    return "Error re-routing: " & e.msg

proc doTrack(t: MailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sendCallback == nil:
    return "Error: mail tool has no send callback bound."
  let vendorErr = ensureVendorEnabled(KindShipment)
  if vendorErr.len > 0: return "Error: " & vendorErr
  if not args.hasKey("tracking_id"):
    return "Error: 'tracking_id' is required."
  let trackingId = args["tracking_id"].getStr()
  let vendorOverride = if args.hasKey("vendor"): args["vendor"].getStr() else: ""

  var metadata = initTable[string, string]()
  metadata["track"] = "true"
  metadata["tracking_id"] = trackingId
  if vendorOverride.len > 0: metadata["vendor"] = vendorOverride

  # Track is a query, not a send — but we use the same callback because
  # the channel manager already has the dispatch path. Vendor adapter
  # interprets the metadata["track"]=true flag.
  try:
    await t.sendCallback(vendorOverride, "", "", t.agentName, "", "", metadata)
    return "Tracking query queued for " & trackingId &
           " (response routed back to caller via channel adapter)"
  except CatchableError as e:
    return "Error querying tracking: " & e.msg

# ── dispatch ────────────────────────────────────────────────────────

proc resolveKind(action: string, args: Table[string, JsonNode]): (string, string) =
  ## Returns (kind, errMsg). Some actions have an unambiguous default
  ## kind; others require explicit kind=.
  if args.hasKey("kind"):
    let k = args["kind"].getStr()
    if k notin [KindInternal, KindEmail, KindShipment]:
      return ("", "Error: unknown kind '" & k & "'. Use: " &
                  KindInternal & " | " & KindEmail & " | " & KindShipment)
    return (k, "")
  case action
  of "archive": return (KindInternal, "")    # only internal has archive
  of "track":   return (KindShipment, "")    # only shipment has track
  else:
    return ("", "Error: 'kind' is required for method=" & action &
                " (internal | email | shipment).")

method execute*(t: MailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not (args.hasKey("method") or args.hasKey("action")):
    return "Error: 'action' is required (send | reply | forward | archive | track)."
  let action = getMethodArg(args)
  let (kind, kindErr) = resolveKind(action, args)
  if kindErr.len > 0: return kindErr

  case action
  of "send":
    case kind
    of KindInternal: return doSendInternal(t, args)
    of KindEmail:    return await doSendEmail(t, args)
    of KindShipment: return await doSendShipment(t, args)
    else: return "Error: unhandled kind"
  of "reply":
    case kind
    of KindEmail:    return await doReplyEmail(t, args)
    of KindInternal: return "Error: reply is not supported for kind=internal " &
                            "(internal mail is fire-and-forget; send a fresh memo)."
    of KindShipment: return "Error: reply is not supported for kind=shipment."
    else: return "Error: unhandled kind"
  of "forward":
    case kind
    of KindEmail:    return await doForwardEmail(t, args)
    of KindShipment: return await doForwardShipment(t, args)
    of KindInternal: return "Error: forward is not supported for kind=internal."
    else: return "Error: unhandled kind"
  of "archive":
    if kind != KindInternal:
      return "Error: archive is only valid for kind=internal."
    return doArchive(t, args)
  of "track":
    if kind != KindShipment:
      return "Error: track is only valid for kind=shipment."
    return await doTrack(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: send | reply | forward | archive | track"
