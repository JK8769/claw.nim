import std/[asyncdispatch, strutils, tables, options]
import ../bus, ../bus_types
import ../services/voice
export options  # `some`/`none`/`Option` reach channel impls via base.nim

type
  TextCaps* = object
    max_length*: int            ## 0 = unbounded
    markdown*: bool

  CardCaps* = object
    kind*: string               ## "CardKit" | "telegram_inline" | "discord_embed" | "actioncard" | …
    interactive*: bool          ## buttons / callbacks supported

  ChannelCapabilities* = object
    text*: TextCaps
    card*: Option[CardCaps]     ## none() if vendor has no card primitive
    file*: bool
    voice*: bool
    react*: bool
    edit*: bool                 ## can edit a sent message
    delete*: bool               ## can delete a sent message
    threading*: bool            ## native thread / reply-chain
    formatting*: seq[string]    ## ["plain", "markdown", "lark_cardkit", "html", …]

  Channel* = ref object of RootObj

method name*(c: Channel): string {.base.} = ""
method start*(c: Channel): Future[void] {.base, async.} = discard
method stop*(c: Channel): Future[void] {.base, async.} = discard
method send*(c: Channel, msg: OutboundMessage): Future[void] {.base, async.} = discard
method isRunning*(c: Channel): bool {.base.} = false
method isAllowed*(c: Channel, senderID: string): bool {.base.} = true
method setTranscriber*(c: Channel, transcriber: GroqTranscriber) {.base.} = discard

method capabilities*(c: Channel): ChannelCapabilities {.base.} =
  ## Conservative default: plain text, nothing else. Each channel impl
  ## overrides with its actual feature set so the chat/mail tools can
  ## drive format selection generically — no hardcoded vendor branches.
  ChannelCapabilities(
    text: TextCaps(max_length: 0, markdown: false),
    card: none(CardCaps),
    file: false, voice: false, react: false,
    edit: false, delete: false, threading: false,
    formatting: @["plain"]
  )

type
  BaseChannel* = ref object of Channel
    bus*: MessageBus
    running*: bool
    name*: string
    allowList*: seq[string]

proc newBaseChannel*(name: string, bus: MessageBus, allowList: seq[string]): BaseChannel =
  BaseChannel(
    bus: bus,
    name: name,
    allowList: allowList,
    running: false
  )

method name*(c: BaseChannel): string = c.name
method isRunning*(c: BaseChannel): bool = c.running

method isAllowed*(c: BaseChannel, senderID: string): bool =
  if c.allowList.len == 0: return true
  for allowed in c.allowList:
    if senderID == allowed: return true
  return false

proc handleMessage*(c: BaseChannel, senderID, chatID, content: string,
                    media: seq[string] = @[],
                    metadata: Table[string, string] = initTable[string, string](),
                    recipientID: string = "",
                    chatKind: ChatKind = ckUnknown) =
  if not c.isAllowed(senderID): return

  # Transport-level session_key for reply routing. The agent loop
  # replaces this with an identity-scoped key before persistence; see
  # identitySessionKey in agent/loop.nim. Channels pass chatKind so the
  # loop knows whether to key-by-sender (DM) or key-by-chat (group).
  let sessionKey = c.name & ":" & chatID & ":" & senderID
  let msg = InboundMessage(
    channel: c.name,
    sender_id: senderID,
    recipient_id: recipientID,
    chat_id: chatID,
    chat_kind: chatKind,
    content: content,
    media: media,
    session_key: sessionKey,
    metadata: metadata
  )
  c.bus.publishInbound(msg)
