import std/[asyncdispatch, json, tables, strutils]
import types, registry

type
  ListTools* = ref object of Tool
    registry: ToolRegistry

proc newListTools*(registry: ToolRegistry): ListTools =
  ListTools(registry: registry)

method name*(t: ListTools): string = "list_tools"
method description*(t: ListTools): string = "List all available tools and their descriptions. Use this to verify your capabilities or discover newly forged tools."
method parameters*(t: ListTools): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{},
    "required": %[]
  }.toTable

method execute*(t: ListTools, args: Table[string, JsonNode]): Future[string] {.async.} =
  let summaries = t.registry.getSummaries()
  if summaries.len == 0:
    return "No tools registered."
  
  var sb = "Current registered tools:\n\n"
  for s in summaries:
    sb.add(s & "\n")
  return sb
