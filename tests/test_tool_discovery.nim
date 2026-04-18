## Integration tests for LLM tool discovery via find_tools.
## Tests that LLMs call find_tools with appropriate keywords when given
## a deferred tool set (core tools visible, others hidden behind taxonomy).
##
## Requires API keys: DEEPSEEK_API_KEY, NVIDIA_API_KEY, NIMCLAW_OPENCODE_API_KEY
## Skips providers whose keys are missing.

import std/[unittest, json, tables, asyncdispatch, os, strutils, sets]
import ../src/nimclaw/providers/http
import ../src/nimclaw/providers/types
import ../src/nimclaw/tools/types
import ../src/nimclaw/tools/registry
import ../src/nimclaw/tools/find
import ../src/nimclaw/schema

# --- Mock tool for building a realistic registry ---

type MockTool = ref object of Tool
  tName: string
  tDesc: string
  tParams: Table[string, JsonNode]

method name*(t: MockTool): string = t.tName
method description*(t: MockTool): string = t.tDesc
method parameters*(t: MockTool): Table[string, JsonNode] = t.tParams
method execute*(t: MockTool, args: Table[string, JsonNode]): Future[string] {.async.} = return ""

proc mock(name, desc: string, tags: seq[string] = @[], hint: string = ""): MockTool =
  result = MockTool(
    tName: name,
    tDesc: desc,
    tParams: {"type": %"object", "properties": %*{}, "required": %*[]}.toTable
  )
  result.setTags(tags)
  if hint.len > 0: result.setSearchHint(hint)

# --- Build test registry matching production layout ---

proc buildTestRegistry(): (ToolRegistry, FindTools) =
  let reg = newToolRegistry()

  # Core visible tools (always sent as full schemas)
  reg.register(mock("reply", "Send a message back to the current chat",
    @["messaging", "core"], "reply to current conversation"))
  reg.register(mock("read_file", "Read contents of a file",
    @["filesystem", "data", "core"], "read file contents from disk"))
  reg.register(mock("exec", "Run shell commands",
    @["system", "dev", "automation", "core"], "run shell commands and scripts"))

  # Unified playwright tool (visible after find_tools activation)
  reg.registerHidden(mock("playwright", "Browser automation via Playwright. Actions: navigate, click, type, screenshot, snapshot, evaluate, etc.",
    @["browser", "web", "ui", "automation"], "browser navigate click type screenshot playwright web automation"))

  # Individual pw_* tools still registered hidden as MCP backing
  reg.registerHidden(mock("pw_navigate", "Navigate browser to a URL",
    @["browser", "web", "ui"], "browser navigate to URL"))
  reg.registerHidden(mock("pw_click", "Click an element on the page",
    @["browser", "web", "ui"], "browser click element"))
  reg.registerHidden(mock("pw_type", "Type text into an input field",
    @["browser", "web", "ui"], "browser type text into form"))
  reg.registerHidden(mock("pw_screenshot", "Take a screenshot of the page",
    @["browser", "web", "ui"], "browser capture screenshot"))

  reg.registerHidden(mock("lark_cli", "Execute Feishu/Lark platform operations: docs, sheets, calendar, tasks",
    @["feishu", "lark", "docs", "calendar", "platform"], "feishu lark docs sheets calendar tasks"))

  reg.registerHidden(mock("git_operations", "Run git commands: commit, push, pull, diff, log",
    @["git", "devops", "vcs"], "git version control operations"))

  reg.registerHidden(mock("cron", "Schedule recurring tasks with cron expressions",
    @["scheduling", "automation", "cron"], "schedule recurring tasks with cron expressions"))

  reg.registerHidden(mock("web_search", "Search the internet for information",
    @["web", "search", "data"], "search the internet for information"))
  reg.registerHidden(mock("web_fetch", "Fetch webpage or URL content",
    @["web", "http", "data"], "fetch webpage or URL content"))

  reg.registerHidden(mock("i2c", "Communicate with I2C devices",
    @["hardware", "i2c", "sensors"], "communicate with I2C devices"))

  # Prefix alias for playwright
  reg.addPrefixAlias("playwright", "pw")

  # find_tools (visible, core)
  let ft = newFindTools(reg)
  ft.setTags(@["utility", "core"])
  ft.setSearchHint("discover and activate hidden tools")
  reg.register(ft)

  return (reg, ft)

# --- Build the system prompt with taxonomy ---

proc buildSystemPrompt(reg: ToolRegistry): string =
  result = "You are a helpful AI assistant with access to tools.\n"
  result.add("You have core tools available directly. For additional capabilities, use `find_tools` to discover and activate hidden tools.\n\n")
  let taxonomy = reg.generateTaxonomy()
  if taxonomy.len > 0:
    result.add("## Additional Tools\nUse `find_tools` to activate tools from these categories:\n" & taxonomy & "\n\n")
  result.add("IMPORTANT: When the user asks for something that requires tools not in your current set, ")
  result.add("call find_tools FIRST with relevant keywords. Do NOT refuse — discover the right tools.\n")

# --- Provider configs ---

type ProviderConfig = object
  name: string
  envVar: string
  apiBase: string
  model: string

let providers = @[
  ProviderConfig(name: "DeepSeek", envVar: "DEEPSEEK_API_KEY",
    apiBase: "https://api.deepseek.com", model: "deepseek-chat"),
  ProviderConfig(name: "Nvidia/Kimi", envVar: "NVIDIA_API_KEY",
    apiBase: "https://integrate.api.nvidia.com/v1", model: "moonshotai/kimi-k2.5"),
]

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

