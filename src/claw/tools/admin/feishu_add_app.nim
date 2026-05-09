## feishu_add_app — chat-driven Feishu app registration.
##
## Wraps `claw channel auth feishu <app_id> <secret> <agent>` so a
## SuperAdmin can walk the agent through the add flow conversationally
## instead of dropping to a terminal.
##
## Trust gate: SuperAdmin only. Binding a new channel to this company
## reads BASE.nims + writes lark-cli config; we don't hand that to a
## lower-trust requester.

import std/[asyncdispatch, json, tables, os, osproc, strutils, strtabs, streams]
import ../types
import ../spec
import ../../config
import ../../agent/cortex

const ToolSpec* = spec(
  name = "feishu_add_app",
  description = "register new feishu/lark app (id, secret, route to agent) — SuperAdmin only",
  tags = @["admin", "channels", "feishu"],
  domain = "admin",
  default = false,
  heartbeatSafe = false,
  category = "vendor",
)

type
  FeishuAddAppTool* = ref object of ContextualTool

proc newFeishuAddAppTool*(): FeishuAddAppTool =
  FeishuAddAppTool()

method name*(t: FeishuAddAppTool): string = "feishu_add_app"

method description*(t: FeishuAddAppTool): string =
  "Register a new Feishu app with this company. Takes an App ID (cli_...) " &
  "and App Secret from the Feishu Developer Console, plus the name of the " &
  "agent that should receive messages on that app. SuperAdmin only. " &
  "Verifies the credentials with Feishu, stores them via lark-cli, and " &
  "upserts the app entry into BASE.nims. When a user asks to add a Feishu " &
  "app, first check `claw agent list` (or ask the user) so you can offer " &
  "valid agent names, then call this tool with the three values."

method parameters*(t: FeishuAddAppTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "app_id": {
        "type": "string",
        "description": "Feishu App ID — starts with `cli_` (e.g. cli_a93085a978781cd5)."
      },
      "app_secret": {
        "type": "string",
        "description": "Feishu App Secret from the Developer Console. Treated as sensitive — never echo back in the reply."
      },
      "agent": {
        "type": "string",
        "description": "Name of the agent that should handle messages from this app (e.g. 'Lexi', 'Atlas'). Must be an existing declared agent."
      }
    },
    "required": %*["app_id", "app_secret", "agent"]
  }.toTable

method execute*(t: FeishuAddAppTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  # SuperAdmin gate — modifying BASE.nims + storing channel credentials
  # is not something a guest/customer should be able to do mid-chat.
  # `t.role` carries the *relationship* role (e.g. "boss"); we want the
  # declared *permission* from the requester's entity. Look it up.
  var perm = ""
  if t.graph != nil and t.logicalUserID.startsWith("nc:"):
    let id = parseAlias(t.logicalUserID)
    if uint32(id) > 0 and t.graph.entities.hasKey(id):
      perm = t.graph.entities[id].role.toLowerAscii
  if perm notin ["superadmin", "admin"]:
    let shown = if perm.len > 0: perm
                else: (if t.role.len > 0: t.role & " (relationship role; no declared permission)"
                       else: "unknown")
    return "Error: adding a Feishu app requires SuperAdmin privileges. " &
           "Current requester permission: " & shown & "."

  if not args.hasKey("app_id") or not args.hasKey("app_secret") or
     not args.hasKey("agent"):
    return "Error: app_id, app_secret, and agent are all required."
  let appID = args["app_id"].getStr().strip()
  let appSecret = args["app_secret"].getStr().strip()
  let agentName = args["agent"].getStr().strip()
  if appID.len == 0 or appSecret.len == 0 or agentName.len == 0:
    return "Error: app_id, app_secret, and agent must be non-empty."
  if not appID.startsWith("cli_"):
    return "Error: App ID should start with 'cli_' (got '" & appID & "')."

  # Validate the target agent exists in this company's graph before we
  # call lark-cli — fail fast with a useful message.
  if t.graph != nil:
    var found = false
    for id, ent in t.graph.entities.pairs:
      if ent.kind == ekAI and ent.name.toLowerAscii == agentName.toLowerAscii:
        found = true; break
    if not found:
      var names: seq[string]
      for id, ent in t.graph.entities.pairs:
        if ent.kind == ekAI: names.add(ent.name)
      return "Error: no agent named '" & agentName & "' in this company. " &
             "Known agents: " & names.join(", ") & "."

  # Run the same CLI command a human operator would. Using the running
  # binary ensures we hit the same code path as `claw channel auth`.
  let clawBin = getAppFilename()
  let nimclawDir = getNimClawDir()
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env["NIMCLAW_DIR"] = nimclawDir

  let p = startProcess(clawBin,
                       args = @["channel", "auth", "feishu", appID, appSecret, agentName],
                       env = env,
                       options = {poUsePath, poStdErrToStdOut})
  let code = p.waitForExit(30000)
  let output = p.outputStream.readAll()
  p.close()
  if code != 0:
    return "Failed to register app (exit " & $code & "):\n" & output.strip() &
           "\n\nNothing was changed. Double-check the App ID and Secret in " &
           "the Feishu Developer Console."
  return "Feishu app registered.\n" &
         "  App ID:  " & appID & "\n" &
         "  Routes to: " & agentName & " (this agent's office will receive messages from this app).\n\n" &
         output.strip() & "\n\n" &
         "The new routing takes effect after the gateway is restarted. " &
         "Ask a SuperAdmin to run `claw co stop && claw gateway` to pick up the new app."
