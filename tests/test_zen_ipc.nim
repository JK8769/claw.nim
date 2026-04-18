## test_zen_ipc — Integration test for live TTML protocol.
## Forks a ZenHost child process, connects via liveMountPage,
## tests mmap writes, socket swaps, event forwarding, and unmount.

import std/[os, json, tables, posix, strutils]
import nimclaw/zen_page
import nimclaw/zen_host

const
  TestSockPath = "/tmp/test_zen_ipc.sock"
  TestDataDir = "/tmp/test_zen_ipc_data"

proc cleanup() =
  var st: Stat
  if stat(TestSockPath.cstring, st) == 0:
    try: removeFile(TestSockPath) except: discard
  if dirExists(TestDataDir):
    for f in walkDir(TestDataDir):
      try: removeFile(f.path) except: discard
    try: removeDir(TestDataDir) except: discard

# ── Host process ─────────────────────────────────────────────────

var hostRunning = true

proc runHost() =
  let host = newZenHost(sockPath = TestSockPath, dataDir = TestDataDir)
  host.start()
  echo "[host] listening on ", TestSockPath

  var sentEvent = false

  while hostRunning:
    host.poll()
    host.pollLive()

    # Once a live connection exists, send a test event after a short delay
    if not sentEvent:
      for connId, conn in host.liveConns:
        if conn.connected:
          echo "[host] sending test click event to ", connId
          host.sendEvent(connId, %*{
            "event": "click",
            "target": "run-testcorp"
          })
          sentEvent = true

    # Log any swap messages received from app
    for connId, conn in host.liveConns.mpairs:
      for msg in conn.inbound:
        echo "[host] received: ", msg{"method"}.getStr("?"), " target=", msg{"target"}.getStr("?")
      conn.inbound.setLen(0)

    sleep(10)

  host.stop()

# ── Client process ───────────────────────────────────────────────

