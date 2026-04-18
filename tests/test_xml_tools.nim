import std/[unittest, json, tables, strutils, asyncdispatch]
import ../src/nimclaw/agent/xml_tools
import ../src/nimclaw/tools/types
import ../src/nimclaw/tools/registry

suite "XML Tool Call Parser":
  test "parse single tool call":
    let response = """Let me check that.
<tool_call>
{"name": "shell", "arguments": {"command": "ls -la"}}
</tool_call>"""
    let calls = parseXmlToolCalls(response)
    check calls.len == 1
    check calls[0].name == "shell"
    check calls[0].arguments["command"].getStr() == "ls -la"

  test "parse multiple tool calls":
    let response = """<tool_call>
{"name": "file_read", "arguments": {"path": "a.txt"}}
</tool_call>
<tool_call>
{"name": "file_read", "arguments": {"path": "b.txt"}}
</tool_call>"""
    let calls = parseXmlToolCalls(response)
    check calls.len == 2
    check calls[0].name == "file_read"
    check calls[1].name == "file_read"
    check calls[0].arguments["path"].getStr() == "a.txt"
    check calls[1].arguments["path"].getStr() == "b.txt"

  test "no tool calls returns empty":
    let response = "Just a normal response with no tools."
    let calls = parseXmlToolCalls(response)
    check calls.len == 0

  test "malformed JSON inside tags is skipped":
    let response = "<tool_call>this is not json</tool_call>"
    let calls = parseXmlToolCalls(response)
    check calls.len == 0

  test "markdown fenced JSON inside tags":
    let response = """<tool_call>
```json
{"name": "shell", "arguments": {"command": "pwd"}}
```
</tool_call>"""
    let calls = parseXmlToolCalls(response)
    check calls.len == 1
    check calls[0].name == "shell"

  test "empty arguments defaults to empty table":
    let response = """<tool_call>{"name": "shell"}</tool_call>"""
    let calls = parseXmlToolCalls(response)
    check calls.len == 1
    check calls[0].name == "shell"
    check calls[0].arguments.len == 0

  test "bracket notation TOOL_CALL":
    let response = """[TOOL_CALL]
{"name": "shell", "arguments": {"command": "echo hi"}}
[/TOOL_CALL]"""
    let calls = parseXmlToolCalls(response)
    check calls.len == 1
    check calls[0].name == "shell"

  test "unclosed tag with valid JSON recovers":
    let response = """<tool_call>{"name": "shell", "arguments": {"command": "ls"}}"""
    let calls = parseXmlToolCalls(response)
    check calls.len == 1
    check calls[0].name == "shell"

suite "XML Tool Text Extraction":
  test "extract text around tool calls":
    let response = """Before text.
<tool_call>
{"name": "shell", "arguments": {"command": "echo hi"}}
</tool_call>
After text."""
    let text = extractTextFromResponse(response)
    check "Before text." in text
    check "After text." in text
    check "<tool_call>" notin text

  test "extract text with no tool calls":
    let response = "Just plain text here."
    let text = extractTextFromResponse(response)
    check text == "Just plain text here."

suite "XML Tool Result Formatting":
  test "format single successful result":
    let results = @[XmlToolResult(name: "shell", output: "hello world", success: true)]
    let formatted = formatToolResults(results)
    check "<tool_result" in formatted
    check "shell" in formatted
    check "hello world" in formatted
    check "ok" in formatted

  test "format failed result":
    let results = @[XmlToolResult(name: "shell", output: "permission denied", success: false)]
    let formatted = formatToolResults(results)
    check "error" in formatted
    check "permission denied" in formatted

  test "format multiple results":
    let results = @[
      XmlToolResult(name: "file_read", output: "contents", success: true),
      XmlToolResult(name: "shell", output: "done", success: true)
    ]
    let formatted = formatToolResults(results)
    check "file_read" in formatted
    check "shell" in formatted

suite "XML Tool Call Detection":
  test "detects tool_call tag":
    check hasXmlToolCalls("some text <tool_call> json </tool_call>")

  test "detects TOOL_CALL bracket":
    check hasXmlToolCalls("text [TOOL_CALL] json [/TOOL_CALL]")

  test "no detection in plain text":
    check not hasXmlToolCalls("just a normal response")

