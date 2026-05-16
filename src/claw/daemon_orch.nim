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
            times, sequtils, locks, options, strformat, strtabs]
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
  result = @[]
  let home = getHomeDir()
  for kind, p in walkDir(home):
    if kind == pcDir and lastPathPart(p).startsWith(".nimclaw-") and isNimclawDir(p):
      result.add((companyNameFromPath(p), p))
  let mountRoots = when defined(macosx): @["/Volumes"]
                   else: @["/media", "/mnt"]
  for root in mountRoots:
    if not dirExists(root): continue
    for vKind, volPath in walkDir(root):
      if vKind != pcDir: continue
      for kind, p in walkDir(volPath):
        if kind == pcDir and lastPathPart(p).startsWith(".nimclaw-") and isNimclawDir(p):
          result.add((companyNameFromPath(p), p))

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

proc runOrchestrator*(host = DefaultHost, port = DefaultPort,
                      useStdio = false) =
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

  # Stdio mode: silence stdout-bound log calls so the JSONL stream
  # stays clean. Then run the JSON-RPC loop and return when stdin EOFs.
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
