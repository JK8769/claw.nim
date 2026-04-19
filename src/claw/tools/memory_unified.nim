## memory — trust-gated store/recall tool.
##
## The tool carries mutable per-turn state (senderID + trustLevel) that
## the agent loop refreshes before each LLM iteration via
## `setRequesterContext`. All data-layer decisions happen here:
##
##   store  — visibility is clamped down to what the current requester is
##            allowed to create (see downgradeForTrust). A Guest cannot
##            save a secret, no matter what they prompt.
##   recall — results are filtered before return. Entries the requester
##            is not authorised to view never enter the tool's output,
##            so the LLM never sees them — compliance is not the gate.
##
## The agent itself (trust 100) can always store and recall anything.

import std/[json, os, tables, asyncdispatch, strformat, strutils]
import types
import ../agent/memory

type
  UnifiedMemoryTool* = ref object of Tool
    store*: MemoryStore
    senderID*: string       ## updated per turn by the agent loop
    trustLevel*: int        ## updated per turn by the agent loop

proc newUnifiedMemoryTool*(ms: MemoryStore): UnifiedMemoryTool =
  ## Starts at trust 100 + senderID "agent" so agent-initiated memory work
  ## before any user message is treated as the agent itself writing.
  UnifiedMemoryTool(store: ms, senderID: "agent", trustLevel: 100)

proc setRequesterContext*(t: UnifiedMemoryTool, senderID: string, trustLevel: int) =
  ## Called by the agent loop before each LLM turn so store/recall see the
  ## current conversation partner. No context → agent itself (trust 100).
  t.senderID = if senderID.len > 0: senderID else: "agent"
  t.trustLevel = trustLevel

method name*(t: UnifiedMemoryTool): string = "memory"

method description*(t: UnifiedMemoryTool): string =
  "Long-term memory — store, recall, list, or forget facts, preferences, and session notes.\n\n" &
  "Actions:\n" &
  "  store   — Save a fact (key + content; optional category, visibility)\n" &
  "  recall  — Search memories by query (optional limit)\n" &
  "  list    — List recent entries (optional limit)\n" &
  "  forget  — Delete a memory by key\n\n" &
  "Visibility (defaults to `private`):\n" &
  "  secret   — agent only (trust 100)\n" &
  "  private  — sender + high-trust (Boss/Master)\n" &
  "  shared   — anyone known (Customer+ / trust ≥ 40)\n" &
  "  public   — anyone, including Guests\n\n" &
  "The runtime clamps visibility downward if the current requester's trust is\n" &
  "insufficient to create the requested level. Do NOT use this tool for\n" &
  "time-based reminders — use `cron`."

method parameters*(t: UnifiedMemoryTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["store", "recall", "list", "forget"],
        "description": "Memory operation"
      },
      "key": {"type": "string", "description": "Memory key (store / forget)"},
      "content": {"type": "string", "description": "Value to store"},
      "query": {"type": "string", "description": "Search query (recall)"},
      "category": {
        "type": "string",
        "enum": ["core", "daily", "reflection", "preference"],
        "description": "Entry category (defaults to core)"
      },
      "visibility": {
        "type": "string",
        "enum": ["secret", "private", "shared", "public"],
        "description": "Who may later retrieve this. Clamped down by the current requester's trust level."
      },
      "limit": {
        "type": "integer",
        "description": "Max results for recall/list (default 5, max 100)"
      }
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

method execute*(t: UnifiedMemoryTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.store == nil:
    return "Error: memory store not configured."

  let action = if args.hasKey("action"): args["action"].getStr() else: ""

  case action
  of "store":
    if not args.hasKey("key") or args["key"].getStr() == "":
      return "Error: 'key' is required for store"
    if not args.hasKey("content") or args["content"].getStr() == "":
      return "Error: 'content' is required for store"
    let key = args["key"].getStr()
    let content = args["content"].getStr()
    let catStr = if args.hasKey("category"): args["category"].getStr() else: "core"
    let requested = if args.hasKey("visibility"):
                      parseVisibility(args["visibility"].getStr())
                    else: mvPrivate
    let actual = downgradeForTrust(requested, t.trustLevel)
    try:
      t.store.store(t.senderID, key, content, parseCategory(catStr),
                    actual, t.trustLevel)
      let note = if actual != requested:
        fmt" (visibility downgraded {requested} → {actual} for trust {t.trustLevel})"
      else: ""
      return fmt"Stored '{key}' as {actual}{note}"
    except Exception as e:
      return fmt"Failed to store '{key}': {e.msg}"

  of "recall":
    if not args.hasKey("query") or args["query"].getStr() == "":
      return "Error: 'query' is required for recall"
    let query = args["query"].getStr()
    let limitRaw = if args.hasKey("limit") and args["limit"].kind == JInt:
                     args["limit"].getInt() else: 5
    let limit = clamp(limitRaw, 1, 100)
    let entries = t.store.recall(t.senderID, t.trustLevel, query, limit)
    if entries.len == 0:
      return fmt"No accessible memories match: {query}"
    var res = fmt"Found {entries.len} memories (filtered by trust {t.trustLevel}):" & "\n"
    for i, e in entries:
      res.add(fmt"{i + 1}. [{e.key}] ({e.category}/{e.visibility}): {e.content}" & "\n")
    return res

  of "list":
    let limitRaw = if args.hasKey("limit") and args["limit"].kind == JInt:
                     args["limit"].getInt() else: 5
    let limit = clamp(limitRaw, 1, 100)
    let entries = t.store.recall(t.senderID, t.trustLevel, "", limit)
    if entries.len == 0:
      return "No accessible memory entries."
    var res = fmt"Memory entries (filtered by trust {t.trustLevel}):" & "\n"
    for i, e in entries:
      var preview = e.content
      if preview.len > 120: preview = preview[0 ..< 120] & "..."
      res.add(fmt"  {i + 1}. {e.key} [{e.category}/{e.visibility}]" & "\n")
      res.add(fmt"     {preview}" & "\n")
    return res

  of "forget":
    if not args.hasKey("key") or args["key"].getStr() == "":
      return "Error: 'key' is required for forget"
    let key = args["key"].getStr()
    # Tombstone rather than hard delete — the JSONL keeps the entry but
    # marks it deleted so future audits can answer "who forgot what, when".
    # Search across all sender files since the forget request may target
    # memory authored by someone else (if requester has sufficient trust).
    var anyFound = false
    if dirExists(t.store.sendersDir):
      for kind, path in walkDir(t.store.sendersDir):
        if kind != pcFile or not path.endsWith(".jsonl"): continue
        let senderID = path.lastPathPart()[0 ..< path.lastPathPart().len - ".jsonl".len]
        if t.store.forget(t.senderID, senderID, key, t.trustLevel):
          anyFound = true
    if anyFound:
      return fmt"Forgot '{key}' (tombstoned)"
    return fmt"No matching memory (or insufficient trust): {key}"

  else:
    return fmt"Error: unknown action '{action}'. Use: store | recall | list | forget"
