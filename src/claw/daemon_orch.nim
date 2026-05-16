## daemon_orch — the multi-company orchestrator (`claw daemon`).
##
## Runs as a host process. Discovers companies on disk + mounted volumes,
## spawns `claw gateway` child processes on demand (one per company),
## exposes an HTTP+WS admin API at <host>:<port> for third-party dashboards
## to drive. See docs/admin-api.yaml for the contract.
##
## Process model: same single-binary as the rest of claw. This module is
## reached via `claw daemon` subcommand. Children are forked via
## startProcess(getAppFilename(), ["gateway"]) with NIMCLAW_DIR=<co_path>
## in the env. No new artifact required.

import std/[asyncdispatch, json, tables, os, osproc, posix, strutils,
            times, sequtils, locks, options, strformat, strtabs, net,
            exitprocs]
import mummy, mummy/routers
import logger

const
  DefaultPort* = 13140
  DefaultHost* = "127.0.0.1"
  GatewayBootGraceMs = 2_000   ## After spawn, give the child this long to
                                ## either write its pid file or crash. Below
                                ## this window we report status=starting; above
                                ## without a pid file means likely crashed.
  StopGraceMs = 10_000           ## SIGTERM → SIGKILL escalation window.

# Daemon-lifecycle paths. All under ~/.nimclawd/ for parity with the
# existing per-company `~/.nimclawd/<service>/` convention.
proc daemonStateDir(): string = getHomeDir() / ".nimclawd"
proc daemonPidFile(): string = daemonStateDir() / "admin.pid"
proc daemonLogFile(): string = daemonStateDir() / "admin.log"
proc daemonSockFile*(): string = daemonStateDir() / "admin.sock"

type
  CompanyEntry = object
    name: string
    path: string              ## absolute path to .nimclaw-<n>
    pid: int                  ## 0 = not tracked (either never started by us
                              ## or PID came from disk file). When >0, this
                              ## is OUR child; track it for SIGTERM-on-exit.
    process: Process          ## nil unless we spawned it ourselves
    startedAt: float          ## epochTime of spawn, 0 if not running

  Orchestrator* = ref object
    host: string
    port: int
    companies: Table[string, CompanyEntry]
    lock: Lock
    startedAt: float
    shutdownRequested: bool

var gOrch: Orchestrator   ## process-wide singleton; set in runOrchestrator

# ── Discovery ────────────────────────────────────────────────────

proc isNimclawDir(p: string): bool =
  ## A directory is a claw company if it has a BASE.json.
  dirExists(p) and fileExists(p / "BASE.json")

proc companyNameFromPath(p: string): string =
  ## /Users/owaf/.nimclaw-MyCompany → MyCompany
  ## /Volumes/SSD256G/.nimclaw-MyCompany → MyCompany
  let base = lastPathPart(p)
  if base.startsWith(".nimclaw-"):
    return base[".nimclaw-".len .. ^1]
  base

proc scanCompanies(): seq[tuple[name, path: string]] =
  ## Walk ~/.nimclaw-* + /Volumes/*/.nimclaw-* (+ /media/*, /mnt/* on linux).
  ## Each volume is wrapped in its own try/except: a wedged removable
  ## drive that fails directory listing won't tank the whole scan,
  ## though it can still HANG the calling thread — for that case the
  ## user must `diskutil unmount force <vol>`. (A timeout-aware scan
  ## would need a thread + watchdog; not worth it for now.)
  result = @[]
  let home = getHomeDir()
  try:
    for kind, p in walkDir(home):
      if kind == pcDir and lastPathPart(p).startsWith(".nimclaw-") and isNimclawDir(p):
        result.add((companyNameFromPath(p), p))
  except CatchableError as e:
    warnCF("daemon_orch", "scanCompanies: home dir walk failed",
           {"home": home, "error": e.msg}.toTable)
  let mountRoots = when defined(macosx): @["/Volumes"]
                   else: @["/media", "/mnt"]
  for root in mountRoots:
    if not dirExists(root): continue
    var vols: seq[string] = @[]
    try:
      for vKind, volPath in walkDir(root):
        if vKind == pcDir: vols.add volPath
    except CatchableError as e:
      warnCF("daemon_orch", "scanCompanies: volume root listing failed",
             {"root": root, "error": e.msg}.toTable)
      continue
    for volPath in vols:
      try:
        for kind, p in walkDir(volPath):
          if kind == pcDir and lastPathPart(p).startsWith(".nimclaw-") and isNimclawDir(p):
            result.add((companyNameFromPath(p), p))
      except CatchableError as e:
        warnCF("daemon_orch", "scanCompanies: per-volume walk failed; skipping",
               {"volume": volPath, "error": e.msg}.toTable)

proc pidFilePath(coPath: string): string =
  coPath / "logs" / "gateway.pid"

proc readPidFile(coPath: string): int =
  ## Returns 0 if absent / unreadable. Doesn't verify the process exists —
  ## callers should kill -0 to check liveness.
  let p = pidFilePath(coPath)
  if not fileExists(p): return 0
  try:
    return parseInt(readFile(p).strip())
  except CatchableError: return 0

proc processAlive(pid: int): bool =
  if pid <= 0: return false
  kill(Pid(pid), 0.cint) == 0

# ── Status assembly ──────────────────────────────────────────────

