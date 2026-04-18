## zen — Channel connecting nimclaw to Zen TUI as a chat provider.
##
## Zen is treated like any other platform (Telegram, Feishu, etc.).
## nimclaw connects TO Zen's zen.sock and registers as a chat provider.
## Zen routes user messages to nimclaw, nimclaw streams responses back.
##
## Protocol (length-prefixed JSON on ~/.zen/zen.sock):
##   → chat.connect  (nimclaw registers with agent roster)
##   ← chat.message  (user sends a message)
##   → chat.token    (nimclaw streams response tokens)
##   → chat.done     (nimclaw signals turn complete)
##   → chat.agents   (nimclaw updates agent roster)

import std/[asyncdispatch, json, strutils, tables, os, net, typedthreads]
import base
import ../bus, ../bus_types, ../config, ../logger, ../protocol

const
  ZenSocketName = "zen.sock"
  ZenDefaultDir = "~/.zen"
  ZenSocketEnv = "ZEN_SOCK"
  MaxMsgSize = 1_048_576
  ReconnectIntervalMs = 3000

type
  ZenReaderArgs = object
    channel: ZenChannel

  ZenChannel* = ref object of BaseChannel
    sock: Socket
    readerThread: Thread[ZenReaderArgs]
    connected*: bool
    providerId: string
    agentRoster: seq[tuple[name, description, model: string]]
    onReconnect*: proc() {.gcsafe.}  ## Called after reconnecting to Zen (e.g. re-mount dashboard)

# ── Socket path resolution ──────────────────────────────────────────

proc zenSocketPath(): string =
  result = getEnv(ZenSocketEnv)
  if result == "":
    result = expandTilde(ZenDefaultDir) / ZenSocketName

# ── Length-prefixed JSON framing ────────────────────────────────────

proc sendMsg(sock: Socket, data: string) =
  var buf: array[4, char]
  buf[0] = char((data.len shr 24) and 0xFF)
  buf[1] = char((data.len shr 16) and 0xFF)
  buf[2] = char((data.len shr 8) and 0xFF)
  buf[3] = char(data.len and 0xFF)
  sock.send(buf.join("") & data)

proc recvMsg(sock: Socket): string =
  var lenBuf = newString(4)
  let n = sock.recv(lenBuf, 4)
  if n == 0: return "" # Clean disconnect
  if n < 4: return ""
  let msgLen = (lenBuf[0].int shl 24) or (lenBuf[1].int shl 16) or
               (lenBuf[2].int shl 8) or lenBuf[3].int
  if msgLen <= 0 or msgLen > MaxMsgSize: return ""
  result = newString(msgLen)
  let r = sock.recv(result, msgLen)
  if r < msgLen: return ""

# ── Agent roster builder ────────────────────────────────────────────

proc buildRosterJson(c: ZenChannel): JsonNode =
  var agents = newJArray()
  for a in c.agentRoster:
    agents.add(%*{"name": a.name, "description": a.description, "model": a.model})
  return agents

# ── Reader thread ───────────────────────────────────────────────────

proc tryConnect(c: ZenChannel): bool =
  ## Attempt to connect to Zen and send chat.connect. Returns true on success.
  let sockPath = zenSocketPath()
  try:
    c.sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    c.sock.connectUnix(sockPath)
    let req = %*{
      "method": "chat.connect",
      "name": "nimclaw",
      "service": serviceRuntimeName(),
      "agents": c.buildRosterJson()
    }
    c.sock.sendMsg($req)
    let resp = try: recvMsg(c.sock) except: ""
    if resp.len > 0:
      let j = try: parseJson(resp) except: nil
      if j != nil and j{"ok"}.getBool(false):
        c.providerId = j{"provider_id"}.getStr("")
        c.connected = true
        infoCF("zen", "Connected to Zen", {"provider_id": c.providerId}.toTable)
        return true
    try: c.sock.close() except: discard
  except:
    try: c.sock.close() except: discard
  return false

