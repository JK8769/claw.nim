## tools — the sea (workforce/capabilities) of the tools / office / company trio.
##
## The agent's craft surface for non-foundation tools: discovery + lifecycle.
## Foundation tools (the framework's built-in 28 or so) ship with the binary
## and are managed by the framework itself. THIS tool is for the additional
## tier — what the agent's company has installed, and what they author.
##
## Actions:
##   find    — discover tools by keyword (was the standalone find_tools)
##   show    — read a tool's description + per-agent gotcha overlay
##   forge   — author a new tool. Default type=cli (a shell-callable script
##             wrapper). For MCP servers, use `tools method=mcp.forge`.
##   update  — rewrite an authored tool's script/spec (workstation-tier only)
##   remove  — delete an authored CLI tool (workstation-tier only)
##   share   — propose a workstation tool for company-tier promotion
##   add_gotcha — append a learned failure mode to the per-agent overlay
##
## Sibling tools on this trio:
##   office   — ship  (agent's vessel — clock/calendar/state/etc.)
##   company  — navigator (org-level direction; cross-office views)

import std/[asyncdispatch, json, tables, strutils, sets, sequtils, os, times]
import ../types, ../registry
import ../spec
import ../cli/cli_tool as cli_tool_mod
import ../cli/forge as cli_forge
import ../../logger

const ToolSpec* = spec(
  name = "tools",
  description = "Agent's craft surface for non-foundation tools. find = discover by keyword. forge = author a CLI-script tool (type=cli, default) or route to mcp.forge. update / remove = manage authored CLI tools. share = propose workstation tool for company-tier promotion.",
  tags = @["utility", "core", "meta", "tools"],
  searchKeywords = @["tools", "find tool", "discover", "search", "activate",
                      "forge", "author", "create tool", "share tool",
                      "remove tool", "update tool", "tool surface",
                      "find_tools"],
  domain = "agent",
  default = true,
  heartbeatSafe = false,
  category = "discovery",
)

const
  DefaultToolTTL* = 5  ## Default turns before an activated tool expires

type
  FindTools* = ref object of Tool
    registry*: ToolRegistry
    activated*: Table[string, int]  ## tool name -> remaining TTL (turns)
    subTools*: Table[string, Tool]  ## sub-tool dispatch (e.g. "mcp" → UnifiedMcpTool).
                                    ## Routed by execute() as `tools method=mcp.<op>`.
    officeDir*: string              ## per-agent office for gotcha overlays.

proc newFindTools*(registry: ToolRegistry, officeDir: string = ""): FindTools =
  FindTools(registry: registry, activated: initTable[string, int](),
             subTools: initTable[string, Tool](),
             officeDir: officeDir)

proc registerSubTool*(t: FindTools, name: string, handler: Tool) =
  ## Register a sub-namespace under tools (e.g. "mcp" routes
  ## `tools method=mcp.<op>` to handler.execute()).
  t.subTools[name.toLowerAscii] = handler

proc activateWithTTL*(t: FindTools, name: string, ttl: int = DefaultToolTTL) =
  ## Activate a tool with a TTL. Re-activating resets the TTL.
  t.activated[name] = ttl

proc tickTTL*(t: FindTools) =
  ## Decrement TTL for all activated tools. Remove expired ones.
  var expired: seq[string] = @[]
  for name, ttl in t.activated.pairs:
    if ttl <= 1:
      expired.add(name)
    else:
      t.activated[name] = ttl - 1
  for name in expired:
    t.activated.del(name)

proc getActivated*(t: FindTools): seq[string] =
  for s in t.activated.keys: result.add(s)

proc getActivatedSet*(t: FindTools): HashSet[string] =
  for s in t.activated.keys: result.incl(s)

