import std/[unittest, json, tables, os, strutils, asyncdispatch]
import ../src/nimclaw/tools/types
import ../src/nimclaw/tools/composio

suite "ComposioTool String Helpers":
  test "normalizeToolSlug converts UPPER_SNAKE_CASE to kebab-case":
    check normalizeToolSlug("GMAIL_SEND_EMAIL") == "gmail-send-email"
    check normalizeToolSlug("  GITHUB_STAR_REPO  ") == "github-star-repo"

  test "normalizeToolSlug ignores already-kebab inputs":
    check normalizeToolSlug("slack-send-message") == "slack-send-message"

  test "normalizeEntityId defaults to 'default' if empty":
    check normalizeEntityId("") == "default"
    check normalizeEntityId("   ") == "default"

  test "normalizeEntityId trims whitespace around inputs":
    check normalizeEntityId("  workspace-12  ") == "workspace-12"

  test "extractApiErrorMessage parses nested message format":
    let jsonPayload = """{"error":{"message":"tool not found"}}"""
    check extractApiErrorMessage(jsonPayload) == "tool not found"

  test "extractApiErrorMessage parses direct message format":
    let jsonPayload = """{"message":"invalid api key"}"""
    check extractApiErrorMessage(jsonPayload) == "invalid api key"

  test "sanitizeErrorMessage redacts long secrets and truncates":
    let secret = "A".repeat(30)
    let msg = "The hidden token is " & secret
    check sanitizeErrorMessage(msg) == "The hidden token is [REDACTED]"
    
    let longMsg = "word ".repeat(50)
    let sanitized = sanitizeErrorMessage(longMsg)
    check sanitized.len == 243
    check sanitized.endsWith("...")

suite "ComposioTool Parameters":
  test "tool name":
    let t = newComposioTool("test-key")
    check t.name() == "composio"

  test "schema validates required fields":
    let t = newComposioTool("test-key")
    let schema = t.parameters()
    check schema["required"].contains(%"action")
    check schema["properties"].hasKey("action")
    check schema["properties"].hasKey("app")
    check schema["properties"].hasKey("tool_slug")
    check schema["properties"].hasKey("params")

  test "requires action parameter on execution":
    let t = newComposioTool("test-key")
    let args = {"app": %"github"}.toTable
    let result = waitFor t.execute(args)
    check "Missing 'action' parameter" in result

  test "rejects operation if configured without API key":
    let t = newComposioTool("")
    let args = {"action": %"list"}.toTable
    let result = waitFor t.execute(args)
    check "Composio API key not configured" in result

  test "connect action dictates missing app/auth_config_id":
    let t = newComposioTool("test-key")
    # Simulate a `connect` action but provide nothing
    let args = {"action": %"connect"}.toTable
    let result = waitFor t.execute(args)
    check "Missing 'app' or 'auth_config_id' for connect" in result

  test "execute action mandates tool_slug or action_name":
    let t = newComposioTool("test-key")
    let args = {"action": %"execute"}.toTable
    let result = waitFor t.execute(args)
    check "Missing 'action_name' (or 'tool_slug') for execute" in result