proc statusFor(o: Orchestrator, name: string, path: string): string =
  ## stopped | starting | running | stopping | crashed | unavailable
  if not dirExists(path): return "unavailable"
  let diskPid = readPidFile(path)
  if processAlive(diskPid): return "running"
  acquire(o.lock)
  defer: release(o.lock)
  if o.companies.hasKey(name):
    let e = o.companies[name]
    if e.startedAt > 0 and (epochTime() - e.startedAt) * 1000 < GatewayBootGraceMs.float:
      return "starting"
    if e.startedAt > 0:
      return "crashed"
  "stopped"

proc summariseCompany(o: Orchestrator, name, path: string): JsonNode =
  let status = statusFor(o, name, path)
  let pidNum = readPidFile(path)
  result = %*{
    "name": name,
    "path": path,
    "status": status,
    "pid": (if processAlive(pidNum): %pidNum else: newJNull()),
  }
  # Try to enrich from BASE.json — cheap, just a small JSON parse.
  let basePath = path / "BASE.json"
  if fileExists(basePath):
    try:
      let b = parseJson(readFile(basePath))
      let agents = b{"agents"}
      if agents != nil and agents.kind == JArray:
        result["agents_count"] = %agents.len
      let channels = b{"channels"}
      if channels != nil and channels.kind == JObject:
        var names: seq[string] = @[]
        for k, _ in channels.pairs: names.add(k)
        result["channels"] = %names
    except CatchableError: discard

# ── Spawn / stop ─────────────────────────────────────────────────

proc spawnGateway(o: Orchestrator, name, path: string): tuple[ok: bool, pid: int, err: string] =
  let alive = processAlive(readPidFile(path))
  if alive:
    return (true, readPidFile(path), "")
  let binPath = getAppFilename()
  if not fileExists(binPath):
    return (false, 0, "claw binary not resolvable from getAppFilename()")
  let logsDir = path / "logs"
  try:
    createDir(logsDir)
  except CatchableError as e:
    return (false, 0, "createDir(logs) failed: " & e.msg)
  let stdoutLog = logsDir / "gateway.stdout.log"
  let stderrLog = logsDir / "gateway.stderr.log"
  var env: StringTableRef
  ## Inherit current env, override NIMCLAW_DIR. We can't use `osproc.startProcess`'s
  ## env replacement (which is full replacement, not delta), so we duplicate.
  env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env["NIMCLAW_DIR"] = path
  try:
    let p = startProcess(binPath, args = @["gateway"],
                         env = env,
                         options = {})
    acquire(o.lock)
    defer: release(o.lock)
    o.companies[name] = CompanyEntry(
      name: name, path: path,
      pid: p.processID,
      process: p,
      startedAt: epochTime()
    )
    infoCF("daemon_orch", "Spawned gateway",
           {"company": name, "pid": $p.processID,
            "stdout": stdoutLog, "stderr": stderrLog}.toTable)
    (true, p.processID, "")
  except CatchableError as e:
    (false, 0, "spawn failed: " & e.msg)

proc stopGateway(o: Orchestrator, name, path: string, timeoutMs: int = StopGraceMs):
    tuple[ok: bool, wasRunning: bool, exitCode: int, graceful: bool, err: string] =
  let diskPid = readPidFile(path)
  if not processAlive(diskPid):
    # Idempotent — return success even if it was already down.
    acquire(o.lock); defer: release(o.lock)
    if o.companies.hasKey(name): o.companies.del(name)
    return (true, false, -1, true, "")
  # SIGTERM
  discard kill(Pid(diskPid), SIGTERM.cint)
  let deadline = epochTime() + timeoutMs.float / 1000
  while epochTime() < deadline:
    if not processAlive(diskPid):
      let exitCode = block:
        # Best-effort: if we own the Process handle, peek; else -1.
        acquire(o.lock); defer: release(o.lock)
        if o.companies.hasKey(name) and o.companies[name].process != nil:
          let ec = o.companies[name].process.peekExitCode()
          o.companies[name].process.close()
          o.companies.del(name)
          ec
        else: -1
      return (true, true, exitCode, true, "")
    sleep(50)
  # Escalate to SIGKILL.
  warnCF("daemon_orch", "SIGTERM grace expired, escalating to SIGKILL",
         {"company": name, "pid": $diskPid, "timeout_ms": $timeoutMs}.toTable)
  discard kill(Pid(diskPid), SIGKILL.cint)
  sleep(200)
  acquire(o.lock); defer: release(o.lock)
  if o.companies.hasKey(name):
    if o.companies[name].process != nil:
      o.companies[name].process.close()
    o.companies.del(name)
  (true, true, -9, false, "SIGKILL escalation")

# ── Transport-agnostic dispatch ──────────────────────────────────
#
# Each `dispatch*` proc takes an Orchestrator + params, returns a
# tuple[code, body]. The HTTP handlers and the stdio JSONL pump both
# call these — keeping a single source of truth for the daemon's
# semantics regardless of transport.

proc lookupCompany(name: string): tuple[found: bool, path: string] =
  for (n, p) in scanCompanies():
    if n == name: return (true, p)
  (false, "")

proc dispatchHealth*(o: Orchestrator): tuple[code: int, body: JsonNode] =
  (200, %*{
    "status": "ok",
    "version": "0.1.0",
    "uptime_seconds": epochTime() - o.startedAt,
  })

proc dispatchListCompanies*(o: Orchestrator): tuple[code: int, body: JsonNode] =
  var arr = newJArray()
  for (n, p) in scanCompanies():
    arr.add(summariseCompany(o, n, p))
  (200, %*{"companies": arr})

