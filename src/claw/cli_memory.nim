import std/strformat
import tools/memory

proc runMemoryCommand*(mem: Memory, args: seq[string]): string =
  if args.len == 0:
    return "Usage: nimclaw memory <stats|count|forget|get|list|search|reindex|drain-outbox>"

  let subcmd = args[0]

  if subcmd == "stats":
    let c = mem.count()
    return "Memory Stats:\n  Backend: markdown\n  Total entries: " & $c

  if subcmd == "count":
    let c = mem.count()
    return $c

  if subcmd == "forget":
    if args.len < 2: return "Usage: nimclaw memory forget <key>"
    let key = args[1]
    discard mem.forget(key)
    return "Deleted memory entry: " & key

  if subcmd == "get":
    if args.len < 2: return "Usage: nimclaw memory get <key>"
    let key = args[1]
    let entry = mem.get(key)
    if entry.id == "": 
      return "Not found: " & key
    
    let cat = if entry.category.kind == mcCustom: entry.category.name else: $entry.category.kind
    return "key: {key}\ncategory: {cat}\ntimestamp: {entry.timestamp}\ncontent: {entry.content}\n".fmt

  if subcmd == "list":
    let categoryObj = toMemoryCategory("all") 
    let entries = mem.list(categoryObj, "")
    var outStr = "Memory entries: listing {entries.len} entries\n".fmt
    for i in 0 ..< min(5, entries.len):
      let entry = entries[i]
      let catName = if entry.category.kind == mcCustom: entry.category.name else: $entry.category.kind
      outStr.add("  {i + 1}. {entry.key} [{catName}] {entry.timestamp}\n".fmt)
    return outStr

  if subcmd == "search":
    if args.len < 2: return "Usage: nimclaw memory search <query>"
    let query = args[1]
    let entries = mem.recall(query, 6)
    var outStr = "Memory entries: search {entries.len} matches\n".fmt
    for i in 0 ..< entries.len:
      let entry = entries[i]
      let catName = if entry.category.kind == mcCustom: entry.category.name else: $entry.category.kind
      outStr.add("  {i + 1}. {entry.key} [{catName}] {entry.timestamp}\n".fmt)
    return outStr

  if subcmd == "reindex":
    return "Skipping reindex: The current 'markdown' memory backend is a flat-file store and doesn't use a vector index that requires rebuilding."

  if subcmd == "drain-outbox":
    return "Skipping drain-outbox: The 'markdown' backend writes synchronously; there is no background queue or outbox to drain."

  return "Unknown memory subcommand: " & subcmd
