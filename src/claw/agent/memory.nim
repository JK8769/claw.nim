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
    mcExperience = "experience"     ## Auto-captured outcome event tied to a
                                    ## partner interaction (cancellation,
                                    ## praise, etc.). Always partner-file;
                                    ## the framework writes these, not the
                                    ## agent. Drives offline synthesis into
                                    ## mcReflection entries on self.jsonl.

  MemoryEntry* = object
    key*: string
    content*: string
    category*: MemoryCategory
    visibility*: MemoryVisibility   ## meaningful on self.jsonl; ignored on partner files
    senderID*: string               ## nc:id context (file's nc:id for partner files;
                                    ## whoever was talking for self.jsonl entries)
    timestamp*: float64             ## epoch seconds — gives the timeline
    storedAtTrust*: int             ## trust at write time (0 = legacy/unknown)
    weight*: float64                ## Outcome-signal magnitude in [-1.0, +1.0].
                                    ## 0.0 = no signal (default; back-compat for
                                    ## entries written before mcExperience existed).
                                    ## Negative = user pushed back (cancellation,
                                    ## frustration); positive = user reinforced
                                    ## (praise, thanks). Magnitude reflects
                                    ## confidence in the signal — strong markers
                                    ## like "做得真好" → 1.0; reflexive politeness
                                    ## like "thanks" → 0.6. Drives clustering /
                                    ## ranking during reflection synthesis.
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

# ── Entity-strip for reflections ────────────────────────────────────
#
# Mechanically removes structural identifiers from text before storage.
# Applied automatically by `memory store category=reflection` so an
# agent-authored reflection that accidentally references a partner's
# nc:id or channel-specific identifier doesn't fingerprint them in the
# reflection store.
#
# Scope (what gets stripped):
#   nc:\d+              cortex IDs
#   ou_[A-Za-z0-9]+     Feishu open_id
#   on_[A-Za-z0-9]+     Feishu open_chat_id
#   oc_[A-Za-z0-9]+     Feishu open_chat_id (alt)
#   om_[A-Za-z0-9]+     Feishu union_id variant
#   @[A-Za-z0-9._-]+    chat @-mentions (any channel)
#
# Scope EXPLICITLY NOT covered (agent's prompt-craft responsibility):
#   display names (no reliable detector)
#   phone numbers / emails (fragile assumptions about format)
#   semantic context ("they're stressed about the merger")
#
# This is the structural backstop. The semantic strip belongs in the
# agent's reflection prompt: "summarize without naming partners; refer
# to them generically." That part is the `thinker` competency's job.

import std/re

let entityStripPatterns = [
  (re"nc:\d+", "[entity]"),
  (re"ou_[A-Za-z0-9]+", "[feishu_id]"),
  (re"on_[A-Za-z0-9]+", "[feishu_id]"),
  (re"oc_[A-Za-z0-9]+", "[feishu_id]"),
  (re"om_[A-Za-z0-9]+", "[feishu_id]"),
  (re"@[A-Za-z0-9._-]+", "[mention]"),
]

proc stripEntityIdentifiers*(text: string): string =
  ## Mechanical structural-identifier strip. ~10ms per call. Used by
  ## reflection-storing paths to prevent partner identifiers leaking
  ## into self.jsonl. Returns text with all known identifier patterns
  ## replaced by generic placeholders.
  result = text
  for (pat, replacement) in entityStripPatterns:
    result = result.replacef(pat, replacement)

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

