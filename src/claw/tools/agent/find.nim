## tools — the sea (workforce/capabilities) of the tools / office / company trio.
##
## The agent's craft surface for non-foundation tools: discovery + lifecycle.
## Foundation tools (the framework's built-in 28 or so) ship with the binary
## and are managed by the framework itself. THIS tool is for the additional
## tier — what the agent's company has installed, and what they author.
##
## Actions:
##   find    — discover tools by keyword (was the standalone find_tools)
##   forge   — author a new tool (CLI script wrapper or MCP server) — Phase 2
##   update  — modify an existing tool's source / schema           — Phase 2
##   share   — publish a tool (cross-agent / cross-company)         — Phase 2
##   remove  — delete an authored tool                              — Phase 2
##
## Sibling tools on this trio:
##   office   — ship  (agent's vessel — clock/calendar/state/etc.)
##   company  — navigator (org-level direction; cross-office views)

import std/[asyncdispatch, json, tables, strutils, sets, sequtils, os, times]
import ../types, ../registry
import ../spec

const ToolSpec* = spec(
  name = "tools",
  description = "Agent's craft surface for non-foundation tools. find = discover by keyword (Phase 1). forge / update / share / remove = author / modify / publish / delete authored tools (Phase 2 stubs).",
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
  "  find   — search for and activate tools by keyword. Use when you need " &
  "a capability not in your current toolset (e.g. 'browser login', " &
  "'git commit', 'cron schedule'). Found tools become available immediately " &
  "for " & $DefaultToolTTL & " turns.\n" &
  "  forge / update / share / remove — Phase 2 (surface locked, " &
  "implementation pending). Today, use `mcp` for MCP server lifecycle " &
  "and `skill method=learn` for workstation-tier authoring.\n\n" &
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
        "description": "Operation. find=discover; show=read description; add_gotcha=append per-agent learned failure to overlay; forge/update/share/remove=Phase 2 stubs. Sub-routes: mcp.<op> (forge/persist/purge MCP servers)."
      },
      "query": %*{
        "type": "string",
        "description": "find — keywords (e.g. 'browser login', 'git commit', 'cron schedule')."
      },
      "name": %*{
        "type": "string",
        "description": "show / add_gotcha — tool name to read or annotate."
      },
      "gotcha": %*{
        "type": "string",
        "description": "add_gotcha only — one-paragraph description of the failure mode + how to avoid it. Appended to <office>/tools_overlay/<name>/gotchas.md with timestamp."
      },
      "include_overlay": %*{
        "type": "boolean",
        "description": "show only — when true (default), include the per-agent gotcha overlay below the canonical description."
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
  "(planned for Phase 2). Surface locked so agents can plan against the " &
  "future API. Today: use `tools method=mcp.forge` for MCP server " &
  "authoring, `skill method=learn` for workstation-tier skill authoring."

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
  of "forge", "update", "share", "remove":
    return phase2Stub(top)
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