# Mock tool for testing buildToolInstructions
type
  MockTool = ref object of Tool
    toolName: string
    toolDesc: string
    toolParams: Table[string, JsonNode]

method name*(t: MockTool): string = t.toolName
method description*(t: MockTool): string = t.toolDesc
method parameters*(t: MockTool): Table[string, JsonNode] = t.toolParams
method execute*(t: MockTool, args: Table[string, JsonNode]): Future[string] {.async.} = return "ok"

proc mockTool(name, desc: string, params: Table[string, JsonNode]): MockTool =
  MockTool(toolName: name, toolDesc: desc, toolParams: params)

suite "XML Tool Instructions":
  test "shows actual parameter names from JSON Schema properties":
    let reg = newToolRegistry()
    reg.register(mockTool("lark_cli", "Execute lark-cli commands", {
      "type": %"object",
      "properties": %*{
        "command": {"type": "string", "description": "The command to run"}
      },
      "required": %["command"]
    }.toTable))
    let instructions = buildToolInstructions(reg)
    check "lark_cli(command)" in instructions
    # Must NOT show schema keys
    check "lark_cli(type" notin instructions
    check "properties" notin instructions

  test "shows multiple parameter names":
    let reg = newToolRegistry()
    reg.register(mockTool("message", "Send a message", {
      "type": %"object",
      "properties": %*{
        "content": {"type": "string"},
        "to": {"type": "string"},
        "channel": {"type": "string"}
      },
      "required": %["content"]
    }.toTable))
    let instructions = buildToolInstructions(reg)
    check "content" in instructions
    check "to" in instructions
    check "channel" in instructions

  test "tool with no properties shows empty parens":
    let reg = newToolRegistry()
    reg.register(mockTool("clock", "Get current time", {
      "type": %"object",
      "properties": %*{}
    }.toTable))
    let instructions = buildToolInstructions(reg)
    check "clock:" in instructions
    # No parameter names
    check "clock()" notin instructions

  test "tool with flat params (no schema wrapper) still works":
    let reg = newToolRegistry()
    reg.register(mockTool("old_tool", "Legacy tool", {
      "query": %*{"type": "string"},
      "limit": %*{"type": "integer"}
    }.toTable))
    let instructions = buildToolInstructions(reg)
    check "query" in instructions
    check "limit" in instructions

  test "filtered instructions respect allowed list":
    let reg = newToolRegistry()
    reg.register(mockTool("reply", "Reply to chat", {
      "type": %"object",
      "properties": %*{"content": {"type": "string"}}
    }.toTable))
    reg.register(mockTool("exec", "Run shell command", {
      "type": %"object",
      "properties": %*{"command": {"type": "string"}}
    }.toTable))
    let instructions = buildToolInstructionsFiltered(reg, @["reply"])
    check "reply(content)" in instructions
    check "exec" notin instructions

  test "Anthropic-style XML tool call parsed correctly":
    let response = """I'll create that document.
<tool_call>
  <name>lark_cli</name>
  <arguments>
    <command>docs +create --title "Test" --markdown "# Hello"</command>
  </arguments>
</tool_call>"""
    let calls = parseXmlToolCalls(response)
    check calls.len == 1
    check calls[0].name == "lark_cli"
    check calls[0].arguments.hasKey("command")
    check calls[0].arguments["command"].getStr() == """docs +create --title "Test" --markdown "# Hello""""

  test "Anthropic-style XML with split args parsed":
    let response = """<tool_call>
  <name>lark_cli</name>
  <arguments>
    <command>docs</command>
    <subcommand>+create</subcommand>
    <params>--title "My Doc"</params>
  </arguments>
</tool_call>"""
    let calls = parseXmlToolCalls(response)
    check calls.len == 1
    check calls[0].name == "lark_cli"
    check calls[0].arguments["command"].getStr() == "docs"
    check calls[0].arguments["subcommand"].getStr() == "+create"
    check calls[0].arguments["params"].getStr() == """--title "My Doc""""
