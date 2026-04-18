## Integration test: multi-step browser login via real playwright CLI.
## Tests that LLMs can sustain a tool-calling loop to complete a real login flow.
## Pass criteria: LLM calls playwright with 'fill' at least once (not just open/snapshot).
##
## Requires API keys in .env or .nimclaw/.env
## Requires: npx @playwright/cli

import std/[unittest, json, tables, asyncdispatch, os, strutils, osproc, re]
import ../src/nimclaw/providers/http
import ../src/nimclaw/providers/types

# --- Env setup ---

proc loadDotEnv() =
  for envPath in [".env", ".nimclaw/.env"]:
    if fileExists(envPath):
      for line in readFile(envPath).splitLines():
        let stripped = line.strip()
        if stripped.len == 0 or stripped.startsWith("#"): continue
        let eqPos = stripped.find('=')
        if eqPos > 0:
          let key = stripped[0..<eqPos].strip()
          var val = stripped[eqPos+1..^1].strip()
          if val.len >= 2 and val[0] == '"' and val[^1] == '"':
            val = val[1..^2]
          putEnv(key, val)

loadDotEnv()

# --- Provider configs ---

type ProviderConfig = object
  name: string
  envVar: string
  apiBase: string
  model: string

let providers = @[
  ProviderConfig(name: "DeepSeek", envVar: "DEEPSEEK_API_KEY",
    apiBase: "https://api.deepseek.com", model: "deepseek-chat"),
  ProviderConfig(name: "Nvidia/Nemotron", envVar: "NVIDIA_API_KEY",
    apiBase: "https://integrate.api.nvidia.com/v1", model: "nvidia/nemotron-3-super-120b-a12b"),
  ProviderConfig(name: "Nvidia/Kimi-k2.5", envVar: "NVIDIA_API_KEY",
    apiBase: "https://integrate.api.nvidia.com/v1", model: "moonshotai/kimi-k2.5"),
  ProviderConfig(name: "Nvidia/Kimi-k2-instruct", envVar: "NVIDIA_API_KEY",
    apiBase: "https://integrate.api.nvidia.com/v1", model: "moonshotai/kimi-k2-instruct"),
  ProviderConfig(name: "Nvidia/MiniMax-m2.5", envVar: "NVIDIA_API_KEY",
    apiBase: "https://integrate.api.nvidia.com/v1", model: "minimaxai/minimax-m2.5"),
  ProviderConfig(name: "Opencode/GLM-5", envVar: "OPENCODE_API_KEY",
    apiBase: "https://opencode.ai/zen/go/v1", model: "glm-5"),
  ProviderConfig(name: "Opencode/Kimi-k2.5", envVar: "OPENCODE_API_KEY",
    apiBase: "https://opencode.ai/zen/go/v1", model: "kimi-k2.5"),
  ProviderConfig(name: "Opencode/MiniMax-m2.5", envVar: "OPENCODE_API_KEY",
    apiBase: "https://opencode.ai/zen/go/v1", model: "minimax-m2.5"),
]

# --- Build the playwright tool definition ---

proc playwrightToolDef(): ToolDefinition =
  ToolDefinition(
    `type`: "function",
    function: ToolFunctionDefinition(
      name: "playwright",
      description: "Browser automation via Playwright CLI. Use this for all web interactions.\n\n" &
        "Commands:\n" &
        "  open [url]                 Open browser (optionally navigate to URL)\n" &
        "  snapshot                   Capture accessibility tree (use this to see page)\n" &
        "  click <target>             Click element (use ref from snapshot, e.g. 'click e5')\n" &
        "  fill <target> <text>       Fill input (e.g. 'fill e12 \"password\"')\n" &
        "  type <text>                Type text into focused element\n" &
        "  press <key>                Press key (Enter, Tab)\n" &
        "  screenshot                 Take a screenshot\n" &
        "\nElement refs: snapshot shows [ref=e12] → use bare ID: 'fill e12 \"text\"'\n" &
        "\nWorkflow: open → snapshot → fill/click → snapshot to verify\n" &
        "For login: open → snapshot → fill username → fill password → click login → snapshot\n" &
        "IMPORTANT: Execute actions directly. Do NOT just describe what you plan to do.",
      parameters: %*{
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "The command (e.g. 'open https://example.com', 'fill e12 \"user\"', 'click e5')"
          }
        },
        "required": ["command"]
      }
    )
  )

proc replyToolDef(): ToolDefinition =
  ToolDefinition(
    `type`: "function",
    function: ToolFunctionDefinition(
      name: "reply",
      description: "Send a message back to the user",
      parameters: %*{
        "type": "object",
        "properties": {
          "content": {"type": "string", "description": "Message to send"}
        },
        "required": ["content"]
      }
    )
  )

# --- Real playwright CLI execution ---

let npxPath = findExe("npx")

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

proc sanitizeRefs(command: string): string =
  result = command.replace(re"\[ref=(e\d+)\]", "$1")
  result = result.replace(re"\bref=(e\d+)\b", "$1")

proc execPlaywright(cmd: string, workDir: string = "."): string =
  ## Execute a playwright CLI command and return the output
  if npxPath.len == 0:
    return "Error: npx not found. Install Node.js."
  let sanitized = sanitizeRefs(cmd.strip())
  if sanitized.len == 0:
    return "Error: empty command"
  let args = @["@playwright/cli"] & parseShellArgs(sanitized)
  try:
    result = execProcess(npxPath, workingDir = workDir, args = args,
                         options = {poUsePath, poStdErrToStdOut})
    result = result.strip()
    if result.len == 0:
      result = "Command completed (no output)"
    # Truncate very long output to avoid blowing up context
    if result.len > 8000:
      result = result[0..7999] & "\n... (truncated)"
  except Exception as e:
    result = "Error executing playwright: " & e.msg