method name*(t: FindTools): string = "tools"
method description*(t: FindTools): string =
  "Agent's craft surface for non-foundation tools.\n\n" &
  "Actions:\n" &
  "  find   — search for and activate tools by keyword (e.g. 'git commit'). " &
  "Found tools become available for " & $DefaultToolTTL & " turns.\n" &
  "  show   — print a tool's canonical description plus your per-agent " &
  "gotcha overlay (if any).\n" &
  "  forge  — author a new CLI-script tool. Default type=cli: pass `name`, " &
  "`description`, `script` (must start with a whitelisted shebang), and " &
  "`parameters` (JSON-schema object). Registered immediately and persisted to " &
  "<office>/workstation/cli/<name>/ for next session.\n" &
  "  update — rewrite an authored CLI tool. Any of `script`, " &
  "`description`, `parameters`, `timeout_ms` may be omitted to keep its " &
  "current value. Workstation-tier only.\n" &
  "  remove — delete an authored CLI tool (workstation-tier only).\n" &
  "  share  — propose a workstation tool for company-tier promotion. " &
  "Writes a manifest under <company>/workspace/proposals/tools/<name>/ for " &
  "operator review.\n" &
  "  add_gotcha — append a learned failure mode to your per-agent overlay.\n" &
  "  mcp.<op> — sub-routes for MCP-server lifecycle (forge/persist/purge).\n\n" &
  "Foundation tools (the framework's built-ins) are always available; " &
  "this tool manages discovery + lifecycle for the additional tier."

method parameters*(t: FindTools): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": %*{
        "type": "string",
        "enum": ["find", "show", "forge", "update", "share", "remove",
                 "add_gotcha"],
        "description": "Operation. find=discover; show=read description; forge=author CLI tool; update=rewrite authored tool; remove=delete authored tool; share=propose for promotion; add_gotcha=append per-agent learned failure. Sub-routes: mcp.<op> (MCP-server forge/persist/purge)."
      },
      "query": %*{
        "type": "string",
        "description": "find — keywords (e.g. 'browser login', 'git commit', 'cron schedule')."
      },
      "name": %*{
        "type": "string",
        "description": "show/forge/update/remove/share/add_gotcha — tool name (kebab/snake-case, lowercase letters, digits, '-' or '_', max 60 chars)."
      },
      "description": %*{
        "type": "string",
        "description": "forge/update — one-sentence description that helps the LLM choose this tool from the catalog."
      },
      "script": %*{
        "type": "string",
        "description": "forge/update — full executable script body. MUST start with an allowed shebang (e.g. '#!/usr/bin/env bash', '#!/usr/bin/env python3'). Reads JSON args on stdin; writes a single string to stdout. Non-zero exit → error to caller."
      },
      "parameters": %*{
        "type": "object",
        "description": "forge/update — JSON-schema object describing the tool's args. Must have type='object' and a 'properties' object. Validated at write time."
      },
      "timeout_ms": %*{
        "type": "integer",
        "description": "forge/update — per-invocation timeout in ms (default 30000, min 1000)."
      },
      "type": %*{
        "type": "string",
        "enum": ["cli"],
        "description": "forge only — 'cli' (default). For MCP servers use `tools method=mcp.forge` instead — the protocols differ enough to warrant separate authoring paths."
      },
      "gotcha": %*{
        "type": "string",
        "description": "add_gotcha only — one-paragraph description of the failure mode + how to avoid it. Appended to <office>/tools_overlay/<name>/gotchas.md with timestamp."
      },
      "include_overlay": %*{
        "type": "boolean",
        "description": "show only — when true (default), include the per-agent gotcha overlay below the canonical description."
      },
      "rationale": %*{
        "type": "string",
        "description": "share only — explain WHY this tool deserves company-tier promotion. Goes into the proposal manifest for the operator."
      }
    },
    "required": %*["method"]
  }.toTable

