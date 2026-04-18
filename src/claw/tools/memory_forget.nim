import std/[json, tables, strformat, asyncdispatch, strutils]
import types, memory

type
  MemoryForgetTool* = ref object of Tool
    memory: Memory

proc newMemoryForgetTool*(memory: Memory): MemoryForgetTool =
  MemoryForgetTool(memory: memory)

method name*(t: MemoryForgetTool): string = "memory_forget"
method description*(t: MemoryForgetTool): string = "Remove a memory by key. Use to delete outdated facts or sensitive data."

method parameters*(t: MemoryForgetTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "key": {
        "type": "string",
        "description": "The key of the memory to forget"
      }
    },
    "required": %["key"]
  }.toTable

method execute*(t: MemoryForgetTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("key") or args["key"].kind != JString:
    return "Missing 'key' parameter"

  let key = args["key"].getStr()
  if key.len == 0:
    return "'key' must not be empty"

  if t.memory == nil:
    return "Memory backend not configured. Cannot forget: {key}".fmt

  let forgotten = t.memory.forget(key)
  if forgotten:
    return "Forgot memory: {key}".fmt
  else:
    return "No memory found with key: {key}".fmt
