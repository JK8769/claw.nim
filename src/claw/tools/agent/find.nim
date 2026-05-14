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

import std/[asyncdispatch, json, tables, strutils, sets]
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

proc newFindTools*(registry: ToolRegistry): FindTools =
  FindTools(registry: registry, activated: initTable[string, int]())

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
  "and `skill action=learn` for workstation-tier authoring.\n\n" &
  "Foundation tools (the framework's built-ins) are always available; " &
  "this tool manages discovery + lifecycle for the additional tier."

method parameters*(t: FindTools): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": %*{
        "type": "string",
        "enum": ["find", "forge", "update", "share", "remove"],
        "description": "Operation. find (Phase 1) | forge / update / share / remove (Phase 2 stubs)."
      },
      "query": %*{
        "type": "string",
        "description": "find — keywords (e.g. 'browser login', 'git commit', 'cron schedule')."
      }
    },
    "required": %*["action"]
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
  "future API. Today: use `mcp` for MCP server lifecycle, `skill " &
  "action=learn` for workstation-tier authoring."

method execute*(t: FindTools, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (find | forge | update | share | remove)"
  let action = args["action"].getStr().toLowerAscii()
  case action
  of "find": return doFind(t, args)
  of "forge", "update", "share", "remove":
    return phase2Stub(action)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: find | forge | update | share | remove."