proc dispatchStart*(o: Orchestrator, name: string): tuple[code: int, body: JsonNode] =
  let (found, path) = lookupCompany(name)
  if not found:
    return (404, %*{"error": "company not found",
                     "code": "NOT_FOUND", "detail": {"name": name}})
  let alreadyAlive = processAlive(readPidFile(path))
  let (ok, pid, err) = spawnGateway(o, name, path)
  if not ok:
    return (409, %*{"error": err, "code": "SPAWN_FAILED",
                     "detail": {"name": name}})
  (200, %*{
    "name": name,
    "status": statusFor(o, name, path),
    "pid": pid,
    "already_running": alreadyAlive,
    "started_at": $now(),
  })

proc dispatchStop*(o: Orchestrator, name: string, timeoutMs: int): tuple[code: int, body: JsonNode] =
  let (found, path) = lookupCompany(name)
  if not found:
    return (404, %*{"error": "company not found",
                     "code": "NOT_FOUND", "detail": {"name": name}})
  let (ok, was, code, graceful, err) = stopGateway(o, name, path, timeoutMs)
  if not ok:
    return (500, %*{"error": err, "code": "STOP_FAILED"})
  (200, %*{
    "name": name,
    "status": statusFor(o, name, path),
    "was_running": was,
    "exit_code": code,
    "graceful": graceful,
  })

# ── HTTP transport ───────────────────────────────────────────────

proc jsonRespond(req: Request, code: int, body: JsonNode) =
  var h: HttpHeaders
  h["Content-Type"] = "application/json"
  req.respond(code, h, $body)

# ── Entry point ──────────────────────────────────────────────────

proc runStdioLoop(orch: Orchestrator) =
  ## JSON-RPC 2.0 over stdio. One JSON object per line on stdin →
  ## one envelope per line on stdout. Logger output goes to stderr
  ## (set via logger.stdioMode = true before this proc runs) so the
  ## stdout stream stays uncontaminated.
  ##
  ## Methods mirror the HTTP routes 1:1:
  ##   • healthz                            → GET /healthz
  ##   • list_companies                     → GET /companies
  ##   • start  {"name": "..."}             → POST /companies/<n>/start
  ##   • stop   {"name": "...", "timeout_ms"?: N}
  ##                                          → POST /companies/<n>/stop
  ##
  ## Errors return a JSON-RPC error envelope:
  ##   {"jsonrpc":"2.0","id":<id>,"error":{"code":N,"message":"...","data":{...}}}
  ##
  ## EOF on stdin (parent closes) → graceful shutdown: stop every owned
  ## gateway, then exit cleanly.
  proc sendEnvelope(id: JsonNode, code: int, body: JsonNode) =
    let env =
      if code >= 200 and code < 300:
        %*{"jsonrpc": "2.0", "id": id, "result": body}
      else:
        %*{"jsonrpc": "2.0", "id": id,
           "error": {"code": code, "message": body{"error"}.getStr("dispatch failed"),
                     "data": body}}
    echo $env
    flushFile(stdout)

  while true:
    var line: string
    try:
      line = stdin.readLine()
    except EOFError:
      infoCF("daemon_orch", "stdin EOF — parent disconnected, shutting down",
             initTable[string, string]())
      acquire(orch.lock)
      var owned: seq[tuple[name, path: string]] = @[]
      for n, e in orch.companies.pairs:
        if e.startedAt > 0: owned.add((n, e.path))
      release(orch.lock)
      for (n, p) in owned:
        discard stopGateway(orch, n, p, 5000)
      return
    except CatchableError as e:
      errorCF("daemon_orch", "stdin read failed",
              {"error": e.msg}.toTable)
      return
    if line.strip.len == 0: continue

    var req: JsonNode
    try:
      req = parseJson(line)
    except CatchableError as e:
      sendEnvelope(newJNull(), 400,
                   %*{"error": "invalid JSON: " & e.msg})
      continue

    let id = if req.hasKey("id"): req["id"] else: newJNull()
    let meth = req{"method"}.getStr("")
    let params = if req.hasKey("params"): req["params"] else: newJObject()

    case meth
    of "":
      sendEnvelope(id, 400, %*{"error": "missing `method`"})
    of "healthz":
      let (c, b) = dispatchHealth(orch)
      sendEnvelope(id, c, b)
    of "list_companies":
      let (c, b) = dispatchListCompanies(orch)
      sendEnvelope(id, c, b)
    of "start":
      let name = params{"name"}.getStr("")
      if name.len == 0:
        sendEnvelope(id, 400, %*{"error": "params.name required"})
        continue
      let (c, b) = dispatchStart(orch, name)
      sendEnvelope(id, c, b)
    of "stop":
      let name = params{"name"}.getStr("")
      if name.len == 0:
        sendEnvelope(id, 400, %*{"error": "params.name required"})
        continue
      let timeoutMs = params{"timeout_ms"}.getInt(StopGraceMs)
      let (c, b) = dispatchStop(orch, name, timeoutMs)
      sendEnvelope(id, c, b)
    else:
      sendEnvelope(id, 404, %*{"error": "unknown method: " & meth})