proc recordExperience*(ms: MemoryStore, ncId, kind, content: string,
                        weight: float64) =
  ## Auto-captured outcome event for the partner identified by `ncId`.
  ## Lands in that partner's isolated experience file; never crosses
  ## into self.jsonl. Framework-only entry point: agents do not call
  ## this directly.
  ##
  ## Reflection synthesis (mcReflection entries on self.jsonl) is
  ## currently AGENT-AUTHORED — the `thinker` competency's heartbeat
  ## duties prompt the agent to read recent partner experiences and
  ## write a sanitized reflection via `memory store category=reflection`.
  ## `stripEntityIdentifiers` is applied automatically on store
  ## (mechanical backstop for nc:id / channel-id leaks); semantic
  ## sanitization (no display names, no specifics) is the agent's
  ## prompt-craft job.
  ##
  ## `kind` is a stable tag the agent keys on when surveying experiences
  ## ("cancelled_turn", "positive_feedback"). `content` is a short
  ## human-readable summary anchored to the agent's recent work
  ## ("iter 5: history queries on plant 荣鑫"). `weight` carries the
  ## signal direction and confidence — see MemoryEntry.weight doc.
  if not ncId.startsWith("nc:"): return
  if kind.len == 0: return
  appendEntry(ms.senderFile(ncId),
    MemoryEntry(
      key: kind, content: content,
      category: mcExperience, visibility: mvPublic,
      senderID: ncId, timestamp: epochTime(),
      weight: weight
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

# ── Cross-source recall: sessions, heart, knowledge ────────────────
##
## Phase 6 of the verify-triangle. The base recall procs above only
## see <office>/memory/. The agent's substantive history actually
## lives in three other stores under the same office root:
##
##   sessions/<partner>.jsonl   — raw conversation turns
##   heart/heartbeat.jsonl       — heartbeat tick log
##   knowledge/<topic>.md        — semantic memory wiki
##
## The procs below let `memory recall scope=...` reach into those
## stores. All return a uniform MemoryHit envelope so cross-source
## results merge cleanly. Time-windowed via fromTs/toTs (epoch
## seconds; 0.0 means "no bound").
##
## `verify` action layers on top: tokenizes a claim, runs recallAll
## per keyword, returns evidence with provenance. The cognitive
## analog of `workstation verify_project` — tool produces evidence,
## agent draws conclusions.

type
  MemoryHit* = object
    source*: string    ## "sessions:<key>" | "memory:self" | "memory:<nc>" | "heart" | "knowledge:<topic>"
    role*: string      ## "user" | "assistant" | "tool" | "system" | "" (n/a for non-session sources)
                       ## Critical for verify: a hit from `role=user`
                       ## means someone *asked* about the keywords —
                       ## not evidence the agent *did* anything.
                       ## `role=assistant` = the agent's own past output.
    ts*: float         ## epoch seconds — for time filtering & ordering
    excerpt*: string   ## ≤300 chars, the matched content
    path*: string      ## absolute path for cite-back

proc officeRoot*(ms: MemoryStore): string =
  ## Office root = parent of memoryDir (`<office>/memory/` → `<office>`).
  parentDir(ms.memoryDir)

proc clipExcerpt(s: string, maxLen = 300): string =
  if s.len <= maxLen: return s
  result = s[0 ..< maxLen] & "…"

proc tsInWindow(ts, fromTs, toTs: float): bool {.inline.} =
  if fromTs > 0.0 and ts < fromTs: return false
  if toTs > 0.0 and ts > toTs: return false
  true

proc matches(content, queryLower: string): bool {.inline.} =
  if queryLower.len == 0: return true
  queryLower in content.toLowerAscii

proc recallSessions*(ms: MemoryStore, query: string,
                     fromTs, toTs: float, limit: int): seq[MemoryHit] =
  ## Sweep <office>/sessions/*.jsonl. Each line is a turn JSON; we
  ## look at `ts` and `content` fields. Anything else (role, speaker,
  ## tool_calls) is ignored for the match.
  result = @[]
  let dir = ms.officeRoot() / "sessions"
  if not dirExists(dir): return
  let qLow = query.toLowerAscii
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    if not path.endsWith(".jsonl"): continue
    let key = path.extractFilename.changeFileExt("")
    var f: File
    if not f.open(path, fmRead): continue
    defer: f.close()
    var line: string
    while f.readLine(line):
      if line.len == 0: continue
      var parsed: JsonNode
      try: parsed = parseJson(line)
      except CatchableError: continue
      if parsed.kind != JObject: continue
      let ts = parsed.getOrDefault("ts").getFloat(0.0)
      if not tsInWindow(ts, fromTs, toTs): continue
      let content = parsed.getOrDefault("content").getStr("")
      if content.len == 0: continue
      if not matches(content, qLow): continue
      let role = parsed.getOrDefault("role").getStr("")
      result.add(MemoryHit(
        source: "sessions:" & key,
        role: role,
        ts: ts,
        excerpt: clipExcerpt(content),
        path: path
      ))
      if result.len >= limit: return

proc recallHeart*(ms: MemoryStore, query: string,
                  fromTs, toTs: float, limit: int): seq[MemoryHit] =
  ## Sweep <office>/heart/heartbeat.jsonl. Each line is a tick event.
  result = @[]
  let path = ms.officeRoot() / "heart" / "heartbeat.jsonl"
  if not fileExists(path): return
  let qLow = query.toLowerAscii
  var f: File
  if not f.open(path, fmRead): return
  defer: f.close()
  var line: string
  while f.readLine(line):
    if line.len == 0: continue
    var parsed: JsonNode
    try: parsed = parseJson(line)
    except CatchableError: continue
    if parsed.kind != JObject: continue
    let ts = parsed.getOrDefault("ts").getFloat(0.0)
    if not tsInWindow(ts, fromTs, toTs): continue
    let kind = parsed.getOrDefault("kind").getStr("")
    let msg = parsed.getOrDefault("msg").getStr("")
    let composed = (kind & " | " & msg & " | " & line).strip()
    if not matches(composed, qLow): continue
    result.add(MemoryHit(
      source: "heart",
      ts: ts,
      excerpt: clipExcerpt(composed),
      path: path
    ))
    if result.len >= limit: return

# (recallKnowledge removed — the knowledge wiki is the `knowledge` tool's
#  domain, accessed via `knowledge lookup` / `knowledge top`. Memory is
#  for raw past events only — different epistemic category.)

proc recallSelfHits*(ms: MemoryStore, trustLevel: int, query: string,
                     fromTs, toTs: float, limit: int): seq[MemoryHit] =
  result = @[]
  for e in ms.recallSelf(trustLevel, query, limit * 4):
    if not tsInWindow(e.timestamp, fromTs, toTs): continue
    result.add(MemoryHit(
      source: "memory:self",
      ts: e.timestamp,
      excerpt: clipExcerpt(e.key & ": " & e.content),
      path: ms.selfPath
    ))
    if result.len >= limit: return

proc recallSenderHits*(ms: MemoryStore, ncId: string, query: string,
                       fromTs, toTs: float, limit: int): seq[MemoryHit] =
  result = @[]
  if not ncId.startsWith("nc:"): return
  for e in ms.recallSender(ncId, query, limit * 4):
    if not tsInWindow(e.timestamp, fromTs, toTs): continue
    result.add(MemoryHit(
      source: "memory:" & ncId,
      ts: e.timestamp,
      excerpt: clipExcerpt(e.key & ": " & e.content),
      path: ms.senderFile(ncId)
    ))
    if result.len >= limit: return

proc recallAll*(ms: MemoryStore, ncId: string, trustLevel: int,
                query: string, fromTs, toTs: float,
                limit: int): seq[MemoryHit] =
  ## Cross-source EXPERIENTIAL recall: sessions + heart + memory(self+sender).
  ## Per-store cap is `limit` so a noisy single store can't crowd out
  ## the others; final list is sorted ts-desc and capped at `limit`.
  ##
  ## Knowledge wiki INTENTIONALLY excluded — knowledge is the SHIP
  ## (timeless facts), memory is the SEA (raw past). Different epistemic
  ## category; use the `knowledge` tool for fact lookups.
  result = @[]
  result.add(ms.recallSessions(query, fromTs, toTs, limit))
  result.add(ms.recallHeart(query, fromTs, toTs, limit))
  result.add(ms.recallSelfHits(trustLevel, query, fromTs, toTs, limit))
  if ncId.startsWith("nc:"):
    result.add(ms.recallSenderHits(ncId, query, fromTs, toTs, limit))
  result.sort(proc(a, b: MemoryHit): int =
    if a.ts > b.ts: -1 elif a.ts < b.ts: 1 else: 0)
  if result.len > limit:
    result.setLen(limit)

# ── Time-arg parsing + claim tokenization (for memory verify) ──────

const Stopwords = ["the", "a", "an", "of", "to", "in", "on", "for",
                   "with", "and", "or", "but", "is", "are", "was",
                   "were", "be", "been", "being", "have", "has", "had",
                   "do", "does", "did", "i", "me", "my", "you", "your",
                   "we", "us", "our", "it", "its", "this", "that",
                   "these", "those", "at", "by", "from", "as"]

proc parseTimeArg*(s: string): float =
  ## Accept "yyyy-MM-dd" (start of day, local) or full ISO 8601.
  ## Returns 0.0 on parse failure (caller treats as "no bound").
  let trimmed = s.strip()
  if trimmed.len == 0: return 0.0
  try:
    if trimmed.len == 10 and trimmed[4] == '-' and trimmed[7] == '-':
      return parse(trimmed, "yyyy-MM-dd", local()).toTime.toUnixFloat
    return parseTime(trimmed, "yyyy-MM-dd'T'HH:mm:sszzz", utc()).toUnixFloat
  except CatchableError:
    try:
      return parseTime(trimmed, "yyyy-MM-dd HH:mm", local()).toUnixFloat
    except CatchableError:
      return 0.0

proc tokenizeClaim*(claim: string): seq[string] =
  ## Lowercase, strip punctuation, drop stopwords + tokens <3 chars.
  result = @[]
  var seen = initTable[string, bool]()
  var word = ""
  template emit() =
    if word.len >= 3 and word notin Stopwords and not seen.hasKey(word):
      result.add(word)
      seen[word] = true
    word.setLen(0)
  for c in claim.toLowerAscii:
    if c in {'a'..'z', '0'..'9', '_', '-'}:
      word.add(c)
    else:
      emit()
  emit()
