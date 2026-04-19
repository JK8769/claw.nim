## Per-agent memory store with two gating mechanisms.
##
## Layout (under each agent's office dir):
##
##   <office>/memory/
##     self.jsonl          # agent's own memory — visibility-gated
##     nc_<N>.jsonl        # one file per conversation partner (graph entity)
##     MEMORY.md           # legacy free-form agent notes (shared-tier fallback)
##     YYYYMM/*.md         # legacy daily notes (shared-tier fallback)
##
## Gating mechanisms:
##
##   1. **Per-sender isolation** — memories the agent records while talking
##      with user X go into X's nc_N.jsonl, which is only ever opened when
##      the agent is talking to X again. Y cannot read X's memory by any
##      policy path; they're in different files. No visibility tag needed
##      on sender-file entries — the file boundary IS the gate.
##
##   2. **Visibility on self.jsonl** — the agent's own memory (reflections,
##      learned facts, company knowledge) is a single store. Entries carry
##      visibility (secret/private/shared/public) and are filtered by the
##      current requester's trust level at recall time. This is where the
##      cicadas-style data-layer filtering applies.
##
## Stores:
##   storeAboutSender  → writes to nc_<N>.jsonl (no visibility needed)
##   storeSelf         → writes to self.jsonl with visibility (clamped by trust)
##
## Recall:
##   recallSender      → reads only the current partner's file
##   recallSelf        → reads self.jsonl, filtered by visibility × trust
##   getMemoryContext  → merges both for system-prompt injection

import std/[os, json, times, strutils, algorithm, tables]

type
  MemoryVisibility* = enum
    mvSecret  = "secret"   # Agent internal only (trust >= 100)
    mvPrivate = "private"  # High-trust only  (trust >= 70)
    mvShared  = "shared"   # Known contacts   (trust >= 40)
    mvPublic  = "public"   # Anyone, including Guest

  MemoryCategory* = enum
    mcCore       = "core"
    mcDaily      = "daily"
    mcReflection = "reflection"
    mcPreference = "preference"

  MemoryEntry* = object
    key*: string
    content*: string
    category*: MemoryCategory
    visibility*: MemoryVisibility   ## only meaningful for self.jsonl entries
    senderID*: string               ## nc:id of the author context (for sender
                                    ## files this equals the file's nc:id;
                                    ## for self.jsonl this is whoever was
                                    ## talking when the agent decided to note
                                    ## something for itself).
    timestamp*: float64
    storedAtTrust*: int             ## trust at write time (0 = legacy/unknown)
    deleted*: bool                  ## tombstone
    deletedBy*: string
    deletedAt*: float64

  MemoryStore* = ref object
    workspace*: string          ## per-agent office dir
    memoryDir*: string          ## <office>/memory
    memoryFile*: string         ## <office>/memory/MEMORY.md (legacy)
    selfPath*: string           ## <office>/memory/self.jsonl

proc newMemoryStore*(workspace: string): MemoryStore =
  let memoryDir = workspace / "memory"
  if not dirExists(memoryDir): createDir(memoryDir)
  MemoryStore(
    workspace: workspace,
    memoryDir: memoryDir,
    memoryFile: memoryDir / "MEMORY.md",
    selfPath: memoryDir / "self.jsonl"
  )

# ── Visibility / trust gate (self.jsonl only) ─────────────────────

proc canView*(visibility: MemoryVisibility, trustLevel: int): bool =
  case visibility
  of mvSecret:  trustLevel >= 100
  of mvPrivate: trustLevel >= 70
  of mvShared:  trustLevel >= 40
  of mvPublic:  true

proc downgradeForTrust*(requested: MemoryVisibility, trustLevel: int): MemoryVisibility =
  ## Clamp visibility downward if the storer's trust isn't high enough
  ## to create the requested level. A Guest can't save a secret.
  if trustLevel < 50 and requested != mvPublic: return mvPublic
  if trustLevel < 70 and requested in {mvSecret, mvPrivate}: return mvShared
  if trustLevel < 100 and requested == mvSecret: return mvPrivate
  requested

# ── File-name sanitisation ─────────────────────────────────────────
# nc:5 → nc_5.jsonl — colons are unfriendly on some filesystems and
# we don't want whitespace/slashes in filenames either.

proc sanitizeId(id: string): string =
  if id.len == 0: return "unknown"
  for c in id:
    if c in Letters or c in Digits or c in {'_', '-', '.'}: result.add(c)
    else: result.add('_')

proc senderFile*(ms: MemoryStore, ncId: string): string =
  ## Path to the memory file for a single conversation partner, keyed by
  ## their graph entity ID (`nc:5` → `nc_5.jsonl`).
  ms.memoryDir / (sanitizeId(ncId) & ".jsonl")

