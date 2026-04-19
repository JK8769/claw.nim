## Per-agent memory store with two gating mechanisms.
##
## Layout (inside each agent's office dir):
##
##   <office>/
##     memory/
##       self.jsonl          # agent's own memory — visibility-gated
##       nc_<N>.jsonl        # one file per conversation partner (nc:id)
##     sessions/              # live conversation state (owned elsewhere)
##     notes/                 # forward-looking notes (owned elsewhere)
##
## Three time-axes as peers under the office: **memory** (past — this module),
## **sessions** (present), **notes** (future). All memory state is JSONL —
## searchable, timeline-ordered by timestamp, append-only with tombstones.
##
## Gating mechanisms:
##
##   1. **Per-sender isolation** — memories recorded while talking with X go
##      into X's nc_<N>.jsonl, which is only opened when the agent is
##      talking to X again. Cross-partner access is impossible by file
##      layout, not by policy check.
##
##   2. **Visibility on self.jsonl** — the agent's own store holds entries
##      tagged secret / private / shared / public. recallSelf filters by
##      the current requester's trust level; low-trust writers have their
##      visibility clamped down automatically.
##
## Stores:
##   storeAboutSender → nc_<N>.jsonl (no visibility)
##   storeSelf        → self.jsonl with visibility (clamped by trust)
##
## Recall:
##   recallSender     → current partner's file only
##   recallSelf       → self.jsonl filtered by visibility × trust
##   getMemoryContext → merges both for system-prompt injection

import std/[os, json, times, strutils, algorithm]

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
    visibility*: MemoryVisibility   ## meaningful on self.jsonl; ignored on partner files
    senderID*: string               ## nc:id context (file's nc:id for partner files;
                                    ## whoever was talking for self.jsonl entries)
    timestamp*: float64             ## epoch seconds — gives the timeline
    storedAtTrust*: int             ## trust at write time (0 = legacy/unknown)
    deleted*: bool                  ## tombstone
    deletedBy*: string
    deletedAt*: float64

  MemoryStore* = ref object
    memoryDir*: string          ## <office>/memory
    selfPath*: string           ## <office>/memory/self.jsonl

proc newMemoryStore*(workspace: string): MemoryStore =
  let memoryDir = workspace / "memory"
  if not dirExists(memoryDir): createDir(memoryDir)
  MemoryStore(
    memoryDir: memoryDir,
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
  ## Clamp visibility downward if the storer's trust isn't high enough.
  ## A Guest can't save a secret, no matter what the LLM is told.
  if trustLevel < 50 and requested != mvPublic: return mvPublic
  if trustLevel < 70 and requested in {mvSecret, mvPrivate}: return mvShared
  if trustLevel < 100 and requested == mvSecret: return mvPrivate
  requested

# ── File-name sanitisation ─────────────────────────────────────────

proc sanitizeId(id: string): string =
  if id.len == 0: return "unknown"
  for c in id:
    if c in Letters or c in Digits or c in {'_', '-', '.'}: result.add(c)
    else: result.add('_')

proc senderFile*(ms: MemoryStore, ncId: string): string =
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
  ## Record something about/with the current conversation partner. Lands
  ## in the partner's isolated file. Visibility is unused — the file
  ## boundary is the access gate. nc:id-only: silently no-op on raw names.
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
  ## Record to the agent's own memory. Caller should have applied
  ## `downgradeForTrust` before passing visibility.
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
  ## nc:id-only: any caller that hasn't resolved to an nc:id gets empty.
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
  ## Reads self.jsonl. Filters by visibility × trustLevel.
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
          # self.jsonl: trust >= 70 can delete anything; self-retract on
          # public/shared only (can't retract your own private/secret).
          let selfRetract = e.senderID == requesterID and
                            e.visibility in {mvPublic, mvShared}
          trustLevel >= 70 or selfRetract
        else:
          # sender file: trust >= 40 can tidy; the partner can always
          # clear their own conversation memory.
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
  forgetEntry(ms.selfPath, requesterID, key, trustLevel, checkSelfAuth = true)

# ── System-prompt injection ────────────────────────────────────────

proc renderEntries(entries: seq[MemoryEntry]): string =
  var lines: seq[string]
  for e in entries:
    var meta = $e.category & "/" & $e.visibility
    if e.storedAtTrust > 0 and e.storedAtTrust < 70:
      meta.add(", from trust " & $e.storedAtTrust)
    lines.add("- [" & e.key & "] (" & meta & "): " & e.content)
  lines.join("\n")

proc getMemoryContext*(ms: MemoryStore, senderNcId: string,
                       trustLevel: int): string =
  ## Two sub-sections: the current partner's conversation memory (opened
  ## only when senderNcId is nc:id form), and the agent's own memory
  ## filtered by visibility × trust.
  var parts: seq[string] = @[]

  if senderNcId.startsWith("nc:"):
    let partnerEntries = ms.recallSender(senderNcId, "", 20)
    if partnerEntries.len > 0:
      parts.add("## Conversation memory (with " & senderNcId & ")\n" &
                renderEntries(partnerEntries))

  let selfEntries = ms.recallSelf(trustLevel, "", 20)
  if selfEntries.len > 0:
    parts.add("## Agent's own memory\n" & renderEntries(selfEntries))

  if parts.len == 0: return ""
  "# Memory\n\n" & parts.join("\n\n---\n\n")