proc runClient() =
  sleep(150)  # Let host start listening
  putEnv("ZEN_SOCK", TestSockPath)

  const testTtml = """
<Tabs id="companies" active="tab-testcorp">
  <Tab id="tab-testcorp" title="TestCorp" icon="○">
    <Row>
      <Text style="bold" color="accent">TestCorp</Text>
      <Text style="dim" color="neutral"> ○ stopped</Text>
    </Row>
    <Space/>
    <Row>
      <Button id="run-testcorp" label="Run" style="success"/>
      <Button id="stop-testcorp" label="Stop" style="warning"/>
    </Row>
    <Space/>
    <Panel title="Agents">
      <Table id="agents" cols="NAME,STATUS" mmap="true"/>
    </Panel>
    <Panel title="Activity">
      <Log id="feed" max="10" mmap="true"/>
    </Panel>
  </Tab>
</Tabs>
"""

  # ── 1. live.mount ─────────────────────────────────────────────
  echo "[client] 1. Mounting live page..."
  let page = liveMountPage("right", "NimClaw Test", testTtml)
  echo "[client]    connId: ", page.connId
  assert page.connId != "", "Should get a connId"
  assert page.mem != nil, "Should have mmap pointer"
  assert page.mem.magic == Magic, "Magic should be ZPG"
  assert page.mem.elemCount == 2, "Should have 2 mmap elements (agents + feed)"
  echo "[client]    PASS: mount OK, magic=ZPG, elemCount=2"

  # ── 2. mmap table writes ────────────────────────────────────
  echo "[client] 2. Testing mmap table writes..."
  page.setRow("agents", 0, @["Lexi", "active"])
  page.setRow("agents", 1, @["Atlas", "idle"])
  page.bumpVersion()

  let td = addr page.mem.elems[0].data.table
  assert td.rowCount == 2, "Expected 2 rows, got " & $td.rowCount
  assert getStr(td.cells[0][0]) == "Lexi"
  assert getStr(td.cells[1][0]) == "Atlas"
  assert getStr(td.cells[0][1]) == "active"
  echo "[client]    PASS: 2 rows written, data matches"

  # ── 3. mmap log writes ──────────────────────────────────────
  echo "[client] 3. Testing mmap log writes..."
  page.appendLog("feed", "07:37 web_search 230ms")
  page.appendLog("feed", "07:38 tts af_heart 3.2s")
  page.bumpVersion()

  let ld = addr page.mem.elems[1].data.log
  assert ld.count == 2, "Expected 2 log lines, got " & $ld.count
  assert getStr(ld.lines[0]) == "07:37 web_search 230ms"
  assert getStr(ld.lines[1]) == "07:38 tts af_heart 3.2s"
  echo "[client]    PASS: 2 log lines, content matches"

  # ── 4. Log wrap-around ──────────────────────────────────────
  echo "[client] 4. Testing log wrap-around..."
  page.clearLog("feed")
  for i in 0 ..< 15:
    page.appendLog("feed", "line " & $i)
  assert ld.count == 10, "Count should cap at 10, got " & $ld.count
  let maxL = ld.maxLines
  let oldest = (ld.head - ld.count + maxL) mod maxL
  assert getStr(ld.lines[oldest]) == "line 5",
    "Oldest should be 'line 5', got '" & getStr(ld.lines[oldest]) & "'"
  echo "[client]    PASS: 15 appended, 10 visible, oldest='line 5'"

  # ── 5. Socket swap ──────────────────────────────────────────
  echo "[client] 5. Testing socket swap..."
  let newTab = """<Tab id="tab-testcorp" title="TestCorp" icon="●">
    <Text style="bold">TestCorp is running</Text>
  </Tab>"""
  page.sendSwap("tab-testcorp", newTab)
  sleep(100)  # Let host poll
  echo "[client]    PASS: swap sent (host should log receipt)"

  # ── 6. Socket replace ──────────────────────────────────────
  echo "[client] 6. Testing socket replace..."
  page.sendReplace("tab-testcorp", newTab)
  sleep(100)
  echo "[client]    PASS: replace sent"

  # ── 7. Receive event from host ──────────────────────────────
  echo "[client] 7. Testing event reception..."
  sleep(200)  # Wait for host to send the click event
  var received = false
  for _ in 0 ..< 20:
    try:
      let ev = page.pollEvent()
      if ev != nil:
        echo "[client]    got event: ", ev{"event"}.getStr("?"), " target=", ev{"target"}.getStr("?")
        assert ev{"event"}.getStr() == "click"
        assert ev{"target"}.getStr() == "run-testcorp"
        received = true
        break
    except IOError:
      break
    sleep(50)
  assert received, "Should have received click event from host"
  echo "[client]    PASS: click event received"

  # ── 8. clearTable + setRows ─────────────────────────────────
  echo "[client] 8. Testing clearTable + setRows..."
  page.clearTable("agents")
  assert td.rowCount == 0, "Expected 0 rows after clear"
  page.setRows("agents", @[@["alpha", "active"], @["beta", "idle"], @["gamma", "active"]])
  assert td.rowCount == 3, "Expected 3 rows, got " & $td.rowCount
  assert getStr(td.cells[2][0]) == "gamma"
  echo "[client]    PASS: clear + setRows OK"

  # ── 9. Version tracking ────────────────────────────────────
  echo "[client] 9. Checking version..."
  let v = page.mem.version
  assert v > 0, "Version should be > 0, got " & $v
  echo "[client]    PASS: version = ", v

  # ── 10. Unmount ─────────────────────────────────────────────
  echo "[client] 10. Unmounting..."
  page.close()
  sleep(100)
  echo "[client]    PASS: unmount sent"

  echo ""
  echo "All 10 tests passed!"

# ── Main ─────────────────────────────────────────────────────────

proc main() =
  cleanup()

  let pid = fork()
  if pid == 0:
    runHost()
    quit(0)
  elif pid < 0:
    echo "fork() failed"
    quit(1)
  else:
    try:
      runClient()
    except Exception as e:
      echo "FAILED: ", e.msg
      echo e.getStackTrace()
      discard kill(pid.Pid, SIGTERM)
      cleanup()
      quit(1)

    discard kill(pid.Pid, SIGTERM)
    var status: cint
    discard waitpid(pid.Pid, status, 0)
    cleanup()

when isMainModule:
  main()
