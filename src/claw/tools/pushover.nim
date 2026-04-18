import std/[json, tables, httpclient, strutils, asyncdispatch, os]
import types

type
  PushoverTool* = ref object of Tool
    workspaceDir*: string

proc newPushoverTool*(workspaceDir: string): PushoverTool =
  PushoverTool(workspaceDir: workspaceDir)

method name*(t: PushoverTool): string = "pushover"

method description*(t: PushoverTool): string = "Send a push notification via Pushover. Requires PUSHOVER_TOKEN and PUSHOVER_USER_KEY in .env file."

method parameters*(t: PushoverTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "message": {"type": "string", "description": "The notification message"},
      "title": {"type": "string", "description": "Optional title"},
      "priority": {"type": "integer", "description": "Priority -2..2 (default 0)"},
      "sound": {"type": "string", "description": "Optional sound name"}
    },
    "required": %["message"]
  }.toTable

proc parseEnvValue*(raw: string): string =
  let trimmed = raw.strip(chars = {' ', '\t', '\r', '\n'})
  if trimmed.len == 0: return trimmed

  let unquoted = if trimmed.len >= 2 and (
    (trimmed[0] == '"' and trimmed[^1] == '"') or
    (trimmed[0] == '\'' and trimmed[^1] == '\'')
  ):
    trimmed[1 ..< ^1]
  else:
    trimmed

  let commentPos = unquoted.find(" #")
  if commentPos != -1:
    return unquoted[0 ..< commentPos].strip(chars = {' ', '\t'})

  return unquoted.strip(chars = {' ', '\t'})

type
  PushoverCreds* = tuple
    token: string
    userKey: string

proc getCredentials*(t: PushoverTool): PushoverCreds =
  let envPath = t.workspaceDir / ".env"
  if not fileExists(envPath):
    raise newException(IOError, "EnvFileNotFound")

  var token = ""
  var userKey = ""

  let content = readFile(envPath)
  for rawLine in content.split('\n'):
    var line = rawLine.strip(chars = {' ', '\t', '\r'})
    if line.len == 0 or line[0] == '#': continue

    if line.startsWith("export "):
      line = line["export ".len .. ^1].strip(chars = {' ', '\t'})

    let eqPos = line.find('=')
    if eqPos != -1:
      let key = line[0 ..< eqPos].strip(chars = {' ', '\t'})
      let value = parseEnvValue(line[eqPos + 1 .. ^1])

      if key == "PUSHOVER_TOKEN":
        token = value
      elif key == "PUSHOVER_USER_KEY":
        userKey = value

  if token == "": raise newException(ValueError, "MissingPushoverToken")
  if userKey == "": raise newException(ValueError, "MissingPushoverUserKey")

  return (token: token, userKey: userKey)

method execute*(t: PushoverTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("message"):
    return "Error: Missing required 'message' parameter"
    
  let message = args["message"].getStr()
  if message.len == 0:
    return "Error: Missing required 'message' parameter"

  if args.hasKey("priority"):
    let p = args["priority"].getInt()
    if p < -2 or p > 2:
      return "Error: Invalid 'priority': expected integer in range -2..=2"

  var creds: PushoverCreds
  try:
    creds = t.getCredentials()
  except IOError:
    return "Error: Failed to load Pushover credentials from .env file (File not found at " & t.workspaceDir & "/.env)"
  except ValueError as e:
    return "Error: Pushover credentials missing in .env: " & e.msg & ". Please ensure both PUSHOVER_TOKEN and PUSHOVER_USER_KEY are set."
    
  # In testing, we don't dispatch live network calls
  let isTesting = defined(testing)
  if isTesting:
    return "Notification sent successfully (simulation)"

  var form = newMultipartData()
  form["token"] = creds.token
  form["user"] = creds.userKey
  form["message"] = message

  if args.hasKey("title"): form["title"] = args["title"].getStr()
  if args.hasKey("priority"): form["priority"] = $args["priority"].getInt()
  if args.hasKey("sound"): form["sound"] = args["sound"].getStr()

  let client = newAsyncHttpClient()
  try:
    let response = await client.post("https://api.pushover.net/1/messages.json", multipart=form)
    let body = await response.body
    if "\"status\":1" in body:
      return "Notification sent successfully"
    else:
      return "Error: Pushover API returned an error: " & body
  except Exception as e:
    return "Error: Failed to send Pushover request: " & e.msg
  finally:
    client.close()
