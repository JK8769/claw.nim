## test_zen_chat — Playwright-style integration test for nimclaw ↔ Zen chat protocol.
##
## Forks: child = fake Zen server (scripted), parent = ZenChannel client.
## Exercises: chat.connect, chat.message, chat.token, chat.done, disconnect,
## reconnect, and chat.agents.

import std/[os, json, tables, posix, strutils, net, asyncdispatch, options]
import nimclaw/channels/zen
import nimclaw/channels/base
import nimclaw/bus, nimclaw/bus_types, nimclaw/config

const
  TestSockPath = "/tmp/test_zen_chat.sock"

# ── Length-prefixed framing (mirrors zen.nim / app_host.nim) ────────

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
  if n < 4: return ""
  let msgLen = (lenBuf[0].int shl 24) or (lenBuf[1].int shl 16) or
               (lenBuf[2].int shl 8) or lenBuf[3].int
  if msgLen <= 0 or msgLen > 1_048_576: return ""
  result = newString(msgLen)
  let r = sock.recv(result, msgLen)
  if r < msgLen: return ""

# ── Cleanup ────────────────────────────────────────────────────────

proc cleanup() =
  var st: Stat
  if stat(TestSockPath.cstring, st) == 0:
    try: removeFile(TestSockPath) except: discard

# ── Fake Zen server (child process) ───────────────────────────────

proc fakeZenServer() =
  ## Scripted server — follows a fixed protocol sequence, asserts along the way.
  let server = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  server.bindUnix(TestSockPath)
  server.listen()

  # ── Scene 1: Initial connection ───────────────────────────────────
  var client: Socket
  server.accept(client)

  # Read chat.connect
  let connectData = client.recvMsg()
  assert connectData.len > 0, "Expected chat.connect"
  let connectReq = parseJson(connectData)
  assert connectReq{"method"}.getStr("") == "chat.connect"
  assert connectReq{"name"}.getStr("") == "nimclaw"
  let agents = connectReq{"agents"}
  assert agents != nil and agents.kind == JArray
  assert agents.len == 1, "Expected 1 agent, got " & $agents.len
  assert agents[0]{"name"}.getStr("") == "TestAgent"

  # Respond OK
  client.sendMsg($ %*{"ok": true, "provider_id": "test_1"})

  # Send chat.message (Zen user → nimclaw)
  sleep(50)  # Let reader thread stabilize
  client.sendMsg($ %*{
    "method": "chat.message",
    "chat_id": "zen:42",
    "agent": "TestAgent",
    "content": "Hello from Zen"
  })

  # Read chat.token (nimclaw → Zen)
  let tokenData = client.recvMsg()
  assert tokenData.len > 0, "Expected chat.token"
  let tokenReq = parseJson(tokenData)
  assert tokenReq{"method"}.getStr("") == "chat.token", "Expected chat.token, got: " & tokenData
  assert tokenReq{"chat_id"}.getStr("") == "zen:42"
  assert tokenReq{"content"}.getStr("") == "Agent reply chunk"
  assert tokenReq{"agent"}.getStr("") == "TestAgent"

  # Read chat.done (nimclaw → Zen)
  # The final send includes both a chat.token (content) and chat.done
  let tokenData2 = client.recvMsg()
  assert tokenData2.len > 0, "Expected second chat.token"
  let tokenReq2 = parseJson(tokenData2)
  assert tokenReq2{"method"}.getStr("") == "chat.token"
  assert tokenReq2{"content"}.getStr("") == "Final chunk"

  let doneData = client.recvMsg()
  assert doneData.len > 0, "Expected chat.done"
  let doneReq = parseJson(doneData)
  assert doneReq{"method"}.getStr("") == "chat.done"
  assert doneReq{"chat_id"}.getStr("") == "zen:42"

  # ── Scene 2: Disconnect ───────────────────────────────────────────
  client.close()
  sleep(100)  # Let reader thread detect disconnect

  # ── Scene 3: Reconnect ────────────────────────────────────────────
  var client2: Socket
  server.accept(client2)

  # Read chat.connect again
  let reconnData = client2.recvMsg()
  assert reconnData.len > 0, "Expected chat.connect on reconnect"
  let reconnReq = parseJson(reconnData)
  assert reconnReq{"method"}.getStr("") == "chat.connect"
  client2.sendMsg($ %*{"ok": true, "provider_id": "test_2"})

  # Read chat.agents (roster update)
  let agentsData = client2.recvMsg()
  assert agentsData.len > 0, "Expected chat.agents"
  let agentsReq = parseJson(agentsData)
  assert agentsReq{"method"}.getStr("") == "chat.agents"
  let updatedAgents = agentsReq{"agents"}
  assert updatedAgents != nil and updatedAgents.len == 2, "Expected 2 agents after update"

  client2.close()
  server.close()

