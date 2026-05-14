## memory — per-partner isolation + trust-gated self memory.
##
## Two stores:
##
##   scope=sender (default)
##     Reads / writes / forgets in the current conversation partner's
##     isolated file (<office>/memory/<nc_id>.jsonl). No visibility
##     needed — cross-partner access is impossible by file layout.
##     Record preferences, session notes, anything about the specific
##     person you're talking with.
##
##   scope=self
##     Reads / writes / forgets in self.jsonl — the agent's own
##     memory. Entries carry visibility tags; recall filters by the
##     current requester's trust level. Use for reflections, learned
##     company facts, cross-conversation knowledge.
##
## The tool's mutable per-turn state (senderNcId, trustLevel) is
## refreshed by the agent loop before each LLM iteration via
## setRequesterContext. Low-trust self-writes are automatically
## downgraded (downgradeForTrust) so a Guest can't stash a secret.

import std/[json, tables, asyncdispatch, strformat, strutils, times, algorithm]
import ../types
import ../spec
import ../../agent/memory

const ToolSpec* = spec(
  name = "memory",
  description = "cross-source memory: query past experiences, reflections, conversations, heartbeats (action=store|recall|list|forget|recent|verify; scope=sender|self|sessions|heart|all). For timeless facts use the `knowledge` tool — different epistemic category (memory = sea / raw past; knowledge = ship / facts).",
  tags = @["memory", "core"],
  domain = "agent",
  default = true,
  heartbeatSafe = false,
  category = "self-management",
)

type
  UnifiedMemoryTool* = ref object of Tool
    store*: MemoryStore
    senderNcId*: string       ## refreshed per turn — nc:id of partner
    trustLevel*: int          ## refreshed per turn

proc newUnifiedMemoryTool*(ms: MemoryStore): UnifiedMemoryTool =
  ## Starts with trust=100 + senderNcId="" (no partner). scope=self still
  ## works in this state (writes to self.jsonl as the agent); scope=sender
  ## will refuse until a real partner's nc:id has been set per-turn.
  UnifiedMemoryTool(store: ms, senderNcId: "", trustLevel: 100)

proc setRequesterContext*(t: UnifiedMemoryTool, senderNcId: string,
                          trustLevel: int) =
  ## Called by the agent loop each turn. Accepts only nc:id form for the
  ## sender. A raw name string is dropped to empty so scope=sender calls
  ## refuse explicitly instead of creating a name-keyed file.
  t.senderNcId = if senderNcId.startsWith("nc:"): senderNcId else: ""
  t.trustLevel = trustLevel

method name*(t: UnifiedMemoryTool): string = "memory"

method description*(t: UnifiedMemoryTool): string =
  "Cross-source memory — past experiences, reflections, conversations, " &
  "heartbeats. The 'sea' in the memory/knowledge/skill trio (raw past, " &
  "with source attribution). For TIMELESS FACTS use the `knowledge` " &
  "tool — different epistemic category.\n\n" &
  "Actions:\n" &
  "  store    — write a memory entry (key + content). Pick scope.\n" &
  "  recall   — substring match. Optional from/to time bounds. " &
  "scope=all sweeps every store.\n" &
  "  list     — recall with empty query (limit-N most recent).\n" &
  "  forget   — tombstone an entry by key.\n" &
  "  recent   — time-window shortcut: `days=N` (e.g. last 7 days).\n" &
  "  verify   — given a `claim`, sweep all stores for evidence with " &
  "provenance. Returns supporting hits with source+ts+excerpt. " &
  "The cognitive analog of `workstation audit scope=project` — tool " &
  "produces evidence, you draw conclusions.\n\n" &
  "Scopes (pick via `scope=...`):\n" &
  "  sender (default) — partner's nc_<id>.jsonl (write/recall/list/forget)\n" &
  "  self             — agent's self.jsonl with visibility gates\n" &
  "  sessions         — raw conversation turns under sessions/ (recall only)\n" &
  "  heart            — heartbeat tick log (recall only)\n" &
  "  all              — sweeps all of the above (recall/recent/verify)\n\n" &
  "Not for time-based reminders — use `cron` instead. Not for facts — " &
  "use `knowledge`."

