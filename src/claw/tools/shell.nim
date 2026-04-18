import std/[os, osproc, json, asyncdispatch, tables, strutils, times, streams, strtabs]
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
method description*(t: ExecTool): string = "Execute a shell command and return its output. Use with caution."
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
  
  let rawCommand = args["command"].getStr()
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
  let startTime = now()
  var output = ""

  # Simple polling for timeout and reading output without blocking
  while p.running:
    if (now() - startTime) > t.timeout:
      p.terminate()
      return "Error: Command timed out after " & $t.timeout

    # Read available data from stream
    let data = p.outputStream.readStr(1024)
    if data != "":
      output.add(data)

    await sleepAsync(50)

  # Final read
  output.add(p.outputStream.readAll())
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
