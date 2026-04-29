import std/[os, osproc, json, asyncdispatch, tables, strutils, times, streams, strtabs]
when defined(posix):
  import std/posix
import regex
import types

type
  ExecTool* = ref object of Tool
    workingDir*: string
    timeout*: Duration
    denyPatterns*: seq[Regex2]
    allowPatterns*: seq[Regex2]
    restrictToWorkspace*: bool

proc newExecTool*(workingDir: string): ExecTool =
  let denyPatternsStrings = [
    r"\brm\s+-[rf]{1,2}\b",
    r"\bdel\s+/[fq]\b",
    r"\brmdir\s+/s\b",
    # Disk-format commands: require an argument that looks like a disk target
    # to avoid matching `--format markdown` style flags.
    r"(^|\s)format\s+[A-Za-z]:",    # Windows: `format C:`
    r"\bmkfs(\.\w+)?\s+/dev/",       # Linux: `mkfs /dev/...`
    r"\bdiskpart\b",
    r"\bdd\s+if=",
    r">\s*/dev/sd[a-z]\b",
    r"\b(shutdown|reboot|poweroff)\b",
    r":\(\)\s*\{.*\};\s*:"
  ]
  var denyPatterns: seq[Regex2] = @[]
  for p in denyPatternsStrings:
    denyPatterns.add(re2(p))

  ExecTool(
    workingDir: workingDir,
    timeout: initDuration(seconds = 60),
    denyPatterns: denyPatterns,
    allowPatterns: @[],
    restrictToWorkspace: false
  )

method name*(t: ExecTool): string = "exec"
method description*(t: ExecTool): string =
  "Execute a shell command and return its output. Use with caution.\n" &
  "\n" &
  "PREFER ONE COMPREHENSIVE INVOCATION OVER MANY SMALL ONES. If your task " &
  "is multi-step (e.g. data analysis: load → transform → train → validate → " &
  "report), write a single self-contained Python/bash script that performs " &
  "all steps, write it to a file with `write_file`, then run it ONCE with " &
  "`exec python3 path.py`. Do NOT call exec 20 times to incrementally " &
  "edit, probe, and re-run — each call costs an iteration toward the agent " &
  "loop's max-iter cap, and the cap will stop you mid-task. The agent " &
  "loop has a hard ceiling (typically 40 tool calls per turn); spending " &
  "30 of them on individual `cat`/`echo`/single-line python invocations " &
  "leaves no budget for the actual work and the loop force-summarises " &
  "without ever reaching the answer.\n" &
  "\n" &
  "Note: stdin to the child is closed immediately after spawn — commands " &
  "that read from stdin (`cat` with no args, `read`, `less`, etc.) get " &
  "EOF instead of hanging. Pass input via files or here-strings inside " &
  "the command if needed."
method parameters*(t: ExecTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "command": {
        "type": "string",
        "description": "The shell command to execute"
      },
      "working_dir": {
        "type": "string",
        "description": "Optional working directory for the command"
      }
    },
    "required": %["command"]
  }.toTable

proc guardCommand(t: ExecTool, command, cwd: string): string =
  let lower = command.toLowerAscii
  for pattern in t.denyPatterns:
    if lower.contains(pattern):
      return "Command blocked by safety guard (dangerous pattern detected)"

  if t.allowPatterns.len > 0:
    var allowed = false
    for pattern in t.allowPatterns:
      if lower.contains(pattern):
        allowed = true
        break
    if not allowed:
      return "Command blocked by safety guard (not in allowlist)"

  if t.restrictToWorkspace:
    if command.contains("..\\") or command.contains("../"):
      return "Command blocked by safety guard (path traversal detected)"
    # More strict path check could be added here

  return ""

const SAFE_ENV_VARS = [
  "PATH", "HOME", "TERM", "LANG", "LC_ALL", "LC_CTYPE", "USER", "SHELL", "TMPDIR", "PWD"
]

