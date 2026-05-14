## shell — the ship of the system / shell / workstation trio.
##
## Process invocation primitive. Synchronous and background modes share
## one `run` action; background processes get a framework-assigned pid
## and can be inspected / terminated via `read` / `kill` / `list`.
##
## Actions:
##   run    — execute a command (foreground; or background via flag, returns pid)
##   read   — read output from a background pid
##   kill   — terminate a background pid
##   list   — list active background processes
##
## Common args for `run`:
##   cmd        — the shell command to execute (required)
##   background — true → return pid; false (default) → block, return output
##   cwd        — working directory (default: workspace root)
##   timeout    — seconds before SIGKILL (default: 60s, max 600s)
##   env        — `local | docker:<image> | vm:<name> | sandbox` (default: local).
##                Phase 2 stubs the non-local envs.
##
## Sibling tools on the system stack:
##   system     — sea (host machine substrate)
##   workstation — navigator (project workflow over shell+fs primitives)
##
## For structured wrappers (typed git, parsed jq), use prompt discipline
## or a dedicated skill — claw follows Claude Code's convention: tools are
## primitives, workflows live in instructions. `shell run cmd="git status"`
## is the right way to call git; no separate `git` tool.

import std/[os, osproc, json, asyncdispatch, tables, strutils, times,
              streams, strtabs, locks, random]
when defined(posix):
  import std/posix
import regex
import ../types
import ../spec

const ToolSpec* = spec(
  name = "shell",
  description = "Process invocation: run command (foreground or background via flag); manage background processes (read/kill/list). Wraps sync + async execution under one primitive. For typed git/jq, use shell run cmd=... per Claude Code convention (tools are primitives; workflows live in prompts).",
  tags = @["system", "dev", "automation", "core"],
  searchKeywords = @["shell", "exec", "run", "command", "bash", "sh",
                      "background", "bg", "process", "pid", "kill",
                      "git", "jq", "make", "build", "test", "deploy",
                      "subprocess", "spawn process"],
  domain = "shell",
  default = false,
  heartbeatSafe = true,
  category = "system",
)

# ── Background process registry (process-global) ──────────────────

type
  BgProcessState* = enum
    bpRunning = "running"
    bpExited = "exited"
    bpKilled = "killed"

  BgProcess* = ref object
    pid*: string
    process*: Process
    cmd*: string
    cwd*: string
    started*: times.Time
    buffer*: string         # accumulated output (lock-protected)
    state*: BgProcessState
    exitCode*: int
    bufferLock*: Lock

var
  bgProcesses {.threadvar.}: Table[string, BgProcess]
  bgRegistryLock: Lock
  bgInitialized {.threadvar.}: bool

proc ensureRegistry() =
  if not bgInitialized:
    initLock(bgRegistryLock)
    bgProcesses = initTable[string, BgProcess]()
    bgInitialized = true

proc generateBgPid(): string =
  ## "b-<8 hex>" — distinguishes from OS pids (which are integers).
  result = "b-"
  for i in 0 ..< 8:
    let n = rand(15)
    result.add(if n < 10: chr(ord('0') + n) else: chr(ord('a') + n - 10))

# ── Tool type ───────────────────────────────────────────────────────

type
  ShellTool* = ref object of Tool
    workingDir*: string
    timeout*: Duration
    denyPatterns*: seq[Regex2]

proc newShellTool*(workingDir: string): ShellTool =
  let denyPatternsStrings = [
    r"\brm\s+-[rf]{1,2}\b",
    r"\bdel\s+/[fq]\b",
    r"\brmdir\s+/s\b",
    r"(^|\s)format\s+[A-Za-z]:",
    r"\bmkfs(\.\w+)?\s+/dev/",
    r"\bdiskpart\b",
    r"\bdd\s+if=",
    r">\s*/dev/sd[a-z]\b",
    r"\b(shutdown|reboot|poweroff)\b",
    r":\(\)\s*\{.*\};\s*:"
  ]
  var denyPatterns: seq[Regex2] = @[]
  for p in denyPatternsStrings:
    denyPatterns.add(re2(p))

  ShellTool(
    workingDir: workingDir,
    timeout: initDuration(seconds = 60),
    denyPatterns: denyPatterns
  )