proc closeBrowser() =
  ## Close any open browser between tests
  discard execPlaywright("close")

proc realToolResult(toolName: string, args: Table[string, JsonNode]): string =
  if toolName == "playwright":
    let cmd = if args.hasKey("command"): args["command"].getStr() else: ""
    if cmd.len == 0: return "Error: command cannot be empty"
    echo "    [exec] playwright " & cmd
    result = execPlaywright(cmd)
    # Show first line of output for debugging
    let firstLine = result.split('\n')[0]
    if firstLine.len > 100:
      echo "    [out]  " & firstLine[0..99] & "..."
    else:
      echo "    [out]  " & firstLine
  elif toolName == "reply":
    let content = if args.hasKey("content"): args["content"].getStr() else: ""
    echo "    [reply] " & content[0..min(content.len-1, 150)]
    result = "Message sent"
  else:
    result = "Unknown tool: " & toolName

# --- Run multi-turn tool loop ---

type LoopResult = object
  iterations: int
  toolCalls: seq[tuple[name, command: string]]
  calledFill: bool
  calledClick: bool
  finalResponse: string
  error: string

proc runLoginLoop(provider: HTTPProvider, model: string, tools: seq[ToolDefinition],
                  maxIter: int = 15): Future[LoopResult] {.async.} =
  var result = LoopResult()
  let sysPrompt = "You are a helpful assistant with browser automation tools.\n" &
    "The user wants you to login to a website. Execute the login directly using tools.\n" &
    "Do NOT describe what you plan to do — call the tools immediately.\n" &
    "After login, reply to the user confirming success.\n" &
    "IMPORTANT: After each action (fill, click), take a snapshot to see the result."

  var messages = @[
    Message(role: "system", content: sysPrompt),
    Message(role: "user", content: "Login to https://web3.isolarcloud.com.cn with username 'njmkuser' and password 'Pw1111$....'")
  ]
  let opts = {"max_tokens": %4096, "temperature": %0.0}.toTable

  for i in 1..maxIter:
    result.iterations = i
    var response: LLMResponse
    try:
      response = await provider.chat(messages, tools, model, opts)
    except Exception as e:
      result.error = e.msg
      return result

    # If LLM returns text with no tool calls, we're done
    if response.tool_calls.len == 0:
      result.finalResponse = response.content
      return result

    # Build single assistant message with all tool calls from this response
    var tcList: seq[ToolCall] = @[]
    for tc in response.tool_calls:
      if tc.name.len == 0: continue
      var argsJson = newJObject()
      for k, v in tc.arguments.pairs:
        argsJson[k] = v
      tcList.add(ToolCall(
        id: tc.id,
        `type`: "function",
        function: ToolFunctionCall(name: tc.name, arguments: $argsJson),
        name: tc.name,
        arguments: tc.arguments
      ))

    if tcList.len > 0:
      messages.add(Message(role: "assistant", content: response.content,
        tool_calls: tcList))

    # Process each tool call and add tool response messages
    for tc in response.tool_calls:
      if tc.name.len == 0: continue

      let cmd = if tc.arguments.hasKey("command"): tc.arguments["command"].getStr() else: ""
      result.toolCalls.add((name: tc.name, command: cmd))

      if tc.name == "playwright":
        if "fill" in cmd.toLowerAscii(): result.calledFill = true
        if "click" in cmd.toLowerAscii(): result.calledClick = true

      # Execute real tool
      let toolResult = realToolResult(tc.name, tc.arguments)

      messages.add(Message(role: "tool", content: toolResult, tool_call_id: tc.id))

  result.finalResponse = "(max iterations reached)"
  return result

# --- Tests ---

suite "Browser login — real website (isolarcloud)":
  let tools = @[playwrightToolDef(), replyToolDef()]

  for cfg in providers:
    test cfg.name & " (" & cfg.model & ")":
      let apiKey = getEnv(cfg.envVar, "")
      if apiKey.len == 0:
        echo "  SKIPPED (no " & cfg.envVar & ")"
        skip()
        continue

      # Close any previous browser session
      closeBrowser()

      let provider = newHTTPProvider(apiKey, cfg.apiBase, cfg.model, timeout = 120)
      let res = waitFor runLoginLoop(provider, cfg.model, tools)

      echo "  Iterations: " & $res.iterations
      echo "  Tool calls:"
      for tc in res.toolCalls:
        let display = if tc.command.len > 0: tc.name & " → " & tc.command
                      else: tc.name
        echo "    - " & display
      echo "  Called fill: " & $res.calledFill
      echo "  Called click: " & $res.calledClick
      if res.error.len > 0:
        echo "  ERROR: " & res.error
      if res.finalResponse.len > 0:
        let maxLen = min(res.finalResponse.len - 1, 200)
        echo "  Response: " & res.finalResponse[0..maxLen]

      if res.error.len > 0:
        echo "  RESULT: FAIL (API error)"
        check false
      elif not res.calledFill:
        echo "  RESULT: FAIL (never called fill — announced plan instead of acting)"
        check false
      elif not res.calledClick:
        echo "  RESULT: FAIL (filled but never clicked login)"
        check false
      else:
        echo "  RESULT: PASS"
        check true

  # Cleanup
  closeBrowser()
