import std/[unittest, json, tables, strutils, options, asyncdispatch]
import ../src/nimclaw/tools/[types, memory, memory_list]

type
  MockMemory = ref object of Memory
    entries: seq[MemoryEntry]

method list*(m: MockMemory, category: MemoryCategoryObj, session_id: string = ""): seq[MemoryEntry] =
  var filtered: seq[MemoryEntry] = @[]
  for e in m.entries:
    if e.category.kind == category.kind:
      if e.category.kind == mcCustom and e.category.name != category.name: continue
      filtered.add(e)
  return filtered

suite "MemoryListTool Tests":
  test "schema has limit parameter":
    let mem = MockMemory()
    let tool = newMemoryListTool(mem)
    let schema = tool.parameters()
    check schema.hasKey("properties")
    check schema["properties"].hasKey("limit")
    
  test "schema has category parameter":
    let mem = MockMemory()
    let tool = newMemoryListTool(mem)
    let schema = tool.parameters()
    check schema["properties"].hasKey("category")
    
  test "executes without backend gracefully fails":
    let tool = newMemoryListTool(nil)
    let args = initTable[string, JsonNode]()
    let result = waitFor tool.execute(args)
    check result.contains("Memory backend not configured")
    
  test "formats memory correctly":
    let mem = MockMemory()
    mem.entries.add(MemoryEntry(key: "fact1", content: "Nim is cool", category: toMemoryCategory("core"), timestamp: "2024-01-01"))
    
    let tool = newMemoryListTool(mem)
    let args = {"category": %"core"}.toTable
    let result = waitFor tool.execute(args)
    
    check result.contains("showing 1/1")
    check result.contains("fact1")
    check result.contains("Nim is cool")
    
  test "handles empty results gracefully":
    let mem = MockMemory()
    let tool = newMemoryListTool(mem)
    let args = {"category": %"core"}.toTable
    let result = waitFor tool.execute(args)
    
    check result.contains("No memory entries found")