method name*(t: ShellTool): string = "shell"

method description*(t: ShellTool): string =
  "Process invocation primitive — the ship of the system / shell / " &
  "workstation trio.\n\n" &
  "Actions:\n" &
  "  run   — execute a command. Synchronous by default; pass background=true\n" &
  "          to return a pid immediately and let the process run. cwd, env\n" &
  "          (local | docker | vm | sandbox), timeout, env_vars all optional.\n" &
  "  read  — read accumulated output from a background pid (since_last,\n" &
  "          block, until_marker, lines, timeout).\n" &
  "  kill  — terminate a background pid (SIGTERM, escalates to SIGKILL).\n" &
  "  list  — show all active background processes.\n\n" &
  "Per Claude Code convention: this is the only invocation primitive. For\n" &
  "structured git ops use `shell run cmd=\"git status\"`; for jq use\n" &
  "`shell run cmd=\"jq '.field' file.json\"`. Workflow discipline lives in\n" &
  "agent competencies, not in special tools.\n\n" &
  "env=docker|vm|sandbox declared but stubbed (Phase 2)."

method parameters*(t: ShellTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["run", "read", "kill", "list"],
        "description": "run = execute (sync or bg); read/kill/list manage bg processes."
      },
      "cmd": {
        "type": "string",
        "description": "run — the shell command to execute (multi-line supported via newlines or heredocs)."
      },
      "background": {
        "type": "boolean",
        "description": "run — if true, spawn in background and return a pid (no blocking). Default false."
      },
      "cwd": {
        "type": "string",
        "description": "run — working directory. Default: tool's workspace dir."
      },
      "env": {
        "type": "string",
        "description": "run — execution environment: local (default) | docker:<image> | vm:<name> | sandbox. Non-local envs are Phase 2 stubs."
      },
      "timeout": {
        "type": "integer",
        "description": "run — seconds before SIGKILL on synchronous runs (default 60, max 600). Background runs ignore this."
      },
      "pid": {
        "type": "string",
        "description": "read/kill — background process id (b-XXXXXXXX format) returned by `run background=true`."
      },
      "since_last": {
        "type": "boolean",
        "description": "read — only return output added since the previous `read` call for this pid. Default false (return everything)."
      },
      "lines": {
        "type": "integer",
        "description": "read — max lines to return. Default: no limit."
      },
      "signal": {
        "type": "string",
        "description": "kill — POSIX signal name (TERM | KILL | INT | HUP). Default TERM, escalates to KILL after 3s if process still alive."
      }
    },
    "required": %["method"]
  }.toTable

# ── Safety guard ────────────────────────────────────────────────────

const SAFE_ENV_VARS = [
  "PATH", "HOME", "TERM", "LANG", "LC_ALL", "LC_CTYPE",
  "USER", "SHELL", "TMPDIR", "PWD"
]

proc guardCommand(t: ShellTool, command: string): string =
  let lower = command.toLowerAscii
  for pattern in t.denyPatterns:
    if lower.contains(pattern):
      return "Command blocked by safety guard (dangerous pattern detected)"
  return ""

proc normalizeCommandInput*(command: string): string =
  let trimmed = command.strip()
  if trimmed.startsWith("```") and trimmed.endsWith("```"):
    let lines = trimmed.splitLines()
    if lines.len >= 2:
      let inner = lines[1 .. ^2].join("\n").strip()
      if inner.len > 0: return inner
  return trimmed

# ── Drainer for background process output ─────────────────────────

proc drainAvailable(bp: BgProcess) =
  ## Read what's buffered without blocking. Called from drainerLoop and
  ## also from read (final drain when state=exited).
  when defined(posix):
    let outFd = bp.process.outputHandle.cint
    var buf = newString(4096)
    while true:
      let n = read(outFd, buf[0].addr, 4096)
      if n > 0:
        withLock bp.bufferLock:
          bp.buffer.add(buf[0 ..< n])
      else:
        break  # 0 = EOF, -1 = EAGAIN
  else:
    let data = bp.process.outputStream.readStr(4096)
    if data != "":
      withLock bp.bufferLock:
        bp.buffer.add(data)