proc doFind(t: FindTools, args: Table[string, JsonNode]): string =
  let query = args.getOrDefault("query", %"").getStr().toLowerAscii()
  if query.len == 0:
    return "Error: 'query' is required for find"
  let keywords = query.split(" ")
  let matches = t.registry.searchTools(keywords)
  if matches.len == 0:
    return "No tools found matching '" & query & "'. Try different keywords."
  for m in matches:
    t.activateWithTTL(m.name)
  var sb = "Activated " & $matches.len & " tools (available for " &
           $DefaultToolTTL & " turns):\n\n"
  for m in matches:
    sb.add("- `" & m.name & "` — " & m.description & "\n")
  sb.add("\nThese tools are now available. Call them directly. " &
         "Use `tools find` again to refresh or discover more.")
  sb

proc phase2Stub(action: string): string =
  "Error: '" & action & "' is in the action set but not yet implemented " &
  "(planned for Phase 2)."

# ── forge / update / remove (CLI-tool authoring) ─────────────────────
#
# CLI tools are agent-authored shell scripts wrapped as first-class Tools.
# See src/claw/tools/cli/cli_tool.nim for the runtime contract; forge.nim
# for the validation rules. These three procs orchestrate write + register.

proc isCliTool(t: Tool): bool =
  ## Detect whether a registered tool is one of OUR authored CLI wrappers
  ## (so update/remove can refuse to touch foundation tools).
  if t.isNil: return false
  t of CliTool

proc doForge(t: FindTools, args: Table[string, JsonNode]): string =
  let kind = if args.hasKey("type"): args["type"].getStr().toLowerAscii() else: "cli"
  if kind != "cli":
    return "Error: forge type='" & kind &
           "' not supported. Use type='cli' (default) for a CLI-script tool, " &
           "or call `tools method=mcp.forge` for an MCP server."

  if not args.hasKey("name"):
    return "Error: 'name' is required for forge"
  if not args.hasKey("description"):
    return "Error: 'description' is required for forge — a one-sentence " &
           "summary that helps the LLM choose this tool from the catalog."
  if not args.hasKey("script"):
    return "Error: 'script' is required for forge — the full executable " &
           "body. MUST start with an allowed shebang."
  if not args.hasKey("parameters"):
    return "Error: 'parameters' is required for forge — a JSON-schema " &
           "object describing the tool's args."

  let name = args["name"].getStr().strip()
  let description = args["description"].getStr().strip()
  let script = args["script"].getStr()
  let parameters = args["parameters"]
  let timeoutMs = if args.hasKey("timeout_ms"):
                     args["timeout_ms"].getInt(DefaultTimeoutMs)
                  else: DefaultTimeoutMs

  # Refuse to shadow a foundation/company tool with the same name.
  let (existing, found) = t.registry.get(name)
  if found and not isCliTool(existing):
    return "Error: '" & name & "' is already registered as a " &
           "foundation/company tool. Pick a different name to avoid " &
           "shadowing — your CLI tool would be invisible behind it."
  if found and isCliTool(existing):
    return "Error: a CLI tool named '" & name & "' already exists. Use " &
           "`tools method=update name=" & name & "` to rewrite it."

  let (ok, msg, tool) = writeCliTool(t.officeDir, name, description, script,
                                      parameters, timeoutMs,
                                      overwrite = false)
  if not ok: return msg

  t.registry.register(tool, hidden = false, allowOverride = false)
  t.activateWithTTL(name)  ## immediately usable this turn
  infoCF("tool", "CLI tool forged",
         {"name": name, "office": t.officeDir, "bytes": $script.len}.toTable)
  return "Forged CLI tool '" & name & "' at " &
         cliToolDir(t.officeDir, name) & "\n" &
         "  - Registered and activated for this session (and " &
         $DefaultToolTTL & " turns).\n" &
         "  - Survives gateway restarts via the workstation/cli loader.\n" &
         "  - Call it directly: `" & name & " <args>`.\n" &
         "  - Refine with `tools method=update name=" & name & "`."

