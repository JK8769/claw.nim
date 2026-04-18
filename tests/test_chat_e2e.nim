## E2E test for NimClaw chat using Zen's test RPCs.
##
## Tests the full flow: Zen → nimclaw zen (chat bridge) → nimclawd → LLM → response
## Uses test.status and test.chat RPCs on zen.sock — no PTY/TUI interaction needed.
##
## Prerequisites:
##   - nimclawd running for MyCompany (`nimclaw service start MyCompany`)
##   - Zen running (`./build/zen`)
##   - nimclaw zen connected (click nimclaw tab in Zen, or launch manually)

import std/[net, nativesockets, json, os, strutils, posix, times, osproc]

const ZenSock = "~/.zen/zen.sock"

# ── IPC helpers ──────────────────────────────────────────────────

proc sendMsg(sock: Socket, data: string) =
  var buf: array[4, char]
  buf[0] = char((data.len shr 24) and 0xFF)
  buf[1] = char((data.len shr 16) and 0xFF)
  buf[2] = char((data.len shr 8) and 0xFF)
  buf[3] = char(data.len and 0xFF)
  sock.send(buf.join("") & data)

proc waitForData(fd: cint, timeoutMs: int): bool =
  ## Wait for data on a socket using poll(). Returns true if data ready.
  var pfd: TPollfd
  pfd.fd = fd
  pfd.events = POLLIN
  let r = poll(addr pfd, 1, timeoutMs.cint)
  return r > 0 and (pfd.revents and POLLIN) != 0

proc recvMsg(sock: Socket, timeoutMs = 60000): string =
  if timeoutMs > 0:
    if not waitForData(sock.getFd().cint, timeoutMs): return ""
  var lenBuf = newString(4)
  let n = sock.recv(lenBuf, 4)
  if n < 4: return ""
  let msgLen = (lenBuf[0].int shl 24) or (lenBuf[1].int shl 16) or
               (lenBuf[2].int shl 8) or lenBuf[3].int
  if msgLen <= 0 or msgLen > 1_048_576: return ""
  result = newString(msgLen)
  discard sock.recv(result, msgLen)

proc zenRPC(meth: string, params: JsonNode = nil, timeoutMs = 60000): JsonNode =
  ## Send a request to Zen's socket and return the parsed response.
  let sockPath = expandTilde(ZenSock)
  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  defer: sock.close()
  sock.connectUnix(sockPath)
  var req = %*{"method": meth}
  if params != nil:
    for k, v in params: req[k] = v
  sock.sendMsg($req)
  let resp = sock.recvMsg(timeoutMs)
  if resp == "": return nil
  try: parseJson(resp) except: nil

proc daemonRPC(meth: string, params: JsonNode = newJObject(), timeoutMs = 30000): JsonNode =
  ## Send a JSON-RPC request to nimclawd.
  let sockPath = expandTilde("~/.nimclawd/mycompany/nimclaw.sock")
  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  defer: sock.close()
  try: sock.connectUnix(sockPath)
  except: return nil
  let req = $ %*{"id": 1, "method": meth, "params": params}
  sock.sendMsg(req)
  let resp = sock.recvMsg(timeoutMs)
  if resp == "": return nil
  try: parseJson(resp) except: nil

proc socketExists(path: string): bool =
  var st: Stat
  stat(path.cstring, st) == 0

# ── Tests ────────────────────────────────────────────────────────

proc test1_daemonAlive(): bool =
  echo "\n--- Test 1: nimclawd is running ---"
  let sockPath = expandTilde("~/.nimclawd/mycompany/nimclaw.sock")
  if not socketExists(sockPath):
    echo "  FAIL: no daemon socket"
    return false
  # Direct test — connect, send status, read response
  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  defer: sock.close()
  try: sock.connectUnix(sockPath)
  except:
    echo "  FAIL: can't connect: " & getCurrentExceptionMsg()
    return false
  echo "  Connected"
  let req = $ %*{"id": 1, "method": "status", "params": {}}
  sock.sendMsg(req)
  echo "  Sent request (" & $req.len & " bytes)"
  if not waitForData(sock.getFd().cint, 5000):
    echo "  FAIL: no data within 5s"
    return false
  echo "  Data available"
  let resp = sock.recvMsg(5000)
  if resp == "":
    echo "  FAIL: empty response"
    return false
  echo "  Got: " & resp[0..min(100, resp.len-1)]
  let r = try: parseJson(resp) except: nil
  if r == nil:
    echo "  FAIL: bad JSON"
    return false
  echo "  OK: daemon PID " & $r{"result", "pid"}.getInt()
  return true