method parameters*(t: UnifiedMemoryTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["store", "recall", "list", "forget", "recent", "verify"]
      },
      "scope": {
        "type": "string",
        "enum": ["sender", "self", "sessions", "heart", "all"],
        "description": "sender (default) — current partner's file. all — sweeps every store with source attribution."
      },
      "key": {"type": "string"},
      "content": {"type": "string"},
      "query": {"type": "string"},
      "category": {
        "type": "string",
        "enum": ["core", "daily", "reflection", "preference"]
      },
      "visibility": {
        "type": "string",
        "enum": ["secret", "private", "shared", "public"],
        "description": "scope=self only. Clamped downward by current trust."
      },
      "limit": {"type": "integer"},
      "from": {
        "type": "string",
        "description": "recall only — start time `yyyy-MM-dd` or ISO 8601"
      },
      "to": {
        "type": "string",
        "description": "recall only — end time `yyyy-MM-dd` or ISO 8601"
      },
      "days": {
        "type": "integer",
        "description": "recent only — last N days from now (1-365)",
        "minimum": 1, "maximum": 365
      },
      "claim": {
        "type": "string",
        "description": "verify only — the assertion to check against the historical record"
      },
      "format": {
        "type": "string",
        "enum": ["text", "json"],
        "description": "Default text (back-compat). json returns structured envelope for programmatic consumption."
      }
    },
    "required": %["action"]
  }.toTable

proc renderHits*(hits: seq[MemoryHit], format, title: string): string =
  ## Format MemoryHits for display. format=text (default) returns a
  ## human-readable summary; format=json returns a structured envelope.
  ## Both surface `role` so the agent can distinguish "I said X" vs
  ## "someone asked me about X" — critical for honest verify reads.
  if format == "json":
    let arr = newJArray()
    for h in hits:
      arr.add(%*{
        "source": h.source,
        "role": h.role,
        "ts": h.ts,
        "excerpt": h.excerpt,
        "path": h.path
      })
    return $(%*{
      "title": title,
      "count": hits.len,
      "hits": arr
    })
  if hits.len == 0:
    return title & ": no matches."
  result = title & " (" & $hits.len & " hits):\n"
  for i, h in hits:
    let tsStr = if h.ts > 0: $fromUnix(int64(h.ts)) else: "?"
    let roleTag =
      if h.role.len > 0: " role=" & h.role
      else: ""
    result.add("  " & $(i + 1) & ". [" & h.source & roleTag & "] " &
               tsStr & "\n     " & h.excerpt & "\n")

proc parseCategory(s: string): MemoryCategory =
  case s.toLowerAscii
  of "daily":      mcDaily
  of "reflection": mcReflection
  of "preference": mcPreference
  else:            mcCore

proc parseVisibility(s: string): MemoryVisibility =
  case s.toLowerAscii
  of "secret": mvSecret
  of "shared": mvShared
  of "public": mvPublic
  else:        mvPrivate

proc extractScope(args: Table[string, JsonNode]): string =
  if args.hasKey("scope"): args["scope"].getStr("sender").toLowerAscii else: "sender"

