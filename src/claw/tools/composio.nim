import std/[json, tables, httpclient, strutils, asyncdispatch, uri, options]
import types

const COMPOSIO_API_BASE_V3 = "https://backend.composio.dev/api/v3"
const COMPOSIO_API_BASE_V2 = "https://backend.composio.dev/api/v2"

type
  ComposioTool* = ref object of Tool
    apiKey*: string
    entityId*: string

proc newComposioTool*(apiKey: string, entityId: string = "default"): ComposioTool =
  ComposioTool(apiKey: apiKey, entityId: entityId)

method name*(t: ComposioTool): string = "composio"

method description*(t: ComposioTool): string =
  "Execute actions on 1000+ apps via Composio (Gmail, Notion, GitHub, Slack, etc.). " &
  "Use action='list' to see available actions, action='execute' with action_name/tool_slug and params, " &
  "or action='connect' with app/auth_config_id to get OAuth URL."

method parameters*(t: ComposioTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {"type": "string", "enum": ["list", "execute", "connect"], "description": "Operation: list, execute, or connect"},
      "app": {"type": "string", "description": "App/toolkit filter for list, or app for connect"},
      "action_name": {"type": "string", "description": "Action identifier to execute"},
      "tool_slug": {"type": "string", "description": "Preferred v3 tool slug (alias of action_name)"},
      "params": {"type": "object", "description": "Parameters for the action"},
      "entity_id": {"type": "string", "description": "Entity/user ID for multi-user setups"},
      "auth_config_id": {"type": "string", "description": "Optional v3 auth config id for connect"},
      "connected_account_id": {"type": "string", "description": "Optional connected account ID for execute"}
    },
    "required": %*["action"]
  }.toTable

# ── Helper functions ────────────────────────────────────────────────

proc normalizeToolSlug*(name: string): string =
  result = ""
  for c in name.strip():
    if c == '_':
      result.add('-')
    else:
      result.add(c.toLowerAscii())
  return result

proc normalizeEntityId*(entityId: string): string =
  let trimmed = entityId.strip()
  if trimmed.len > 0:
    return trimmed
  return "default"

proc extractApiErrorMessage*(body: string): string =
  try:
    let parsed = parseJson(body)
    if parsed.hasKey("error") and parsed["error"].kind == JObject:
      if parsed["error"].hasKey("message") and parsed["error"]["message"].kind == JString:
        return parsed["error"]["message"].getStr()
    if parsed.hasKey("message") and parsed["message"].kind == JString:
      return parsed["message"].getStr()
  except JsonParsingError:
    discard
  return ""

proc sanitizeErrorMessage*(msg: string): string =
  var sanitized = msg.replace("\n", " ")
  
  # Scan for long alphanumeric runs (potential tokens) and redact
  result = ""
  var i = 0
  while i < sanitized.len:
    if sanitized[i].isAlphaNumeric:
      let start = i
      while i < sanitized.len and sanitized[i].isAlphaNumeric: i.inc
      if i - start > 20:
        result.add("[REDACTED]")
      else:
        result.add(sanitized[start..<i])
    else:
      result.add(sanitized[i])
      i.inc

  if result.len <= 240:
    return result
  else:
    return result[0..<240] & "..."

# ── HTTP helpers ───────────────────────────────────────────────

proc httpGet(t: ComposioTool, url: string): Future[string] {.async.} =
  let client = newAsyncHttpClient()
  client.headers = newHttpHeaders([("x-api-key", t.apiKey)])
  try:
    let response = await client.request(url, HttpGet)
    let body = await response.body
    if response.code.is2xx:
      return body
    else:
      let apiMsg = extractApiErrorMessage(body)
      let outMsg = if apiMsg.len > 0: apiMsg else: "HTTP " & $(response.code)
      return "Composio API Error: " & sanitizeErrorMessage(outMsg)
  except Exception as e:
    return "Network Error: " & e.msg
  finally:
    client.close()

proc httpPost(t: ComposioTool, url: string, bodyJson: string): Future[string] {.async.} =
  let client = newAsyncHttpClient()
  client.headers = newHttpHeaders([
    ("x-api-key", t.apiKey),
    ("Content-Type", "application/json")
  ])
  try:
    let response = await client.request(url, HttpPost, bodyJson)
    let resBody = await response.body
    if response.code.is2xx:
      return resBody
    else:
      let apiMsg = extractApiErrorMessage(resBody)
      let outMsg = if apiMsg.len > 0: apiMsg else: "HTTP " & $(response.code)
      return "Composio API Error: " & sanitizeErrorMessage(outMsg)
  except Exception as e:
    return "Network Error: " & e.msg
  finally:
    client.close()

# ── Actions ──────────────────────────────────────────────────

