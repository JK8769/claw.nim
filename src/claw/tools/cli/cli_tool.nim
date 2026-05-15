## CliTool — agent-authored, shell-callable tools (Tier-3 workstation tier).
##
## A CliTool wraps an executable script (any language) and exposes it as a
## first-class Tool that the agent can call. The contract:
##
##   - The script reads a JSON object on stdin (the tool args).
##   - The script writes a single string to stdout (the tool result).
##   - Non-zero exit codes return stderr concatenated with the message
##     "Error: script exited with status N".
##   - Stdout is capped at MaxResultSize (registry default).
##
## Storage layout (per agent):
##
##   <officeDir>/workstation/cli/<tool-name>/
##     ├── tool.json      ## spec: name, description, parameters JSON-schema, timeout_ms
##     └── run            ## the executable script (chmod +x)
##
## Why this design (vs ad-hoc shell calls):
##
##   - The agent gets a SCHEMA-VALIDATED parameter surface, so the LLM
##     plans against typed inputs rather than guessing flags.
##   - Forge writes the spec + script together, then the loader registers
##     it on next startup — survives gateway restarts.
##   - The same `tools method=update` path can rewrite either source
##     (script + spec) atomically, like MCP forge does for Nim sources.
##   - CLI is the LIGHTWEIGHT alternative to MCP: a 5-line bash one-liner
##     becomes a tool without compiling a Nim binary. Reserve MCP forge
##     for tools that need stateful stdin/stdout protocols.

import std/[asyncdispatch, json, tables, os, osproc, streams, strutils, times]
import ../types
import ../../logger

const
  DefaultTimeoutMs* = 30_000   ## 30s — sane default for CLI script timeouts.
  MaxStdoutBytes = 60_000      ## Hard cap to prevent runaway scripts from
                               ## blowing out the agent's context.

type
  CliTool* = ref object of Tool
    toolName*: string
    toolDescription*: string
    toolParams*: Table[string, JsonNode]
    scriptPath*: string        ## absolute path to the executable script
    timeoutMs*: int            ## per-invocation timeout in ms

proc newCliTool*(name, description, scriptPath: string,
                  params: Table[string, JsonNode],
                  timeoutMs: int = DefaultTimeoutMs): CliTool =
  CliTool(toolName: name, toolDescription: description,
          toolParams: params, scriptPath: scriptPath,
          timeoutMs: max(1_000, timeoutMs))

method name*(t: CliTool): string = t.toolName
method description*(t: CliTool): string = t.toolDescription
method parameters*(t: CliTool): Table[string, JsonNode] = t.toolParams

proc argsToJson(args: Table[string, JsonNode]): string =
  ## Serialize the args table as a JSON object so the script can parse
  ## stdin with `jq -c .` or any JSON library.
  var obj = newJObject()
  for k, v in args.pairs: obj[k] = v
  $obj

method execute*(t: CliTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not fileExists(t.scriptPath):
    return "Error: CLI tool script missing at " & t.scriptPath &
           " — was it deleted? Re-forge with `tools method=forge`."

  let payload = argsToJson(args)
  let startT = epochTime()

  # Cooperative async: poll the process so the gateway event loop keeps
  # ticking. forge.nim uses synchronous waitForExit; we don't, because a
  # 30-second script there would block heartbeats.
  var p: Process
  try:
    p = startProcess(t.scriptPath, args = @[],
                     options = {poStdErrToStdOut})
  except OSError as e:
    return "Error: failed to start CLI tool '" & t.toolName &
           "': " & e.msg

  try:
    # Trailing newline keeps `read -r` happy in bash scripts under `set -e`
    # — without it `read` returns 1 at EOF without newline and aborts the
    # script before stdin has been consumed.
    p.inputStream.write(payload & "\n")
    p.inputStream.close()
  except CatchableError as e:
    p.terminate()
    return "Error: failed to write args to CLI tool '" & t.toolName &
           "': " & e.msg

  # Poll until exit or timeout, yielding to the event loop.
  let deadline = startT + (t.timeoutMs.float / 1000.0)
  while p.running:
    if epochTime() > deadline:
      p.terminate()
      await sleepAsync(50)
      if p.running: p.kill()
      return "Error: CLI tool '" & t.toolName & "' exceeded timeout (" &
             $t.timeoutMs & "ms)"
    await sleepAsync(25)

  let exitCode = p.peekExitCode()
  var output = ""
  try:
    output = p.outputStream.readAll()
  except CatchableError: discard
  p.close()

  if output.len > MaxStdoutBytes:
    output = output[0 ..< MaxStdoutBytes] &
             "\n... [truncated, " & $(output.len - MaxStdoutBytes) &
             " bytes elided]"

  if exitCode != 0:
    infoCF("cli_tool", "CLI tool exited non-zero",
           {"name": t.toolName, "exit": $exitCode}.toTable)
    return "Error: CLI tool '" & t.toolName & "' exited with status " &
           $exitCode & "\n" & output.strip()

  output.strip()

# ── Spec persistence (tool.json on disk) ─────────────────────────────

proc cliToolBaseDir*(officeDir: string): string =
  ## All CLI tools live under <officeDir>/workstation/cli/.
  officeDir / "workstation" / "cli"

proc cliToolDir*(officeDir, toolName: string): string =
  cliToolBaseDir(officeDir) / toolName

proc readSpec*(specPath: string): JsonNode =
  ## Load tool.json. Raises CatchableError on missing/malformed.
  if not fileExists(specPath):
    raise newException(IOError, "spec missing at " & specPath)
  parseJson(readFile(specPath))

proc fromDir*(toolDir: string): CliTool =
  ## Construct a CliTool from on-disk artifacts. Used by the loader
  ## at startup and by forge after writing fresh files.
  let specPath = toolDir / "tool.json"
  let scriptPath = toolDir / "run"
  let spec = readSpec(specPath)
  let name = spec{"name"}.getStr("")
  if name.len == 0:
    raise newException(ValueError,
                       "tool.json missing 'name' at " & specPath)
  let description = spec{"description"}.getStr("(no description)")
  let timeoutMs = spec{"timeout_ms"}.getInt(DefaultTimeoutMs)
  var params = initTable[string, JsonNode]()
  let paramsNode = spec{"parameters"}
  if paramsNode.kind == JObject:
    for k, v in paramsNode.pairs: params[k] = v
  newCliTool(name, description, scriptPath, params, timeoutMs)

proc discoverCliTools*(officeDir: string): seq[CliTool] =
  ## Scan <officeDir>/workstation/cli/* and return one CliTool per
  ## valid spec directory. Malformed entries are logged and skipped.
  result = @[]
  let base = cliToolBaseDir(officeDir)
  if not dirExists(base): return
  for kind, path in walkDir(base):
    if kind != pcDir: continue
    try:
      result.add(fromDir(path))
    except CatchableError as e:
      infoCF("cli_tool", "Skipped malformed CLI tool dir",
             {"path": path, "error": e.msg}.toTable)
