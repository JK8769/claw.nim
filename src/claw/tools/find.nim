import std/[asyncdispatch, json, tables, strutils, sets]
import types, registry

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

method name*(t: FindTools): string = "find_tools"
method description*(t: FindTools): string =
  "Search for and activate tools by keyword. Use this when you need a capability not in your current toolset " &
  "(e.g. browser, git, hardware, schedule, email). Found tools become available immediately."
method parameters*(t: FindTools): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "query": %*{
        "type": "string",
        "description": "Search keywords (e.g. 'browser login', 'git commit', 'cron schedule', 'i2c sensor')"
      }
    },
    "required": %*["query"]
  }.toTable

method execute*(t: FindTools, args: Table[string, JsonNode]): Future[string] {.async.} =
  let query = args.getOrDefault("query", %"").getStr().toLowerAscii()
  if query.len == 0:
    return "Error: query parameter is required"

  let keywords = query.split(" ")
  let matches = t.registry.searchTools(keywords)

  if matches.len == 0:
    return "No tools found matching '" & query & "'. Try different keywords."

  for m in matches:
    t.activateWithTTL(m.name)

  var sb = "Activated " & $matches.len & " tools (available for " & $DefaultToolTTL & " turns):\n\n"
  for m in matches:
    sb.add("- `" & m.name & "` — " & m.description & "\n")
  sb.add("\nThese tools are now available. Call them directly. Use find_tools again to refresh.")
  return sb