proc listActionsV3(t: ComposioTool, appName: Option[string]): Future[string] {.async.} =
  let url = if appName.isSome:
    COMPOSIO_API_BASE_V3 & "/tools?toolkits=" & encodeUrl(appName.get) & "&page=1&page_size=100"
  else:
    COMPOSIO_API_BASE_V3 & "/tools?page=1&page_size=100"
  return await t.httpGet(url)

proc listActionsV2(t: ComposioTool, appName: Option[string]): Future[string] {.async.} =
  let url = if appName.isSome:
    COMPOSIO_API_BASE_V2 & "/actions?appNames=" & encodeUrl(appName.get)
  else:
    COMPOSIO_API_BASE_V2 & "/actions"
  return await t.httpGet(url)

proc listActions(t: ComposioTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let app = if args.hasKey("app"): some(args["app"].getStr()) else: none(string)
  let v3Res = await t.listActionsV3(app)
  if not v3Res.startsWith("Composio API Error"): return v3Res
  return await t.listActionsV2(app)

proc executeActionV3(t: ComposioTool, actionName: string, args: Table[string, JsonNode], entityId: Option[string], connectedAccountId: Option[string]): Future[string] {.async.} =
  let slug = normalizeToolSlug(actionName)
  let url = COMPOSIO_API_BASE_V3 & "/tools/" & encodeUrl(slug) & "/execute"
  let eid = normalizeEntityId(if entityId.isSome: entityId.get else: t.entityId)

  var payload = %*{
    "user_id": eid
  }
  
  if args.hasKey("params"):
    payload["arguments"] = args["params"]
  else:
    payload["arguments"] = newJObject()

  if connectedAccountId.isSome:
    payload["connected_account_id"] = %*(connectedAccountId.get)

  return await t.httpPost(url, $payload)

proc executeActionV2(t: ComposioTool, actionName: string, args: Table[string, JsonNode]): Future[string] {.async.} =
  let url = COMPOSIO_API_BASE_V2 & "/actions/" & encodeUrl(actionName) & "/execute"
  
  # For v2, the entire args object is typically sent, wrapped appropriately or direct
  let payload = %args
  return await t.httpPost(url, $payload)

proc executeAction(t: ComposioTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  var actionNameRaw = ""
  if args.hasKey("tool_slug"): actionNameRaw = args["tool_slug"].getStr()
  elif args.hasKey("action_name"): actionNameRaw = args["action_name"].getStr()
  
  if actionNameRaw.len == 0:
    return "Missing 'action_name' (or 'tool_slug') for execute"

  let entityIdStr = if args.hasKey("entity_id"): some(args["entity_id"].getStr()) else: none(string)
  let connectedStr = if args.hasKey("connected_account_id"): some(args["connected_account_id"].getStr()) else: none(string)

  let v3Res = await t.executeActionV3(actionNameRaw, args, entityIdStr, connectedStr)
  if not v3Res.startsWith("Composio API Error") and not v3Res.startsWith("Network Error"):
    return v3Res

  return await t.executeActionV2(actionNameRaw, args)

proc connectActionV3(t: ComposioTool, app: Option[string], entity: string): Future[string] {.async.} =
  if app.isNone: return "Missing 'app' for v3 connect"
  let url = COMPOSIO_API_BASE_V3 & "/connected_accounts/link"
  let payload = %*{"user_id": entity}
  return await t.httpPost(url, $payload)

proc connectAction(t: ComposioTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let appStr = if args.hasKey("app"): some(args["app"].getStr()) else: none(string)
  if appStr.isNone and not args.hasKey("auth_config_id"):
    return "Missing 'app' or 'auth_config_id' for connect"

  let entityRawStr = if args.hasKey("entity_id"): some(args["entity_id"].getStr()) else: none(string)
  let entity = normalizeEntityId(if entityRawStr.isSome: entityRawStr.get else: t.entityId)

  let v3Res = await t.connectActionV3(appStr, entity)
  if not v3Res.startsWith("Composio API Error") and not v3Res.startsWith("Network Error"):
    return v3Res

  let appForV2 = if appStr.isSome: appStr.get else: return "Missing 'app' for connect (v2 fallback)"
  
  # V2 connection API fallback
  let url = COMPOSIO_API_BASE_V2 & "/connectedAccounts"
  let payload = %*{
    "entity_id": entity,
    "appName": appForV2
  }
  return await t.httpPost(url, $payload)

method execute*(t: ComposioTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.apiKey.len == 0:
    # Attempt to bypass network calls for pure parsing tests locally using a dummy
    # but actual tool execution fails if empty, same as rust/zig.
    return "Composio API key not configured. Set COMPOSIO_API_KEY environment variable."

  let action = if args.hasKey("action"): args["action"].getStr() else: ""
  if action == "":
    return "Missing 'action' parameter"

  if action == "list":
    return await t.listActions(args)
  elif action == "execute":
    return await t.executeAction(args)
  elif action == "connect":
    return await t.connectAction(args)
  else:
    return "Unknown action '" & action & "'. Use 'list', 'execute', or 'connect'."
