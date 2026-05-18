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
import posix
import base
import ../bus, ../bus_types, ../config, ../logger, ../protocol
import ../agent/binding as agentBinding
import ../agent/cortex as agentCortex

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
    # Stable per-OS-account identifier zen reports in chat.connect
    # (`local:<USER>` by default; `$ZEN_USER` override). Used as the
    # channel user-id for `bind` flow and message routing — same
    # role `feishu_<id>` plays for the Feishu adapter. Defaults to
    # "zen_user" for backward compatibility with zen versions that
    # don't populate the field.
    zenUser: string
    # Kernel-reported UID of the connected zen process via
    # LOCAL_PEERCRED (macOS) / SO_PEERCRED (Linux). Unspoofable —
    # the source-of-truth for the local-trust auto-bind decision.
    # See docs/zen-local-trust-binding.md. -1 = not yet queried or
    # unsupported on this platform; treated as "untrusted".
    peerUid: int
    # Set once after the first message from a trusted local peer is
    # successfully auto-bound, so we don't retry the bind logic on
    # every subsequent message. Doesn't gate sends — just avoids
    # redundant work / log spam.
    autoBindAttempted: bool
    # Captured at construction from cfg.workspacePath(). Used by the
    # local-trust auto-bind path to load/save the cortex graph
    # without re-resolving the company workspace on every message.
    workspace: string
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

# ── Peer credentials (LOCAL_PEERCRED / SO_PEERCRED) ────────────────
#
# Returns the kernel-reported UID of the process on the other end of
# a connected Unix socket. Unspoofable — the OS reads it from the
# remote process's credential structure, not from anything the peer
# sends over the wire. Used by the zen channel's local-trust check
# (see docs/zen-local-trust-binding.md). Returns -1 on any error or
# on platforms where this isn't supported; the auto-bind path
# treats -1 as "untrusted, fall through to invite flow".

when defined(linux):
  type Ucred {.importc: "struct ucred", header: "<sys/socket.h>".} = object
    pid {.importc.}: cint
    uid {.importc.}: cuint
    gid {.importc.}: cuint
  const SO_PEERCRED_VAL = 17.cint   # SO_PEERCRED on Linux
  proc getPeerUid(sock: Socket): int =
    var cred: Ucred
    var sz: SockLen = sizeof(cred).SockLen
    if getsockopt(sock.getFd().SocketHandle, SOL_SOCKET,
                  SO_PEERCRED_VAL, addr cred, addr sz) != 0:
      return -1
    return cred.uid.int
elif defined(macosx) or defined(bsd):
  # macOS exposes LOCAL_PEERCRED at SOL_LOCAL via xucred, but the
  # simpler primitive is `getpeereid` (POSIX), which returns just
  # (uid, gid). It's a direct kernel-side lookup of the remote
  # process's effective UID — same unspoofability guarantee.
  proc getpeereid(s: SocketHandle, uid: ptr Uid, gid: ptr Gid): cint
       {.importc, header: "<unistd.h>".}
  proc getPeerUid(sock: Socket): int =
    var uid: Uid
    var gid: Gid
    if getpeereid(sock.getFd().SocketHandle, addr uid, addr gid) != 0:
      return -1
    return uid.int
else:
  proc getPeerUid(sock: Socket): int = -1

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
        # Stable OS-account id for this zen install — see field doc.
        # Fall back to "zen_user" so older zens (no `user` field)
        # still connect, just without per-user binding capability.
        c.zenUser = j{"user"}.getStr("zen_user")
        # Kernel-verified peer UID for the local-trust check.
        # Captured once per connection; -1 if the kernel call failed
        # or the platform is unsupported.
        c.peerUid = getPeerUid(c.sock)
        c.autoBindAttempted = false
        c.connected = true
        infoCF("zen", "Connected to Zen",
               {"provider_id": c.providerId,
                "user": c.zenUser,
                "peer_uid": $c.peerUid}.toTable)
        return true
    try: c.sock.close() except: discard
  except:
    try: c.sock.close() except: discard
  return false

proc handleZenMessage(c: ZenChannel, req: JsonNode) {.gcsafe.} =
  ## Process one parsed JSON message from zen.
  {.cast(gcsafe).}:
    let meth = req{"method"}.getStr("")
    case meth
    of "chat.message":
      let chatId = req{"chat_id"}.getStr("")
      let agent = req{"agent"}.getStr("")
      let content = req{"content"}.getStr("")
      if content.len > 0:
        var meta = initTable[string, string]()
        meta["zen_chat_id"] = chatId
        let user = if c.zenUser.len > 0: c.zenUser else: "zen_user"
        # Local-trust auto-bind. Runs once per connection. When the
        # connecting zen process is the same OS user as this daemon
        # AND the company has a SuperAdmin without a `zen` binding
        # yet, stamp the binding directly (skip the invite-code
        # roundtrip). See docs/zen-local-trust-binding.md.
        if not c.autoBindAttempted and
           c.peerUid >= 0 and c.peerUid == getuid().int:
          c.autoBindAttempted = true
          let graph = loadWorld(c.workspace)
          if graph != nil:
            if autoBindLocalCreator(graph, c.workspace, "zen", user):
              infoCF("zen", "Auto-bound trusted local user",
                     {"user": user, "uid": $c.peerUid}.toTable)
            else:
              infoCF("zen", "No auto-bind candidate; using invite flow",
                     {"user": user}.toTable)
        c.handleMessage(user, chatId, content,
                       metadata = meta, recipientID = agent)
        infoCF("zen", "Received message", {"chat_id": chatId, "agent": agent}.toTable)
    else: discard

