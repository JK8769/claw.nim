import std/[json, tables, asyncdispatch, strformat]
import types, memory

type
  MemoryStoreTool* = ref object of Tool
    memory*: Memory

proc newMemoryStoreTool*(m: Memory = nil): MemoryStoreTool =
  MemoryStoreTool(memory: m)

method name*(t: MemoryStoreTool): string = "memory_store"
method description*(t: MemoryStoreTool): string = "Store durable user facts, preferences, and decisions in long-term memory. Use category 'core' for stable facts, 'daily' for session notes, 'conversation' for important context only. Do NOT use this tool for time-based reminders or alarms; use the 'cron' tool instead."
method parameters*(t: MemoryStoreTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "key": {
        "type": "string",
        "description": "Short, unique identifier, e.g., 'user_allergies'"
      },
      "content": {
        "type": "string",
        "description": "The detailed factual information to remember for the long term"
      },
      "category": {
        "type": "string",
        "enum": ["core", "daily", "conversation"],
        "description": "Memory category"
      }
    },
    "required": %["key", "content"]
  }.toTable

method execute*(t: MemoryStoreTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("key") or args["key"].getStr() == "": return "Error: key is required"
  if not args.hasKey("content") or args["content"].getStr() == "": return "Error: content is required"

  let key = args["key"].getStr()
  let content = args["content"].getStr()
  let catStr = if args.hasKey("category"): args["category"].getStr() else: "core"
  let category = toMemoryCategory(catStr)

  if t.memory == nil:
    return "Memory backend not configured. Cannot store: {key} = {content}".fmt

  try:
    t.memory.store(key, content, category, "")
    return "Stored memory: {key} ({category})".fmt
  except Exception as e:
    return "Failed to store memory '{key}': {e.msg}".fmt
