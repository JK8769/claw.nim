## Session store — per-conversation state for the agent.
##
## Layout on disk (under `<office>/sessions/`):
##
##   <key>.jsonl        — append-only message log, one JSON object per line
##   <key>.meta.json    — small per-session header, rewritten on update
##   attachments/<key>/ — binary assets (images, PDFs, video) referenced by
##                         path from within the JSONL lines
##
## Session `<key>` is the identity-scoped key the loop derives per turn
## (see identitySessionKey — `nc_5`, `nc_11`, `system_heartbeat`, etc.).
## 1:1 DMs and group chats share the same layout; groups simply have more
## than one non-agent participant and messages carry a `speaker` field
## identifying who sent each one.
##
## Why split JSONL + meta:
##
##   - Append costs one `write()`; rewriting the whole session each turn
##     (the old format) grew linearly with history.
##   - Meta is small (< 1KB typical) — rewriting it per turn is cheap.
##   - `grep`/`tail -f` still work on the JSONL during debugging.
##   - "Which sessions involve Alice?" answered by scanning the meta
##     files, not by parsing every JSONL line.
##
## Back-compat: legacy single-blob `<key>.json` files are read on first
## access and converted transparently. No manual migration step.

import std/[os, times, tables, locks, json, strutils]
import jsony
import providers/types as providers_types

type
  SessionKind* = enum
    skDM     = "dm"         ## 1:1 agent ↔ partner
    skGroup  = "group"      ## 3+ participants; messages tagged by speaker
    skSystem = "system"     ## synthetic (heartbeat, cron)

  Attachment* = object
    ## Reference, not bytes. Actual payload lives under
    ## `<office>/sessions/attachments/<session-key>/…`.
    kind*: string           ## "image" | "video" | "pdf" | "audio" | "file"
    path*: string           ## relative to <office>/sessions/attachments/
    mime*: string
    size*: int

  SessionMessage* = object
    ts*: float64            ## epoch seconds — newest-last in the JSONL
    speaker*: string        ## nc:id of who produced this message ("" for
                            ## system/tool output)
    role*: string           ## providers_types.Message.role — "user",
                            ## "assistant", "tool", "system"
    content*: string        ## the text (may be "" when only attachments)
    reasoning_content*: string  ## DeepSeek V4 / o1-style thinking-mode
                                ## reasoning. Echoed back to the API on
                                ## subsequent turns — without this, v4
                                ## rejects with "The reasoning_content in
                                ## the thinking mode must be passed back".
                                ## Empty for non-thinking models or for
                                ## user/tool/system roles.
    tool_calls*: seq[providers_types.ToolCall]
                                ## Assistant role: function calls the
                                ## model emitted this turn. Preserved so
                                ## replays after `/restart` keep the
                                ## proper "assistant(tool_calls) → tool"
                                ## protocol pairing instead of replaying
                                ## tool results as bare user messages.
    tool_call_id*: string       ## Tool role: which assistant tool_call
                                ## this result corresponds to.
    name*: string               ## Tool role: tool name. Some providers
                                ## require it alongside tool_call_id.
    attachments*: seq[Attachment]

  SessionMeta* = object
    key*: string
    kind*: SessionKind
    participants*: seq[string]        ## nc:ids; for DMs, agent + partner
    created*: float64
    updated*: float64
    messageCount*: int
    attachmentCount*: int
    summary*: string
    summaryWatermark*: int            ## msg index at/above which history
                                      ## is still raw; anything below has
                                      ## been folded into `summary`.

  Session* = ref object
    key*: string
    meta*: SessionMeta
    messages*: seq[SessionMessage]    ## in-memory cache of the JSONL tail

  SessionManager* = ref object
    sessions*: Table[string, Session]
    lock*: Lock
    storage*: string                  ## <office>/sessions

# ── Paths ──────────────────────────────────────────────────────────

proc logPath(sm: SessionManager, key: string): string =
  sm.storage / (key & ".jsonl")