proc readerLoop(args: ZenReaderArgs) {.thread, gcsafe.} =
  ## Outer loop: while the channel is running. Inner loop: while
  ## connected, read+dispatch. On disconnect, poll `tryConnect`
  ## every `ReconnectIntervalMs` until either zen comes back (jump
  ## back to the inner read loop) or the channel shuts down. This
  ## means a zen restart no longer requires a gateway restart.
  let c = args.channel
  {.cast(gcsafe).}:
    infoC("zen", "Reader thread started")
    while c.running:
      while c.running and c.connected:
        let data = try: recvMsg(c.sock) except: ""
        if data == "":
          infoC("zen", "Disconnected from Zen")
          c.connected = false
          try: c.sock.close() except: discard
          break
        let req = try: parseJson(data) except: nil
        if req != nil: c.handleZenMessage(req)
      # Disconnected — retry until zen comes back or we're shut down.
      while c.running and not c.connected:
        sleep(ReconnectIntervalMs)
        if not c.running: break
        if tryConnect(c):
          infoC("zen", "Reconnected after mid-life disconnect")
          break
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
    peerUid: -1,
    workspace: cfg.workspacePath(),
    agentRoster: @[]
  )
  # Build roster from named agents config. Each agent has their own
  # `models[0]` post-Phase 4; fall back to the deprecated singular
  # `model` field, then to "" (Zen surfaces empty as "—").
  for agent in cfg.agents.named:
    let primary =
      if agent.models.len > 0: agent.models[0]
      elif agent.model.len > 0: agent.model
      else: ""
    result.agentRoster.add((
      name: agent.name,
      description: "",
      model: primary
    ))
  # Always include default agent if not already listed
  if result.agentRoster.len == 0:
    result.agentRoster.add((name: "Lexi", description: "General assistant", model: ""))

method name*(c: ZenChannel): string = "zen"

method capabilities*(c: ZenChannel): ChannelCapabilities =
  ChannelCapabilities(
    text: TextCaps(max_length: 0, markdown: true),
    card: some(CardCaps(kind: "zen_pane", interactive: true)),
    file: true, voice: false, react: false,
    edit: true, delete: true, threading: false,
    formatting: @["plain", "markdown", "zen_pane"]
  )

proc reconnectLoop(c: ZenChannel) {.async.} =
  ## Background retry loop. Polls ~/.zen/zen.sock every
  ## `ReconnectIntervalMs` until the channel either connects or the
  ## owning gateway shuts down. Without this, a gateway started
  ## before zen comes up stays disconnected forever — the user has
  ## to manually restart the daemon. Fixes the "open zen, see
  ## (no agents loaded), have to restart claw" footgun.
  while c.running and not c.connected:
    await sleepAsync(ReconnectIntervalMs)
    if not c.running: break
    if c.connected: break
    if tryConnect(c):
      createThread(c.readerThread, readerLoop, ZenReaderArgs(channel: c))
      if c.onReconnect != nil: c.onReconnect()
      infoC("zen", "Connected after retry")
      return

method start*(c: ZenChannel) {.async.} =
  if c.running:
    infoC("zen", "Zen channel already running")
    return

  c.running = true
  infoC("zen", "Starting Zen channel...")
  if tryConnect(c):
    createThread(c.readerThread, readerLoop, ZenReaderArgs(channel: c))
  else:
    # Zen not up yet — keep polling in the background. The retry
    # loop exits when we connect, when the gateway stops, or when
    # the channel is otherwise shut down.
    infoC("zen", "Zen not available, polling in background")
    asyncCheck reconnectLoop(c)

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
    let primary =
      if agent.models.len > 0: agent.models[0]
      elif agent.model.len > 0: agent.model
      else: ""
    c.agentRoster.add((
      name: agent.name,
      description: "",
      model: primary
    ))
  if c.agentRoster.len == 0:
    c.agentRoster.add((name: "Lexi", description: "General assistant", model: ""))

  if c.connected and c.sock != nil:
    let msg = $ %*{
      "method": "chat.agents",
      "agents": c.buildRosterJson()
    }
    try:
      c.sock.sendMsg(msg)
    except:
      errorC("zen", "Failed to send chat.agents: " & getCurrentExceptionMsg())
