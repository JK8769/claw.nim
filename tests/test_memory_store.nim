import std/[unittest, json, tables, asyncdispatch, strutils]
import ../src/nimclaw/tools/[memory_store, memory, memory_markdown]

type
  MockMemory = ref object of Memory
    storedKey: string
    storedContent: string
    storedCat: string

method name*(m: MockMemory): string = "mock"
method store*(m: MockMemory, key, content: string, category: MemoryCategoryObj, session_id: string = "") =
  m.storedKey = key
  m.storedContent = content
  m.storedCat = $category

suite "MemoryStoreTool Tests":
  test "schema has key and content required":
    let t = newMemoryStoreTool(nil)
    let schema = t.parameters()
    check schema["required"].getElems().len >= 2

  test "executes without backend gracefully fails":
    let t = newMemoryStoreTool(nil)
    let args = {"key": %"lang", "content": %"Prefers Nim"}.toTable
    let result = waitFor t.execute(args)
    check result.contains("Memory backend not configured")

  test "missing key rejects":
    let t = newMemoryStoreTool(nil)
    let args = {"content": %"no key"}.toTable
    let result = waitFor t.execute(args)
    check result.contains("Error: key is required")

  test "missing content rejects":
    let t = newMemoryStoreTool(nil)
    let args = {"key": %"no_content"}.toTable
    let result = waitFor t.execute(args)
    check result.contains("Error: content is required")

  test "stores with backend successfully":
    var backend = MockMemory()
    let t = newMemoryStoreTool(backend)
    let args = {"key": %"lang", "content": %"Prefers Nim", "category": %"core"}.toTable
    let result = waitFor t.execute(args)
    check result.contains("Stored memory:")
    check backend.storedKey == "lang"
    check backend.storedContent == "Prefers Nim"
    check backend.storedCat == "core"

  test "default category is core":
    var backend = MockMemory()
    let t = newMemoryStoreTool(backend)
    let args = {"key": %"test", "content": %"value"}.toTable
    let result = waitFor t.execute(args)
    check backend.storedCat == "core"