proc metaPath(sm: SessionManager, key: string): string =
  sm.storage / (key & ".meta.json")

proc attachmentsDir*(sm: SessionManager, key: string): string =
  sm.storage / "attachments" / key

# ── Load / migrate ─────────────────────────────────────────────────

proc readAllJsonl(path: string): seq[SessionMessage] =
  ## Hydrate every line of a session log into a SessionMessage.
  ##
  ## Uses jsony's `fromJson`, which fills missing fields with their type's
  ## zero value. This is critical for backward compatibility: older
  ## entries on disk (written before `reasoning_content` / `tool_calls` /
  ## `tool_call_id` / `name` were added to the schema) lack those keys.
  ## std/json's strict `.to()` raised "key not found" on every such line
  ## and silently dropped it — meaning a session that hadn't been written
  ## to since the schema grew would load as zero messages, even though
  ## the JSONL on disk was intact. That bug surfaced as `/session status`
  ## showing 0-msg rows for legitimately full sessions.
  if not fileExists(path): return
  try:
    for line in lines(path):
      let trimmed = line.strip()
      if trimmed.len == 0: continue
      try:
        result.add(trimmed.fromJson(SessionMessage))
      except CatchableError: discard
  except IOError: discard

proc loadMeta(sm: SessionManager, key: string): SessionMeta =
  let path = sm.metaPath(key)
  result = SessionMeta(
    key: key,
    kind: skDM,
    participants: @[],
    summaryWatermark: 0
  )
  if fileExists(path):
    try:
      result = readFile(path).fromJson(SessionMeta)
    except CatchableError: discard

proc writeMeta(sm: SessionManager, session: Session) =
  if sm.storage == "": return
  try:
    writeFile(sm.metaPath(session.key), session.meta.toJson())
  except CatchableError: discard

proc migrateLegacyJson(sm: SessionManager, key: string): bool =
  ## Read a pre-v2 `<key>.json` blob (if present) and split it into the
  ## new JSONL + meta pair. Removes the legacy file on success. Returns
  ## true if a migration happened.
  let legacyPath = sm.storage / (key & ".json")
  if not fileExists(legacyPath): return false
  if fileExists(sm.logPath(key)): return false  # already migrated
  try:
    let j = parseJson(readFile(legacyPath))
    let logF = open(sm.logPath(key), fmWrite)
    var msgCount = 0
    if j.hasKey("messages"):
      for m in j["messages"]:
        let msg = SessionMessage(
          ts: 0.0,
          speaker: "",
          role: m{"role"}.getStr(""),
          content: m{"content"}.getStr(""),
          attachments: @[]
        )
        logF.writeLine($(%msg))
        inc msgCount
    logF.close()
    var meta = SessionMeta(
      key: key,
      kind: skDM,
      participants: @[],
      created: j{"created"}.getFloat(0.0),
      updated: j{"updated"}.getFloat(0.0),
      messageCount: msgCount,
      summary: j{"summary"}.getStr(""),
      summaryWatermark: 0
    )
    writeFile(sm.metaPath(key), meta.toJson())
    removeFile(legacyPath)
    return true
  except CatchableError:
    return false

proc loadSession(sm: SessionManager, key: string): Session =
  ## Hydrate a Session from disk. Runs legacy migration first if needed.
  discard sm.migrateLegacyJson(key)
  result = Session(
    key: key,
    meta: sm.loadMeta(key),
    messages: readAllJsonl(sm.logPath(key))
  )
  if result.meta.key == "": result.meta.key = key