proc skipIfNoKey(envVar: string): string =
  result = getEnv(envVar, "")
  if result.len == 0:
    echo "  SKIPPED (no " & envVar & ")"

# --- Test scenarios ---

type TestScenario = object
  name: string
  prompt: string
  expectKeywords: seq[string]  ## Keywords we expect in the find_tools query
  expectTools: seq[string]     ## Tool names that should be found by searchTools

let scenarios = @[
  TestScenario(
    name: "login to website",
    prompt: "Help me login to https://isolarcloud.com",
    expectKeywords: @["browser", "login", "web"],
    expectTools: @["playwright"]
  ),
  TestScenario(
    name: "create a doc",
    prompt: "Create a Feishu document titled 'Weekly Report' with a summary of this week",
    expectKeywords: @["doc", "feishu", "lark", "create"],
    expectTools: @["lark_cli"]
  ),
  TestScenario(
    name: "schedule a task",
    prompt: "Remind me every Monday at 9am to check the server logs",
    expectKeywords: @["schedule", "cron", "remind"],
    expectTools: @["cron"]
  ),
  TestScenario(
    name: "search the web",
    prompt: "Search the internet for the latest Nim language release notes",
    expectKeywords: @["search", "web"],
    expectTools: @["web_search"]
  ),
]

# --- Unit tests: verify searchTools returns correct results for expected keywords ---

suite "Tool discovery - searchTools correctness":
  let (reg, _) = buildTestRegistry()

  for scenario in scenarios:
    test scenario.name & " — keywords find expected tools":
      # Test each expected keyword individually and combined
      var found = initHashSet[string]()
      for kw in scenario.expectKeywords:
        let results = reg.searchTools(@[kw])
        for r in results:
          found.incl(r.name)

      for expected in scenario.expectTools:
        check expected in found

  test "playwright wrapper found, pw_ internals excluded":
    let results = reg.searchTools(@["playwright"])
    var names: seq[string] = @[]
    for r in results: names.add(r.name)
    check "playwright" in names
    # Internal pw_* tools should be filtered out
    for n in names:
      check not n.startsWith("pw_")

  test "deferred mode separates core from hidden":
    let strategy = inferStrategy("deepseek-chat")
    let (defs, hidden) = reg.getDefinitionsDeferred(strategy)
    # Core tools should have full schemas
    var coreNames: seq[string] = @[]
    for d in defs: coreNames.add(d.function.name)
    check "reply" in coreNames
    check "find_tools" in coreNames
    check "exec" in coreNames
    # playwright wrapper and lark_cli should be hidden (discoverable)
    check "playwright" in hidden
    check "lark_cli" in hidden
    # pw_* internals should not appear anywhere
    for d in defs:
      check not d.function.name.startsWith("pw_")
    for h in hidden:
      check not h.startsWith("pw_")

  test "taxonomy includes hidden tool groups":
    let taxonomy = reg.generateTaxonomy()
    check taxonomy.len > 0
    check "browser" in taxonomy.toLowerAscii()
    check "feishu" in taxonomy.toLowerAscii() or "lark" in taxonomy.toLowerAscii()

# --- LLM integration tests: verify LLMs call find_tools ---

suite "Tool discovery - LLM calls find_tools":
  let (reg, findTool) = buildTestRegistry()
  let strategy = inferStrategy("deepseek-chat")
  let (coreDefs, _) = reg.getDefinitionsDeferred(strategy)
  let sysPrompt = buildSystemPrompt(reg)

  for cfg in providers:
    for scenario in scenarios:
      test cfg.name & " — " & scenario.name:
        let apiKey = skipIfNoKey(cfg.envVar)
        if apiKey.len == 0:
          skip()
          continue

        let provider = newHTTPProvider(apiKey, cfg.apiBase, cfg.model, timeout = 60)
        let messages = @[
          Message(role: "system", content: sysPrompt),
          Message(role: "user", content: scenario.prompt)
        ]
        let opts = {"max_tokens": %2048, "temperature": %0.0}.toTable

        let response = waitFor provider.chat(messages, coreDefs, cfg.model, opts)

        # The LLM should call find_tools
        var findToolCalled = false
        var query = ""
        for tc in response.tool_calls:
          if tc.name == "find_tools":
            findToolCalled = true
            query = tc.arguments.getOrDefault("query", %"").getStr("")
            break

        if not findToolCalled:
          echo "    FAIL: LLM did not call find_tools"
          echo "    Response: " & response.content[0..min(response.content.len-1, 200)]
          if response.tool_calls.len > 0:
            echo "    Tool calls: "
            for tc in response.tool_calls:
              echo "      - " & tc.name
        check findToolCalled

        if findToolCalled and query.len > 0:
          echo "    find_tools query: \"" & query & "\""

          # Verify the query keywords actually find the expected tools
          let keywords = query.toLowerAscii().split(" ")
          let results = reg.searchTools(keywords)
          var foundNames: seq[string] = @[]
          for r in results: foundNames.add(r.name)

          echo "    Found tools: " & foundNames.join(", ")

          # At least one expected tool should be in results
          var anyExpected = false
          for expected in scenario.expectTools:
            if expected in foundNames:
              anyExpected = true
              break
          if not anyExpected:
            echo "    WARN: Expected one of " & scenario.expectTools.join(", ") & " but got " & foundNames.join(", ")
          check anyExpected