# ── Test client (parent process) ──────────────────────────────────

proc drainInbound(bus: MessageBus, timeoutMs: int = 2000): InboundMessage =
  ## Poll the bus synchronously until a message arrives or timeout.
  var elapsed = 0
  while elapsed < timeoutMs:
    let (msg, ok) = bus.tryConsumeInbound()
    if ok: return msg
    sleep(10)
    elapsed += 10
  raise newException(AssertionDefect, "Timed out waiting for inbound message")

proc runTest() =
  sleep(100)  # Let fake Zen start listening

  putEnv("ZEN_SOCK", TestSockPath)

  # Build minimal config with one agent
  var cfg = Config()
  cfg.default_model = "test-model"
  cfg.agents.named = @[NamedAgentConfig(name: "TestAgent", model: "test-model")]

  let bus = newMessageBus()
  let zc = newZenChannel(cfg, bus)

  # ── 1. Connect ───────────────────────────────────────────────────
  echo "1. Connecting to fake Zen..."
  waitFor zc.start()
  assert zc.connected, "Should be connected after start"
  echo "   Connected OK (provider_id assigned by server)"

  # ── 2. Receive chat.message ──────────────────────────────────────
  echo "2. Waiting for inbound chat.message..."
  let msg = drainInbound(bus)
  assert msg.channel == "zen"
  assert msg.content == "Hello from Zen"
  assert msg.chat_id == "zen:42"
  assert msg.metadata["zen_chat_id"] == "zen:42"
  assert msg.recipient_id == "TestAgent"
  echo "   Inbound message OK: \"" & msg.content & "\" → agent " & msg.recipient_id

  # ── 3. Send chat.token ──────────────────────────────────────────
  echo "3. Sending chat.token (streaming chunk)..."
  let outMsg = OutboundMessage(
    channel: "zen",
    sender_agent: "TestAgent",
    chat_id: "zen:42",
    content: "Agent reply chunk",
    metadata: initTable[string, string]()
  )
  waitFor zc.send(outMsg)
  echo "   chat.token sent OK"

  # ── 4. Send chat.done (final response) ──────────────────────────
  echo "4. Sending final chunk + chat.done..."
  var finalMeta = initTable[string, string]()
  finalMeta["final"] = "true"
  let finalMsg = OutboundMessage(
    channel: "zen",
    sender_agent: "TestAgent",
    chat_id: "zen:42",
    content: "Final chunk",
    metadata: finalMeta
  )
  waitFor zc.send(finalMsg)
  echo "   chat.done sent OK"

  # ── 5. Detect disconnect ────────────────────────────────────────
  echo "5. Waiting for disconnect..."
  var waited = 0
  while zc.connected and waited < 2000:
    sleep(10)
    waited += 10
  assert not zc.connected, "Should detect disconnect"
  echo "   Disconnect detected OK"

  # ── 6. Reconnect ────────────────────────────────────────────────
  echo "6. Reconnecting..."
  sleep(100)  # Let fake Zen prepare for reconnect accept
  zc.reconnect()
  assert zc.connected, "Should be connected after reconnect"
  echo "   Reconnect OK"

  # ── 7. Update roster ────────────────────────────────────────────
  echo "7. Pushing updated agent roster..."
  var cfg2 = cfg
  cfg2.agents.named = @[
    NamedAgentConfig(name: "TestAgent", model: "test-model"),
    NamedAgentConfig(name: "Agent2", model: "other-model")
  ]
  zc.updateRoster(cfg2)
  echo "   chat.agents sent OK"

  # ── 8. Stop ─────────────────────────────────────────────────────
  echo "8. Stopping ZenChannel..."
  sleep(100)  # Let fake Zen read the agents message and close
  waitFor zc.stop()
  assert not zc.connected
  echo "   Stopped OK"

  bus.close()
  echo ""
  echo "All tests passed!"

# ── Main ──────────────────────────────────────────────────────────

proc main() =
  cleanup()

  let pid = fork()
  if pid == 0:
    # Child: fake Zen server
    try:
      fakeZenServer()
    except Exception as e:
      echo "FAKE ZEN FAILED: ", e.msg
      echo e.getStackTrace()
      quit(1)
    quit(0)
  elif pid < 0:
    echo "fork() failed"
    quit(1)
  else:
    # Parent: test client
    try:
      runTest()
    except Exception as e:
      echo "FAILED: ", e.msg
      echo e.getStackTrace()
      discard kill(pid.Pid, SIGTERM)
      cleanup()
      quit(1)

    # Clean up child
    discard kill(pid.Pid, SIGTERM)
    var status: cint
    discard waitpid(pid.Pid, status, 0)
    cleanup()

when isMainModule:
  main()
