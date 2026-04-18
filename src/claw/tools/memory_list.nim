import std/[json, tables, strformat, asyncdispatch, strutils]
import types, memory

type
  MemoryListTool* = ref object of Tool
    memory: Memory

proc newMemoryListTool*(memory: Memory): MemoryListTool =
  MemoryListTool(memory: memory)

method name*(t: MemoryListTool): string = "memory_list"
method description*(t: MemoryListTool): string = "List memory entries chronologically or by category. Use for requests like 'show first N memory records'."

method parameters*(t: MemoryListTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "limit": {
        "type": "integer",
        "description": "Max entries to return (default: 5, max: 100)"
      },
      "category": {
        "type": "string",
        "description": "Optional category filter (core|daily|conversation|custom)"
      },
      "include_content": {
        "type": "boolean",
        "description": "Include content preview (default: true)"
      }
    }
  }.toTable

method execute*(t: MemoryListTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.memory == nil:
    return "Memory backend not configured. Cannot list entries."

  let limitRaw = if args.hasKey("limit") and args["limit"].kind == JInt: args["limit"].getInt() else: 5
  let limit = if limitRaw > 0 and limitRaw <= 100: limitRaw else: 5

  var categoryObj = toMemoryCategory("all") # Using custom category as default/all
  if args.hasKey("category") and args["category"].kind == JString:
    let catStr = args["category"].getStr()
    if catStr.len > 0:
      categoryObj = toMemoryCategory(catStr)

  let includeContent = if args.hasKey("include_content") and args["include_content"].kind == JBool: args["include_content"].getBool() else: true

  let entries = t.memory.list(categoryObj, "")
  if entries.len == 0:
    return "No memory entries found."

  let shown = min(limit, entries.len)
  var outStr = "Memory entries: showing {shown}/{entries.len}\n".fmt

  var written = 0
  for i in 0 ..< entries.len:
    if written >= shown: break
    let entry = entries[i]
    let catName = if entry.category.kind == mcCustom: entry.category.name else: $entry.category.kind
    outStr.add("  {written + 1}. {entry.key} [{catName}] {entry.timestamp}\n".fmt)
    if includeContent:
      var preview = entry.content
      if preview.len > 120:
        preview = preview[0 ..< 120] & "..."
      outStr.add("     {preview}\n".fmt)
    written += 1

  return outStr
