## Per-sender, visibility-tagged memory store.
##
## Design (adapted from cicadas/core/memory.nim):
##
## - Each memory entry has a visibility tag (secret / private / shared /
##   public) and a category (core / daily / reflection / preference).
## - Entries are persisted as JSONL, **keyed by the sender** (user who
##   was talking with the agent when the entry was stored). One file per
##   sender under `<office>/memory/senders/<senderID>.jsonl`.
## - `getMemoryContext(requesterID, trustLevel)` returns only entries the
##   requester is *authorized* to see. Filtering happens in the data layer,
##   not via prompt instructions.
##
## Why this shape matters:
##
## The old model dumped the full `MEMORY.md` into every system prompt and
## relied on "do not reveal to guests" prose to gate access. That is
## prompt-layer gating — model-dependent and jailbreak-prone. Here the LLM
## literally does not receive unauthorised entries, so compliance is not
## a security boundary.
##
## Legacy `MEMORY.md` (if present) is still read, but every line is
## treated as `shared` visibility — visible to trustLevel ≥ 40. New writes
## go to per-sender JSONL.

import std/[os, json, times, strutils, algorithm, tables]

type
  MemoryVisibility* = enum
    mvSecret  = "secret"   # Only the agent (trust 100+) can ever see this
    mvPrivate = "private"  # Sender + agent + high-trust Boss/Master
    mvShared  = "shared"   # Anyone with trustLevel >= 40
    mvPublic  = "public"   # Anyone, including Guest

  MemoryCategory* = enum
    mcCore       = "core"         # Stable facts about the user/project
    mcDaily      = "daily"        # Time-bucketed session notes
    mcReflection = "reflection"   # Agent's own self-reflection
    mcPreference = "preference"   # User-stated preferences

  MemoryEntry* = object
    key*: string
    content*: string
    category*: MemoryCategory
    visibility*: MemoryVisibility
    senderID*: string          ## Who was talking when this was stored
    timestamp*: float64

  MemoryStore* = ref object
    workspace*: string         ## Per-agent office dir
    memoryDir*: string         ## <office>/memory
    sendersDir*: string        ## <office>/memory/senders
    memoryFile*: string        ## Legacy <office>/memory/MEMORY.md

proc newMemoryStore*(workspace: string): MemoryStore =
  let memoryDir = workspace / "memory"
  let sendersDir = memoryDir / "senders"
  if not dirExists(memoryDir): createDir(memoryDir)
  if not dirExists(sendersDir): createDir(sendersDir)
  MemoryStore(
    workspace: workspace,
    memoryDir: memoryDir,
    sendersDir: sendersDir,
    memoryFile: memoryDir / "MEMORY.md"
  )

# ── Visibility / trust gate ────────────────────────────────────────
# The core rule. Changing this changes what the LLM sees — review with care.
#   Secret:  only with trust >= 100 (the agent itself, or a SuperAdmin)
#   Private: trust >= 70 (Staff+, Master, Boss)
#   Shared:  trust >= 40 (Customer+, i.e. anyone known)
#   Public:  trust >= 0  (any Guest)

proc canView*(visibility: MemoryVisibility, trustLevel: int): bool =
  ## Data-layer authorisation check. Called at recall / context-build time.
  case visibility
  of mvSecret:  trustLevel >= 100
  of mvPrivate: trustLevel >= 70
  of mvShared:  trustLevel >= 40
  of mvPublic:  true

proc downgradeForTrust*(requested: MemoryVisibility, trustLevel: int): MemoryVisibility =
  ## A low-trust user cannot *create* high-visibility memories. If they try,
  ## the store silently downgrades. Mirror of cicadas's rule:
  ##   trust < 50  → at most public
  ##   trust < 70  → at most shared
  ##   trust < 100 → at most private
  ## (The agent itself — trust 100 — can store anything, including secrets.)
  if trustLevel < 50 and requested != mvPublic: return mvPublic
  if trustLevel < 70 and requested in {mvSecret, mvPrivate}: return mvShared
  if trustLevel < 100 and requested == mvSecret: return mvPrivate
  requested

# ── Persistence ────────────────────────────────────────────────────

proc sanitizeSender(id: string): string =
  ## Make a sender ID safe as a filename. Collapses /, :, whitespace to _.
  result = newStringOfCap(id.len)
  for c in id:
    if c in Letters or c in Digits or c in {'_', '-', '.'}: result.add(c)
    else: result.add('_')
  if result.len == 0: result = "unknown"

proc senderFile(ms: MemoryStore, senderID: string): string =
  ms.sendersDir / (sanitizeSender(senderID) & ".jsonl")

proc store*(ms: MemoryStore, senderID, key, content: string,
            category: MemoryCategory = mcCore,
            visibility: MemoryVisibility = mvPrivate) =
  ## Appends an entry to the sender's JSONL. Visibility is NOT downgraded
  ## here — caller (the tool) is responsible for applying trust-based
  ## downgrade so the agent's own writes stay un-clamped.
  let path = ms.senderFile(senderID)
  let entry = MemoryEntry(
    key: key,
    content: content,
    category: category,
    visibility: visibility,
    senderID: senderID,
    timestamp: epochTime()
  )
  let f = open(path, fmAppend)
  f.writeLine($(%entry))
  f.close()

