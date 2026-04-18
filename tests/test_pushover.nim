import std/[unittest, json, tables, os, strutils, asyncdispatch]
import ../src/nimclaw/tools/types
import ../src/nimclaw/tools/pushover

suite "PushoverTool Tests":
  setup:
    let ws = getTempDir() / "pushover_test_" & $getCurrentProcessId()
    createDir(ws)
    let tool = newPushoverTool(ws)
    
  teardown:
    removeDir(ws)

  test "tool name":
    check tool.name() == "pushover"

  test "schema has message required":
    let params = tool.parameters()
    check params["required"].getElems().contains(%"message")
    check params["properties"].hasKey("message")

  test "rejects missing message":
    let args = {"title": %"Hello"}.toTable
    let result = waitFor tool.execute(args)
    check "message" in result.toLowerAscii()

  test "rejects empty message":
    let args = {"message": %""}.toTable
    let result = waitFor tool.execute(args)
    check "message" in result.toLowerAscii()

  test "rejects priority below -2":
    let args = {"message": %"Hello", "priority": %(-3)}.toTable
    let result = waitFor tool.execute(args)
    check "priority" in result.toLowerAscii()

  test "rejects priority above 2":
    let args = {"message": %"Hello", "priority": %(5)}.toTable
    let result = waitFor tool.execute(args)
    check "priority" in result.toLowerAscii()

  test "fails gracefully on missing .env":
    let emptyWs = getTempDir() / "pushover_empty"
    let emptyTool = newPushoverTool(emptyWs)
    let args = {"message": %"Hello"}.toTable
    let result = waitFor emptyTool.execute(args)
    check "credential" in result.toLowerAscii()

suite "PushoverTool Env Parsing":
  test "parseEnvValue strips whitespace":
    check parseEnvValue("  myvalue  ") == "myvalue"
    
  test "parseEnvValue strips quotes":
    check parseEnvValue("\"quotedvalue\"") == "quotedvalue"
    check parseEnvValue("'singlequoted'") == "singlequoted"
    
  test "parseEnvValue strips inline comments":
    check parseEnvValue("myvalue # this is a comment") == "myvalue"
    
  test "getCredentials reads token and user_key from .env":
    let ws = getTempDir() / "pushover_env_1"
    createDir(ws)
    writeFile(ws / ".env", "PUSHOVER_TOKEN=token123\nPUSHOVER_USER_KEY=user456\n")
    let tool = newPushoverTool(ws)
    let creds = tool.getCredentials()
    check creds.token == "token123"
    check creds.userKey == "user456"
    removeDir(ws)

  test "getCredentials reads exported and quoted values":
    let ws = getTempDir() / "pushover_env_2"
    createDir(ws)
    writeFile(ws / ".env", "export PUSHOVER_TOKEN=\"token-abc\"\nexport PUSHOVER_USER_KEY='key-xyz'\n")
    let tool = newPushoverTool(ws)
    let creds = tool.getCredentials()
    check creds.token == "token-abc"
    check creds.userKey == "key-xyz"
    removeDir(ws)
    
  test "getCredentials fails on missing token":
    let ws = getTempDir() / "pushover_env_3"
    createDir(ws)
    writeFile(ws / ".env", "PUSHOVER_USER_KEY=user456\n")
    let tool = newPushoverTool(ws)
    expect Exception:
      discard tool.getCredentials()
    removeDir(ws)