proc doUpdate(t: FindTools, args: Table[string, JsonNode]): string =
  if not args.hasKey("name"):
    return "Error: 'name' is required for update"
  let name = args["name"].getStr().strip()
  let (existing, found) = t.registry.get(name)
  if not found:
    return "Error: no tool named '" & name & "' is registered. Use " &
           "`tools method=forge` to author it, or `tools method=find " &
           "query=...` to locate an existing one."
  if not isCliTool(existing):
    return "Error: '" & name & "' is a foundation/company tool — its " &
           "source is framework-controlled. To accumulate learnings, use " &
           "`tools method=add_gotcha name=" & name & "` instead."

  let existingCli = CliTool(existing)
  # Load current on-disk values as the baseline so partial updates work.
  let currentDescription = existingCli.toolDescription
  var currentParams = newJObject()
  for k, v in existingCli.toolParams.pairs: currentParams[k] = v
  let currentTimeout = existingCli.timeoutMs
  let currentScript = if fileExists(existingCli.scriptPath):
                        readFile(existingCli.scriptPath)
                      else: ""

  let nextDescription = if args.hasKey("description"):
                           args["description"].getStr().strip()
                        else: currentDescription
  let nextScript = if args.hasKey("script"): args["script"].getStr()
                   else: currentScript
  let nextParams = if args.hasKey("parameters"): args["parameters"]
                   else: currentParams
  let nextTimeout = if args.hasKey("timeout_ms"):
                       args["timeout_ms"].getInt(currentTimeout)
                    else: currentTimeout

  if nextScript.len == 0:
    return "Error: no existing script found and 'script' not provided — " &
           "nothing to write."

  let (ok, msg, tool) = writeCliTool(t.officeDir, name, nextDescription,
                                      nextScript, nextParams, nextTimeout,
                                      overwrite = true)
  if not ok: return msg

  t.registry.register(tool, hidden = false, allowOverride = true)
  infoCF("tool", "CLI tool updated",
         {"name": name, "office": t.officeDir,
          "bytes": $nextScript.len}.toTable)
  var changed: seq[string]
  if args.hasKey("script"): changed.add("script")
  if args.hasKey("description"): changed.add("description")
  if args.hasKey("parameters"): changed.add("parameters")
  if args.hasKey("timeout_ms"): changed.add("timeout_ms")
  return "Updated CLI tool '" & name & "' at " &
         cliToolDir(t.officeDir, name) & "\n" &
         "  - Fields changed: " &
         (if changed.len > 0: changed.join(", ") else: "(none — no-op)") & "\n" &
         "  - New registration replaces the old in this session."

proc doRemove(t: FindTools, args: Table[string, JsonNode]): string =
  if not args.hasKey("name"):
    return "Error: 'name' is required for remove"
  let name = args["name"].getStr().strip()
  let (existing, found) = t.registry.get(name)
  if not found:
    return "Error: no tool named '" & name & "' is registered."
  if not isCliTool(existing):
    return "Error: '" & name & "' is a foundation/company tool — those " &
           "ship with the framework or company config and aren't removable " &
           "via this surface. (You can `tools method=add_gotcha` to record " &
           "learned failures.)"

  let keepSource = if args.hasKey("delete_source"):
                      not args["delete_source"].getBool(false)
                   else: true
  let (ok, msg) = removeCliTool(t.officeDir, name, keepSource = keepSource)
  if not ok: return msg

  t.registry.unregisterMcpServer(name)
  ## ^^ harmless if it wasn't an MCP server. The registry also exposes a
  ## plain unregister path internally via session cleanup; for CLI tools
  ## we rely on `allowOverride` semantics — the next forge with the same
  ## name replaces the entry. To force immediate removal from the live
  ## table we'd need a public `unregister(name)` on ToolRegistry; for now
  ## the agent should restart the session if they want it gone NOW.
  if name in t.activated: t.activated.del(name)
  infoCF("tool", "CLI tool removed",
         {"name": name, "office": t.officeDir,
          "keep_source": $keepSource}.toTable)
  msg & "\n  - Catalog entry will clear on next gateway restart " &
        "(in-session it stays registered as a stale stub)."

