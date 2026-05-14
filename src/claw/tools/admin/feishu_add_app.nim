## feishu_add_app — chat-driven Feishu app registration helper.
##
## Formerly an agent-facing `feishu_add_app` tool; folded into
## `channel method=add_app vendor=feishu`. The detection + dispatch
## logic stays here as a callable proc; channel_unified imports it.
##
## Trust gate: SuperAdmin only. Binding a new channel to this company
## reads BASE.nims + writes lark-cli config; we don't hand that to a
## lower-trust requester.

import std/[json, os, osproc, strutils, strtabs, streams, tables]
import ../../config
import ../../agent/cortex

proc runFeishuAddApp*(graph: WorldGraph,
                      role: string,
                      logicalUserID: string,
                      appID: string,
                      appSecret: string,
                      agentName: string): string =
  ## Register a new Feishu app with this company. Returns a human-readable
  ## message (success or error). All inputs validated; subprocess error
  ## paths surfaced. Used by `channel method=add_app vendor=feishu` —
  ## the channel tool's add_app handler calls this proc directly.

  # SuperAdmin gate — modifying BASE.nims + storing channel credentials
  # is not something a guest/customer should be able to do mid-chat.
  # `role` carries the *relationship* role (e.g. "boss"); we want the
  # declared *permission* from the requester's entity. Look it up.
  var perm = ""
  if graph != nil and logicalUserID.startsWith("nc:"):
    let id = parseAlias(logicalUserID)
    if uint32(id) > 0 and graph.entities.hasKey(id):
      perm = graph.entities[id].role.toLowerAscii
  if perm notin ["superadmin", "admin"]:
    let shown = if perm.len > 0: perm
                else: (if role.len > 0: role & " (relationship role; no declared permission)"
                       else: "unknown")
    return "Error: adding a Feishu app requires SuperAdmin privileges. " &
           "Current requester permission: " & shown & "."

  if appID.len == 0 or appSecret.len == 0 or agentName.len == 0:
    return "Error: app_id, app_secret, and agent must be non-empty."
  if not appID.startsWith("cli_"):
    return "Error: App ID should start with 'cli_' (got '" & appID & "')."

  # Validate the target agent exists in this company's graph before we
  # call lark-cli — fail fast with a useful message.
  if graph != nil:
    var found = false
    for id, ent in graph.entities.pairs:
      if ent.kind == ekAI and ent.name.toLowerAscii == agentName.toLowerAscii:
        found = true; break
    if not found:
      var names: seq[string]
      for id, ent in graph.entities.pairs:
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
