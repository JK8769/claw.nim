

type
  MemoryCategory* = enum
    mcCore = "core"
    mcDaily = "daily"
    mcConversation = "conversation"
    mcCustom

  MemoryCategoryObj* = object
    case kind*: MemoryCategory
    of mcCustom:
      name*: string
    else:
      discard

  MemoryEntry* = object
    id*: string
    key*: string
    content*: string
    category*: MemoryCategoryObj
    timestamp*: string
    session_id*: string
    score*: float

proc toMemoryCategory*(s: string): MemoryCategoryObj =
  if s == "core": return MemoryCategoryObj(kind: mcCore)
  if s == "daily": return MemoryCategoryObj(kind: mcDaily)
  if s == "conversation": return MemoryCategoryObj(kind: mcConversation)
  return MemoryCategoryObj(kind: mcCustom, name: s)

proc `$`*(c: MemoryCategoryObj): string =
  if c.kind == mcCustom: return c.name
  return $c.kind

type
  Memory* = ref object of RootObj

method name*(m: Memory): string {.base.} = ""
method store*(m: Memory, key, content: string, category: MemoryCategoryObj, session_id: string = "") {.base.} = discard
method recall*(m: Memory, query: string, limit: int = 10, session_id: string = ""): seq[MemoryEntry] {.base.} = @[]
method get*(m: Memory, key: string): MemoryEntry {.base.} = MemoryEntry()
method list*(m: Memory, category: MemoryCategoryObj, session_id: string = ""): seq[MemoryEntry] {.base.} = @[]
method forget*(m: Memory, key: string): bool {.base.} = false
method count*(m: Memory): int {.base.} = 0