# ── share (propose for company-tier promotion) ───────────────────────
#
# Writes a JSON proposal manifest under <project>/workspace/proposals/tools/
# for operator review. No automatic merge — the operator (human) decides
# whether to copy the tool into <project>/workspace/skills-equivalent CLI
# location. The manifest captures everything an operator needs: name,
# description, parameters, script body, rationale, author agent.

proc doShare(t: FindTools, args: Table[string, JsonNode]): string =
  if not args.hasKey("name"):
    return "Error: 'name' is required for share"
  if not args.hasKey("rationale"):
    return "Error: 'rationale' is required for share — explain WHY this " &
           "tool deserves company-tier promotion (use cases, frequency, " &
           "what it unlocks)."
  let name = args["name"].getStr().strip()
  let rationale = args["rationale"].getStr().strip()
  let (existing, found) = t.registry.get(name)
  if not found:
    return "Error: no tool named '" & name & "' is registered."
  if not isCliTool(existing):
    return "Error: '" & name & "' is a foundation/company tool — it's " &
           "already at or above company tier; nothing to propose."

  let existingCli = CliTool(existing)
  let script = if fileExists(existingCli.scriptPath):
                  readFile(existingCli.scriptPath)
               else: ""
  # Proposals land in the project workspace (one level up from the
  # agent's office dir). officeDir is typically
  # <project>/workspace/offices/<agent>; parent of parent is workspace.
  let projectWorkspace = t.officeDir.parentDir.parentDir
  let proposalsDir = projectWorkspace / "proposals" / "tools" / name
  try:
    if not dirExists(proposalsDir): createDir(proposalsDir)
    var manifest = newJObject()
    manifest["name"] = %name
    manifest["description"] = %existingCli.toolDescription
    manifest["timeout_ms"] = %existingCli.timeoutMs
    var params = newJObject()
    for k, v in existingCli.toolParams.pairs: params[k] = v
    manifest["parameters"] = params
    manifest["rationale"] = %rationale
    manifest["proposed_at"] = %times.now().format("yyyy-MM-dd HH:mm")
    manifest["source_office"] = %t.officeDir
    writeFile(proposalsDir / "manifest.json", manifest.pretty(2))
    if script.len > 0:
      writeFile(proposalsDir / "run", script)
  except CatchableError as e:
    return "Error: failed to write proposal: " & e.msg

  infoCF("tool", "CLI tool share proposed",
         {"name": name, "proposal_dir": proposalsDir}.toTable)
  return "Proposed CLI tool '" & name & "' for company-tier promotion.\n" &
         "  - Manifest: " & proposalsDir / "manifest.json" & "\n" &
         "  - Script:   " & proposalsDir / "run" & "\n" &
         "  - Operator will review and (if approved) copy under " &
         "the company's curated tool directory."

# ── show / add_gotcha ──────────────────────────────────────────────
#
# Mirrors skill.show / skill.add_gotcha. Per-agent overlay accumulates
# learned gotchas about a tool without modifying the framework spec.
#
#   <office>/tools_overlay/<tool-name>/gotchas.md

proc toolOverlayPath(t: FindTools, toolName: string): string =
  t.officeDir / "tools_overlay" / toolName / "gotchas.md"