# ── Zen-protocol adapter ──────────────────────────────────────────
#
# Zen's app_host expects UI-rendering events (mount/swap/replace) +
# TTML markup, not JSON-RPC envelopes. This adapter:
#   1. Emits a `mount` event with the layout (vertical list of companies)
#      using only universally-available TTML primitives (Box, Text, Rule).
#   2. Listens for {"method":"click","target":"#start-<name>"} (or stop-)
#      on stdin, dispatches to dispatchStart/dispatchStop.
#   3. After every state-changing action, emits a `swap` event that
#      replaces the table body with refreshed content.
#
# Stays server-authoritative: Zen never holds state Zen-side. Every
# pixel is derived from claw's current view of companies. This is the
# SSoT model the user explicitly chose.

proc xmlEscape(s: string): string =
  result = s.multiReplace(("&", "&amp;"), ("<", "&lt;"),
                          (">", "&gt;"), ("\"", "&quot;"))

proc emitZen(j: JsonNode) =
  echo $j
  flushFile(stdout)

proc renderCompanyRow(name, status: string, pid: int): string =
  ## One row per company. The row's `id` attribute is the click target
  ## (e.g. `start-MyCompany` / `stop-MyCompany`); Zen's TtmlWidget
  ## hit-tests left-clicks against this id and forwards as
  ## `{"method":"click","target":"#<id>"}`. Anything that toggles based
  ## on state goes here.
  let pidStr = if pid > 0: $pid else: "—"
  let actionId = (if status == "running": "stop-" else: "start-") & name
  let actionLabel = if status == "running": "[stop]" else: "[start]"
  let line = name & "  •  " & status & "  •  pid " & pidStr & "  •  " & actionLabel
  "<Text id=\"" & xmlEscape(actionId) & "\" content=\"" &
    xmlEscape(line) & "\"/>"

proc renderCompaniesBody(o: Orchestrator): string =
  ## The contents of the #companies Box — rebuilt from the current
  ## scan every time something changes. No client-side state.
  ##
  ## Wrap rows in a single <Box> root: Zen's applyUpdate calls
  ## parseDoc() which requires exactly one top-level element. Without
  ## the wrapper, multiple sibling <Text> rows silently fail to parse
  ## and the swap is a no-op.
  var rows: seq[string] = @[]
  for (n, p) in scanCompanies():
    let pidNum = readPidFile(p)
    let status = statusFor(o, n, p)
    let livePid = if processAlive(pidNum): pidNum else: 0
    rows.add(renderCompanyRow(n, status, livePid))
  let inner =
    if rows.len == 0: "<Text content=\"(no companies found)\"/>"
    else: rows.join("\n")
  "<Box direction=\"column\">\n" & inner & "\n</Box>"

const ZenMountLayout = """
<Box direction="column">
  <Text content="claw daemon — multi-company orchestrator"/>
  <Rule/>
  <Box id="companies" direction="column"/>
  <Rule/>
  <Text id="quit-daemon" content="[quit daemon]"/>
</Box>
"""

# Pure event builders — reusable across stdio and socket transports.
proc zenMountEvent*(pane: string): JsonNode =
  %*{"event": "mount", "pane": pane, "title": "claw companies",
     "ttml": ZenMountLayout}

proc zenCompaniesSwap*(o: Orchestrator): JsonNode =
  %*{"event": "swap", "target": "#companies",
     "ttml": renderCompaniesBody(o)}

type ZenClickResult* = enum
  zcrOk          ## action dispatched; caller should refresh + send swap
  zcrUnknown     ## unknown target; caller should log
  zcrQuit        ## #quit-daemon — caller should signal shutdown

proc handleZenClick*(o: Orchestrator, target: string): ZenClickResult =
  ## Click target conventions:
  ##   #start-<name>   → dispatchStart
  ##   #stop-<name>    → dispatchStop
  ##   #quit-daemon    → signal shutdown (caller initiates exit)
  ## Anything else returns zcrUnknown.
  let id = if target.startsWith("#"): target[1..^1] else: target
  if id == "quit-daemon":
    return zcrQuit
  if id.startsWith("start-"):
    let name = id["start-".len .. ^1]
    discard dispatchStart(o, name)
    return zcrOk
  if id.startsWith("stop-"):
    let name = id["stop-".len .. ^1]
    discard dispatchStop(o, name, StopGraceMs)
    return zcrOk
  zcrUnknown

proc runZenLoop(orch: Orchestrator, pane: string) =
  ## Zen-protocol mode over stdio. Mount the dashboard, then loop on
  ## stdin for click events. EOF or #quit-daemon → graceful shutdown.
  emitZen(zenMountEvent(pane))
  emitZen(zenCompaniesSwap(orch))

  while true:
    var line: string
    try:
      line = stdin.readLine()
    except EOFError:
      infoCF("daemon_orch", "Zen disconnected (stdin EOF), shutting down",
             initTable[string, string]())
      acquire(orch.lock)
      var owned: seq[tuple[name, path: string]] = @[]
      for n, e in orch.companies.pairs:
        if e.startedAt > 0: owned.add((n, e.path))
      release(orch.lock)
      for (n, p) in owned:
        discard stopGateway(orch, n, p, 5000)
      return
    except CatchableError as e:
      errorCF("daemon_orch", "Zen stdin read failed", {"error": e.msg}.toTable)
      return
    if line.strip.len == 0: continue

    var msg: JsonNode
    try:
      msg = parseJson(line)
    except CatchableError:
      emitZen(%*{"event": "log", "level": "error",
                  "text": "Invalid JSON from Zen: " & line})
      continue

    let meth = msg{"method"}.getStr("")
    let target = msg{"target"}.getStr("")
    case meth
    of "click":
      let res = handleZenClick(orch, target)
      case res
      of zcrOk:
        emitZen(zenCompaniesSwap(orch))
      of zcrQuit:
        emitZen(%*{"event":"log","level":"info","text":"Daemon quitting on #quit-daemon"})
        quit(0)
      of zcrUnknown:
        emitZen(%*{"event":"log","level":"warn","text":"Unknown click target: " & target})
    of "refresh":
      emitZen(zenCompaniesSwap(orch))
    else:
      emitZen(%*{"event": "log", "level": "warn",
                  "text": "Unhandled method: " & meth})