proc readerLoop(args: ZenReaderArgs) {.thread, gcsafe.} =
  ## Read messages until disconnect. No reconnect — Zen initiates reconnection.
  let c = args.channel
  {.cast(gcsafe).}:
    infoC("zen", "Reader thread started")
    while c.running and c.connected:
      let data = try: recvMsg(c.sock)
                 except: ""
      if data == "":
        infoC("zen", "Disconnected from Zen")
        c.connected = false
        try: c.sock.close() except: discard
        break

      let req = try: parseJson(data)
                except: continue
      let meth = req{"method"}.getStr("")

      case meth
      of "chat.message":
        let chatId = req{"chat_id"}.getStr("")
        let agent = req{"agent"}.getStr("")
        let content = req{"content"}.getStr("")
        if content.len > 0:
          var meta = initTable[string, string]()
          meta["zen_chat_id"] = chatId
          c.handleMessage("zen_user", chatId, content,
                         metadata = meta, recipientID = agent)
          infoCF("zen", "Received message", {"chat_id": chatId, "agent": agent}.toTable)
      else:
        discard

    infoC("zen", "Reader thread exiting")

proc reconnect*(c: ZenChannel) =
  ## Called externally (e.g. from RPC) to reconnect to Zen.
  if c.connected: return
  if tryConnect(c):
    createThread(c.readerThread, readerLoop, ZenReaderArgs(channel: c))
    if c.onReconnect != nil:
      c.onReconnect()

# ── Channel interface ───────────────────────────────────────────────

proc newZenChannel*(cfg: Config, bus: MessageBus): ZenChannel =
  result = ZenChannel(
    bus: bus,
    name: "zen",
    allowList: @[],
    running: false,
    connected: false,
    agentRoster: @[]
  )
  # Build roster from named agents config
  for agent in cfg.agents.named:
    result.agentRoster.add((
      name: agent.name,
      description: "",
      model: if agent.model != "": agent.model else: cfg.default_model
    ))
  # Always include default agent if not already listed
  if result.agentRoster.len == 0:
    result.agentRoster.add((name: "Lexi", description: "General assistant", model: cfg.default_model))

method name*(c: ZenChannel): string = "zen"

method start*(c: ZenChannel) {.async.} =
  if c.running:
    infoC("zen", "Zen channel already running")
    return

  c.running = true
  infoC("zen", "Starting Zen channel...")
  # Try once — Zen will trigger reconnect via RPC if needed later
  if tryConnect(c):
    createThread(c.readerThread, readerLoop, ZenReaderArgs(channel: c))
  else:
    infoC("zen", "Zen not available, waiting for reconnect signal")

method stop*(c: ZenChannel) {.async.} =
  c.running = false
  c.connected = false
  if c.sock != nil:
    try: c.sock.close()
    except: discard
  joinThread(c.readerThread)
  infoC("zen", "Zen channel stopped")

method send*(c: ZenChannel, msg: OutboundMessage) {.async.} =
  if not c.connected or c.sock == nil: return

  let chatId = msg.chat_id
  let agent = msg.sender_agent

  # Send chat.token with the content
  if msg.content.len > 0:
    let tokenMsg = $ %*{
      "method": "chat.token",
      "chat_id": chatId,
      "agent": agent,
      "content": msg.content
    }
    try:
      c.sock.sendMsg(tokenMsg)
    except:
      errorC("zen", "Failed to send chat.token: " & getCurrentExceptionMsg())
      c.connected = false
      return

  # If this is the final response, send chat.done
  if msg.metadata.hasKey("final"):
    let doneMsg = $ %*{
      "method": "chat.done",
      "chat_id": chatId,
      "agent": agent
    }
    try:
      c.sock.sendMsg(doneMsg)
    except:
      errorC("zen", "Failed to send chat.done: " & getCurrentExceptionMsg())
      c.connected = false

proc updateRoster*(c: ZenChannel, cfg: Config) =
  ## Push updated agent roster to Zen.
  c.agentRoster = @[]
  for agent in cfg.agents.named:
    c.agentRoster.add((
      name: agent.name,
      description: "",
      model: if agent.model != "": agent.model else: cfg.default_model
    ))
  if c.agentRoster.len == 0:
    c.agentRoster.add((name: "Lexi", description: "General assistant", model: cfg.default_model))

  if c.connected and c.sock != nil:
    let msg = $ %*{
      "method": "chat.agents",
      "agents": c.buildRosterJson()
    }
    try:
      c.sock.sendMsg(msg)
    except:
      errorC("zen", "Failed to send chat.agents: " & getCurrentExceptionMsg())
