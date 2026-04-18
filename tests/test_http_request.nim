import std/[unittest, json, tables, strutils, asyncdispatch]
import ../src/nimclaw/tools/types
import ../src/nimclaw/tools/http_request

suite "HttpRequestTool Tests":
  setup:
    let tool = newHttpRequestTool()

  test "has correct name and description":
    check tool.name() == "http_request"
    check tool.description().len > 0

  test "schema requires url":
    let params = tool.parameters()
    check params["required"].getElems().contains(%"url")
    check params["properties"].hasKey("url")
    check params["properties"].hasKey("method")
    check params["properties"].hasKey("headers")
    check params["properties"].hasKey("body")

  test "executing without url fails":
    let args = {"other": %"value"}.toTable
    let result = waitFor tool.execute(args)
    check "url" in result.toLowerAscii()

  test "executing with non-http scheme fails":
    let args = {"url": %"ftp://example.com"}.toTable
    let result = waitFor tool.execute(args)
    check "http" in result.toLowerAscii()

  test "executing with localhost SSRF is blocked":
    let args = {"url": %"http://127.0.0.1:8080/admin"}.toTable
    let result = waitFor tool.execute(args)
    check "local" in result.toLowerAscii() or "block" in result.toLowerAscii()

  test "executing with localhost alias SSRF is blocked":
    let args = {"url": %"http://2130706433/admin"}.toTable
    let result = waitFor tool.execute(args)
    check "local" in result.toLowerAscii() or "block" in result.toLowerAscii()

  test "executing with unsupported method fails":
    let args = {"url": %"https://example.com", "method": %"INVALID"}.toTable
    let result = waitFor tool.execute(args)
    check "unsupported" in result.toLowerAscii()

  test "redactHeadersForDisplay redacts sensitive api keys":
    let headers = [("Authorization", "Bearer secret-token"), ("Content-Type", "application/json")]
    let redacted = redactHeadersForDisplay(headers)
    check "REDACTED" in redacted
    check "secret-token" notin redacted
    check "application/json" in redacted

  test "redactHeadersForDisplay redacts custom api keys":
    let headers = [("x-api-key", "my-key"), ("X-Secret-Token", "tok-123")]
    let redacted = redactHeadersForDisplay(headers)
    check "my-key" notin redacted
    check "tok-123" notin redacted
