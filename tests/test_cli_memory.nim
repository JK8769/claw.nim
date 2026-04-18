import std/[unittest, options, strutils]
import ../src/nimclaw/cli_memory
import ../src/nimclaw/tools/memory

type MockMemory = ref object of Memory
  counts: int
  forgets: seq[string]

method count*(m: MockMemory): int = m.counts
method forget*(m: MockMemory, key: string): bool =
  m.forgets.add(key)
  return true

method get*(m: MockMemory, key: string): MemoryEntry =
  if key == "test_key":
    return MemoryEntry(id: "1", key: "test_key", content: "some stuff", timestamp: "now", category: toMemoryCategory("core"))
  return MemoryEntry(id: "")

method list*(m: MockMemory, category: MemoryCategoryObj, session_id: string = ""): seq[MemoryEntry] =
  return @[ MemoryEntry(id: "1", key: "k", content: "c", timestamp: "1", category: toMemoryCategory("core")) ]

method recall*(m: MockMemory, query: string, limit: int = 10, session_id: string = ""): seq[MemoryEntry] =
  if query == "bob":
    return @[ MemoryEntry(id: "2", key: "bob_node", content: "alice", timestamp: "2", category: toMemoryCategory("core")) ]
  return @[]

suite "CLI Memory Subcommands":
  test "count returns memory count":
    let mem = MockMemory(counts: 5)
    let output = runMemoryCommand(mem, @["count"])
    check output == "5"

  test "forget calls memory forget":
    let mem = MockMemory()
    let output = runMemoryCommand(mem, @["forget", "lost_key"])
    check mem.forgets == @["lost_key"]
    check output == "Deleted memory entry: lost_key"

  test "get finds existing key":
    let mem = MockMemory()
    let output = runMemoryCommand(mem, @["get", "test_key"])
    check "content: some stuff" in output

  test "get complains about missing key":
    let mem = MockMemory()
    let output = runMemoryCommand(mem, @["get", "missing_key"])
    check "Not found: missing_key" in output

  test "list returns correct memory items":
    let mem = MockMemory()
    let output = runMemoryCommand(mem, @["list"])
    check "listing 1 entries" in output

  test "search queries the memory":
    let mem = MockMemory()
    let output = runMemoryCommand(mem, @["search", "bob"])
    check "search 1 matches" in output

  test "stats returns memory stats":
    let mem = MockMemory(counts: 42)
    let output = runMemoryCommand(mem, @["stats"])
    check "Total entries: 42" in output

  test "reindex returns status message":
    let mem = MockMemory()
    let output = runMemoryCommand(mem, @["reindex"])
    check "Skipping reindex" in output

  test "drain-outbox returns status message":
    let mem = MockMemory()
    let output = runMemoryCommand(mem, @["drain-outbox"])
    check "Skipping drain-outbox" in output