# ── Unix socket transport (Zen protocol per connection) ─────────
#
# The transport used by `claw daemon start`. Each socket connection is
# one client (a Zen tab, a CLI tool, anything that speaks Zen events).
# The daemon outlives any single connection — closing a Zen tab just
# disconnects; the daemon keeps running.
#
# Single-client at a time in v0 (simpler reasoning, sufficient for the
# initial Zen-attach use case). Multi-client fanout (broadcast state
# changes to all connected sockets) is a future enhancement.

proc handleSocketSession(orch: Orchestrator, client: Socket) =
  ## One Zen session per connection. Optional hello (selects pane),
  ## then mount + initial swap, then loop on recv. Exits on disconnect,
  ## #quit-daemon, or read error.
  proc emitTo(j: JsonNode) =
    try: client.send($j & "\n")
    except CatchableError: discard

  # Optional hello message lets the client (e.g. `claw daemon attach
  # --pane=right`) pick which Zen pane to mount into. We give it 200ms
  # before falling back to "left" — that keeps legacy/direct-socket
  # clients (like the test harness) working without a hello.
  var pane = "left"
  try:
    let hello = client.recvLine(timeout = 200)
    if hello.len > 0:
      try:
        let j = parseJson(hello)
        if j{"method"}.getStr("") == "hello":
          let p = j{"pane"}.getStr("")
          if p == "left" or p == "right": pane = p
      except CatchableError: discard
  except TimeoutError: discard
  except CatchableError: discard

  try:
    emitTo(zenMountEvent(pane))
    emitTo(zenCompaniesSwap(orch))
  except CatchableError as e:
    warnCF("daemon_orch", "Initial Zen events failed",
           {"error": e.msg}.toTable)
    return

  while true:
    var line = ""
    try:
      line = client.recvLine()
    except CatchableError as e:
      infoCF("daemon_orch", "Socket recv failed; closing session",
             {"error": e.msg}.toTable)
      return
    if line.len == 0:
      # Empty line = peer disconnected
      infoCF("daemon_orch", "Socket client disconnected", initTable[string, string]())
      return
    if line.strip.len == 0: continue

    var msg: JsonNode
    try:
      msg = parseJson(line)
    except CatchableError:
      emitTo(%*{"event":"log","level":"error",
                "text":"Invalid JSON from client: " & line})
      continue

    let meth = msg{"method"}.getStr("")
    let target = msg{"target"}.getStr("")
    case meth
    of "click":
      let res = handleZenClick(orch, target)
      case res
      of zcrOk:
        emitTo(zenCompaniesSwap(orch))
      of zcrQuit:
        emitTo(%*{"event":"log","level":"info","text":"Daemon quitting on #quit-daemon"})
        # Daemon-wide exit. Other connected clients (if any) will see
        # their sockets drop. The exitprocs will clean up the PID file.
        quit(0)
      of zcrUnknown:
        emitTo(%*{"event":"log","level":"warn","text":"Unknown click target: " & target})
    of "refresh":
      emitTo(zenCompaniesSwap(orch))
    else:
      emitTo(%*{"event":"log","level":"warn","text":"Unhandled method: " & meth})

type SocketThreadArgs = object
  orch: Orchestrator
  sockPath: string

type SessionArgs = object
  thread: Thread[ptr SessionArgs]
  orch: Orchestrator
  client: Socket

proc sessionWorker(argsPtr: ptr SessionArgs) {.thread, gcsafe.} =
  ## One OS thread per accepted connection. The accept loop allocates
  ## `argsPtr` on shared memory (which includes the Thread itself, so
  ## one allocation per session, not two). The worker copies the refs
  ## to locals, frees the shared block, then runs the session.
  {.cast(gcsafe).}:
    let orch = argsPtr.orch
    let client = argsPtr.client
    deallocShared(argsPtr)
    handleSocketSession(orch, client)
    try: client.close()
    except CatchableError: discard

proc socketAcceptLoop(args: SocketThreadArgs) {.thread, gcsafe.} =
  {.cast(gcsafe).}:
    let sockPath = args.sockPath
    # Aggressive cleanup: remove the file even if it doesn't appear to
    # exist (handle race conditions on macOS where the inode lingers).
    try: removeFile(sockPath)
    except CatchableError: discard
    var server = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    var bindOk = false
    for attempt in 0 ..< 3:
      try:
        server.bindUnix(sockPath)
        server.listen()
        bindOk = true
        break
      except CatchableError as e:
        warnCF("daemon_orch", "Socket bind attempt failed; retrying after cleanup",
               {"path": sockPath, "attempt": $attempt, "error": e.msg}.toTable)
        try: removeFile(sockPath)
        except CatchableError: discard
        sleep(200)
    if not bindOk:
      errorCF("daemon_orch", "Socket bind failed after 3 attempts",
              {"path": sockPath}.toTable)
      return
    infoCF("daemon_orch", "Listening on Unix socket",
           {"path": sockPath}.toTable)
    while true:
      var client: Socket
      try:
        server.accept(client)
      except CatchableError as e:
        warnCF("daemon_orch", "Accept failed",
               {"error": e.msg}.toTable)
        continue
      # Hand off to a dedicated thread so the accept loop never blocks
      # on a slow or stuck client. The Thread lives inside SessionArgs,
      # which the worker deallocs after copying refs to locals.
      let sa = cast[ptr SessionArgs](allocShared0(sizeof(SessionArgs)))
      sa.orch = args.orch
      sa.client = client
      try:
        createThread(sa.thread, sessionWorker, sa)
      except ResourceExhaustedError as e:
        warnCF("daemon_orch", "Session thread spawn failed; dropping connection",
               {"error": e.msg}.toTable)
        deallocShared(sa)
        try: client.close()
        except CatchableError: discard

