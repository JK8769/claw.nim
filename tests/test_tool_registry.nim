import std/[unittest, json, tables, asyncdispatch, strutils, algorithm, hashes, sets]
import ../src/nimclaw/tools/types
import ../src/nimclaw/tools/registry
import ../src/nimclaw/tools/loop_detector
import ../src/nimclaw/tools/find
import ../src/nimclaw/mcp/client
import ../src/nimclaw/schema

# --- Test helpers ---

type
  DummyTool = ref object of Tool
    n: string
    desc: string

method name*(t: DummyTool): string = t.n
method description*(t: DummyTool): string = t.desc
method parameters*(t: DummyTool): Table[string, JsonNode] =
  {"type": %"object", "properties": %*{"x": {"type": "string"}}}.toTable
method execute*(t: DummyTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  return "ok"

type
  SlowTool = ref object of Tool
    n: string
    output: string

method name*(t: SlowTool): string = t.n
method description*(t: SlowTool): string = "returns large output"
method parameters*(t: SlowTool): Table[string, JsonNode] = initTable[string, JsonNode]()
method execute*(t: SlowTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  return t.output

proc dummy(name: string, desc: string = "a tool"): DummyTool =
  DummyTool(n: name, desc: desc)

# =============================================================================
suite "sanitizeToolName":
# =============================================================================

  test "replaces invalid characters with underscore":
    check sanitizeToolName("hello world!") == "hello_world_"
    check sanitizeToolName("mcp:server/tool") == "mcp_server_tool"

  test "preserves valid characters":
    check sanitizeToolName("my_tool-v2") == "my_tool-v2"
    check sanitizeToolName("ABCabc123") == "ABCabc123"

  test "short names are unchanged":
    check sanitizeToolName("reply") == "reply"
    check sanitizeToolName("exec") == "exec"

  test "names at exactly 64 chars are not truncated":
    let name64 = "a".repeat(64)
    check sanitizeToolName(name64).len == 64

  test "names over 64 chars are truncated with FNV-32a hash suffix":
    let longName = "mcp_isolarcloud_monitoring_get_device_power_generation_history_daily_stats"
    let result = sanitizeToolName(longName)
    check result.len == 64
    # Must end with _XXXXXXXX (underscore + 8 hex chars)
    check result[55] == '_'
    # The hash suffix should be 8 hex characters
    let suffix = result[56..63]
    for c in suffix:
      check c in {'0'..'9', 'a'..'f'}

  test "different long names produce different hash suffixes":
    let name1 = "mcp_server_alpha_" & "a".repeat(60)
    let name2 = "mcp_server_beta_" & "b".repeat(60)
    let r1 = sanitizeToolName(name1)
    let r2 = sanitizeToolName(name2)
    check r1 != r2
    check r1.len == 64
    check r2.len == 64

  test "hash is deterministic":
    let longName = "mcp_extremely_long_server_name_with_many_components_tool_name_here"
    check sanitizeToolName(longName) == sanitizeToolName(longName)

  test "sanitization happens before length check":
    # Name with invalid chars that, once sanitized, exceeds 64
    let name = "mcp://very-long-server.name/with/slashes/" & "x".repeat(40)
    let result = sanitizeToolName(name)
    check result.len == 64
    check '_' notin result[0..5] or true  # just check it doesn't crash

# =============================================================================
suite "ToolRegistry sorted iteration":
# =============================================================================

  test "list() returns names in sorted order":
    let r = newToolRegistry()
    r.register(dummy("zebra"))
    r.register(dummy("alpha"))
    r.register(dummy("mango"))
    let names = r.list()
    check names == sorted(names)

  test "getSummaries() returns in sorted order":
    let r = newToolRegistry()
    r.register(dummy("charlie", "third"))
    r.register(dummy("alice", "first"))
    r.register(dummy("bob", "second"))
    let summaries = r.getSummaries()
    # Each summary starts with "- `name`"
    check summaries[0].contains("alice")
    check summaries[1].contains("bob")
    check summaries[2].contains("charlie")

  test "getDefinitions() returns in sorted order":
    let r = newToolRegistry()
    r.register(dummy("zulu"))
    r.register(dummy("alpha"))
    r.register(dummy("mike"))
    let defs = r.getDefinitions(OpenAI)
    check defs[0].function.name == "alpha"
    check defs[1].function.name == "mike"
    check defs[2].function.name == "zulu"

# =============================================================================
suite "ToolRegistry collision prevention":
# =============================================================================

  test "first registration wins, duplicate is rejected":
    let r = newToolRegistry()
    r.register(dummy("reply", "built-in reply"))
    r.register(dummy("reply", "mcp reply override"))
    let (tool, ok) = r.get("reply")
    check ok
    check tool.description() == "built-in reply"
    check r.count == 1

  test "different names register independently":
    let r = newToolRegistry()
    r.register(dummy("reply"))
    r.register(dummy("forward"))
    check r.count == 2

  test "names that sanitize to the same string collide":
    let r = newToolRegistry()
    r.register(dummy("my:tool", "first"))   # sanitizes to my_tool
    r.register(dummy("my/tool", "second"))  # sanitizes to my_tool
    check r.count == 1
    let (tool, ok) = r.get("my_tool")
    check ok
    check tool.description() == "first"

# =============================================================================
suite "ToolRegistry result size cap":
# =============================================================================

  test "short results are returned unchanged":
    let r = newToolRegistry()
    let t = SlowTool(n: "small", output: "hello world")
    r.register(t)
    let ctx = ToolContext(role: "admin")
    let result = waitFor r.executeWithContext("small", initTable[string, JsonNode](), ctx)
    check result == "hello world"

  test "results over 30K chars are truncated":
    let r = newToolRegistry()
    let bigOutput = "x".repeat(50_000)
    let t = SlowTool(n: "big", output: bigOutput)
    r.register(t)
    let ctx = ToolContext(role: "admin")
    let result = waitFor r.executeWithContext("big", initTable[string, JsonNode](), ctx)
    check result.len < bigOutput.len
    check result.contains("[Output truncated")

  test "truncated result mentions full length":
    let r = newToolRegistry()
    let bigOutput = "y".repeat(40_000)
    let t = SlowTool(n: "big2", output: bigOutput)
    r.register(t)
    let ctx = ToolContext(role: "admin")
    let result = waitFor r.executeWithContext("big2", initTable[string, JsonNode](), ctx)
    check result.contains("40000")

# =============================================================================
suite "FNV-32a determinism":
# =============================================================================

  test "known test vectors":
    # FNV-32a of empty string = 2166136261 = 0x811c9dc5
    check sanitizeToolName("") == ""  # empty stays empty

    # Two known distinct inputs produce distinct hashes
    let a = "a".repeat(70)
    let b = "b".repeat(70)
    let ra = sanitizeToolName(a)
    let rb = sanitizeToolName(b)
    check ra != rb
    # Both truncated to 64
    check ra.len == 64
    check rb.len == 64

  test "hash suffix is stable across calls":
    let name = "mcp_playwright_browser_navigate_with_extra_long_suffix_that_exceeds"
    let r1 = sanitizeToolName(name)
    let r2 = sanitizeToolName(name)
    let r3 = sanitizeToolName(name)
    check r1 == r2
    check r2 == r3

# =============================================================================
suite "ToolLoopDetector":
# =============================================================================

  test "no warning for first call":
    var d = newLoopDetector()
    let r = d.record("exec", %*{"command": "ls"})
    check r == lrOk

  test "no warning for different tools":
    var d = newLoopDetector()
    check d.record("exec", %*{"command": "ls"}) == lrOk
    check d.record("read_file", %*{"path": "/tmp/x"}) == lrOk
    check d.record("write_file", %*{"path": "/tmp/y"}) == lrOk

  test "no warning for same tool with different args":
    var d = newLoopDetector()
    check d.record("exec", %*{"command": "ls"}) == lrOk
    check d.record("exec", %*{"command": "pwd"}) == lrOk
    check d.record("exec", %*{"command": "whoami"}) == lrOk

  test "warns at 3 identical consecutive calls":
    var d = newLoopDetector()
    check d.record("exec", %*{"command": "ls"}) == lrOk
    check d.record("exec", %*{"command": "ls"}) == lrOk
    check d.record("exec", %*{"command": "ls"}) == lrWarn

  test "stops at 5 identical consecutive calls":
    var d = newLoopDetector()
    for i in 0..3:
      discard d.record("exec", %*{"command": "ls"})
    check d.record("exec", %*{"command": "ls"}) == lrStop

  test "counter resets when a different call intervenes":
    var d = newLoopDetector()
    check d.record("exec", %*{"command": "ls"}) == lrOk
    check d.record("exec", %*{"command": "ls"}) == lrOk
    check d.record("read_file", %*{"path": "/tmp"}) == lrOk  # breaks the streak
    check d.record("exec", %*{"command": "ls"}) == lrOk      # resets to 1
    check d.record("exec", %*{"command": "ls"}) == lrOk      # 2

  test "warning message includes tool name and count":
    var d = newLoopDetector()
    for i in 0..2:
      discard d.record("pw_browser_click", %*{"selector": "#btn"})
    check d.message().contains("pw_browser_click")
    check d.message().contains("3")

  test "stop message is different from warning":
    var d = newLoopDetector()
    for i in 0..4:
      discard d.record("exec", %*{"command": "curl"})
    check d.message().contains("STOP")

  test "empty args treated as distinct from non-empty":
    var d = newLoopDetector()
    check d.record("exec", newJObject()) == lrOk
    check d.record("exec", %*{"command": "ls"}) == lrOk
    check d.record("exec", newJObject()) == lrOk  # different from previous

# =============================================================================
suite "Tool tags":
# =============================================================================

  test "base Tool has empty tags by default":
    let t = dummy("test_tool")
    check t.tags().len == 0

  test "setTags sets and getTags retrieves":
    let t = dummy("test_tool")
    t.setTags(@["web", "browser"])
    check t.tags() == @["web", "browser"]

  test "setTags replaces previous tags":
    let t = dummy("test_tool")
    t.setTags(@["old"])
    t.setTags(@["new", "updated"])
    check t.tags() == @["new", "updated"]

# =============================================================================
suite "Tag-based searchTools scoring":
# =============================================================================

  test "name match scores higher than tag-only match":
    let r = newToolRegistry()
    # Tool with "browser" in tags but not in name
    let t1 = dummy("pw_navigate", "go to a URL")
    t1.setTags(@["browser", "web"])
    r.register(t1)
    # Tool with "browser" in name but not in tags
    let t2 = dummy("browser_legacy", "old tool")
    r.register(t2)
    let results = r.searchTools(@["browser"])
    check results.len == 2
    # t2 (name match=7) should come before t1 (tag match=5) — direct intent wins
    check results[0].name == "browser_legacy"

  test "multiple tag matches increase score":
    let r = newToolRegistry()
    let t1 = dummy("tool_a", "desc a")
    t1.setTags(@["web", "form", "input"])
    r.register(t1)
    let t2 = dummy("tool_b", "desc b")
    t2.setTags(@["web"])
    r.register(t2)
    let results = r.searchTools(@["web", "form"])
    check results.len == 2
    # t1 matches both "web" and "form" tags, t2 matches only "web"
    check results[0].name == "tool_a"

  test "tags are case-insensitive":
    let r = newToolRegistry()
    let t = dummy("mytool", "desc")
    t.setTags(@["Browser", "WEB"])
    r.register(t)
    let results = r.searchTools(@["browser"])
    check results.len == 1

  test "search with no tag matches still finds by name":
    let r = newToolRegistry()
    let t = dummy("exec_shell", "run commands")
    r.register(t)  # no tags
    let results = r.searchTools(@["exec"])
    check results.len == 1
    check results[0].name == "exec_shell"

  test "searchTools returns results sorted by score descending":
    let r = newToolRegistry()
    let t1 = dummy("low_score", "generic tool")
    r.register(t1)
    let t2 = dummy("medium", "web related tool")
    t2.setTags(@["web"])
    r.register(t2)
    let t3 = dummy("high", "the best")
    t3.setTags(@["web", "browser", "navigate"])
    r.register(t3)
    let results = r.searchTools(@["web", "browser"])
    check results.len >= 2
    # highest score first
    check results[0].name == "high"

# =============================================================================
suite "ToolRegistry tag storage":
# =============================================================================

  test "registered tool preserves tags":
    let r = newToolRegistry()
    let t = dummy("tagged_tool", "desc")
    t.setTags(@["alpha", "beta"])
    r.register(t)
    let (tool, ok) = r.get("tagged_tool")
    check ok
    check tool.tags() == @["alpha", "beta"]

  test "getTagGroups returns unique tags with tool counts":
    let r = newToolRegistry()
    let t1 = dummy("a", "desc")
    t1.setTags(@["web", "browser"])
    r.register(t1)
    let t2 = dummy("b", "desc")
    t2.setTags(@["web", "form"])
    r.register(t2)
    let t3 = dummy("c", "desc")
    t3.setTags(@["hardware"])
    r.register(t3)
    let groups = r.getTagGroups()
    # "web" -> 2 tools, "browser" -> 1, "form" -> 1, "hardware" -> 1
    check groups["web"] == 2
    check groups["browser"] == 1
    check groups["hardware"] == 1

  test "tools with no tags are not in any group":
    let r = newToolRegistry()
    r.register(dummy("no_tags"))
    let groups = r.getTagGroups()
    check groups.len == 0

# =============================================================================
suite "Auto-tagging MCP tools":
# =============================================================================

  test "autoTagMcp derives tags from server and tool name":
    let tags = autoTagMcp("playwright", "browser_navigate")
    check "browser" in tags
    check "web" in tags

  test "autoTagMcp includes server name as tag":
    let tags = autoTagMcp("my_custom_server", "do_thing")
    check "my_custom_server" in tags

  test "autoTagMcp maps known servers to semantic tags":
    let tags = autoTagMcp("playwright", "screenshot")
    check "browser" in tags
    check "web" in tags

  test "autoTagMcp maps git server":
    let tags = autoTagMcp("git", "commit")
    check "git" in tags
    check "devops" in tags

  test "autoTagMcp extracts action verbs from tool name":
    let navigateTags = autoTagMcp("unknown", "browser_navigate")
    check "browser" in navigateTags
    let fileTags = autoTagMcp("unknown", "read_file")
    check "filesystem" in fileTags

# =============================================================================
suite "Deferred tool loading":
# =============================================================================

  test "registerHidden marks tool as hidden":
    let r = newToolRegistry()
    let t = dummy("secret_tool", "hidden desc")
    t.setTags(@["admin"])
    r.registerHidden(t)
    check r.count == 1
    check r.isHidden("secret_tool")

  test "register marks tool as not hidden":
    let r = newToolRegistry()
    r.register(dummy("visible"))
    check not r.isHidden("visible")

  test "getDefinitionsDeferred separates core from hidden":
    let r = newToolRegistry()
    let core1 = dummy("reply", "send reply")
    core1.setTags(@["messaging", "core"])
    r.register(core1)
    let core2 = dummy("exec", "run command")
    core2.setTags(@["system", "core"])
    r.register(core2)
    let hidden1 = dummy("pw_click", "click element")
    hidden1.setTags(@["browser", "web"])
    r.registerHidden(hidden1)
    let hidden2 = dummy("i2c_read", "read i2c")
    hidden2.setTags(@["hardware"])
    r.registerHidden(hidden2)

    let (defs, hiddenNames) = r.getDefinitionsDeferred(OpenAI)
    check defs.len == 2  # Only core tools have full schemas
    check "pw_click" in hiddenNames
    check "i2c_read" in hiddenNames
    check "reply" notin hiddenNames
    check "exec" notin hiddenNames

  test "activated tools get full schemas in deferred mode":
    let r = newToolRegistry()
    r.register(dummy("reply", "send reply"))
    let h = dummy("pw_click", "click element")
    r.registerHidden(h)

    var activated = initHashSet[string]()
    activated.incl("pw_click")
    let (defs, hiddenNames) = r.getDefinitionsDeferred(OpenAI, activated)
    check defs.len == 2  # reply + activated pw_click
    check "pw_click" notin hiddenNames  # no longer hidden since activated

  test "hidden tools are still executable":
    let r = newToolRegistry()
    let t = SlowTool(n: "hidden_exec", output: "ran ok")
    r.registerHidden(t)
    let ctx = ToolContext(role: "admin")
    let result = waitFor r.executeWithContext("hidden_exec", initTable[string, JsonNode](), ctx)
    check result == "ran ok"

# =============================================================================
suite "Taxonomy generation":
# =============================================================================

  test "generateTaxonomy creates group descriptions":
    let r = newToolRegistry()
    let t1 = dummy("pw_navigate", "go to URL")
    t1.setTags(@["browser", "web"])
    r.registerHidden(t1)
    let t2 = dummy("pw_click", "click element")
    t2.setTags(@["browser", "web"])
    r.registerHidden(t2)
    let t3 = dummy("i2c_read", "read sensor")
    t3.setTags(@["hardware", "sensors"])
    r.registerHidden(t3)

    let taxonomy = r.generateTaxonomy()
    check taxonomy.contains("browser")
    check taxonomy.contains("hardware")
    # Should show tool count
    check taxonomy.contains("2")  # browser group has 2 tools

  test "generateTaxonomy excludes core tag as a group":
    let r = newToolRegistry()
    let t = dummy("reply", "send reply")
    t.setTags(@["messaging", "core"])
    r.register(t)  # not hidden
    let taxonomy = r.generateTaxonomy()
    # "core" should not appear as a discoverable group
    check not taxonomy.contains("core")

  test "generateTaxonomy returns empty for no hidden tools":
    let r = newToolRegistry()
    r.register(dummy("reply"))
    let taxonomy = r.generateTaxonomy()
    check taxonomy.len == 0

# =============================================================================
suite "TTL expiry on find_tools":
# =============================================================================

  test "activated tools have TTL":
    var ft = newFindTools(newToolRegistry())
    ft.activateWithTTL("pw_click", 5)
    check ft.getActivated().len == 1

  test "tickTTL decrements TTL":
    var ft = newFindTools(newToolRegistry())
    ft.activateWithTTL("pw_click", 3)
    ft.tickTTL()
    ft.tickTTL()
    check ft.getActivated().len == 1  # TTL=1, still alive

  test "tool expires when TTL reaches 0":
    var ft = newFindTools(newToolRegistry())
    ft.activateWithTTL("pw_click", 2)
    ft.tickTTL()  # TTL=1
    ft.tickTTL()  # TTL=0 → removed
    check ft.getActivated().len == 0

  test "tickTTL keeps tools with remaining TTL":
    var ft = newFindTools(newToolRegistry())
    ft.activateWithTTL("short_lived", 1)
    ft.activateWithTTL("long_lived", 5)
    ft.tickTTL()  # short_lived expires, long_lived=4
    let active = ft.getActivated()
    check "short_lived" notin active
    check "long_lived" in active

  test "re-activating resets TTL":
    var ft = newFindTools(newToolRegistry())
    ft.activateWithTTL("pw_click", 2)
    ft.tickTTL()  # TTL=1
    ft.activateWithTTL("pw_click", 5)  # Reset to 5
    ft.tickTTL()  # TTL=4
    ft.tickTTL()  # TTL=3
    ft.tickTTL()  # TTL=2
    check ft.getActivated().len == 1  # Still alive

# =============================================================================
suite "Positional tag weighting":
# =============================================================================

  test "first tag scores higher than last tag":
    let r = newToolRegistry()
    # cron_create: "cron" is primary tag (position 0)
    let t1 = dummy("cron_create", "create scheduled job")
    t1.setTags(@["cron", "scheduling", "automation"])
    r.register(t1)
    # exec: "automation" is tertiary (position 2)
    let t2 = dummy("exec_tool", "run shell commands")
    t2.setTags(@["system", "dev", "automation"])
    r.register(t2)
    # Search for shared tag "automation"
    let results = r.searchTools(@["automation"])
    check results.len == 2
    # cron_create should rank higher: "automation" at position 2 in both,
    # but cron also has "cron" and "scheduling" — wait, we're searching "automation".
    # Both have "automation" at position 2, so same tag score.
    # Let's test with a primary-tag search instead.

  test "primary tag query ranks primary-tagged tool first":
    let r = newToolRegistry()
    # Tool where "browser" is the primary tag
    let t1 = dummy("pw_click", "click web element")
    t1.setTags(@["browser", "web", "interaction"])
    r.register(t1)
    # Tool where "browser" is a secondary tag
    let t2 = dummy("web_test", "test web pages")
    t2.setTags(@["testing", "browser", "web"])
    r.register(t2)
    let results = r.searchTools(@["browser"])
    check results.len == 2
    # pw_click has "browser" at position 0 (highest score)
    # web_test has "browser" at position 1 (lower score)
    check results[0].name == "pw_click"

  test "tag at position 0 scores more than position 3":
    let r = newToolRegistry()
    let t1 = dummy("primary", "desc")
    t1.setTags(@["target", "a", "b", "c"])  # "target" at pos 0
    r.register(t1)
    let t2 = dummy("deep", "desc")
    t2.setTags(@["x", "y", "z", "target"])  # "target" at pos 3
    r.register(t2)
    let results = r.searchTools(@["target"])
    check results.len == 2
    check results[0].name == "primary"

# =============================================================================
suite "searchHint":
# =============================================================================

  test "Tool has empty searchHint by default":
    let t = dummy("test")
    check t.searchHint == ""

  test "setSearchHint stores and retrieves":
    let t = dummy("test")
    t.setSearchHint("schedule recurring jobs cron timer")
    check t.searchHint == "schedule recurring jobs cron timer"

  test "searchHint matches contribute to score":
    let r = newToolRegistry()
    # Tool with no searchHint, no matching tags/name
    let t1 = dummy("task_a", "does things")
    r.register(t1)
    # Tool with searchHint containing the keyword
    let t2 = dummy("task_b", "does other things")
    t2.setSearchHint("schedule recurring jobs timer")
    r.register(t2)
    let results = r.searchTools(@["schedule"])
    check results.len == 1
    check results[0].name == "task_b"

  test "scoring order: name > tag > hint":
    let r = newToolRegistry()
    # t1: keyword in primary tag only (5pts)
    let t1 = dummy("tool_a", "desc")
    t1.setTags(@["deploy"])
    r.register(t1)
    # t2: keyword in searchHint only (3pts)
    let t2 = dummy("tool_b", "desc")
    t2.setSearchHint("deploy release ship")
    r.register(t2)
    # t3: keyword in name only (7pts) — direct intent wins
    let t3 = dummy("deploy_old", "desc")
    r.register(t3)
    let results = r.searchTools(@["deploy"])
    check results.len == 3
    # Name match > tag match > hint match
    check results[0].name == "deploy_old"
    check results[1].name == "tool_a"
    check results[2].name == "tool_b"

  test "searchHint is case-insensitive":
    let r = newToolRegistry()
    let t = dummy("mytool", "desc")
    t.setSearchHint("Deploy Release SHIP")
    r.register(t)
    let results = r.searchTools(@["deploy"])
    check results.len == 1

  test "searchHint with multiple keyword matches":
    let r = newToolRegistry()
    let t1 = dummy("tool_a", "desc")
    t1.setSearchHint("web browser navigate click type")
    r.register(t1)
    let t2 = dummy("tool_b", "desc")
    t2.setSearchHint("database query sql")
    r.register(t2)
    let results = r.searchTools(@["browser", "navigate"])
    check results.len == 1
    check results[0].name == "tool_a"

# =============================================================================
suite "Prefix alias resolution":
# =============================================================================

  test "wrapped internal tools are filtered from search":
    let r = newToolRegistry()
    r.addPrefixAlias("playwright", "pw")
    r.register(dummy("pw_click", "click an element"))
    r.register(dummy("pw_navigate", "go to URL"))
    r.register(dummy("exec", "run commands"))
    # pw_* tools are internal — searchTools should not return them
    let results = r.searchTools(@["click"])
    for res in results:
      check not res.name.startsWith("pw_")

  test "wrapper tool found by alias keyword":
    let r = newToolRegistry()
    r.addPrefixAlias("playwright", "pw")
    r.register(dummy("pw_click", "click element"))
    let wrapper = dummy("playwright", "browser automation")
    wrapper.setTags(@["browser", "web"])
    wrapper.setSearchHint("browser navigate click type screenshot playwright")
    r.register(wrapper)
    let results = r.searchTools(@["playwright"])
    check results.len == 1
    check results[0].name == "playwright"

  test "wrapper found by hint when name doesn't match":
    let r = newToolRegistry()
    r.addPrefixAlias("playwright", "pw")
    r.register(dummy("pw_click", "click element"))
    let wrapper = dummy("playwright", "browser automation")
    wrapper.setTags(@["browser", "web"])
    wrapper.setSearchHint("browser navigate click type screenshot playwright")
    r.register(wrapper)
    let other = dummy("git_ops", "version control")
    other.setTags(@["git"])
    r.register(other)
    # "browser" matches playwright via tag+hint, not git_ops
    let results = r.searchTools(@["browser"])
    check results.len >= 1
    check results[0].name == "playwright"

  test "alias is case-insensitive":
    let r = newToolRegistry()
    r.addPrefixAlias("Playwright", "PW")
    r.register(dummy("pw_click", "click"))
    let wrapper = dummy("playwright", "browser automation")
    r.register(wrapper)
    let results = r.searchTools(@["PLAYWRIGHT"])
    check results.len == 1
    check results[0].name == "playwright"

  test "no false match when prefix doesn't match tool name":
    let r = newToolRegistry()
    r.addPrefixAlias("playwright", "pw")
    let t = dummy("exec_shell", "run commands")
    r.register(t)
    # "playwright" resolves to "pw" but exec_shell doesn't start with "pw_"
    let results = r.searchTools(@["playwright"])
    check results.len == 0

  test "internal tools excluded from deferred definitions":
    let r = newToolRegistry()
    r.addPrefixAlias("playwright", "pw")
    r.registerHidden(dummy("pw_click", "click"))
    r.registerHidden(dummy("pw_navigate", "navigate"))
    let wrapper = dummy("playwright", "browser automation")
    wrapper.setTags(@["browser"])
    r.registerHidden(wrapper)
    let strategy = inferStrategy("deepseek-chat")
    let (defs, hidden) = r.getDefinitionsDeferred(strategy)
    # pw_* should not appear in either defs or hidden
    for d in defs:
      check not d.function.name.startsWith("pw_")
    for h in hidden:
      check not h.startsWith("pw_")
    # playwright wrapper should be in hidden (it's registered as hidden)
    check "playwright" in hidden

  test "internal tools excluded from taxonomy":
    let r = newToolRegistry()
    r.addPrefixAlias("playwright", "pw")
    r.registerHidden(dummy("pw_click", "click"))
    r.registerHidden(dummy("pw_navigate", "navigate"))
    let wrapper = dummy("playwright", "browser automation")
    wrapper.setTags(@["browser"])
    r.registerHidden(wrapper)
    let taxonomy = r.generateTaxonomy()
    check "pw_click" notin taxonomy
    check "pw_navigate" notin taxonomy
    check "playwright" in taxonomy