# ── JSONL I/O ──────────────────────────────────────────────────────

proc appendEntry(path: string, entry: MemoryEntry) =
  let f = open(path, fmAppend)
  f.writeLine($(%entry))
  f.close()

proc readEntries(path: string): seq[MemoryEntry] =
  if not fileExists(path): return
  try:
    for line in lines(path):
      let trimmed = line.strip()
      if trimmed.len == 0: continue
      try:
        result.add(parseJson(trimmed).to(MemoryEntry))
      except CatchableError: discard
  except IOError: discard

# ── Store ──────────────────────────────────────────────────────────

proc storeAboutSender*(ms: MemoryStore, ncId, key, content: string,
                      category: MemoryCategory = mcCore,
                      storedAtTrust: int = 0) =
  ## Record something about/with this conversation partner. Lands in their
  ## isolated file. Visibility is mvPublic by convention — it's meaningless
  ## here because the file is only opened when talking to ncId again.
  ## nc:id-only: silent no-op if the caller hasn't resolved a graph id.
  ## (The runtime adds unknown guests to the graph before we get here; if
  ## that hasn't happened, refusing the write is better than creating a
  ## name-keyed file that would orphan when the id finally resolves.)
  if not ncId.startsWith("nc:"): return
  appendEntry(ms.senderFile(ncId),
    MemoryEntry(
      key: key, content: content,
      category: category, visibility: mvPublic,
      senderID: ncId, timestamp: epochTime(),
      storedAtTrust: storedAtTrust
    ))

proc storeSelf*(ms: MemoryStore, authorNcId, key, content: string,
                category: MemoryCategory = mcCore,
                visibility: MemoryVisibility = mvPrivate,
                storedAtTrust: int = 0) =
  ## Record to the agent's own memory (self.jsonl). Visibility governs
  ## who can recall this later via trust filtering. Caller should have
  ## applied `downgradeForTrust` before passing visibility.
  appendEntry(ms.selfPath,
    MemoryEntry(
      key: key, content: content,
      category: category, visibility: visibility,
      senderID: authorNcId, timestamp: epochTime(),
      storedAtTrust: storedAtTrust
    ))

# ── Recall ─────────────────────────────────────────────────────────

proc recallSender*(ms: MemoryStore, ncId: string, query: string = "",
                   limit: int = 10): seq[MemoryEntry] =
  ## Only reads ncId's own file. Cross-partner access is impossible.
  ## nc:id-only: any caller that hasn't resolved their sender to an nc:id
  ## gets an empty result. Name-keyed files are never created or read.
  if not ncId.startsWith("nc:"): return
  let entries = readEntries(ms.senderFile(ncId))
  let qLow = query.toLowerAscii
  for e in entries:
    if e.deleted: continue
    if qLow.len > 0 and qLow notin e.content.toLowerAscii and
       qLow notin e.key.toLowerAscii:
      continue
    result.add(e)
  result.sort(proc(a, b: MemoryEntry): int = cmp(b.timestamp, a.timestamp))
  if result.len > limit: result = result[0 ..< limit]

proc recallSelf*(ms: MemoryStore, trustLevel: int, query: string = "",
                 limit: int = 10): seq[MemoryEntry] =
  ## Reads only self.jsonl. Filters by visibility × trustLevel.
  let entries = readEntries(ms.selfPath)
  let qLow = query.toLowerAscii
  for e in entries:
    if e.deleted: continue
    if not canView(e.visibility, trustLevel): continue
    if qLow.len > 0 and qLow notin e.content.toLowerAscii and
       qLow notin e.key.toLowerAscii:
      continue
    result.add(e)
  result.sort(proc(a, b: MemoryEntry): int = cmp(b.timestamp, a.timestamp))
  if result.len > limit: result = result[0 ..< limit]

# ── Forget (tombstone) ─────────────────────────────────────────────

proc forgetEntry(path, requesterID, key: string, trustLevel: int,
                 checkSelfAuth: bool): bool =
  ## Tombstones one entry by key. Returns true if a live match was found.
  ## Auth rules differ by file kind — callers pass the right flag.
  if not fileExists(path): return false
  var rewritten: seq[string]
  var found = false
  let now = epochTime()
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0: continue
    try:
      var e = parseJson(trimmed).to(MemoryEntry)
      let canDelete = block:
        if checkSelfAuth:
          # self.jsonl: trust >= 70 can delete anything; or author self-retract
          # on public/shared (can't retract own private/secret without trust).
          let selfRetract = e.senderID == requesterID and
                            e.visibility in {mvPublic, mvShared}
          trustLevel >= 70 or selfRetract
        else:
          # sender file: the entry is inherently scoped to one partner;
          # trust >= 40 (Customer+) can tidy; partner can always clear
          # their own conversation memory.
          trustLevel >= 40 or e.senderID == requesterID
      if e.key == key and canDelete and not e.deleted:
        e.deleted = true
        e.deletedBy = requesterID
        e.deletedAt = now
        rewritten.add($(%e))
        found = true
      else:
        rewritten.add(line)
    except CatchableError:
      rewritten.add(line)
  if found:
    writeFile(path, rewritten.join("\n") & "\n")
  found