proc newSessionManager*(storage: string): SessionManager =
  result = SessionManager(
    sessions: initTable[string, Session](),
    storage: storage
  )
  initLock(result.lock)
  if storage == "": return
  if not dirExists(storage): createDir(storage)
  # Eagerly load everything we can find. Each session is small.
  for file in walkFiles(storage / "*.jsonl"):
    let base = file.lastPathPart()
    let key = base[0 ..< base.len - ".jsonl".len]
    result.sessions[key] = result.loadSession(key)
  # Pick up any pre-v2 .json that hasn't been migrated yet.
  for file in walkFiles(storage / "*.json"):
    let base = file.lastPathPart()
    if base.endsWith(".meta.json"): continue
    let key = base[0 ..< base.len - ".json".len]
    if not result.sessions.hasKey(key):
      result.sessions[key] = result.loadSession(key)

# ── Lifecycle ──────────────────────────────────────────────────────

proc getOrCreate*(sm: SessionManager, key: string): Session =
  acquire(sm.lock)
  defer: release(sm.lock)
  if sm.sessions.hasKey(key): return sm.sessions[key]
  let now = getTime().toUnixFloat()
  let s = Session(
    key: key,
    meta: SessionMeta(
      key: key,
      kind: skDM,
      participants: @[],
      created: now,
      updated: now,
      summaryWatermark: 0
    ),
    messages: @[]
  )
  sm.sessions[key] = s
  return s

# ── Append messages ────────────────────────────────────────────────

proc appendToLog(sm: SessionManager, session: Session, msg: SessionMessage) =
  if sm.storage == "": return
  try:
    let f = open(sm.logPath(session.key), fmAppend)
    f.writeLine($(%msg))
    f.close()
  except CatchableError: discard

proc addRichMessage*(sm: SessionManager, key: string, msg: SessionMessage) =
  ## Preferred API — caller supplies speaker + timestamp + attachments.
  ## Appends one line to the JSONL and updates the meta.
  acquire(sm.lock)
  defer: release(sm.lock)
  if not sm.sessions.hasKey(key):
    let now = getTime().toUnixFloat()
    sm.sessions[key] = Session(
      key: key,
      meta: SessionMeta(
        key: key, kind: skDM, participants: @[],
        created: now, updated: now
      ),
      messages: @[]
    )
  let session = sm.sessions[key]
  var m = msg
  if m.ts == 0.0: m.ts = getTime().toUnixFloat()
  session.messages.add(m)
  session.meta.updated = m.ts
  session.meta.messageCount = session.messages.len
  session.meta.attachmentCount += m.attachments.len
  if m.speaker.len > 0 and m.speaker notin session.meta.participants:
    session.meta.participants.add(m.speaker)
  sm.appendToLog(session, m)
  sm.writeMeta(session)

proc addFullMessage*(sm: SessionManager, key: string,
                      msg: providers_types.Message) =
  ## Legacy API — no speaker / no attachments. Kept for call sites that
  ## haven't been updated; prefer addRichMessage. Carries through every
  ## protocol-relevant field (reasoning_content, tool_calls,
  ## tool_call_id, name) so the message round-trips losslessly across
  ## `/restart` and the LLM sees the same shape it generated.
  sm.addRichMessage(key, SessionMessage(
    ts: 0.0, speaker: "", role: msg.role, content: msg.content,
    reasoning_content: msg.reasoning_content,
    tool_calls: msg.tool_calls,
    tool_call_id: msg.tool_call_id,
    name: msg.name,
    attachments: @[]
  ))

proc addMessage*(sm: SessionManager, key, role, content: string) =
  sm.addFullMessage(key, providers_types.Message(role: role, content: content))

proc addWithSpeaker*(sm: SessionManager, key, role, content, speaker: string,
                     attachments: seq[Attachment] = @[]) =
  ## Preferred wrapper: tags each message with who produced it so group
  ## sessions can tell participants apart. Attachments default empty.
  sm.addRichMessage(key, SessionMessage(
    ts: 0.0, speaker: speaker, role: role, content: content,
    attachments: attachments
  ))

# ── Reads ──────────────────────────────────────────────────────────

