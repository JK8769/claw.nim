## Integration tests for LLM tool calling across providers.
## Requires API keys in environment: DEEPSEEK_API_KEY, OPENCODE_API_KEY, NVIDIA_API_KEY
## Skips providers whose keys are missing.
##
## Tests both native JSON tool calling (DeepSeek, Nvidia) and XML fallback (Opencode/Kimi).

import std/[unittest, json, tables, asyncdispatch, os, strutils]
import ../src/nimclaw/providers/http
import ../src/nimclaw/providers/types
import ../src/nimclaw/agent/xml_tools
import ../src/nimclaw/tools/types
import ../src/nimclaw/tools/registry

# --- Test tool definitions (JSON Schema, for native tool calling) ---

let larkCliDef = ToolDefinition(
  `type`: "function",
  function: ToolFunctionDefinition(
    name: "lark_cli",
    description: "Execute Feishu/Lark platform operations. Available: docs +create --title T --markdown M, docs +fetch --doc URL, calendar +agenda, task +create --title T.",
    parameters: %*{
      "type": "object",
      "properties": {
        "command": {
          "type": "string",
          "description": "The lark-cli subcommand and flags (e.g. 'docs +create --title \"Report\" --markdown \"# Hello\"')"
        }
      },
      "required": ["command"]
    }
  )
)

let replyDef = ToolDefinition(
  `type`: "function",
  function: ToolFunctionDefinition(
    name: "reply",
    description: "Send a message back to the current chat.",
    parameters: %*{
      "type": "object",
      "properties": {
        "content": {"type": "string", "description": "The message to send"}
      },
      "required": ["content"]
    }
  )
)

let tools = @[larkCliDef, replyDef]

# --- Mock tool for XML instruction building ---

type MockTool = ref object of Tool
  tName: string
  tDesc: string
  tParams: Table[string, JsonNode]

method name*(t: MockTool): string = t.tName
method description*(t: MockTool): string = t.tDesc
method parameters*(t: MockTool): Table[string, JsonNode] = t.tParams
method execute*(t: MockTool, args: Table[string, JsonNode]): Future[string] {.async.} = return ""

proc buildXmlRegistry(): ToolRegistry =
  let reg = newToolRegistry()
  reg.register(MockTool(
    tName: "lark_cli",
    tDesc: "Execute Feishu/Lark platform operations. Available: docs +create --title T --markdown M, docs +fetch --doc URL, calendar +agenda.",
    tParams: {
      "type": %"object",
      "properties": %*{
        "command": {"type": "string", "description": "The lark-cli subcommand and flags"}
      },
      "required": %["command"]
    }.toTable
  ))
  reg.register(MockTool(
    tName: "reply",
    tDesc: "Send a message back to the current chat.",
    tParams: {
      "type": %"object",
      "properties": %*{
        "content": {"type": "string", "description": "The message to send"}
      },
      "required": %["content"]
    }.toTable
  ))
  return reg

# --- Helpers ---

proc makeMessages(prompt: string, xmlInstructions: string = ""): seq[Message] =
  var sysContent = "You are a helpful assistant. When asked to create a document, use the lark_cli tool. Always use a tool — never just reply with text."
  if xmlInstructions.len > 0:
    sysContent &= "\n" & xmlInstructions
  @[
    Message(role: "system", content: sysContent),
    Message(role: "user", content: prompt)
  ]

proc skipIfNoKey(envVar: string): string =
  let key = getEnv(envVar, "")
  if key.len == 0:
    echo "  SKIPPED (no " & envVar & ")"
  return key

# --- Provider configs ---

type ProviderConfig = object
  name: string
  envVar: string
  apiBase: string
  model: string
  useXml: bool  # true = XML tool calling fallback, false = native JSON

let providers = @[
  ProviderConfig(name: "DeepSeek", envVar: "DEEPSEEK_API_KEY", apiBase: "https://api.deepseek.com", model: "deepseek-chat", useXml: false),
  ProviderConfig(name: "Opencode/Kimi", envVar: "OPENCODE_API_KEY", apiBase: "https://opencode.ai/zen/go/v1", model: "kimi-k2.5", useXml: true),
  ProviderConfig(name: "Nvidia/Kimi", envVar: "NVIDIA_API_KEY", apiBase: "https://integrate.api.nvidia.com/v1", model: "moonshotai/kimi-k2.5", useXml: false),
]

# Load .env if present
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

# --- Tests ---