method execute*(t: UnifiedMemoryTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.store == nil:
    return "Error: memory store not configured."

  let action = if args.hasKey("action"): args["action"].getStr() else: ""
  let scope = extractScope(args)

  case action
  of "store":
    if not args.hasKey("key") or args["key"].getStr() == "":
      return "Error: 'key' is required"
    if not args.hasKey("content") or args["content"].getStr() == "":
      return "Error: 'content' is required"
    let key = args["key"].getStr()
    let catStr = if args.hasKey("category"): args["category"].getStr() else: "core"
    let category = parseCategory(catStr)
    # Reflections get the structural-identifier strip applied automatically.
    # Mechanical backstop — agents are expected to also write the reflection
    # in generic terms (e.g. "the partner" not "Lubin"); this catches the
    # nc:id / channel-id leaks the prompt-craft layer might miss.
    let content =
      if category == mcReflection:
        stripEntityIdentifiers(args["content"].getStr())
      else:
        args["content"].getStr()
    case scope
    of "self":
      let requested = if args.hasKey("visibility"):
                        parseVisibility(args["visibility"].getStr())
                      else: mvPrivate
      let actual = downgradeForTrust(requested, t.trustLevel)
      try:
        t.store.storeSelf(t.senderNcId, key, content,
                          category, actual, t.trustLevel)
        let note = if actual != requested:
          fmt" (visibility clamped {requested} → {actual} for trust {t.trustLevel})"
        else: ""
        let stripNote = if category == mcReflection:
          " (entity-strip applied: nc:id/channel-id placeholders inserted)"
        else: ""
        return fmt"Stored in self.jsonl as {actual}{note}{stripNote}"
      except Exception as e:
        return fmt"Failed to store '{key}' to self: {e.msg}"
    else:  # sender scope
      if t.senderNcId.len == 0:
        return "Error: scope=sender requires a resolved partner. The current requester has no nc:id yet — try scope=self or route through a channel that registers the user in the graph."
      try:
        t.store.storeAboutSender(t.senderNcId, key, content,
                                  category, t.trustLevel)
        return fmt"Stored '{key}' in conversation memory for {t.senderNcId}"
      except Exception as e:
        return fmt"Failed to store '{key}' to sender file: {e.msg}"

  of "recall":
    let query = if args.hasKey("query"): args["query"].getStr() else: ""
    let limitRaw = if args.hasKey("limit") and args["limit"].kind == JInt:
                     args["limit"].getInt() else: 5
    let limit = clamp(limitRaw, 1, 100)
    let fromTs = if args.hasKey("from"): parseTimeArg(args["from"].getStr()) else: 0.0
    let toTs   = if args.hasKey("to"):   parseTimeArg(args["to"].getStr())   else: 0.0
    let format = if args.hasKey("format"): args["format"].getStr("text") else: "text"

    case scope
    of "self":
      # Existing per-store recall path — kept verbatim for back-compat.
      let entries = t.store.recallSelf(t.trustLevel, query, limit)
      if entries.len == 0: return "No accessible self-memory entries match."
      var res = fmt"Self memory (trust {t.trustLevel}):" & "\n"
      for i, e in entries:
        var tag = $e.category & "/" & $e.visibility
        if e.storedAtTrust > 0 and e.storedAtTrust < 70:
          tag.add(fmt", from trust {e.storedAtTrust}")
        res.add(fmt"  {i + 1}. [{e.key}] ({tag}): {e.content}" & "\n")
      return res
    of "sender":
      let entries = t.store.recallSender(t.senderNcId, query, limit)
      if entries.len == 0:
        return fmt"No conversation memory found for {t.senderNcId}"
      var res = fmt"Conversation memory with {t.senderNcId}:" & "\n"
      for i, e in entries:
        res.add(fmt"  {i + 1}. [{e.key}] ({e.category}): {e.content}" & "\n")
      return res
    of "sessions":
      return renderHits(t.store.recallSessions(query, fromTs, toTs, limit),
                        format, fmt"Sessions matching '{query}'")
    of "heart":
      return renderHits(t.store.recallHeart(query, fromTs, toTs, limit),
                        format, fmt"Heartbeat events matching '{query}'")
    of "knowledge":
      return "Error: scope=knowledge removed from memory — use the " &
             "`knowledge` tool instead. Try `knowledge lookup topic=…` " &
             "for fact-by-name reads or `knowledge top` for highest-rated. " &
             "Memory stays for episodic events ('did this happen?')."
    of "all":
      return renderHits(t.store.recallAll(t.senderNcId, t.trustLevel,
                                           query, fromTs, toTs, limit),
                        format, fmt"Cross-source recall matching '{query}'")
    else:
      return fmt"Error: unknown scope '{scope}' for recall"

  of "list":
    # Same as recall with empty query — kept for agent ergonomics.
    let limitRaw = if args.hasKey("limit") and args["limit"].kind == JInt:
                     args["limit"].getInt() else: 10
    let limit = clamp(limitRaw, 1, 100)
    case scope
    of "self":
      let entries = t.store.recallSelf(t.trustLevel, "", limit)
      if entries.len == 0: return "No accessible self-memory entries."
      var res = fmt"Self memory (trust {t.trustLevel}):" & "\n"
      for i, e in entries:
        var tag = $e.category & "/" & $e.visibility
        if e.storedAtTrust > 0 and e.storedAtTrust < 70:
          tag.add(fmt", from trust {e.storedAtTrust}")
        var preview = e.content
        if preview.len > 120: preview = preview[0 ..< 120] & "..."
        res.add(fmt"  {i + 1}. {e.key} [{tag}]" & "\n     " & preview & "\n")
      return res
    else:
      let entries = t.store.recallSender(t.senderNcId, "", limit)
      if entries.len == 0:
        return fmt"No conversation memory for {t.senderNcId}"
      var res = fmt"Conversation memory with {t.senderNcId}:" & "\n"
      for i, e in entries:
        var preview = e.content
        if preview.len > 120: preview = preview[0 ..< 120] & "..."
        res.add(fmt"  {i + 1}. {e.key} [{e.category}]" & "\n     " & preview & "\n")
      return res

  of "forget":
    if not args.hasKey("key") or args["key"].getStr() == "":
      return "Error: 'key' is required for forget"
    let key = args["key"].getStr()
    let ok = case scope
      of "self": t.store.forgetSelf(t.senderNcId, key, t.trustLevel)
      else:      t.store.forgetSender(t.senderNcId, t.senderNcId, key, t.trustLevel)
    if ok: return fmt"Forgot '{key}' in {scope} memory (tombstoned)"
    return fmt"No matching entry in {scope} memory (or insufficient trust): {key}"

  of "recent":
    if not args.hasKey("days") or args["days"].kind != JInt:
      return "Error: 'days' (integer) is required for recent"
    let days = clamp(args["days"].getInt(), 1, 365)
    let query = if args.hasKey("query"): args["query"].getStr() else: ""
    let limit = if args.hasKey("limit") and args["limit"].kind == JInt:
                  clamp(args["limit"].getInt(), 1, 100) else: 20
    let format = if args.hasKey("format"): args["format"].getStr("text") else: "text"
    let fromTs = epochTime() - float(days * 86400)
    # `recent` defaults to scope=all (the most useful "what was I
    # doing in the last N days" query). Explicit scope still honored.
    let recentScope = if args.hasKey("scope"): scope else: "all"
    let hits =
      case recentScope
      of "sessions":  t.store.recallSessions(query, fromTs, 0.0, limit)
      of "heart":     t.store.recallHeart(query, fromTs, 0.0, limit)
      of "knowledge": @[]  # removed — see `knowledge` tool
      of "self":      t.store.recallSelfHits(t.trustLevel, query, fromTs, 0.0, limit)
      of "sender":    t.store.recallSenderHits(t.senderNcId, query, fromTs, 0.0, limit)
      else:           t.store.recallAll(t.senderNcId, t.trustLevel,
                                         query, fromTs, 0.0, limit)
    return renderHits(hits, format,
                      fmt"Last {days} day(s) — scope={recentScope}, query='{query}'")

  of "verify":
    if not args.hasKey("claim") or args["claim"].getStr().strip() == "":
      return "Error: 'claim' is required for verify"
    let claim = args["claim"].getStr().strip()
    let limitPerKw = if args.hasKey("limit") and args["limit"].kind == JInt:
                       clamp(args["limit"].getInt(), 1, 20) else: 5
    let format = if args.hasKey("format"): args["format"].getStr("text") else: "text"
    let fromTs = if args.hasKey("from"): parseTimeArg(args["from"].getStr()) else: 0.0
    # Self-reference guard: cap toTs at `now() - VerifyLookbackBuffer`
    # so the verify call can't sweep up the inflight message that
    # contains the very keywords being verified. Without this, verify
    # always returns evidence_found whenever the claim shares keywords
    # with the user's own question. Buffer needs to cover the common
    # "user msg arrives → agent thinks → calls verify" delay (typically
    # 5-30s; we choose 60s to comfortably cover slower providers and
    # iteration chains). Real evidence almost never lands in the last
    # minute of a session anyway.
    const VerifyLookbackBuffer = 60.0   # seconds
    let userToTs = if args.hasKey("to"): parseTimeArg(args["to"].getStr()) else: 0.0
    let toTs =
      if userToTs > 0.0: userToTs
      else: epochTime() - VerifyLookbackBuffer

    let keywords = tokenizeClaim(claim)
    if keywords.len == 0:
      return "Error: claim has no usable keywords (after stripping " &
             "stopwords + tokens <3 chars). Be more specific — name " &
             "concrete entities, dates, actions."

    var seen = initTable[string, bool]()
    var combined: seq[MemoryHit] = @[]
    for kw in keywords:
      for hit in t.store.recallAll(t.senderNcId, t.trustLevel,
                                    kw, fromTs, toTs, limitPerKw):
        let key = hit.source & "|" & $hit.ts & "|" & hit.path
        if not seen.hasKey(key):
          seen[key] = true
          combined.add(hit)
    combined.sort(proc(a, b: MemoryHit): int =
      if a.ts > b.ts: -1 elif a.ts < b.ts: 1 else: 0)

    let verdict = if combined.len > 0: "evidence_found" else: "no_evidence_found"
    if format == "json":
      let evidence = newJArray()
      for hit in combined:
        evidence.add(%*{
          "source": hit.source,
          "ts": hit.ts,
          "excerpt": hit.excerpt,
          "path": hit.path
        })
      return $(%*{
        "claim": claim,
        "keywords": keywords,
        "verdict": verdict,
        "evidence": evidence
      })
    let kwJoined = keywords.join(", ")
    var res = "Verify: '" & claim & "'\n" &
              "  Keywords: " & kwJoined & "\n" &
              "  Verdict: " & verdict & " (" & $combined.len & " hits)\n"
    if combined.len == 0:
      res.add("\n  No supporting evidence found in any memory store. " &
              "Either the claim is false, or the events predate the " &
              "earliest log, or the keywords don't match the recorded " &
              "wording. Try `recall scope=all query='...'` with " &
              "alternative phrasing.\n")
      return res
    res.add("\n  Evidence (most recent first):\n")
    for i, hit in combined:
      let tsStr = if hit.ts > 0: $fromUnix(int64(hit.ts)) else: "?"
      let roleTag =
        if hit.role.len > 0: " role=" & hit.role
        else: ""
      res.add(fmt"  {i + 1}. [{hit.source}{roleTag}] {tsStr}" & "\n     " &
              hit.excerpt & "\n")
    res.add("\n  Read these citations and DECIDE — do they actually " &
            "support the claim? Provenance is preserved (source + role + " &
            "ts + path) so you can cite specifics.\n" &
            "  IMPORTANT — interpret by role: hits with role=user are " &
            "messages someone SENT YOU (not evidence YOU did anything); " &
            "role=assistant are YOUR OWN past statements. For 'I did X' " &
            "claims, weight assistant hits much more heavily than user " &
            "hits. The verify tool returns raw matches; the judgment is " &
            "yours.\n")
    return res

  else:
    return fmt"Error: unknown action '{action}'. Use: store | recall | list | forget | recent | verify"
