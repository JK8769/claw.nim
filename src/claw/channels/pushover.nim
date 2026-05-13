## pushover — outbound-only push-notification Channel.
##
## Pushover is fire-and-forget: server → mobile device, no inbound. Send-
## only, plain text, ~1024-char body limit. Reached via `chat send vendor=
## pushover to=nc:X text=...`; the channel pulls the recipient's user_key
## from their entity's identifiers (key `pushover:...`) and the app token
## from PUSHOVER_TOKEN in the company's .env (single token per company).
##
## Replaces the former `pushover` tool (deleted in the migration to one-
## tool-per-comm-verb): notifications are a transport, not a separate verb.

import std/[asyncdispatch, httpclient, strutils, tables, options]
import base as channel_base
import ../bus, ../bus_types, ../config, ../logger

type
  PushoverChannel* = ref object of BaseChannel
    cfg*: PushoverConfig

proc newPushoverChannel*(cfg: PushoverConfig, bus: MessageBus): PushoverChannel =
  result = PushoverChannel(cfg: cfg)
  result.bus = bus
  result.name = "pushover"
  result.allowList = cfg.allow_from
  result.running = false

method name*(c: PushoverChannel): string = "pushover"

method capabilities*(c: PushoverChannel): ChannelCapabilities =
  ## Pushover: plain text only, ~1024 chars. No card / file / voice / etc.
  ChannelCapabilities(
    text: TextCaps(max_length: 1024, markdown: false),
    card: none(CardCaps),
    file: false, voice: false, react: false,
    edit: false, delete: false, threading: false,
    formatting: @["plain"]
  )

method start*(c: PushoverChannel) {.async.} =
  ## Outbound-only — no listening loop, no socket, no polling. Just flag
  ## running so dispatchOutbound considers us valid.
  c.running = true
  infoC("pushover", "Channel registered (outbound-only)")

method stop*(c: PushoverChannel) {.async.} =
  c.running = false

method send*(c: PushoverChannel, msg: OutboundMessage) {.async.} =
  if not c.running: return
  let userKey = msg.chat_id
  if userKey.len == 0:
    warnC("pushover", "send: empty user_key (msg.chat_id is the per-recipient pushover key)")
    return
  if c.cfg.token.len == 0:
    warnC("pushover", "send: PUSHOVER_TOKEN not configured (set in .env)")
    return

  var form = newMultipartData()
  form["token"]   = c.cfg.token
  form["user"]    = userKey
  form["message"] = msg.content
  if msg.metadata.hasKey("title"):    form["title"]    = msg.metadata["title"]
  if msg.metadata.hasKey("priority"): form["priority"] = msg.metadata["priority"]
  if msg.metadata.hasKey("sound"):    form["sound"]    = msg.metadata["sound"]

  let client = newAsyncHttpClient()
  try:
    let response = await client.post(
      "https://api.pushover.net/1/messages.json", multipart = form)
    let body = await response.body
    if "\"status\":1" in body:
      infoCF("pushover", "Notification sent",
             {"user": userKey}.toTable)
    else:
      warnCF("pushover", "API error", {"body": body}.toTable)
  except Exception as e:
    errorCF("pushover", "Send failed", {"error": e.msg}.toTable)
  finally:
    client.close()
