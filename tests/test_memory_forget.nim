import std/[unittest, json, tables, strutils, options, asyncdispatch]
import ../src/nimclaw/tools/[types, memory, memory_forget]

type
  MockMemory = ref object of Memory
    deletedKey: string

method forget*(m: MockMemory, key: string): bool =
  if key == "exists":
    m.deletedKey = key
    return true
  return false

suite "MemoryForgetTool Tests":
  test "schema has key parameter":
    let mem = MockMemory()
    let tool = newMemoryForgetTool(mem)
    let schema = tool.parameters()
    check schema.hasKey("properties")
    check schema["properties"].hasKey("key")
    
  test "schema identifies key as required":
    let mem = MockMemory()
    let tool = newMemoryForgetTool(mem)
    let schema = tool.parameters()
    check schema["required"].kind == JArray
    check schema["required"].elems.len > 0
    check schema["required"].elems[0].getStr() == "key"

  test "executes without backend gracefully fails":
    let tool = newMemoryForgetTool(nil)
    let args = {"key": %"test"}.toTable
    let result = waitFor tool.execute(args)
    check result.contains("Memory backend not configured")

  test "missing key is rejected":
    let mem = MockMemory()
    let tool = newMemoryForgetTool(mem)
    let args = initTable[string, JsonNode]()
    let result = waitFor tool.execute(args)
    check result.contains("Missing 'key' parameter")
    
  test "returns success template upon backend deletion":
    let mem = MockMemory()
    let tool = newMemoryForgetTool(mem)
    let args = {"key": %"exists"}.toTable
    let result = waitFor tool.execute(args)
    
    check mem.deletedKey == "exists"
    check result.contains("Forgot memory: exists")
    
  test "handles missing key fallback correctly":
    let mem = MockMemory()
    let tool = newMemoryForgetTool(mem)
    let args = {"key": %"doesnotexist"}.toTable
    let result = waitFor tool.execute(args)
    
    check result.contains("No memory found with key")