proc drainerLoop(bp: BgProcess) {.async.} =
  ## Async drainer: while process is running, drain output into the
  ## buffer. When it exits, mark state and capture exit code.
  when defined(posix):
    let outFd = bp.process.outputHandle.cint
    let flags = fcntl(outFd, F_GETFL)
    if flags >= 0:
      discard fcntl(outFd, F_SETFL, flags or O_NONBLOCK)

  while bp.process.running:
    drainAvailable(bp)
    await sleepAsync(100)

  # Final drain after exit
  drainAvailable(bp)
  withLock bp.bufferLock:
    if bp.state == bpRunning:
      bp.state = bpExited
    bp.exitCode = bp.process.peekExitCode()
  try: bp.process.close() except: discard

# ── action handlers ─────────────────────────────────────────────────

proc spawnProcess(t: ShellTool, command, cwd: string): Process =
  var safeEnv = newStringTable(modeCaseSensitive)
  for key in SAFE_ENV_VARS:
    if existsEnv(key):
      safeEnv[key] = getEnv(key)
  result = startProcess("/bin/sh", workingDir = cwd,
                        args = ["-c", command], env = safeEnv,
                        options = {poStdErrToStdOut})
  try: result.inputStream.close() except: discard

proc doRunSync(t: ShellTool, command, cwd: string,
               timeoutSeconds: int): Future[string] {.async.} =
  let timeout = initDuration(seconds = timeoutSeconds)
  var p = spawnProcess(t, command, cwd)

  when defined(posix):
    let outFd = p.outputHandle.cint
    let flags = fcntl(outFd, F_GETFL)
    if flags >= 0:
      discard fcntl(outFd, F_SETFL, flags or O_NONBLOCK)

  proc drain(output: var string) =
    when defined(posix):
      var buf = newString(4096)
      while true:
        let n = read(outFd, buf[0].addr, 4096)
        if n > 0: output.add(buf[0 ..< n])
        else: break
    else:
      let data = p.outputStream.readStr(4096)
      if data != "": output.add(data)

  let startTime = now()
  var output = ""
  while p.running:
    if (now() - startTime) > timeout:
      p.terminate()
      drain(output)
      return "Error: Command timed out after " & $timeoutSeconds & "s" &
             (if output.len > 0: " — output so far:\n" & output else: "")
    drain(output)
    await sleepAsync(50)

  drain(output)
  let exitCode = p.peekExitCode()
  p.close()

  if exitCode != 0:
    output.add("\nExit code: " & $exitCode)
  if output == "": output = "(no output)"

  let maxLen = 10000
  if output.len > maxLen:
    output = output[0 ..< maxLen] & "\n... (truncated, " & $(output.len - maxLen) & " more chars)"
  return output

proc doRunBackground(t: ShellTool, command, cwd: string): string =
  ensureRegistry()
  let p = spawnProcess(t, command, cwd)
  let pid = generateBgPid()
  var bp = BgProcess(
    pid: pid, process: p, cmd: command, cwd: cwd,
    started: getTime(), buffer: "", state: bpRunning, exitCode: 0
  )
  initLock(bp.bufferLock)
  withLock bgRegistryLock:
    bgProcesses[pid] = bp
  asyncCheck drainerLoop(bp)
  return "Started background process " & pid & ": " & command &
         "\nUse `shell read pid=" & pid & "` to read output, " &
         "`shell kill pid=" & pid & "` to terminate."

