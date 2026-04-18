import std/[unittest, json, os, osproc, options, strtabs, strutils, streams, asyncdispatch, tables]
import ../src/nimclaw/channels/feishu
import ../src/nimclaw/config
import ../src/nimclaw/tools/lark
import ../src/nimclaw/tools/types

# Resolve lark-cli binary and config dir once for integration tests
let larkCliBin = findLarkCli()
let testAppID = "cli_a93085a978781cd5"
let configDir = getNimClawDir() / "channels" / "feishu" / "lark-cli-" & testAppID

proc hasLarkCli(): bool = larkCliBin.len > 0
proc hasLarkCliConfig(): bool = hasLarkCli() and fileExists(configDir / "config.json")

proc makeLarkEnv(): StringTableRef =
  ## Build env table that inherits parent env + sets config dir.
  let env = newStringTable(modeCaseSensitive)
  for key, val in envPairs():
    env[key] = val
  env["LARKSUITE_CLI_CONFIG_DIR"] = configDir
  env

suite "Feishu buildPostContent":
  test "simple text":
    let result = buildPostContent("Hello world")
    let j = parseJson(result)
    check j["zh_cn"]["content"].len == 1
    check j["zh_cn"]["content"][0][0]["text"].getStr() == "Hello world\n"

  test "multiline text":
    let result = buildPostContent("line1\nline2\nline3")
    let j = parseJson(result)
    check j["zh_cn"]["content"].len == 3
    check j["zh_cn"]["content"][0][0]["text"].getStr() == "line1\n"
    check j["zh_cn"]["content"][1][0]["text"].getStr() == "line2\n"
    check j["zh_cn"]["content"][2][0]["text"].getStr() == "line3\n"

  test "empty text":
    let result = buildPostContent("")
    let j = parseJson(result)
    check j["zh_cn"]["content"].len == 1
    check j["zh_cn"]["content"][0][0]["text"].getStr() == "\n"

  test "markdown table":
    let text = "| A | B |\n| --- | --- |\n| 1 | 2 |"
    let result = buildPostContent(text)
    let j = parseJson(result)
    # Table is rendered as a single text block
    check j["zh_cn"]["content"].len >= 1
    let tableText = j["zh_cn"]["content"][0][0]["text"].getStr()
    check tableText.contains("A")
    check tableText.contains("B")
    check tableText.contains("1")
    check tableText.contains("2")

suite "Feishu tryExtractInteractiveCard":
  test "non-JSON returns none":
    check tryExtractInteractiveCard("hello").isNone

  test "plain JSON object returns none":
    check tryExtractInteractiveCard("""{"foo": "bar"}""").isNone

  test "nimclaw_feishu interactive card":
    let content = """{"nimclaw_feishu": {"msg_type": "interactive", "card": {"header": {"title": {"tag": "plain_text", "content": "Test"}}}}}"""
    let result = tryExtractInteractiveCard(content)
    check result.isSome
    let card = parseJson(result.get)
    check card["header"]["title"]["content"].getStr() == "Test"

  test "direct msg_type interactive card":
    let content = """{"msg_type": "interactive", "card": {"header": {"title": {"tag": "plain_text", "content": "Direct"}}}}"""
    let result = tryExtractInteractiveCard(content)
    check result.isSome

  test "nimclaw_feishu non-interactive returns none":
    let content = """{"nimclaw_feishu": {"msg_type": "text", "card": {}}}"""
    check tryExtractInteractiveCard(content).isNone