proc readAllEntries(ms: MemoryStore): seq[MemoryEntry] =
  ## Load every sender's entries. Malformed lines are skipped silently.
  if not dirExists(ms.sendersDir): return
  for kind, path in walkDir(ms.sendersDir):
    if kind != pcFile or not path.endsWith(".jsonl"): continue
    try:
      for line in lines(path):
        let trimmed = line.strip()
        if trimmed.len == 0: continue
        try:
          result.add(parseJson(trimmed).to(MemoryEntry))
        except CatchableError: discard
    except IOError: discard

proc recall*(ms: MemoryStore, requesterID: string, trustLevel: int,
             query: string = "", limit: int = 10): seq[MemoryEntry] =
  ## Data-layer filter. The LLM only sees what the requester may see.
  ##
  ## Ordering: newest first. Query (if given) is a case-insensitive substring
  ## match against key + content. Requester sees entries stored by themselves
  ## regardless of visibility (you can always read what you wrote), plus
  ## entries of sufficient visibility stored by others.
  let entries = ms.readAllEntries()
  let qLow = query.toLowerAscii
  for e in entries:
    let authorised = (e.senderID == requesterID) or canView(e.visibility, trustLevel)
    if not authorised: continue
    if qLow.len > 0 and qLow notin e.content.toLowerAscii and qLow notin e.key.toLowerAscii:
      continue
    result.add(e)
  result.sort(proc(a, b: MemoryEntry): int = cmp(b.timestamp, a.timestamp))
  if result.len > limit: result = result[0 ..< limit]

proc forget*(ms: MemoryStore, senderID, key: string, trustLevel: int): bool =
  ## Remove one entry by key. Only the entry's own sender OR a sufficiently
  ## trusted requester (>= 70) may delete. Rewrites the JSONL without that line.
  let path = ms.senderFile(senderID)
  if not fileExists(path): return false
  var kept: seq[string]
  var found = false
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0: continue
    try:
      let e = parseJson(trimmed).to(MemoryEntry)
      let authorised = e.senderID == senderID or trustLevel >= 70
      if e.key == key and authorised:
        found = true
        continue
      kept.add(line)
    except CatchableError:
      kept.add(line)  # preserve unparsable lines rather than losing data
  if found:
    writeFile(path, kept.join("\n") & (if kept.len > 0: "\n" else: ""))
  found

# ── Legacy MEMORY.md (read-only backward compat) ──────────────────

proc readLegacyMd(ms: MemoryStore): string =
  if fileExists(ms.memoryFile): return readFile(ms.memoryFile)
  return ""

proc readLegacyDailyNotes(ms: MemoryStore, days: int): string =
  ## Pre-visibility daily notes (sibling of MEMORY.md). Treated as shared.
  var notes: seq[string]
  for i in 0 ..< days:
    let date = now() - i.days
    let dateStr = date.format("yyyyMMdd")
    let monthDir = dateStr[0..5]
    let filePath = ms.memoryDir / monthDir / (dateStr & ".md")
    if fileExists(filePath): notes.add(readFile(filePath))
  if notes.len == 0: return ""
  notes.join("\n\n---\n\n")

# ── System-prompt injection ───────────────────────────────────────
# `getMemoryContext` is what `buildSystemPrompt` calls each turn.
# Everything it returns will be visible to the LLM.

proc getMemoryContext*(ms: MemoryStore, requesterID: string,
                       trustLevel: int): string =
  var parts: seq[string] = @[]

  let entries = ms.recall(requesterID, trustLevel, "", 20)
  if entries.len > 0:
    var lines = @["## Recent Memory"]
    for e in entries:
      lines.add("- [" & e.key & "] (" & $e.category & "/" & $e.visibility &
                "): " & e.content)
    parts.add(lines.join("\n"))

  # Legacy MEMORY.md — only surfaced if caller has shared-level access.
  # Treat as a single shared-visibility document so hardcoded memos don't
  # leak to untrusted guests.
  if canView(mvShared, trustLevel):
    let legacy = ms.readLegacyMd()
    if legacy.strip.len > 0:
      parts.add("## Long-term Memory (legacy)\n\n" & legacy)
    let notes = ms.readLegacyDailyNotes(3)
    if notes.strip.len > 0:
      parts.add("## Recent Daily Notes (legacy)\n\n" & notes)

  if parts.len == 0: return ""
  "# Memory\n\n" & parts.join("\n\n---\n\n")

# ── Legacy file-edit helpers (kept for tools still writing MEMORY.md) ──
# New tools should use `store` and per-sender storage instead.

proc readLongTerm*(ms: MemoryStore): string =
  ## DEPRECATED: returns the whole MEMORY.md unfiltered. Kept only for
  ## tools that edit the file directly. Do not use for prompt injection.
  ms.readLegacyMd()

proc writeLongTerm*(ms: MemoryStore, content: string) =
  ## DEPRECATED: direct MEMORY.md write. Prefer `store` with visibility.
  writeFile(ms.memoryFile, content)

proc appendToday*(ms: MemoryStore, content: string) =
  ## DEPRECATED: appends a Markdown line to the per-day file. Kept for
  ## tools that still write legacy daily notes. Prefer `store` with
  ## category=mcDaily + appropriate visibility.
  let today = now().format("yyyyMMdd")
  let monthDir = today[0..5]
  let todayFile = ms.memoryDir / monthDir / (today & ".md")
  if not dirExists(ms.memoryDir / monthDir):
    createDir(ms.memoryDir / monthDir)
  var existing = ""
  if fileExists(todayFile): existing = readFile(todayFile)
  var updated = ""
  if existing == "":
    updated = "# " & now().format("yyyy-MM-dd") & "\n\n" & content
  else:
    updated = existing & "\n" & content
  writeFile(todayFile, updated)
