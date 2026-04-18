import std/[os, strutils, strformat, times, algorithm]
import memory

type
  MarkdownMemory* = ref object of Memory
    workspaceDir*: string
    globalDir*: string # Store global workspace for read-only alignment

proc newMarkdownMemory*(workspaceDir: string, globalDir: string = ""): MarkdownMemory =
  MarkdownMemory(workspaceDir: workspaceDir, globalDir: globalDir)

proc corePath(m: MarkdownMemory): string = m.workspaceDir / "memory" / "MEMORY.md"

proc dailyPath(m: MarkdownMemory): string =
  let now = now()
  m.workspaceDir / "notes" / "{now.year:0>4}-{now.month.ord:0>2}-{now.monthday:0>2}.md".fmt

proc ensureDir(path: string) =
  let dir = parentDir(path)
  if dir != "" and not dirExists(dir):
    createDir(dir)

proc appendToFile(path, content: string) =
  ensureDir(path)
  
  var existing = ""
  if fileExists(path):
    existing = readFile(path)
    
  var toWrite = ""
  if existing.len > 0 and not existing.endsWith("\n"):
    toWrite = "\n" & content & "\n"
  else:
    toWrite = content & "\n"
    
  let f = open(path, fmAppend)
  f.write(toWrite)
  f.close()

proc parseEntries(text, filename: string, category: MemoryCategoryObj): seq[MemoryEntry] =
  var entries: seq[MemoryEntry] = @[]
  var lineIdx = 0
  
  for line in text.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"): continue
    
    let clean = if trimmed.startsWith("- "): trimmed[2..^1] else: trimmed
    let id = "{filename}:{lineIdx}".fmt
    
    var finalKey = id
    var finalContent = clean
    
    if clean.startsWith("**"):
      let endIdx = clean.find("**:", 2)
      if endIdx > 2:
        finalKey = clean[2 ..< endIdx]
        finalContent = clean[endIdx + 3 .. ^1].strip()
    
    entries.add(MemoryEntry(
      id: id,
      key: finalKey,
      content: finalContent,
      category: category,
      timestamp: filename,
      session_id: ""
    ))
    lineIdx += 1
    
  return entries

proc readAllEntries(m: MarkdownMemory): seq[MemoryEntry] =
  var all: seq[MemoryEntry] = @[]
  var seenPaths: seq[string] = @[]
  let coreFiles = ["Memorandum.md", "MEMORY.md", "memory.md"]

  # 1. Read Global Workspace Memorandum (Read Only)
  if m.globalDir != "":
    let globalMemDir = m.globalDir / "memorandum"
    if dirExists(globalMemDir):
      for f in coreFiles:
        let p = globalMemDir / f
        if fileExists(p):
          let canonical = expandFilename(p)
          if canonical in seenPaths: continue
          seenPaths.add(canonical)
          let label = "global:" & f[0 .. ^4]
          all.add(parseEntries(readFile(p), label, toMemoryCategory("core")))

  # 2. Read Agent-Specific Core Identity (Read/Write)
  for f in coreFiles:
    let p = m.workspaceDir / "memory" / f
    if fileExists(p):
      let canonical = expandFilename(p)
      if canonical in seenPaths: continue
      seenPaths.add(canonical)
      let label = "local:" & f[0 .. ^4]
      all.add(parseEntries(readFile(p), label, toMemoryCategory("core")))

  # 3. Read Agent-Specific Daily Notes (Read/Write)
  let notesDir = m.workspaceDir / "notes"
  if dirExists(notesDir):
    for kind, path in walkDir(notesDir):
      if kind == pcFile and path.endsWith(".md"):
        let fname = extractFilename(path)
        if coreFiles.contains(fname): continue
        let label = fname[0 .. ^4]
        all.add(parseEntries(readFile(path), label, toMemoryCategory("daily")))
        
  return all

method name*(m: MarkdownMemory): string = "markdown"

method store*(m: MarkdownMemory, key, content: string, category: MemoryCategoryObj, session_id: string = "") =
  let entryText = "- **{key}**: {content}".fmt
  let path = if category.kind == mcCore: m.corePath() else: m.dailyPath()
  appendToFile(path, entryText)

method recall*(m: MarkdownMemory, query: string, limit: int = 10, session_id: string = ""): seq[MemoryEntry] =
  let all = m.readAllEntries()
  let queryLower = query.toLowerAscii()
  var keywords = @[queryLower] # Simplified keyword splitting
  
  var scored: seq[MemoryEntry] = @[]
  for entry in all:
    let contentLower = entry.content.toLowerAscii()
    var matched = 0
    for kw in keywords:
      if contentLower.contains(kw): matched += 1
      
    if matched > 0:
      var e = entry
      e.score = float(matched) / float(keywords.len)
      scored.add(e)
      
  scored.sort(proc (x, y: MemoryEntry): int = cmp(y.score, x.score))
  if scored.len > limit: return scored[0 ..< limit]
  return scored

method get*(m: MarkdownMemory, key: string): MemoryEntry =
  let all = m.readAllEntries()
  var found = false
  var matching: MemoryEntry
  
  # Return latest matching entry
  for e in all:
    if e.key == key: 
      matching = e
      found = true
      continue
      
    let trimmed = e.content.strip()
    if trimmed.startsWith("**"):
      let endIdx = trimmed.find("**:", 2)
      if endIdx > 2:
        let ek = trimmed[2 ..< endIdx]
        if ek == key:
          matching = e
          found = true
          continue
          
    if e.content.contains(key):
      matching = e
      found = true
      
  if found: return matching
  return MemoryEntry(id: "")

method list*(m: MarkdownMemory, category: MemoryCategoryObj, session_id: string = ""): seq[MemoryEntry] =
  let all = m.readAllEntries()
  var filtered: seq[MemoryEntry] = @[]
  for e in all:
    if e.category.kind == category.kind:
      if e.category.kind == mcCustom and e.category.name != category.name: continue
      filtered.add(e)
  return filtered

method count*(m: MarkdownMemory): int =
  m.readAllEntries().len
