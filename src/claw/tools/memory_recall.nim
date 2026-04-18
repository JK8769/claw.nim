import std/[json, tables, strformat, asyncdispatch, strutils]
import types, memory

type
  MemoryRecallTool* = ref object of Tool
    memory: Memory

proc newMemoryRecallTool*(memory: Memory): MemoryRecallTool =
  MemoryRecallTool(memory: memory)

method name*(t: MemoryRecallTool): string = "memory_recall"
method description*(t: MemoryRecallTool): string = "Search long-term memory for relevant facts, preferences, or context."

method parameters*(t: MemoryRecallTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "query": {
        "type": "string",
        "description": "Keywords or phrase to search for in memory"
      },
      "limit": {
        "type": "integer",
        "description": "Max results to return (default: 5)"
      }
    },
    "required": %["query"]
  }.toTable

method execute*(t: MemoryRecallTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("query") or args["query"].kind != JString:
    return "Missing 'query' parameter"

  let query = args["query"].getStr()
  if query.len == 0:
    return "'query' must not be empty"

  if t.memory == nil:
    return "Memory backend not configured. Cannot search for: {query}".fmt

  let limitRaw = if args.hasKey("limit") and args["limit"].kind == JInt: args["limit"].getInt() else: 5
  let limit = if limitRaw > 0 and limitRaw <= 100: limitRaw else: 5

  let entries = t.memory.recall(query, limit, "")
  if entries.len == 0:
    return "No memories found matching: {query}".fmt

  let plural = if entries.len == 1: "y" else: "ies"
  var outStr = "Found {entries.len} memor{plural}:\n".fmt
  for i, entry in entries:
    let catName = if entry.category.kind == mcCustom: entry.category.name else: $entry.category.kind
    outStr.add("{i + 1}. [{entry.key}] ({catName}): {entry.content}\n".fmt)

  return outStr
