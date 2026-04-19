import std/[tables, asyncdispatch]

type
  ChatKind* = enum
    ## Does this message arrive in a 1:1 or a multi-party room?
    ## Channels set this from their platform-native signal (Telegram's
    ## `chat.type`, Feishu's `chat_id` prefix, WhatsApp's JID suffix,
    ## Discord's channel type, etc.). The agent loop branches on it
    ## to key sessions per-partner (DM) or per-group.
    ckUnknown  = "unknown"   # channel didn't decide
    ckDM       = "dm"        # 1:1 with the agent
    ckGroup    = "group"     # 3+ participants; `chat_id` is the group

  InboundMessage* = object
    channel*: string
    sender_id*: string
    recipient_id*: string
    chat_id*: string
    chat_kind*: ChatKind
    content*: string
    media*: seq[string]
    session_key*: string
    metadata*: Table[string, string]

  OutboundKind* = enum
    Regular, Typing

  OutboundMessage* = object
    channel*: string
    sender_agent*: string
    chat_id*: string
    content*: string
    kind*: OutboundKind
    reply_to_message_id*: string
    app_id*: string
    metadata*: Table[string, string]

  MessageHandler* = proc (msg: InboundMessage): Future[void] {.async.}

proc newOutbound*(channel, senderAgent, chatID, content: string, replyTo = "", appID = "", metadata: Table[string, string] = initTable[string, string]()): OutboundMessage =
  OutboundMessage(channel: channel, sender_agent: senderAgent, chat_id: chatID, content: content, reply_to_message_id: replyTo, app_id: appID, metadata: metadata)
