## Gateway IPC — supports two modes:
## 1. stdio: Zen spawns `nimclaw gateway --stdio`. JSONL on stdin/stdout + mmap.
## 2. socket: Legacy Unix socket for backward compat (CLI agent.send).
##
## stdio is the primary mode for Zen integration. Socket is kept for headless daemon.

import std/[net, json, os, strutils, tables, posix, locks]
import ../protocol, ../logger

# ── JSONL stdio protocol ────────────────────────────────────────

type
  StdioHandler* = proc(msg: JsonNode): seq[JsonNode] {.gcsafe.}
    ## Handle a message from stdin. Returns zero or more response messages
    ## to write to stdout. For streaming (chat.token), handler calls
    ## emitStdout() directly.

  StdioServer* = ref object
    handler*: StdioHandler
    running*: bool
    thread: Thread[StdioServer]

var gStdoutLock: Lock
gStdoutLock.initLock()

proc emitStdout*(msg: JsonNode) =
  ## Thread-safe write a JSONL message to stdout.
  gStdoutLock.acquire()
  try:
    stdout.writeLine($msg)
    stdout.flushFile()
  finally:
    gStdoutLock.release()

proc emitStdout*(event: string, data: JsonNode = newJObject()) =
  var msg = data.copy()
  msg["event"] = %event
  emitStdout(msg)

proc stdioLoop(ss: StdioServer) {.thread, gcsafe.} =
  {.cast(gcsafe).}:
    while ss.running:
      try:
        let line = stdin.readLine()
        if line.len == 0: continue
        let msg = try: parseJson(line)
                  except: continue
        let responses = ss.handler(msg)
        for resp in responses:
          emitStdout(resp)
      except IOError:
        # EOF — parent closed stdin
        ss.running = false
        break
      except:
        discard

proc newStdioServer*(handler: StdioHandler): StdioServer =
  StdioServer(handler: handler, running: false)

proc start*(ss: StdioServer) =
  ss.running = true
  infoCF("stdio", "Listening on stdin", initTable[string, string]())
  createThread(ss.thread, stdioLoop, ss)

proc stop*(ss: StdioServer) =
  ss.running = false

proc waitForEof*(ss: StdioServer) =
  ## Block until stdin EOF (Zen closed). Use in main loop.
  joinThread(ss.thread)

# ── Legacy socket server (for headless daemon mode) ──────────────

proc socketFileExists(path: string): bool =
  var st: Stat
  stat(path.cstring, st) == 0

type
  RpcHandler* = proc(req: RpcRequest): JsonNode {.gcsafe.}
    ## Synchronous RPC handler — runs on socket thread.

  SocketServer* = ref object
    path: string
    server: Socket
    handler: RpcHandler
    running*: bool
    thread: Thread[SocketServer]

proc sendLenPrefixed(client: Socket, data: string) =
  var buf: array[4, char]
  buf[0] = char((data.len shr 24) and 0xFF)
  buf[1] = char((data.len shr 16) and 0xFF)
  buf[2] = char((data.len shr 8) and 0xFF)
  buf[3] = char(data.len and 0xFF)
  client.send(buf.join("") & data)

proc handleSocketClient(ss: SocketServer, client: Socket) {.gcsafe.} =
  defer: client.close()
  try:
    var lenBuf = newString(4)
    let n = client.recv(lenBuf, 4)
    if n < 4: return
    let msgLen = (lenBuf[0].int shl 24) or (lenBuf[1].int shl 16) or
                 (lenBuf[2].int shl 8) or lenBuf[3].int
    if msgLen <= 0 or msgLen > 1_048_576: return
    var data = newString(msgLen)
    let r = client.recv(data, msgLen)
    if r < msgLen: return

    let req = parseRpcRequest(data)
    let resp = ss.handler(req)
    let respJson = if resp == nil: $ %*{"id": req.id, "error": "no response"}
                   else: $ %*{"id": req.id, "result": resp}
    client.sendLenPrefixed(respJson)
  except:
    debugCF("socket", "Client error", {"error": getCurrentExceptionMsg()}.toTable)

proc socketLoop(ss: SocketServer) {.thread, gcsafe.} =
  {.cast(gcsafe).}:
    while ss.running:
      try:
        var client: Socket
        ss.server.accept(client)
        ss.handleSocketClient(client)
      except OSError:
        if ss.running: sleep(10)

proc newSocketServer*(handler: RpcHandler): SocketServer =
  SocketServer(path: socketPath(), handler: handler, running: false)

proc start*(ss: SocketServer) =
  if socketFileExists(ss.path):
    removeFile(ss.path)
  ss.server = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  ss.server.bindUnix(ss.path)
  discard chmod(ss.path.cstring, 0o700)
  ss.server.listen()
  ss.running = true
  infoCF("socket", "Listening", {"path": ss.path}.toTable)
  createThread(ss.thread, socketLoop, ss)

proc stop*(ss: SocketServer) =
  ss.running = false
  try: ss.server.close()
  except: discard
  if socketFileExists(ss.path):
    removeFile(ss.path)