proc doShow(t: FindTools, args: Table[string, JsonNode]): string =
  if not args.hasKey("name"):
    return "Error: 'name' is required for show"
  let name = args["name"].getStr().strip()
  let (tool, found) = t.registry.get(name)
  if not found:
    return "Error: tool '" & name & "' not registered. Use `tools method=find query=...` to discover."
  var body = "# " & tool.name & "\n\n" & tool.description
  let includeOverlay = if args.hasKey("include_overlay"):
                          args["include_overlay"].getBool(true) else: true
  if includeOverlay and t.officeDir.len > 0:
    let overlayPath = t.toolOverlayPath(tool.name)
    if fileExists(overlayPath):
      try:
        body.add("\n\n---\n\n")
        body.add("# Gotchas (per-agent overlay)\n\n")
        body.add("> Append-only learned failures via `tools method=add_gotcha`. " &
                 "Per-agent — does NOT modify the canonical tool spec.\n\n")
        body.add(readFile(overlayPath))
      except CatchableError: discard
  body

proc doAddGotcha(t: FindTools, args: Table[string, JsonNode]): string =
  if not args.hasKey("name"):
    return "Error: 'name' is required for add_gotcha"
  if not args.hasKey("gotcha"):
    return "Error: 'gotcha' is required (one-paragraph failure mode + how to avoid it)"
  let name = args["name"].getStr().strip()
  let gotcha = args["gotcha"].getStr().strip()
  if gotcha.len == 0:
    return "Error: 'gotcha' must not be empty"
  if t.officeDir.len == 0:
    return "Error: tool not bound to an office workspace"
  let (_, found) = t.registry.get(name)
  if not found:
    return "Error: tool '" & name & "' not registered. Use `tools method=find query=...` first."
  let overlayPath = t.toolOverlayPath(name)
  let overlayDir = parentDir(overlayPath)
  try:
    if not dirExists(overlayDir): createDir(overlayDir)
    let now = times.now().format("yyyy-MM-dd HH:mm")
    let isNew = not fileExists(overlayPath)
    let entry = (if isNew: "" else: "\n\n") &
                "## " & now & "\n\n" & gotcha & "\n"
    let f = open(overlayPath, fmAppend)
    defer: f.close()
    if isNew:
      f.write("# Gotchas overlay for tool `" & name & "`\n\n")
      f.write("Append-only. Each entry is one learned failure mode + how " &
              "to avoid it. Per-agent overlay; does NOT modify the canonical " &
              "tool description.\n")
    f.write(entry)
  except CatchableError as e:
    return "Error: failed to append gotcha: " & e.msg
  return "Appended gotcha to overlay for '" & name & "' at " & overlayPath & "\n" &
         "  - View via `tools method=show name=" & name & "` (overlay rendered below the description)\n" &
         "  - Append-only; future sessions see it accumulated."

method execute*(t: FindTools, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("method"):
    return "Error: 'method' is required (find | forge | update | share | remove | mcp.<op>)"
  let methodPath = getMethodArg(args).toLowerAscii()

  # Parse: split on first dot for sub-tool routing.
  let dotIdx = methodPath.find('.')
  let top = if dotIdx < 0: methodPath else: methodPath[0 ..< dotIdx]
  let rest = if dotIdx < 0: "" else: methodPath[dotIdx + 1 .. ^1]

  case top
  of "find":        return doFind(t, args)
  of "show":        return doShow(t, args)
  of "add_gotcha":  return doAddGotcha(t, args)
  of "forge":       return doForge(t, args)
  of "update":      return doUpdate(t, args)
  of "remove":      return doRemove(t, args)
  of "share":       return doShare(t, args)
  else:
    # Try registered sub-tools (e.g. mcp).
    if t.subTools.hasKey(top):
      var subArgs = initTable[string, JsonNode]()
      subArgs["method"] = %rest
      for k, v in args.pairs:
        if k != "method": subArgs[k] = v
      return await t.subTools[top].execute(subArgs)
    var available: seq[string]
    for s in t.subTools.keys: available.add(s)
    let availStr = if available.len > 0: " | " & available.mapIt(it & ".<op>").join(" | ") else: ""
    return "Error: Unknown method '" & methodPath &
           "'. Use: find | show | add_gotcha | forge | update | share | remove" & availStr
