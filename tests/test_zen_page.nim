## test_zen_page — Unit tests for zen_page discoverElements and cli_zen helpers.

import std/[unittest, json, tables, os, strutils]
import nimclaw/zen_page
import nimclaw/cli_zen {.all.}

suite "discoverElements":
  test "only discovers mmap=true elements":
    let ttml = """
      <Panel title="Agents">
        <Table id="agents" cols="NAME,STATUS" mmap="true"/>
      </Panel>
      <Panel title="Info">
        <Table id="info" cols="KEY,VALUE"/>
      </Panel>
      <Panel title="Activity">
        <Log id="feed" max="10" mmap="true"/>
      </Panel>
    """
    let elems = discoverElements(ttml)
    check elems.len == 2
    check elems[0].id == "agents"
    check elems[0].kind == ekTable
    check elems[0].cols == @["NAME", "STATUS"]
    check elems[1].id == "feed"
    check elems[1].kind == ekLog
    check elems[1].maxLines == 10

  test "returns empty for no mmap elements":
    let ttml = """<Table id="t1" cols="A,B"><Tr>1|2</Tr></Table>"""
    check discoverElements(ttml).len == 0

  test "handles nested mmap elements":
    let ttml = """
      <Tabs id="tabs" active="t1">
        <Tab id="t1" title="One">
          <Table id="inner" cols="X" mmap="true"/>
        </Tab>
      </Tabs>
    """
    let elems = discoverElements(ttml)
    check elems.len == 1
    check elems[0].id == "inner"

suite "slug":
  test "lowercases and replaces spaces":
    check slug("MyCompany") == "mycompany"
    check slug("Test Corp") == "test-corp"
    check slug("default") == "default"
    check slug("A B C") == "a-b-c"

suite "escXml":
  test "escapes special characters":
    check escXml("a & b") == "a &amp; b"
    check escXml("<tag>") == "&lt;tag&gt;"
    check escXml("x=\"y\"") == "x=&quot;y&quot;"
    check escXml("plain") == "plain"

suite "parseBaseJson":
  setup:
    let dir = "/tmp/test_parse_base"
    createDir(dir)

  teardown:
    try: removeFile(dir / "BASE.json") except: discard
    try: removeDir(dir) except: discard

  test "parses providers":
    writeFile(dir / "BASE.json", $ %*{
      "providers": {
        "deepseek": {"name": "deepseek", "apiBase": "https://api.deepseek.com", "defaultModel": "deepseek-chat"}
      }
    })
    let data = parseBaseJson(dir)
    check data.providers.len == 1

  test "parses agents":
    writeFile(dir / "BASE.json", $ %*{
      "config": {"agents": {"named": [
        {"name": "Lexi", "model": "deepseek-chat", "provider": "deepseek", "role": "Secretary"}
      ]}}
    })
    let data = parseBaseJson(dir)
    check data.agents.len == 1

  test "parses channels":
    writeFile(dir / "BASE.json", $ %*{
      "config": {"channels": {
        "telegram": {"enabled": true},
        "discord": {"enabled": false}
      }}
    })
    let data = parseBaseJson(dir)
    check data.channels.len == 1

  test "parses graph entities and orgName":
    writeFile(dir / "BASE.json", $ %*{
      "@graph": [
        {"id": "corp1", "kind": "Corporate", "name": "TestCorp"},
        {"id": "p1", "kind": "Person", "name": "Jerry", "permission-group": "SuperAdmin"},
        {"id": "a1", "kind": "AI", "name": "Lexi", "jobTitle": "Secretary",
         "reportsTo": [{"id": "p1", "@annotation": {"role": "boss", "trustLevel": 100}}]}
      ]
    })
    let data = parseBaseJson(dir)
    check data.orgName == "TestCorp"
    check data.entities.len == 3

  test "returns empty for missing file":
    let data = parseBaseJson("/tmp/nonexistent_dir_12345")
    check data.providers.len == 0
    check data.agents.len == 0

  test "returns empty for invalid json":
    writeFile(dir / "BASE.json", "not json {{{")
    let data = parseBaseJson(dir)
    check data.providers.len == 0

suite "buildCompanyTab":
  setup:
    createDir("/tmp/.nimclaw-test-build")

  teardown:
    try: removeFile("/tmp/.nimclaw-test-build/BASE.json") except: discard
    try: removeDir("/tmp/.nimclaw-test-build") except: discard

  test "running company gets ● icon and success color":
    writeFile("/tmp/.nimclaw-test-build/BASE.json", $ %*{
      "providers": {"ollama": {"name": "ollama", "apiBase": "localhost", "defaultModel": "gemma"}}
    })
    let tab = buildCompanyTab(CompanyInfo(name: "TestCorp", dir: "/tmp/.nimclaw-test-build", running: true, pid: 1))
    check tab.contains("tab-testcorp")
    check tab.contains("icon=\"●\"")
    check tab.contains("success")
    check tab.contains("run-testcorp")
    check tab.contains("stop-testcorp")
    check tab.contains("delete-testcorp")
    check tab.contains("ollama")

  test "stopped company gets ○ icon":
    writeFile("/tmp/.nimclaw-test-build/BASE.json", $ %*{})
    let tab = buildCompanyTab(CompanyInfo(name: "My Co", dir: "/tmp/.nimclaw-test-build", running: false, pid: 0))
    check tab.contains("icon=\"○\"")
    check tab.contains("tab-my-co")
    check tab.contains("neutral")

  test "includes org chart when graph exists":
    writeFile("/tmp/.nimclaw-test-build/BASE.json", $ %*{
      "@graph": [
        {"id": "c1", "kind": "Corporate", "name": "Acme"},
        {"id": "p1", "kind": "Person", "name": "Alice"},
        {"id": "a1", "kind": "AI", "name": "Lexi", "jobTitle": "Secretary",
         "reportsTo": [{"id": "p1", "@annotation": {"role": "boss", "trustLevel": 80}}]}
      ]
    })
    let tab = buildCompanyTab(CompanyInfo(name: "Test", dir: "/tmp/.nimclaw-test-build", running: false, pid: 0))
    check tab.contains("Organization")
    check tab.contains("Acme")
    check tab.contains("Alice")
    check tab.contains("Lexi")
    check tab.contains("reports to")
    check tab.contains("trust:80")

suite "buildDashboardTtml":
  setup:
    createDir("/tmp/.nimclaw-test-dash")
    writeFile("/tmp/.nimclaw-test-dash/BASE.json", $ %*{})

  teardown:
    try: removeFile("/tmp/.nimclaw-test-dash/BASE.json") except: discard
    try: removeDir("/tmp/.nimclaw-test-dash") except: discard

  test "empty companies shows + tab active":
    let ttml = buildDashboardTtml(@[])
    check ttml.contains("active=\"tab-add\"")
    check ttml.contains("tab-add")

  test "first company tab is active":
    let companies = @[
      CompanyInfo(name: "Alpha", dir: "/tmp/.nimclaw-test-dash", running: true, pid: 1),
      CompanyInfo(name: "Beta", dir: "/tmp/.nimclaw-test-dash", running: false, pid: 0)
    ]
    let ttml = buildDashboardTtml(companies)
    check ttml.contains("active=\"tab-alpha\"")
    check ttml.contains("tab-beta")
    check ttml.contains("tab-add")

  test "always includes + tab at end":
    let companies = @[
      CompanyInfo(name: "Only", dir: "/tmp/.nimclaw-test-dash", running: false, pid: 0)
    ]
    let ttml = buildDashboardTtml(companies)
    check ttml.contains("tab-add")
    check ttml.contains("Select a template")
