## Playwright browser automation tool via @playwright/cli.
## Single tool with a `command` parameter — same pattern as lark_cli.
## Replaces the MCP-based approach (21 individual pw_* tools) with a
## token-efficient CLI designed for AI agents.

import std/[asyncdispatch, json, tables, strutils, os, osproc, times, streams]
import regex
import types

type
  PlaywrightTool* = ref object of Tool
    npxPath: string
    workDir: string  # Where .playwright-cli/ artifacts are stored
    timeout: Duration

proc findNpx(): string =
  result = findExe("npx")

proc newPlaywrightTool*(workDir: string): PlaywrightTool =
  PlaywrightTool(
    npxPath: findNpx(),
    workDir: workDir,
    timeout: initDuration(seconds = 60)
  )

method name*(t: PlaywrightTool): string = "playwright"

method description*(t: PlaywrightTool): string =
  "Browser automation via Playwright CLI. Use this for all web interactions.\n\n" &
  "Commands:\n" &
  "  open [url]                 Open browser (optionally navigate to URL)\n" &
  "  goto <url>                 Navigate to a URL\n" &
  "  snapshot [element]         Capture accessibility tree (use this to see page)\n" &
  "  screenshot [target]        Take a screenshot\n" &
  "  click <target>             Click an element (use ref from snapshot, e.g. 'click e5')\n" &
  "  type <text>                Type text into focused element\n" &
  "  fill <target> <text>       Fill text into an input (e.g. 'fill e12 \"password\"')\n" &
  "  select <target> <value>    Select dropdown option\n" &
  "  hover <target>             Hover over element\n" &
  "  press <key>                Press keyboard key (Enter, Tab, etc.)\n" &
  "  eval <js>                  Evaluate JavaScript expression\n" &
  "  network                    List network requests since page load\n" &
  "  console                    List console messages\n" &
  "  cookie-list                List all cookies\n" &
  "  localstorage-list          List localStorage entries\n" &
  "  state-save [file]          Save auth state (cookies+storage) to file\n" &
  "  state-load <file>          Load auth state from file\n" &
  "  tracing-start              Start recording trace + network log\n" &
  "  tracing-stop               Stop tracing (saves to .playwright-cli/traces/)\n" &
  "  tab-list                   List open tabs\n" &
  "  tab-new [url]              Open new tab\n" &
  "  tab-close [index]          Close a tab\n" &
  "  close                      Close the browser\n" &
  "\nElement refs: snapshot shows 'textbox \"User\" [ref=e12]' → use bare ID: 'fill e12 \"myuser\"'\n" &
  "\n## RULES (mandatory)\n" &
  "1. **VERIFY EVERY ACTION**: After EVERY click, fill, or navigation, call `snapshot` to see the result. NEVER assume an action succeeded — check the page.\n" &
  "2. **Report failures**: If a login fails, form submission shows an error, or a page doesn't load, report the EXACT error text from the snapshot to the user.\n" &
  "3. **Never claim success without proof**: Before saying 'done' or 'success', you MUST have a snapshot showing the expected result.\n" &
  "\nWorkflow:\n" &
  "1. open <url> → snapshot → interact (click/fill/type) → snapshot to verify\n" &
  "2. For login: open → snapshot → fill username → fill password → click login → **snapshot to check result** → report success or error\n" &
  "3. To capture API calls: tracing-start BEFORE the action, then do the action, then\n" &
  "   snapshot (wait for page to load), THEN tracing-stop. Read the .network file after.\n" &
  "4. To persist login: state-save after login, state-load before future sessions\n" &
  "5. After completing the task, ALWAYS reply to the user with results. Do not just stop.\n" &
  "\nFiles saved to .playwright-cli/ in workspace."

method parameters*(t: PlaywrightTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "command": {
        "type": "string",
        "description": "The playwright-cli command and arguments (e.g. 'goto https://example.com', 'click e5', 'fill e12 \"mypassword\"', 'snapshot')"
      }
    },
    "required": %["command"]
  }.toTable

proc sanitizeRefs(command: string): string =
  ## Strip [ref=eN] wrappers to bare eN — LLMs often copy the snapshot format literally.
  ## e.g. 'fill [ref=e64] "password"' → 'fill e64 "password"'
  result = command.replace(re2"\[ref=(e\d+)\]", "$1")
  # Also handle ref=eN without brackets
  result = result.replace(re2"\bref=(e\d+)\b", "$1")

proc parseShellArgs(s: string): seq[string] =
  ## Splits a command string into arguments, respecting double and single quotes.
  result = @[]
  var i = 0
  var current = ""
  while i < s.len:
    let c = s[i]
    if c in {'"', '\''}:
      let quote = c
      inc i
      while i < s.len and s[i] != quote:
        if s[i] == '\\' and i + 1 < s.len and s[i + 1] == quote:
          current.add(quote)
          i += 2
        else:
          current.add(s[i])
          inc i
      if i < s.len: inc i  # skip closing quote
    elif c in {' ', '\t'}:
      if current.len > 0:
        result.add(current)
        current = ""
      inc i
    else:
      current.add(c)
      inc i
  if current.len > 0:
    result.add(current)

method execute*(t: PlaywrightTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  var command = ""
  if args.hasKey("command"):
    command = args["command"].getStr().strip()
  # Handle LLM splitting args across multiple keys
  for key in ["subcommand", "action"]:
    if args.hasKey(key):
      let v = args[key].getStr().strip()
      if v.len > 0: command = command & " " & v
  for key in ["args", "arguments", "params", "url", "target", "text"]:
    if args.hasKey(key):
      let v = args[key].getStr().strip()
      if v.len > 0: command = command & " " & v
  command = command.strip()

  if command.len == 0:
    return "Error: command cannot be empty. Example: 'goto https://example.com'"

  if t.npxPath.len == 0:
    return "Error: npx not found. Install Node.js to use playwright."

  # Fix common LLM mistakes: [ref=e64] → e64
  command = sanitizeRefs(command)

  let cmdArgs = @["@playwright/cli"] & parseShellArgs(command)

  try:
    let p = startProcess(t.npxPath, workingDir = t.workDir, args = cmdArgs,
                         options = {poUsePath, poStdErrToStdOut})
    let startTime = now()
    var output = ""

    while p.running:
      if (now() - startTime) > t.timeout:
        p.terminate()
        discard p.waitForExit(3000)
        p.close()
        return "Error: command timed out after " & $(t.timeout.inSeconds) & "s"
      let chunk = p.outputStream.readStr(4096)
      if chunk.len > 0:
        output.add(chunk)
      await sleepAsync(50)

    # Read remaining output
    output.add(p.outputStream.readAll())
    let code = p.peekExitCode()
    p.close()

    if code != 0:
      return "Error (exit " & $code & "): " & output.strip()

    let result = output.strip()
    if result.len == 0:
      return "Command completed successfully (no output)"

    return result
  except Exception as e:
    return "Error executing playwright-cli: " & e.msg
