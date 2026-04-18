import std/[tables, asyncdispatch]

type
  InboundMessage* = object
    channel*: string
    sender_id*: string
    recipient_id*: string
    chat_id*: string
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
