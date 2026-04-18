## Unified memory tool — replaces memory_store, memory_recall, memory_list, memory_forget.
## Single tool with `action` parameter dispatching to the appropriate operation.

import std/[json, tables, asyncdispatch, strformat, strutils]
import types, memory

type
  UnifiedMemoryTool* = ref object of Tool
    memory*: Memory

proc newUnifiedMemoryTool*(m: Memory): UnifiedMemoryTool =
  UnifiedMemoryTool(memory: m)

method name*(t: UnifiedMemoryTool): string = "memory"

method description*(t: UnifiedMemoryTool): string =
  "Long-term memory for storing and retrieving facts, preferences, and context.\n\n" &
  "Actions:\n" &
  "  store   — Save a fact (requires key + content, optional category)\n" &
  "  recall  — Search memories by query (optional limit)\n" &
  "  list    — List entries by category or all (optional limit, category)\n" &
  "  forget  — Delete a memory by key\n\n" &
  "Do NOT use this for time-based reminders — use 'cron' instead."

method parameters*(t: UnifiedMemoryTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["store", "recall", "list", "forget"],
        "description": "The memory operation to perform"
      },
      "key": {
        "type": "string",
        "description": "Memory key (for store/forget)"
      },
      "content": {
        "type": "string",
        "description": "Content to store (for store)"
      },
      "query": {
        "type": "string",
        "description": "Search query (for recall)"
      },
      "category": {
        "type": "string",
        "enum": ["core", "daily", "conversation"],
        "description": "Category filter (for store/list)"
      },
      "limit": {
        "type": "integer",
        "description": "Max results (default 5, max 100; for recall/list)"
      }
    },
    "required": %["action"]
  }.toTable

method execute*(t: UnifiedMemoryTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.memory == nil:
    return "Error: Memory backend not configured."

  let action = if args.hasKey("action"): args["action"].getStr() else: ""

  case action
  of "store":
    if not args.hasKey("key") or args["key"].getStr() == "":
      return "Error: 'key' is required for store"
    if not args.hasKey("content") or args["content"].getStr() == "":
      return "Error: 'content' is required for store"
    let key = args["key"].getStr()
    let content = args["content"].getStr()
    let catStr = if args.hasKey("category"): args["category"].getStr() else: "core"
    let category = toMemoryCategory(catStr)
    try:
      t.memory.store(key, content, category, "")
      return "Stored memory: {key} ({category})".fmt
    except Exception as e:
      return "Failed to store memory '{key}': {e.msg}".fmt

  of "recall":
    if not args.hasKey("query") or args["query"].getStr() == "":
      return "Error: 'query' is required for recall"
    let query = args["query"].getStr()
    let limitRaw = if args.hasKey("limit") and args["limit"].kind == JInt: args["limit"].getInt() else: 5
    let limit = clamp(limitRaw, 1, 100)
    let entries = t.memory.recall(query, limit, "")
    if entries.len == 0:
      return "No memories found matching: {query}".fmt
    let plural = if entries.len == 1: "y" else: "ies"
    var res = "Found {entries.len} memor{plural}:\n".fmt
    for i, entry in entries:
      let catName = if entry.category.kind == mcCustom: entry.category.name else: $entry.category.kind
      res.add("{i + 1}. [{entry.key}] ({catName}): {entry.content}\n".fmt)
    return res

  of "list":
    let limitRaw = if args.hasKey("limit") and args["limit"].kind == JInt: args["limit"].getInt() else: 5
    let limit = clamp(limitRaw, 1, 100)
    var categoryObj = toMemoryCategory("all")
    if args.hasKey("category") and args["category"].kind == JString:
      let catStr = args["category"].getStr()
      if catStr.len > 0:
        categoryObj = toMemoryCategory(catStr)
    let entries = t.memory.list(categoryObj, "")
    if entries.len == 0:
      return "No memory entries found."
    let shown = min(limit, entries.len)
    var res = "Memory entries: showing {shown}/{entries.len}\n".fmt
    for i in 0 ..< shown:
      let entry = entries[i]
      let catName = if entry.category.kind == mcCustom: entry.category.name else: $entry.category.kind
      var preview = entry.content
      if preview.len > 120: preview = preview[0 ..< 120] & "..."
      res.add("  {i + 1}. {entry.key} [{catName}] {entry.timestamp}\n     {preview}\n".fmt)
    return res

  of "forget":
    if not args.hasKey("key") or args["key"].getStr() == "":
      return "Error: 'key' is required for forget"
    let key = args["key"].getStr()
    let forgotten = t.memory.forget(key)
    if forgotten:
      return "Forgot memory: {key}".fmt
    else:
      return "No memory found with key: {key}".fmt

  else:
    return "Error: Unknown action '{action}'. Use: store, recall, list, or forget".fmt
