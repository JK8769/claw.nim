import std/[unittest, json, tables, strutils, options, asyncdispatch]
import ../src/nimclaw/tools/[types, memory, memory_recall]

type
  MockMemory = ref object of Memory
    entries: seq[MemoryEntry]

method recall*(m: MockMemory, query: string, limit: int = 10, session_id: string = ""): seq[MemoryEntry] =
  var filtered: seq[MemoryEntry] = @[]
  for e in m.entries:
    if e.content.contains(query) or e.key.contains(query):
      filtered.add(e)
  return filtered

suite "MemoryRecallTool Tests":
  test "schema has query parameter":
    let mem = MockMemory()
    let tool = newMemoryRecallTool(mem)
    let schema = tool.parameters()
    check schema.hasKey("properties")
    check schema["properties"].hasKey("query")
    
  test "schema identifies query as required":
    let mem = MockMemory()
    let tool = newMemoryRecallTool(mem)
    let schema = tool.parameters()
    check schema["required"].kind == JArray
    check schema["required"].elems.len > 0
    check schema["required"].elems[0].getStr() == "query"

  test "executes without backend gracefully fails":
    let tool = newMemoryRecallTool(nil)
    let args = {"query": %"test"}.toTable
    let result = waitFor tool.execute(args)
    check result.contains("Memory backend not configured")

  test "missing query is rejected":
    let mem = MockMemory()
    let tool = newMemoryRecallTool(mem)
    let args = initTable[string, JsonNode]()
    let result = waitFor tool.execute(args)
    check result.contains("Missing 'query' parameter")
    
  test "formats memory correctly":
    let mem = MockMemory()
    mem.entries.add(MemoryEntry(key: "fact1", content: "Nim is cool", category: toMemoryCategory("core"), timestamp: "2024-01-01"))
    
    let tool = newMemoryRecallTool(mem)
    let args = {"query": %"Nim"}.toTable
    let result = waitFor tool.execute(args)
    
    check result.contains("Found 1 memory")
    check result.contains("fact1")
    check result.contains("Nim is cool")
    
  test "handles empty results gracefully":
    let mem = MockMemory()
    let tool = newMemoryRecallTool(mem)
    let args = {"query": %"Nonexistent"}.toTable
    let result = waitFor tool.execute(args)
    
    check result.contains("No memories found matching")