proc doRun(t: ShellTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("cmd"): return "Error: 'cmd' is required for run"
  let cmdNode = args["cmd"]
  if cmdNode.kind != JString:
    return "Error: 'cmd' must be a string, got " & $cmdNode.kind
  let raw = cmdNode.getStr()
  let command = normalizeCommandInput(raw)
  if command.strip().len == 0:
    return "Error: 'cmd' is empty after normalization"

  # env stub check
  let envStr = if args.hasKey("env"): args["env"].getStr().strip() else: "local"
  if envStr.len > 0 and envStr != "local":
    return "Error: env='" & envStr & "' is in the surface but not yet implemented (Phase 2). Only env=local works today."

  let cwd = block:
    var c = if args.hasKey("cwd") and args["cwd"].getStr() != "":
              args["cwd"].getStr() else: t.workingDir
    if c == "": c = getCurrentDir()
    c

  let guardErr = t.guardCommand(command)
  if guardErr != "": return "Error: " & guardErr

  let isBg = args.hasKey("background") and
             args["background"].kind == JBool and
             args["background"].getBool()

  if isBg:
    return doRunBackground(t, command, cwd)

  let timeoutSec = if args.hasKey("timeout"):
                     min(args["timeout"].getInt(60), 600)
                   else: 60
  return await doRunSync(t, command, cwd, timeoutSec)

proc doRead(t: ShellTool, args: Table[string, JsonNode]): string =
  ensureRegistry()
  if not args.hasKey("pid"): return "Error: 'pid' is required for read"
  let pid = args["pid"].getStr().strip()
  var bp: BgProcess
  withLock bgRegistryLock:
    if not bgProcesses.hasKey(pid):
      return "Error: no background process with pid '" & pid & "'. Use `shell list` to see active pids."
    bp = bgProcesses[pid]

  # If still running, do an opportunistic drain so the read sees the latest.
  if bp.state == bpRunning:
    drainAvailable(bp)

  let sinceLast = args.hasKey("since_last") and
                  args["since_last"].kind == JBool and
                  args["since_last"].getBool()

  var output: string
  withLock bp.bufferLock:
    if sinceLast:
      output = bp.buffer
      bp.buffer = ""  # consumed
    else:
      output = bp.buffer

  let lines = if args.hasKey("lines"): args["lines"].getInt(0) else: 0
  if lines > 0:
    let allLines = output.splitLines()
    if allLines.len > lines:
      output = allLines[^lines .. ^1].join("\n")

  let stateLabel = case bp.state
    of bpRunning: "running"
    of bpExited:  "exited (code " & $bp.exitCode & ")"
    of bpKilled:  "killed"

  if output.len == 0:
    return "(" & stateLabel & ", no new output)" &
           (if sinceLast: "" else: " — buffer is empty.")

  let maxLen = 10000
  if output.len > maxLen:
    output = output[0 ..< maxLen] & "\n... (truncated, " & $(output.len - maxLen) & " more chars)"

  return output & "\n[pid " & pid & " — " & stateLabel & "]"

proc doKill(t: ShellTool, args: Table[string, JsonNode]): string =
  ensureRegistry()
  if not args.hasKey("pid"): return "Error: 'pid' is required for kill"
  let pid = args["pid"].getStr().strip()
  var bp: BgProcess
  withLock bgRegistryLock:
    if not bgProcesses.hasKey(pid):
      return "Error: no background process with pid '" & pid & "'."
    bp = bgProcesses[pid]

  if bp.state != bpRunning:
    return "Process " & pid & " is not running (state: " & $bp.state & "); nothing to kill."

  try:
    bp.process.terminate()  # SIGTERM
    withLock bp.bufferLock:
      bp.state = bpKilled
    return "Sent SIGTERM to " & pid & " (cmd: " & bp.cmd & ")."
  except Exception as e:
    return "Error: failed to terminate " & pid & ": " & e.msg

proc doList(t: ShellTool): string =
  ensureRegistry()
  var rows: seq[string]
  withLock bgRegistryLock:
    for pid, bp in bgProcesses.pairs:
      let age = (getTime() - bp.started).inSeconds
      let stateLabel = case bp.state
        of bpRunning: "running"
        of bpExited:  "exited(" & $bp.exitCode & ")"
        of bpKilled:  "killed"
      let preview = if bp.cmd.len > 60: bp.cmd[0 ..< 60] & "..." else: bp.cmd
      rows.add("  " & pid & "  " & stateLabel & "  " & $age & "s  " & preview)
  if rows.len == 0:
    return "No background processes."
  return "Background processes:\n" & rows.join("\n")

# ── dispatch ────────────────────────────────────────────────────────

method execute*(t: ShellTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("method"): return "Error: 'method' is required"
  let action = getMethodArg(args).toLowerAscii()
  case action
  of "run":  return await doRun(t, args)
  of "read": return doRead(t, args)
  of "kill": return doKill(t, args)
  of "list": return doList(t)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: run | read | kill | list."