proc normalizeCommandInput*(command: string): string =
  let trimmed = command.strip()
  if trimmed.startsWith("```") and trimmed.endsWith("```"):
    let lines = trimmed.splitLines()
    if lines.len >= 2:
      # Return everything between the first and last line
      var inner = lines[1 .. ^2].join("\n").strip()
      if inner.len > 0: return inner
  return trimmed

method execute*(t: ExecTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("command"): return "Error: command is required"

  # `command` must be a string (shell command). On JObject/JArray, getStr() would
  # silently return "", `sh -c ""` would succeed, and the tool would produce the
  # useless "(no output)" — breaking the agent's recovery. Reject with guidance.
  let cmdNode = args["command"]
  if cmdNode.kind != JString:
    return "Error: 'command' must be a string, got " & $cmdNode.kind &
           ". If you need to pass structured data to a CLI, stringify it " &
           "first, or use a dedicated tool if one exists for that domain."
  if cmdNode.getStr().strip().len == 0:
    return "Error: 'command' is empty. Pass the shell command to run."

  let rawCommand = cmdNode.getStr()
  let command = normalizeCommandInput(rawCommand)
  
  var cwd = t.workingDir
  if args.hasKey("working_dir") and args["working_dir"].getStr() != "":
    cwd = args["working_dir"].getStr()

  if cwd == "":
    cwd = getCurrentDir()

  let guardErr = t.guardCommand(command, cwd)
  if guardErr != "":
    return "Error: " & guardErr

  # Build a safe environment string table
  var safeEnv = newStringTable(modeCaseSensitive)
  for key in SAFE_ENV_VARS:
    if existsEnv(key):
      safeEnv[key] = getEnv(key)

  var p = startProcess("/bin/sh", workingDir = cwd, args = ["-c", command], env = safeEnv, options = {poStdErrToStdOut})

  # Close the parent side of the child's stdin pipe so any command that
  # reads from stdin (`cat`, `read`, `less`, etc.) gets immediate EOF
  # rather than blocking forever on input that will never arrive. The
  # exec tool has no way to pipe input to the child, so leaving stdin
  # open just creates a deadlock surface.
  try: p.inputStream.close()
  except CatchableError: discard

  # Make the child's stdout fd non-blocking so the polling loop can
  # actually re-check the timeout between reads. With blocking reads,
  # `readStr(1024)` waits for data the child may never produce — the
  # whole loop deadlocks in the first iteration and `t.timeout` never
  # gets evaluated. Non-blocking lets us drain whatever's available
  # and yield back to the loop body each tick.
  when defined(posix):
    let outFd = p.outputHandle.cint
    let flags = fcntl(outFd, F_GETFL)
    if flags >= 0:
      discard fcntl(outFd, F_SETFL, flags or O_NONBLOCK)

  proc drainAvailable(output: var string) =
    when defined(posix):
      var buf = newString(4096)
      while true:
        let n = read(outFd, buf[0].addr, 4096)
        if n > 0:
          output.add(buf[0 ..< n])
        else:
          break  # 0 = EOF, -1 = EAGAIN/EWOULDBLOCK or real error
    else:
      let data = p.outputStream.readStr(4096)
      if data != "": output.add(data)

  let startTime = now()
  var output = ""

  while p.running:
    if (now() - startTime) > t.timeout:
      p.terminate()
      drainAvailable(output)
      return "Error: Command timed out after " & $t.timeout &
             (if output.len > 0: " — output so far:\n" & output else: "")
    drainAvailable(output)
    await sleepAsync(50)

  # Final drain after the child has exited.
  drainAvailable(output)
  let exitCode = p.peekExitCode()
  p.close()

  if exitCode != 0:
    output.add("\nExit code: " & $exitCode)

  if output == "":
    output = "(no output)"

  let maxLen = 10000
  if output.len > maxLen:
    output = output[0 ..< maxLen] & "\n... (truncated, " & $(output.len - maxLen) & " more chars)"

  return output