proc getHistory*(sm: SessionManager, key: string): seq[providers_types.Message] =
  ## Returns the LLM-facing message list. Messages before summaryWatermark
  ## are skipped — the summary stands in for them. Caller is expected to
  ## inject the summary separately.
  acquire(sm.lock)
  defer: release(sm.lock)
  if not sm.sessions.hasKey(key): return @[]
  let session = sm.sessions[key]
  let startIdx = max(0, session.meta.summaryWatermark)
  if startIdx >= session.messages.len: return @[]
  for m in session.messages[startIdx .. ^1]:
    result.add(providers_types.Message(
      role: m.role, content: m.content,
      reasoning_content: m.reasoning_content,
      tool_calls: m.tool_calls,
      tool_call_id: m.tool_call_id,
      name: m.name))

proc getRichHistory*(sm: SessionManager, key: string): seq[SessionMessage] =
  acquire(sm.lock)
  defer: release(sm.lock)
  if not sm.sessions.hasKey(key): return @[]
  sm.sessions[key].messages

proc getSummary*(sm: SessionManager, key: string): string =
  acquire(sm.lock)
  defer: release(sm.lock)
  if not sm.sessions.hasKey(key): return ""
  sm.sessions[key].meta.summary

proc setSummary*(sm: SessionManager, key, summary: string) =
  acquire(sm.lock)
  defer: release(sm.lock)
  if not sm.sessions.hasKey(key): return
  let session = sm.sessions[key]
  session.meta.summary = summary
  session.meta.updated = getTime().toUnixFloat()
  sm.writeMeta(session)

# ── Group-chat helpers ─────────────────────────────────────────────

proc setKind*(sm: SessionManager, key: string, kind: SessionKind) =
  acquire(sm.lock)
  defer: release(sm.lock)
  if not sm.sessions.hasKey(key): return
  let s = sm.sessions[key]
  s.meta.kind = kind
  sm.writeMeta(s)

proc addParticipant*(sm: SessionManager, key, ncId: string) =
  acquire(sm.lock)
  defer: release(sm.lock)
  if not sm.sessions.hasKey(key): return
  let s = sm.sessions[key]
  if ncId.len > 0 and ncId notin s.meta.participants:
    s.meta.participants.add(ncId)
    sm.writeMeta(s)

# ── Summary compaction ─────────────────────────────────────────────

proc truncateHistory*(sm: SessionManager, key: string, keepLast: int) =
  ## Sliding window. Does NOT erase the JSONL — moves the watermark so
  ## old raw lines are kept on disk for audit, but excluded from what
  ## the LLM sees. Combine with setSummary to replace them with a
  ## summary string.
  acquire(sm.lock)
  defer: release(sm.lock)
  if not sm.sessions.hasKey(key): return
  let session = sm.sessions[key]
  let total = session.messages.len
  if total <= keepLast:
    session.meta.summaryWatermark = 0
  else:
    session.meta.summaryWatermark = total - keepLast
  session.meta.updated = getTime().toUnixFloat()
  sm.writeMeta(session)

# ── Clear / save ───────────────────────────────────────────────────

proc clearSession*(sm: SessionManager, key: string) =
  ## Wipes the in-memory buffer AND both on-disk files. Attachments dir
  ## is left alone (may contain referenced blobs the user still wants).
  acquire(sm.lock)
  defer: release(sm.lock)
  if sm.sessions.hasKey(key):
    let s = sm.sessions[key]
    s.messages = @[]
    s.meta.summary = ""
    s.meta.messageCount = 0
    s.meta.attachmentCount = 0
    s.meta.summaryWatermark = 0
    s.meta.updated = getTime().toUnixFloat()
  for ext in [".jsonl", ".meta.json", ".json"]:
    let p = sm.storage / (key & ext)
    if fileExists(p):
      try: removeFile(p) except: discard

proc save*(sm: SessionManager, session: Session) =
  ## No-op for compatibility. Writes happen on every addMessage /
  ## setSummary — nothing to flush.
  discard
