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

import std/[json, tables, asyncdispatch, strformat, strutils]
import types
import ../agent/memory

type
  UnifiedMemoryTool* = ref object of Tool
    store*: MemoryStore
    senderNcId*: string       ## refreshed per turn — nc:id of partner
    trustLevel*: int          ## refreshed per turn

proc newUnifiedMemoryTool*(ms: MemoryStore): UnifiedMemoryTool =
  ## Starts with trust=100 + senderNcId="agent" so agent-initiated work
  ## before any user turn is treated as the agent itself.
  UnifiedMemoryTool(store: ms, senderNcId: "agent", trustLevel: 100)

proc setRequesterContext*(t: UnifiedMemoryTool, senderNcId: string,
                          trustLevel: int) =
  ## Called by the agent loop each turn so store/recall scope to the
  ## current conversation partner.
  t.senderNcId = if senderNcId.len > 0: senderNcId else: "agent"
  t.trustLevel = trustLevel

method name*(t: UnifiedMemoryTool): string = "memory"

method description*(t: UnifiedMemoryTool): string =
  "Two-scope memory store.\n\n" &
  "Actions: store | recall | list | forget.\n" &
  "Scopes (pick via `scope=...`):\n" &
  "  sender — conversation memory for the person you're talking with now.\n" &
  "           Default. No visibility needed; isolated by file per nc:id.\n" &
  "  self   — your own memory (reflections, learned facts, company data).\n" &
  "           Entries take `visibility` (secret|private|shared|public);\n" &
  "           recall filters by the current requester's trust level.\n\n" &
  "When in doubt, use scope=sender for anything about/with the user,\n" &
  "and scope=self only when deliberately recording something for yourself.\n" &
  "Not for time-based reminders — use `cron` instead."

method parameters*(t: UnifiedMemoryTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["store", "recall", "list", "forget"]
      },
      "scope": {
        "type": "string",
        "enum": ["sender", "self"],
        "description": "sender (default) — current partner's file; self — agent's own memory"
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
      "limit": {"type": "integer"}
    },
    "required": %["action"]
  }.toTable

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
    let content = args["content"].getStr()
    let catStr = if args.hasKey("category"): args["category"].getStr() else: "core"
    case scope
    of "self":
      let requested = if args.hasKey("visibility"):
                        parseVisibility(args["visibility"].getStr())
                      else: mvPrivate
      let actual = downgradeForTrust(requested, t.trustLevel)
      try:
        t.store.storeSelf(t.senderNcId, key, content,
                          parseCategory(catStr), actual, t.trustLevel)
        let note = if actual != requested:
          fmt" (visibility clamped {requested} → {actual} for trust {t.trustLevel})"
        else: ""
        return fmt"Stored in self.jsonl as {actual}{note}"
      except Exception as e:
        return fmt"Failed to store '{key}' to self: {e.msg}"
    else:  # sender scope
      try:
        t.store.storeAboutSender(t.senderNcId, key, content,
                                  parseCategory(catStr), t.trustLevel)
        return fmt"Stored '{key}' in conversation memory for {t.senderNcId}"
      except Exception as e:
        return fmt"Failed to store '{key}' to sender file: {e.msg}"

  of "recall":
    let query = if args.hasKey("query"): args["query"].getStr() else: ""
    let limitRaw = if args.hasKey("limit") and args["limit"].kind == JInt:
                     args["limit"].getInt() else: 5
    let limit = clamp(limitRaw, 1, 100)
    case scope
    of "self":
      let entries = t.store.recallSelf(t.trustLevel, query, limit)
      if entries.len == 0: return "No accessible self-memory entries match."
      var res = fmt"Self memory (trust {t.trustLevel}):" & "\n"
      for i, e in entries:
        var tag = $e.category & "/" & $e.visibility
        if e.storedAtTrust > 0 and e.storedAtTrust < 70:
          tag.add(fmt", from trust {e.storedAtTrust}")
        res.add(fmt"  {i + 1}. [{e.key}] ({tag}): {e.content}" & "\n")
      return res
    else:
      let entries = t.store.recallSender(t.senderNcId, query, limit)
      if entries.len == 0:
        return fmt"No conversation memory found for {t.senderNcId}"
      var res = fmt"Conversation memory with {t.senderNcId}:" & "\n"
      for i, e in entries:
        res.add(fmt"  {i + 1}. [{e.key}] ({e.category}): {e.content}" & "\n")
      return res

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

  else:
    return fmt"Error: unknown action '{action}'. Use: store | recall | list | forget"
