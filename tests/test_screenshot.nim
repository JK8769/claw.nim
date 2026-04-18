import std/[unittest, json, tables, os, strutils, asyncdispatch]
import ../src/nimclaw/tools/types
import ../src/nimclaw/tools/screenshot

suite "ScreenshotTool Tests":
  setup:
    let ws = getTempDir() / "screenshot_test_" & $getCurrentProcessId()
    createDir(ws)
    let tool = newScreenshotTool(ws)
    
  teardown:
    removeDir(ws)

  test "tool name":
    check tool.name() == "screenshot"

  test "schema has optional filename":
    let params = tool.parameters()
    # It shouldn't require any fields
    if params.hasKey("required"):
      check params["required"].getElems().len == 0
    check params["properties"].hasKey("filename")

  test "execute returns mock IMAGE tag in test mode with default filename":
    let args = initTable[string, JsonNode]()
    let result = waitFor tool.execute(args)
    check "[IMAGE:" in result
    check "screenshot.png" in result

  test "execute returns mock IMAGE tag in test mode with custom filename":
    let args = {"filename": %"capture.png"}.toTable
    let result = waitFor tool.execute(args)
    check "[IMAGE:" in result
    check "capture.png" in result
    check "screenshot.png" notin result