proc forgetSender*(ms: MemoryStore, senderNcId, requesterID, key: string,
                   trustLevel: int): bool =
  if not senderNcId.startsWith("nc:"): return false
  forgetEntry(ms.senderFile(senderNcId), requesterID, key, trustLevel,
              checkSelfAuth = false)

proc forgetSelf*(ms: MemoryStore, requesterID, key: string,
                 trustLevel: int): bool =
  forgetEntry(ms.selfPath, requesterID, key, trustLevel,
              checkSelfAuth = true)

# ── Legacy MEMORY.md — read-only back-compat ───────────────────────

proc readLegacyMd(ms: MemoryStore): string =
  if fileExists(ms.memoryFile): readFile(ms.memoryFile) else: ""

proc readLegacyDailyNotes(ms: MemoryStore, days: int): string =
  var notes: seq[string]
  for i in 0 ..< days:
    let date = now() - i.days
    let dateStr = date.format("yyyyMMdd")
    let monthDir = dateStr[0..5]
    let filePath = ms.memoryDir / monthDir / (dateStr & ".md")
    if fileExists(filePath): notes.add(readFile(filePath))
  if notes.len == 0: "" else: notes.join("\n\n---\n\n")

# ── System-prompt injection ────────────────────────────────────────

proc renderEntries(entries: seq[MemoryEntry]): string =
  ## Markdown bullet list with optional provenance annotation.
  var lines: seq[string]
  for e in entries:
    var meta = $e.category & "/" & $e.visibility
    if e.storedAtTrust > 0 and e.storedAtTrust < 70:
      meta.add(", from trust " & $e.storedAtTrust)
    lines.add("- [" & e.key & "] (" & meta & "): " & e.content)
  lines.join("\n")

proc getMemoryContext*(ms: MemoryStore, senderNcId: string,
                       trustLevel: int): string =
  ## Two sub-sections: conversation memory with the current partner,
  ## and agent's own memory filtered by trust. Legacy MEMORY.md / daily
  ## notes surface only for trust >= 40 (shared tier).
  var parts: seq[string] = @[]

  let partnerEntries = ms.recallSender(senderNcId, "", 20)
  if partnerEntries.len > 0:
    parts.add("## Conversation memory (with " & senderNcId & ")\n" &
              renderEntries(partnerEntries))

  let selfEntries = ms.recallSelf(trustLevel, "", 20)
  if selfEntries.len > 0:
    parts.add("## Agent's own memory\n" & renderEntries(selfEntries))

  if canView(mvShared, trustLevel):
    let legacy = ms.readLegacyMd().strip
    if legacy.len > 0:
      parts.add("## Long-term Memory (legacy)\n\n" & legacy)
    let notes = ms.readLegacyDailyNotes(3).strip
    if notes.len > 0:
      parts.add("## Recent Daily Notes (legacy)\n\n" & notes)

  if parts.len == 0: return ""
  "# Memory\n\n" & parts.join("\n\n---\n\n")

# ── Deprecated helpers (kept only for direct-file writers) ─────────

proc readLongTerm*(ms: MemoryStore): string =
  ## DEPRECATED: returns MEMORY.md unfiltered. Prefer getMemoryContext.
  ms.readLegacyMd()

proc writeLongTerm*(ms: MemoryStore, content: string) =
  ## DEPRECATED: direct MEMORY.md write. Prefer storeSelf.
  writeFile(ms.memoryFile, content)

proc appendToday*(ms: MemoryStore, content: string) =
  ## DEPRECATED: legacy daily-notes writer. Prefer storeAboutSender
  ## (category: mcDaily) or storeSelf.
  let today = now().format("yyyyMMdd")
  let monthDir = today[0..5]
  let todayFile = ms.memoryDir / monthDir / (today & ".md")
  if not dirExists(ms.memoryDir / monthDir):
    createDir(ms.memoryDir / monthDir)
  var existing = ""
  if fileExists(todayFile): existing = readFile(todayFile)
  var updated =
    if existing == "":
      "# " & now().format("yyyy-MM-dd") & "\n\n" & content
    else:
      existing & "\n" & content
  writeFile(todayFile, updated)
