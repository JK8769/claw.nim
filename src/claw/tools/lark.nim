import std/[asyncdispatch, json, tables, strutils, os, osproc, strtabs, times, streams]
import types
import ../channels/feishu as feishu_channel
import ../config

type
  LarkCliTool* = ref object of ContextualTool
    larkCliBin*: string
    defaultConfigDir*: string
    timeout*: Duration

proc newLarkCliTool*(): LarkCliTool =
  let bin = feishu_channel.findLarkCli()
  # Use first configured feishu app's config dir as default
  var defaultDir = ""
  let nimclawDir = getNimClawDir()
  let feishuDir = nimclawDir / "channels" / "feishu"
  if dirExists(feishuDir):
    for kind, path in walkDir(feishuDir):
      if kind == pcDir and path.extractFilename.startsWith("lark-cli-"):
        if fileExists(path / "config.json"):
          defaultDir = path
          break
  LarkCliTool(
    larkCliBin: bin,
    defaultConfigDir: defaultDir,
    timeout: initDuration(seconds = 60)
  )

const BlockedCommands = [
  "im +messages-send",
  "im +messages-reply",
]

proc isBlockedCommand(command: string): bool =
  let lower = command.strip().toLowerAscii()
  for blocked in BlockedCommands:
    if lower.startsWith(blocked):
      return true
  false

method name*(t: LarkCliTool): string = "lark_cli"
method description*(t: LarkCliTool): string =
  "Execute Feishu/Lark platform operations via lark-cli. " &
  "Use this for docs, sheets, calendar, tasks, mail, drive, wiki, contacts, and other Feishu workspace actions. " &
  "Do NOT use this for sending chat messages — use the 'reply' or 'message' tool instead.\n\n" &
  "Available commands:\n" &
  "  docs +create --title T --markdown M    Create a document\n" &
  "  docs +fetch --doc URL                  Fetch document content\n" &
  "  docs +update --doc URL --markdown M    Update a document\n" &
  "  docs +search --query Q                 Search docs/wiki\n" &
  "  sheets +create --title T               Create spreadsheet\n" &
  "  sheets +read --sheet-id ID --range R   Read cells\n" &
  "  sheets +append --sheet-id ID ...       Append rows\n" &
  "  sheets +write --sheet-id ID ...        Write cells\n" &
  "  calendar +agenda                       View today's agenda\n" &
  "  calendar +create --title T --start S   Create event\n" &
  "  task +create --title T                 Create task\n" &
  "  task +get-my-tasks                     List my tasks\n" &
  "  contact +search-user --query Q         Search users\n" &
  "  contact +get-user                      Get user info\n" &
  "  mail +triage                           List mail\n" &
  "  mail +send --to T --subject S          Send email\n" &
  "  drive +upload --file F                 Upload file\n" &
  "  drive +download --file-token T         Download file\n" &
  "  wiki spaces list                       List wiki spaces\n" &
  "  base +record-list --app-token T ...    List table records\n" &
  "  im +chat-search --query Q             Search chats\n" &
  "  im +messages-search --query Q         Search messages\n" &
  "\nRun with --help for any command to see all options.\n" &
  "Use --as user for user-identity operations, --as bot (default) for bot."

method parameters*(t: LarkCliTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "command": {
        "type": "string",
        "description": "The lark-cli subcommand and flags to execute (e.g. 'docs +create --title \"Report\" --markdown \"# Hello\"')"
      }
    },
    "required": %["command"]
  }.toTable

proc parseShellArgs(s: string): seq[string] =
  ## Splits a command string into arguments, respecting double and single quotes.
  ## e.g. `docs +create --title "my doc" --markdown "# Hello"` ->
  ##   @["docs", "+create", "--title", "my doc", "--markdown", "# Hello"]
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

method execute*(t: LarkCliTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  # Reconstruct command from split XML args.
  # LLMs may split into: command="docs", subcommand="+create", params/args="--title ..."
  # Or provide a single command="docs +create --title ..."
  var command = ""
  if args.hasKey("command"):
    command = args["command"].getStr().strip()
  for key in ["subcommand", "action", "sub_command"]:
    if args.hasKey(key):
      let v = args[key].getStr().strip()
      if v.len > 0: command = command & " " & v
  for key in ["params", "args", "arguments", "flags", "options"]:
    if args.hasKey(key):
      let v = args[key].getStr().strip()
      if v.len > 0: command = command & " " & v
  command = command.strip()
  if command.len == 0:
    return "Error: command cannot be empty"

  if t.larkCliBin.len == 0:
    return "Error: lark-cli binary not found. Build with: nimble build_lark"

  if isBlockedCommand(command):
    return "Error: '" & command.split(" ")[0..1].join(" ") & "' is not allowed through this tool. Use the 'reply' tool to send messages to the current chat, or the 'message' tool to send to a specific person."

  # Resolve config dir from context appID or use default
  var configDir = t.defaultConfigDir
  if t.appID.len > 0:
    let appDir = getNimClawDir() / "channels" / "feishu" / "lark-cli-" & t.appID
    if fileExists(appDir / "config.json"):
      configDir = appDir

  if configDir.len == 0:
    return "Error: No lark-cli configuration found. Run: nimclaw channel add feishu <APP_ID> <APP_SECRET>"

  # Build env inheriting parent + config dir
  let env = newStringTable(modeCaseSensitive)
  for key, val in envPairs():
    env[key] = val
  env["LARKSUITE_CLI_CONFIG_DIR"] = configDir

  # Execute lark-cli — parse command respecting quoted strings
  let fullArgs = parseShellArgs(command)
  if fullArgs.len == 0:
    return "Error: empty command"

  try:
    let p = startProcess(t.larkCliBin, args = fullArgs, env = env, options = {poUsePath, poStdErrToStdOut})
    let startTime = now()
    var output = ""

    while p.running:
      if (now() - startTime) > t.timeout:
        p.terminate()
        discard p.waitForExit(3000)
        p.close()
        return "Error: command timed out after " & $(t.timeout.inSeconds) & " seconds"
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

    let maxLen = 30000
    if result.len > maxLen:
      return result[0 ..< maxLen] & "\n... (truncated, " & $(result.len - maxLen) & " more chars)"
    return result
  except Exception as e:
    return "Error executing lark-cli: " & e.msg