suite "LLM Tool Calling - Native JSON":
  for cfg in providers:
    if cfg.useXml: continue

    test cfg.name & " - calls lark_cli with command parameter":
      let apiKey = skipIfNoKey(cfg.envVar)
      if apiKey.len == 0: skip()

      let provider = newHTTPProvider(apiKey, cfg.apiBase, cfg.model, timeout = 60)
      let messages = makeMessages("Create a Feishu document titled 'Test Doc' with content '# Hello World'")
      let opts = {"max_tokens": %2048, "temperature": %0.0}.toTable

      let response = waitFor provider.chat(messages, tools, cfg.model, opts)

      # Should have tool calls
      check response.tool_calls.len > 0
      if response.tool_calls.len > 0:
        # Find the lark_cli call
        var found = false
        for tc in response.tool_calls:
          if tc.name == "lark_cli":
            found = true
            # Arguments should contain command
            check tc.arguments.hasKey("command")
            if tc.arguments.hasKey("command"):
              let cmd = tc.arguments["command"].getStr("")
              check cmd.len > 0
              check "docs" in cmd.toLowerAscii() or "create" in cmd.toLowerAscii()
              echo "    " & cfg.name & " lark_cli command: " & cmd[0..min(cmd.len-1, 80)]
            break
        check found

    test cfg.name & " - tool call has non-empty name":
      let apiKey = skipIfNoKey(cfg.envVar)
      if apiKey.len == 0: skip()

      let provider = newHTTPProvider(apiKey, cfg.apiBase, cfg.model, timeout = 60)
      let messages = makeMessages("Reply with 'hello' to the chat")
      let opts = {"max_tokens": %1024, "temperature": %0.0}.toTable

      let response = waitFor provider.chat(messages, tools, cfg.model, opts)

      if response.tool_calls.len > 0:
        for tc in response.tool_calls:
          check tc.name.strip().len > 0

suite "LLM Tool Calling - XML Fallback":
  let xmlRegistry = buildXmlRegistry()
  let xmlInstructions = buildToolInstructions(xmlRegistry)

  # Verify instructions contain correct param names (not schema keys)
  test "XML instructions show parameter names not schema keys":
    check "lark_cli(command)" in xmlInstructions
    check "reply(content)" in xmlInstructions
    check "(type," notin xmlInstructions
    check "properties" notin xmlInstructions

  for cfg in providers:
    if not cfg.useXml: continue

    test cfg.name & " - returns XML tool call with correct parameter":
      let apiKey = skipIfNoKey(cfg.envVar)
      if apiKey.len == 0: skip()

      let provider = newHTTPProvider(apiKey, cfg.apiBase, cfg.model, timeout = 60)
      # For XML mode, tools go in the system prompt, not as tool definitions
      let messages = makeMessages(
        "Create a Feishu document titled 'Test Doc' with markdown content '# Hello'",
        xmlInstructions
      )
      let emptyTools: seq[ToolDefinition] = @[]
      let opts = {"max_tokens": %2048, "temperature": %0.0}.toTable

      let response = waitFor provider.chat(messages, emptyTools, cfg.model, opts)

      # Response should contain XML tool call markup
      check response.content.len > 0
      let hasToolCall = hasXmlToolCalls(response.content)
      check hasToolCall

      if hasToolCall:
        let calls = parseXmlToolCalls(response.content)
        check calls.len > 0
        if calls.len > 0:
          # Find lark_cli call
          var found = false
          for call in calls:
            if call.name == "lark_cli":
              found = true
              check call.arguments.hasKey("command")
              if call.arguments.hasKey("command"):
                let cmd = call.arguments["command"].getStr("")
                check cmd.len > 0
                echo "    " & cfg.name & " lark_cli command: " & cmd[0..min(cmd.len-1, 80)]
              break
          if not found:
            echo "    " & cfg.name & " tool calls: "
            for call in calls:
              echo "      - " & call.name & " args=" & $call.arguments
          check found

    test cfg.name & " - does not produce empty tool names":
      let apiKey = skipIfNoKey(cfg.envVar)
      if apiKey.len == 0: skip()

      let provider = newHTTPProvider(apiKey, cfg.apiBase, cfg.model, timeout = 60)
      let messages = makeMessages("Reply with 'hello' to the current chat", xmlInstructions)
      let emptyTools: seq[ToolDefinition] = @[]
      let opts = {"max_tokens": %1024, "temperature": %0.0}.toTable

      let response = waitFor provider.chat(messages, emptyTools, cfg.model, opts)

      if hasXmlToolCalls(response.content):
        let calls = parseXmlToolCalls(response.content)
        for call in calls:
          check call.name.strip().len > 0