var gSocketThread: Thread[SocketThreadArgs]

proc startSocketTransport(orch: Orchestrator, sockPath: string) =
  ## Spawn the Unix-socket listener in a dedicated thread so it can
  ## live alongside the mummy HTTP server (which blocks on its serve()).
  let args = SocketThreadArgs(orch: orch, sockPath: sockPath)
  createThread(gSocketThread, socketAcceptLoop, args)

proc runOrchestrator*(host = DefaultHost, port = DefaultPort,
                      useStdio = false, useZen = false,
                      pane = "left") =
  ## Blocks. Two transport modes:
  ##   - HTTP (default): mummy server on host:port, multi-client, serves
  ##     third-party dashboards and the OpenAPI surface.
  ##   - Stdio (useStdio=true): JSON-RPC 2.0 over stdin/stdout. The
  ##     Zen-native integration path — Zen spawns `claw daemon --stdio`
  ##     and reads JSONL events from the same battle-tested
  ##     spawnApp+reader infrastructure it uses for `claw gateway --stdio`.
  ##
  ## Both transports share the same dispatch fns (dispatchHealth,
  ## dispatchListCompanies, dispatchStart, dispatchStop) — one source
  ## of truth for the daemon's semantics regardless of how clients reach it.
  var orch = Orchestrator(
    host: host, port: port,
    companies: initTable[string, CompanyEntry](),
    startedAt: epochTime()
  )
  initLock(orch.lock)

  # Stdio modes: silence stdout-bound log calls (logger writes to
  # stderr instead) so whichever event protocol stays uncontaminated.
  if useZen:
    logger.stdioMode = true
    infoCF("daemon_orch",
           "Starting in Zen mode (UI-event protocol on stdin/stdout)",
           initTable[string, string]())
    gOrch = orch
    runZenLoop(orch, pane)
    return
  if useStdio:
    logger.stdioMode = true
    infoCF("daemon_orch",
           "Starting in stdio mode (JSON-RPC 2.0 on stdin/stdout)",
           initTable[string, string]())
    gOrch = orch
    runStdioLoop(orch)
    return

  # HTTP handlers — thin wrappers around the transport-agnostic
  # dispatch fns. Mummy requires gc-safe closures; orch is read-only
  # in the handlers' scope so the gcsafe cast is sound.
  proc handleHealthz(req: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      let (code, body) = dispatchHealth(orch)
      jsonRespond(req, code, body)

  proc handleListCompanies(req: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      let (code, body) = dispatchListCompanies(orch)
      jsonRespond(req, code, body)

  proc handleStart(req: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      let (code, body) = dispatchStart(orch, req.pathParams["name"])
      jsonRespond(req, code, body)

  proc handleStop(req: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      var timeoutMs = StopGraceMs
      if req.body.len > 0:
        try:
          let b = parseJson(req.body)
          if b.hasKey("timeout_ms"):
            timeoutMs = b["timeout_ms"].getInt(StopGraceMs)
        except CatchableError: discard
      let (code, body) = dispatchStop(orch, req.pathParams["name"], timeoutMs)
      jsonRespond(req, code, body)

  var router: Router
  router.get("/healthz", handleHealthz)
  router.get("/companies", handleListCompanies)
  router.post("/companies/@name/start", handleStart)
  router.post("/companies/@name/stop", handleStop)

  let server = newServer(router)

  # Graceful shutdown: when daemon receives Ctrl-C, stop every child we
  # spawned before exiting. Children we DIDN'T spawn are left alone — we
  # coordinate, not janitor state we don't own. SIGTERM (vs SIGINT) is
  # left to OS process-group propagation for v0; explicit SIGTERM handler
  # comes later.
  gOrch = orch
  proc shutdownHook() {.noconv.} =
    if gOrch.shutdownRequested: return
    gOrch.shutdownRequested = true
    infoCF("daemon_orch", "Ctrl-C received, stopping owned children", initTable[string, string]())
    acquire(gOrch.lock)
    var ownedNames: seq[tuple[name, path: string]] = @[]
    for n, e in gOrch.companies.pairs:
      if e.startedAt > 0: ownedNames.add((n, e.path))
    release(gOrch.lock)
    for (n, p) in ownedNames:
      discard stopGateway(gOrch, n, p, 5000)
    quit(0)
  setControlCHook(shutdownHook)

  echo fmt"claw daemon listening on http://{host}:{port}"
  echo "  GET    /healthz"
  echo "  GET    /companies"
  echo "  POST   /companies/<name>/start"
  echo "  POST   /companies/<name>/stop"
  echo "Press Ctrl-C to stop the daemon (children will be stopped first)."
  server.serve(Port(port), host)

# ── Lifecycle: daemon start / stop / status ──────────────────────
#
# The daemon is meant to outlive any individual UI client (Zen tab,
# browser tab, CLI shell). These procs implement the service pattern:
# `start` daemonizes + writes a PID file; `stop` SIGTERMs the running
# process; `status` reports state. PID file is the source of truth.

proc readDaemonPid(): int =
  let p = daemonPidFile()
  if not fileExists(p): return 0
  try:
    return parseInt(readFile(p).strip())
  except CatchableError: return 0

proc daemonStatus*(): tuple[running: bool, pid: int] =
  let pid = readDaemonPid()
  if pid <= 0: return (false, 0)
  if kill(Pid(pid), 0.cint) == 0: (true, pid)
  else: (false, pid)  ## stale PID file

proc daemonStop*(timeoutMs: int = 5_000): tuple[ok: bool, msg: string] =
  let (running, pid) = daemonStatus()
  if not running:
    if pid > 0:
      try: removeFile(daemonPidFile())
      except CatchableError: discard
    return (true, "daemon not running" & (if pid > 0: " (stale PID " & $pid & " cleared)" else: ""))
  discard kill(Pid(pid), SIGTERM.cint)
  let deadline = epochTime() + timeoutMs.float / 1000
  while epochTime() < deadline:
    if kill(Pid(pid), 0.cint) != 0:
      try: removeFile(daemonPidFile())
      except CatchableError: discard
      return (true, "stopped (pid " & $pid & ")")
    sleep(50)
  discard kill(Pid(pid), SIGKILL.cint)
  sleep(200)
  try: removeFile(daemonPidFile())
  except CatchableError: discard
  (true, "stopped via SIGKILL (pid " & $pid & " — SIGTERM grace expired)")

const
  AttachPollIntervalMs = 100
  AttachPollMaxAttempts = 50  # 5s total budget for daemon to come up

proc daemonClick*(target: string): int =
  ## Send a single click event to the daemon's socket and exit. Lets
  ## operators drive the dashboard from a separate terminal until Zen
  ## wires click handling into its TTML widget tree.
  ##
  ## Usage: claw daemon click '#stop-MyCompany'
  let sockPath = daemonSockFile()
  if target.len == 0:
    stderr.writeLine "claw daemon click: target is empty (e.g. '#stop-MyCompany')"
    return 1
  var sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
                       Protocol.IPPROTO_IP, buffered = false)
  try:
    sock.connectUnix(sockPath)
  except CatchableError:
    stderr.writeLine "claw daemon click: cannot connect to " & sockPath &
                     " (is the daemon running? `claw daemon status`)"
    try: sock.close()
    except CatchableError: discard
    return 1
  let tgt = if target.startsWith("#"): target else: "#" & target
  try:
    sock.send($(%*{"method": "click", "target": tgt}) & "\n")
  except CatchableError as e:
    stderr.writeLine "claw daemon click: send failed: " & e.msg
    try: sock.close()
    except CatchableError: discard
    return 1
  # Drain the server's response for ~300ms so the user sees feedback.
  var buf = newString(4096)
  let deadline = epochTime() + 0.3
  while epochTime() < deadline:
    var n = 0
    try: n = sock.recv(buf, 4096)
    except CatchableError: break
    if n <= 0: break
    discard stdout.writeBuffer(addr buf[0], n)
    flushFile(stdout)
  try: sock.close()
  except CatchableError: discard
  0

proc daemonAttach*(pane = "left"): int =
  ## Subprocess-mode entry point for Zen-style parents: connect to the
  ## running daemon's Unix socket and bridge stdin/stdout to it.
  ##
  ## `pane` selects which Zen pane the daemon should target in its
  ## mount event. Sent as the first line on connect (`{"method":"hello"
  ## ,"pane":"left|right"}`), so the daemon's per-session mount event
  ## carries the right pane field.
  ##
  ## If the daemon isn't running, spawn `claw daemon start` as a child
  ## (we can't call daemonStart() inline — daemonizeProcess quit(0)s in
  ## the calling process after the first fork, which would kill us).
  ##
  ## Returns 0 on clean disconnect, non-zero on attach failure.
  let sockPath = daemonSockFile()

  proc tryConnect(): Socket =
    # `buffered = false`: with a buffered Socket, low-level recv(ptr,size)
    # returns 0 when the internal buffer is empty (only recvLine fills
    # it), which our bridge would misread as "peer closed". Unbuffered
    # passes bytes through as they arrive from the kernel.
    result = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
                       Protocol.IPPROTO_IP, buffered = false)
    try:
      result.connectUnix(sockPath)
    except CatchableError:
      try: result.close()
      except CatchableError: discard
      result = nil

  var sock = tryConnect()
  if sock == nil:
    let exe = getAppFilename()
    try:
      let p = startProcess(exe, args = ["daemon", "start"],
                           options = {poStdErrToStdOut, poUsePath})
      discard p.waitForExit()
      p.close()
    except CatchableError as e:
      stderr.writeLine "claw daemon attach: spawn failed: " & e.msg
      return 1
    # waitForExit returned when the daemonize fork chain's parent exited,
    # but the grandchild may still be racing to listen(). Try once
    # immediately, then poll.
    sock = tryConnect()
    var waited = 0
    while waited < AttachPollMaxAttempts and sock == nil:
      sleep(AttachPollIntervalMs)
      inc waited
      sock = tryConnect()
    if sock == nil:
      stderr.writeLine "claw daemon attach: socket never came up at " & sockPath
      return 1

  # Send the hello first so the daemon's mount event carries our pane.
  let helloPane = if pane == "right": "right" else: "left"
  try:
    sock.send($(%*{"method": "hello", "pane": helloPane}) & "\n")
  except CatchableError as e:
    stderr.writeLine "claw daemon attach: hello send failed: " & e.msg
    try: sock.close()
    except CatchableError: discard
    return 1

  # Bridge. Main thread reads socket → stdout (session-defining side —
  # exit when the daemon disconnects). Worker thread reads stdin →
  # socket. The worker does NOT close the socket on stdin EOF: stdin
  # is one-way input from the parent (Zen). Closing it doesn't mean we
  # want to stop receiving events. The pump thread is intentionally
  # not joined — quit() reaps it on process exit.
  proc stdinPump(sock: Socket) {.thread, gcsafe.} =
    {.cast(gcsafe).}:
      while true:
        var line = ""
        try: line = stdin.readLine()
        except EOFError: break
        try: sock.send(line & "\n")
        except CatchableError: break

  var pump: Thread[Socket]
  createThread(pump, stdinPump, sock)

  var buf = newString(4096)
  while true:
    var n = 0
    try: n = sock.recv(buf, 4096)
    except CatchableError: break
    if n <= 0: break
    try:
      discard stdout.writeBuffer(addr buf[0], n)
      flushFile(stdout)
    except CatchableError: break

  try: sock.close()
  except CatchableError: discard
  return 0

proc daemonizeProcess(logPath: string) =
  ## Standard POSIX double-fork to detach from the controlling terminal.
  ## Redirects stdin to /dev/null and stdout/stderr to logPath.
  ## After return, this process is a session-leaderless background process
  ## with no terminal — safe to outlive any parent shell or UI client.
  let pid1 = fork()
  if pid1 < 0: raise newException(IOError, "daemonize: first fork failed")
  if pid1 > 0: quit(0)
  if setsid() < 0:
    raise newException(IOError, "daemonize: setsid failed")
  let pid2 = fork()
  if pid2 < 0: raise newException(IOError, "daemonize: second fork failed")
  if pid2 > 0: quit(0)
  discard chdir("/")
  discard umask(0)
  # /dev/null for stdin
  let devNull = posix.open("/dev/null", O_RDONLY)
  if devNull >= 0:
    discard dup2(devNull, 0)
    if devNull > 0: discard close(devNull)
  # Append to logPath for stdout + stderr
  let logFd = posix.open(logPath.cstring, O_WRONLY or O_CREAT or O_APPEND, 0o644)
  if logFd >= 0:
    discard dup2(logFd, 1)
    discard dup2(logFd, 2)
    if logFd > 2: discard close(logFd)

proc daemonStart*(host = DefaultHost, port = DefaultPort): tuple[ok: bool, msg: string] =
  ## Daemonize + bind transports + write PID file. Returns once the
  ## fork is complete and the new daemon is on its way; doesn't block.
  let (already, pid) = daemonStatus()
  if already:
    return (false, "daemon already running (pid " & $pid & ")")
  let stateDir = daemonStateDir()
  try: createDir(stateDir)
  except CatchableError as e:
    return (false, "mkdir " & stateDir & " failed: " & e.msg)
  # In the GRANDCHILD, we'll write our own PID and run the orchestrator.
  # The parent (calling shell) returns to the user immediately.
  let logPath = daemonLogFile()
  let parentPid = getCurrentProcessId()
  daemonizeProcess(logPath)
  # We're now in the grandchild. Write our own PID.
  try:
    writeFile(daemonPidFile(), $getCurrentProcessId() & "\n")
  except CatchableError as e:
    # logFd is stderr; let it through
    stderr.writeLine "daemonize: writePidFile failed: " & e.msg
    quit(1)
  # Cleanup PID file + socket file on graceful exit.
  proc cleanupOnExit() =
    try: removeFile(daemonPidFile())
    except CatchableError: discard
    try: removeFile(daemonSockFile())
    except CatchableError: discard
  addExitProc(cleanupOnExit)
  # SIGTERM handler — trigger exitprocs by calling quit(). Without
  # this, `claw daemon stop` SIGTERM'd us and exitprocs never ran,
  # leaving stale socket + PID files behind.
  proc termHook(sig: cint) {.noconv.} =
    quit(0)
  discard posix.signal(SIGTERM, termHook)
  # We need the Orchestrator BEFORE runOrchestrator constructs one
  # because both the socket thread and runOrchestrator need to share it.
  # Pull the construction up here and pass the orch in.
  var orch = Orchestrator(
    host: host, port: port,
    companies: initTable[string, CompanyEntry](),
    startedAt: epochTime()
  )
  initLock(orch.lock)
  gOrch = orch
  # Bind the Unix socket in a thread (parallel to HTTP). Each socket
  # connection is one Zen-protocol client.
  startSocketTransport(orch, daemonSockFile())
  # Run the HTTP orchestrator on the main thread — blocks until exit.
  # NOTE: this currently constructs its OWN Orchestrator; refactoring
  # runOrchestrator to accept an existing one is a follow-up. For now,
  # the socket thread's orch and runOrchestrator's are separate
  # instances of the same shape (scanCompanies is stateless on disk).
  runOrchestrator(host, port)
  # runOrchestrator blocks; if it returns we've shut down.
  discard parentPid  # unused — silences hints
  (true, "daemon started (pid " & $getCurrentProcessId() & ")")