suite "Feishu buildPostContent":
  test "bare url becomes a tag":
    let post = parseJson(buildPostContent("Visit https://example.com for info"))
    let elems = post["zh_cn"]["content"][0]
    var foundLink = false
    for e in elems:
      if e["tag"].getStr() == "a":
        check e["href"].getStr() == "https://example.com"
        check e["text"].getStr() == "example.com"
        foundLink = true
    check foundLink

  test "markdown link becomes a tag":
    let post = parseJson(buildPostContent("Click [here](https://example.com) to view"))
    let elems = post["zh_cn"]["content"][0]
    var foundLink = false
    for e in elems:
      if e["tag"].getStr() == "a":
        check e["href"].getStr() == "https://example.com"
        check e["text"].getStr() == "here"
        foundLink = true
    check foundLink

  test "bold text":
    let post = parseJson(buildPostContent("This is **important**"))
    let elems = post["zh_cn"]["content"][0]
    var foundBold = false
    for e in elems:
      if e["tag"].getStr() == "text" and e.hasKey("style"):
        check e["text"].getStr() == "important"
        foundBold = true
    check foundBold

  test "no urls":
    let post = parseJson(buildPostContent("plain text"))
    let elems = post["zh_cn"]["content"][0]
    check elems[0]["tag"].getStr() == "text"
    check elems[0]["text"].getStr() == "plain text"

  test "multiline":
    let post = parseJson(buildPostContent("line1\nline2"))
    check post["zh_cn"]["content"].len == 2

suite "Feishu findLarkCli":
  test "finds lark-cli binary":
    # Should find it in thridparty/cli/ or on PATH
    let bin = findLarkCli()
    if bin.len > 0:
      check fileExists(bin)
    else:
      skip()

suite "Feishu lark-cli integration":
  ## These tests require a configured lark-cli with valid credentials.
  ## They test actual API calls to verify the CLI invocation patterns work.

  test "lark-cli binary exists and runs":
    if not hasLarkCli(): skip()
    let (output, code) = execCmdEx(larkCliBin & " --help")
    check code == 0
    check output.contains("lark-cli")

  test "lark-cli config exists":
    if not hasLarkCliConfig(): skip()
    check fileExists(configDir / "config.json")
    let config = parseJson(readFile(configDir / "config.json"))
    check config["apps"].len > 0
    check config["apps"][0]["appId"].getStr() == testAppID

  test "event subscribe connects (WebSocket)":
    if not hasLarkCliConfig(): skip()
    let env = makeLarkEnv()
    let p = startProcess(larkCliBin,
      args = ["event", "+subscribe", "--event-types", "im.message.receive_v1", "--compact"],
      env = env, options = {poUsePath, poStdErrToStdOut})
    # Read merged stdout+stderr for connection status
    let outStream = p.outputStream()
    var connected = false
    var lines = 0
    var line = ""
    while lines < 20:
      if not outStream.readLine(line): break
      if line.contains("Connected"):
        connected = true
        break
      inc lines
    p.terminate()
    discard p.waitForExit(3000)
    p.close()
    check connected

  test "send text message via --text":
    if not hasLarkCliConfig(): skip()
    let env = makeLarkEnv()
    let p = startProcess(larkCliBin,
      args = ["im", "+messages-send",
              "--chat-id", "oc_136b46cfde0e7ddeddc43f24bd28e702",
              "--text", "[test] text message from test_feishu.nim",
              "--as", "bot"],
      env = env, options = {poUsePath})
    let output = p.outputStream.readAll()
    let code = p.waitForExit(15000)
    p.close()
    check code == 0
    let j = parseJson(output)
    check j["ok"].getBool() == true
    check j["data"]["message_id"].getStr().startsWith("om_")

  test "send markdown message via --markdown":
    if not hasLarkCliConfig(): skip()
    let env = makeLarkEnv()
    let p = startProcess(larkCliBin,
      args = ["im", "+messages-send",
              "--chat-id", "oc_136b46cfde0e7ddeddc43f24bd28e702",
              "--markdown", "[test] **bold** and _italic_ from test_feishu.nim",
              "--as", "bot"],
      env = env, options = {poUsePath})
    let output = p.outputStream.readAll()
    let code = p.waitForExit(15000)
    p.close()
    check code == 0
    let j = parseJson(output)
    check j["ok"].getBool() == true

  test "send post format via --msg-type post --content":
    if not hasLarkCliConfig(): skip()
    let content = buildPostContent("[test] post format from test_feishu.nim")
    let env = makeLarkEnv()
    let p = startProcess(larkCliBin,
      args = ["im", "+messages-send",
              "--chat-id", "oc_136b46cfde0e7ddeddc43f24bd28e702",
              "--msg-type", "post",
              "--content", content,
              "--as", "bot"],
      env = env, options = {poUsePath})
    let output = p.outputStream.readAll()
    let code = p.waitForExit(15000)
    p.close()
    check code == 0
    let j = parseJson(output)
    check j["ok"].getBool() == true

  test "send reply to message":
    if not hasLarkCliConfig(): skip()
    # First send a message to get a message_id
    let env = makeLarkEnv()
    let p1 = startProcess(larkCliBin,
      args = ["im", "+messages-send",
              "--chat-id", "oc_136b46cfde0e7ddeddc43f24bd28e702",
              "--text", "[test] parent message for reply test",
              "--as", "bot"],
      env = env, options = {poUsePath})
    let out1 = p1.outputStream.readAll()
    let code1 = p1.waitForExit(15000)
    p1.close()
    check code1 == 0
    let parentMsgId = parseJson(out1)["data"]["message_id"].getStr()
    check parentMsgId.startsWith("om_")

    # Now reply to it
    let p2 = startProcess(larkCliBin,
      args = ["im", "+messages-reply",
              "--message-id", parentMsgId,
              "--text", "[test] reply from test_feishu.nim",
              "--as", "bot"],
      env = env, options = {poUsePath})
    let out2 = p2.outputStream.readAll()
    let code2 = p2.waitForExit(15000)
    p2.close()
    check code2 == 0
    let j2 = parseJson(out2)
    check j2["ok"].getBool() == true

  test "env inheritance required for keychain access":
    if not hasLarkCliConfig(): skip()
    # Test that empty env (without HOME etc) fails
    let emptyEnv = newStringTable(modeCaseSensitive)
    emptyEnv["LARKSUITE_CLI_CONFIG_DIR"] = configDir
    let p = startProcess(larkCliBin,
      args = ["im", "+messages-send",
              "--chat-id", "oc_136b46cfde0e7ddeddc43f24bd28e702",
              "--text", "should fail",
              "--as", "bot"],
      env = emptyEnv, options = {poUsePath})
    let output = p.outputStream.readAll()
    let errOutput = p.errorStream.readAll()
    let code = p.waitForExit(15000)
    p.close()
    # With empty env, lark-cli should fail (can't access keychain)
    check(code != 0 or not output.contains("\"ok\": true"))