proc test2_daemonAgentSend(): bool =
  echo "\n--- Test 2: daemon agent.send (Lexi) ---"
  let r = daemonRPC("agent.send", %*{"name": "Lexi", "message": "say hello in one word"})
  if r == nil:
    echo "  FAIL: no response"
    return false
  if r{"error"}.kind != JNull and r{"error"}.getStr("") != "":
    echo "  FAIL: " & $r{"error"}
    return false
  let text = if r{"result"}.kind == JString: r{"result"}.getStr()
             else: $r{"result"}
  echo "  OK: \"" & text[0..min(80, text.len-1)] & "\""
  return true

proc test3_zenAlive(): bool =
  echo "\n--- Test 3: Zen is running ---"
  if not socketExists(expandTilde(ZenSock)):
    echo "  FAIL: no Zen socket"
    return false
  let r = zenRPC("test.status", timeoutMs = 5000)
  if r == nil:
    echo "  FAIL: no response from Zen"
    return false
  if not r{"ok"}.getBool(false):
    echo "  FAIL: " & $r
    return false
  let providers = r{"chatProviders"}
  let liveConns = r{"liveConns"}
  echo "  OK: " & $providers.len & " chat providers, " & $liveConns.len & " live connections"
  return true

proc test4_chatProviderConnected(): bool =
  echo "\n--- Test 4: NimClaw chat provider registered ---"
  let r = zenRPC("test.status", timeoutMs = 5000)
  if r == nil:
    echo "  FAIL: can't reach Zen"
    return false
  let providers = r{"chatProviders"}
  if providers == nil or providers.len == 0:
    echo "  FAIL: no chat providers"
    return false
  var found = false
  for p in providers:
    let name = p{"name"}.getStr("")
    let service = p{"service"}.getStr("")
    let connected = p{"connected"}.getBool(false)
    let agents = p{"agents"}
    echo "  Provider: " & name & "/" & service & " connected=" & $connected &
         " agents=" & $agents.len
    if connected and agents.len > 0:
      found = true
  if not found:
    echo "  FAIL: no connected provider with agents"
  else:
    echo "  OK"
  return found

proc test5_chatE2E(): bool =
  echo "\n--- Test 5: test.chat E2E (Zen → nimclaw zen → daemon → LLM) ---"
  echo "  Sending 'say hello in one word' to Lexi via test.chat..."
  let r = zenRPC("test.chat", %*{"agent": "Lexi", "message": "say hello in one word"},
                 timeoutMs = 60000)
  if r == nil:
    echo "  FAIL: no response (timeout?)"
    return false
  if not r{"ok"}.getBool(false):
    echo "  FAIL: " & r{"error"}.getStr($r)
    return false
  let response = r{"response"}.getStr("")
  if response.len == 0:
    echo "  FAIL: empty response"
    return false
  echo "  OK: \"" & response[0..min(80, response.len-1)] & "\""
  return true

# ── Main ─────────────────────────────────────────────────────────

echo "=== NimClaw Chat E2E Tests ==="

var passed, failed, skipped = 0

template run(test: untyped, required: bool = false) =
  try:
    if test: inc passed
    else:
      inc failed
      if required:
        echo "\n  (skipping remaining tests — prerequisite failed)"
        break mainTests
  except:
    echo "  ERROR: " & getCurrentExceptionMsg()
    inc failed
    if required:
      echo "\n  (skipping remaining tests — prerequisite failed)"
      break mainTests

block mainTests:
  run test1_daemonAlive(), required = true
  run test2_daemonAgentSend()
  run test3_zenAlive(), required = true
  run test4_chatProviderConnected(), required = true
  run test5_chatE2E()

echo "\n=== " & $passed & " passed, " & $failed & " failed ==="
if failed > 0: quit(1)