suite "LarkCliTool":
  var tool: LarkCliTool

  setup:
    tool = newLarkCliTool()
    # Set context with test app ID
    tool.appID = testAppID

  test "tool is created with binary path":
    check tool.larkCliBin.len > 0
    check tool.defaultConfigDir.len > 0

  test "tool name and description":
    check tool.name == "lark_cli"
    check tool.description.contains("docs")
    check tool.description.contains("sheets")
    check tool.description.contains("calendar")

  test "blocks im +messages-send":
    let result = waitFor tool.execute({"command": %"im +messages-send --chat-id oc_xxx --text hello"}.toTable)
    check result.contains("not allowed")
    check result.contains("reply")

  test "blocks im +messages-reply":
    let result = waitFor tool.execute({"command": %"im +messages-reply --message-id om_xxx --text hello"}.toTable)
    check result.contains("not allowed")

  test "allows im +chat-search":
    if not hasLarkCliConfig(): skip()
    let result = waitFor tool.execute({"command": %"im +chat-search --query test"}.toTable)
    # Should not error with "not allowed"
    check not result.contains("not allowed")

  test "empty command returns error":
    let result = waitFor tool.execute({"command": %""}.toTable)
    check result.contains("Error")

  test "missing command returns error":
    let result = waitFor tool.execute(initTable[string, JsonNode]())
    check result.contains("Error")

  test "executes calendar +agenda":
    if not hasLarkCliConfig(): skip()
    let result = waitFor tool.execute({"command": %"calendar +agenda"}.toTable)
    # Should return JSON or "no events" — not an error about blocked commands
    check not result.contains("not allowed")

  test "executes contact +search-user":
    if not hasLarkCliConfig(): skip()
    let result = waitFor tool.execute({"command": %"contact +search-user --query test"}.toTable)
    check not result.contains("not allowed")

  test "executes docs +search":
    if not hasLarkCliConfig(): skip()
    let result = waitFor tool.execute({"command": %"docs +search --query test"}.toTable)
    check not result.contains("not allowed")
