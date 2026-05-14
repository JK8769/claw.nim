## knowledge — agent's cross-project semantic memory (the 'ship' in
## the memory/knowledge/skill trio).
##
## memory   = sea     (raw past — store, recall, forget)
## knowledge = ship   (timeless facts — consolidate, lookup, rank, top)
## skill    = navigator (procedural how-to — list, load, learn)
##
## Each fact lives at `<office>/knowledge/<topic>.md`. Optional YAML
## frontmatter at the top carries metadata (created, ranks, deprecated
## flag); entries below the frontmatter are append-only timestamped
## blocks. Files without frontmatter parse cleanly as defaults — no
## migration needed for existing wikis.
##
## Actions:
##
##   consolidate  — write a new fact / append to an existing topic
##   lookup       — read a topic's body + metadata + rank summary
##   list         — enumerate topics in this agent's wiki
##   rank         — express judgment on a fact (1-10 with reason). One
##                  per agent per topic (later ranks overwrite). Builds
##                  the wiki's quality signal — agents decide value.
##   top          — list topics sorted by average rank (highest first)
##
## Vocabulary discipline (vs memory):
##
##   "did this happen?"        →  memory recall
##   "is this true?"           →  knowledge lookup
##   "I noticed something"     →  memory store (one-off)
##                                knowledge consolidate (cross-project insight)
##
## Ranks are OPTIONAL — facts surface in lookups regardless. Ranking
## refines order when present, no friction when absent.

import std/[asyncdispatch, json, tables, strutils, times, os, algorithm]
import ./types
import ./spec
import ../logger
import ../agent/memory  # stripEntityIdentifiers

const ToolSpec* = spec(
  name = "knowledge",
  description = "cross-project semantic memory wiki — timeless facts. " &
                "actions: consolidate (write/append) | lookup (read) | " &
                "list (enumerate) | rank (1-10 judgment, agent-decided) | " &
                "top (sort by avg rank). For raw past events, use memory. " &
                "For procedural how-to, use skill.",
  tags = @["agent", "core", "knowledge", "wiki"],
  searchKeywords = @["knowledge", "wiki", "fact", "lookup", "consolidate",
                     "rank", "score", "promote insight", "topic",
                     "semantic memory"],
  domain = "agent",
  default = true,
  heartbeatSafe = true,
  category = "self-management",
)

type
  KnowledgeTool* = ref object of ContextualTool
    workspace*: string         ## agent's office dir
    agentLabel*: string        ## stable attribution for entries (set at
                                ## construction; ContextualTool.agentName
                                ## is set per-call and may be empty when
                                ## invoked outside a normal turn)

proc newKnowledgeTool*(workspace, agentName: string): KnowledgeTool =
  KnowledgeTool(workspace: workspace, agentLabel: agentName)

method name*(t: KnowledgeTool): string = "knowledge"

method description*(t: KnowledgeTool): string =
  "Cross-project semantic memory wiki. The 'ship' in the memory/" &
  "knowledge/skill trio — timeless facts that outlast any single " &
  "project.\n\n" &
  "Actions:\n" &
  "  consolidate  — write a new fact or append to an existing topic\n" &
  "                 (requires: topic, insight; optional: source)\n" &
  "  lookup       — read a topic's body + rank summary (requires: topic)\n" &
  "  list         — enumerate topics in this agent's wiki\n" &
  "  rank         — express judgment on a topic (requires: topic, score 1-10;\n" &
  "                 optional: reason). One vote per agent per topic.\n" &
  "  top          — list topics sorted by average rank (highest first)\n\n" &
  "Wiki lives at <office>/knowledge/<topic>.md. Ranks accumulate in " &
  "the file's YAML frontmatter; aggregate is shown when ≥ 2 agents " &
  "have voted (else the topic shows as 'unrated'). Vocabulary: use " &
  "this for 'is this true?' lookups; use memory for 'did this happen?'."

method parameters*(t: KnowledgeTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["consolidate", "lookup", "list", "rank", "top",
                 "update", "deprecate", "link"],
        "description": "Operation to perform"
      },
      "topic": {
        "type": "string",
        "description": "consolidate/lookup/rank — topic slug (kebab-case " &
                       "letters/digits/hyphens; no leading/trailing/double " &
                       "hyphens). Becomes <topic>.md."
      },
      "insight": {
        "type": "string",
        "description": "consolidate — the fact / observation, written so " &
                       "future-you can act without the original context. " &
                       "1-3 sentences. Don't include narrative ('I noticed…'); " &
                       "write the lesson directly."
      },
      "source": {
        "type": "string",
        "description": "consolidate (optional) — provenance. Project name, " &
                       "conversation reference, external citation. Helps " &
                       "future-you trust or revisit the claim."
      },
      "score": {
        "type": "integer",
        "minimum": 1,
        "maximum": 10,
        "description": "rank — your judgment on this fact's value (1=trivial, " &
                       "10=core). Agents decide value; aggregate is averaged " &
                       "across votes."
      },
      "reason": {
        "type": "string",
        "description": "rank (optional but recommended) — why this score? " &
                       "Reasoning makes rank actionable signal, not just a " &
                       "number. Example: 'core to Q3 strategy', 'outdated for new product'."
      },
      "limit": {
        "type": "integer",
        "minimum": 1,
        "description": "top (optional) — max topics to return. Default 10."
      },
      "to": {
        "type": "string",
        "description": "link — target topic slug. Combined with `topic` " &
                       "(the source), records: from `topic` → to `to`."
      }
    },
    "required": %["method"]
  }.toTable

# ── format / kebab validation ──────────────────────────────────────

proc isKebabSafe(s: string): bool =
  if s.len < 2: return false
  for ch in s:
    if not (ch in {'a'..'z', '0'..'9', '-'}): return false
  if s[0] == '-' or s[^1] == '-': return false
  if "--" in s: return false
  true

# ── frontmatter shape ──────────────────────────────────────────────

type
  Rank* = object
    by*: string         ## agent label (display)
    nc*: string         ## nc:id (machine-stable identity)
    score*: int         ## 1-10
    reason*: string     ## why
    at*: string         ## ISO timestamp

  Link* = object
    to*: string         ## target topic slug
    reason*: string     ## why these are linked
    by*: string         ## agent label that linked them

  TopicMeta* = object
    created*: string         ## ISO date when first consolidated
    ranks*: seq[Rank]        ## per-agent votes (one per nc:id; later replaces)
    links*: seq[Link]        ## cross-references to other topics
    deprecated*: bool        ## true when superseded / no longer accurate
    deprecated_at*: string   ## ISO date marked
    deprecated_by*: string   ## agent who marked it
    deprecated_reason*: string  ## why (link to replacement, or root cause)

# ── YAML-ish frontmatter parser (hand-rolled — only the shape we need) ──
# We don't pull in a full YAML lib for this; the format is intentionally
# narrow (--- delimited; "key: value" lines for scalars; "ranks:" list of
# inline-object-shaped lines). Existing wiki files without frontmatter
# parse cleanly as TopicMeta() defaults.

proc readFile2(path: string): string =
  try: readFile(path) except CatchableError: ""

proc parseFrontmatter(raw: string): tuple[meta: TopicMeta, body: string] =
  ## Returns (meta, body). If no frontmatter present, meta is default
  ## and body is the entire raw text — files written without frontmatter
  ## parse cleanly.
  result = (meta: TopicMeta(), body: raw)
  if not raw.startsWith("---\n"): return
  let endIdx = raw.find("\n---\n", 4)
  if endIdx < 0: return
  let header = raw[4 ..< endIdx]
  let body = raw[endIdx + 5 ..< raw.len]
  result.meta = TopicMeta()
  type Section = enum secNone, secRanks, secLinks
  var section = secNone
  proc parseInline(t: string): seq[(string, string)] =
    ## "{key: \"v\", k2: 5, ...}" → seq of (key, value). Splits on
    ## commas at the top level only — commas inside "..." quoted
    ## values are preserved (so a rank reason like 'core, pivotal'
    ## round-trips correctly).
    let inner = t.find('{')
    let close = t.rfind('}')
    if inner < 0 or close <= inner: return
    let kv = t[inner + 1 ..< close]
    var pairs: seq[string]
    var cur = ""
    var inQ = false
    var prev = '\0'
    for ch in kv:
      if ch == '"' and prev != '\\':
        inQ = not inQ
        cur.add(ch)
      elif ch == ',' and not inQ:
        pairs.add(cur); cur = ""
      else:
        cur.add(ch)
      prev = ch
    if cur.len > 0: pairs.add(cur)
    for pair in pairs:
      let p = pair.strip()
      let colon = p.find(':')
      if colon <= 0: continue
      let k = p[0 ..< colon].strip()
      var v = p[colon + 1 .. ^1].strip()
      if v.startsWith("\"") and v.endsWith("\"") and v.len >= 2:
        v = v[1 ..< v.len - 1]
        v = v.replace("\\\"", "\"").replace("\\\\", "\\")
      result.add((k, v))
  for line in header.splitLines:
    let t = line.strip()
    if t.startsWith("created:"):
      result.meta.created = t["created:".len .. ^1].strip()
      section = secNone
    elif t.startsWith("deprecated:"):
      let v = t["deprecated:".len .. ^1].strip().toLowerAscii()
      result.meta.deprecated = v in ["true", "yes", "1"]
      section = secNone
    elif t.startsWith("deprecated_at:"):
      result.meta.deprecated_at = t["deprecated_at:".len .. ^1].strip()
      section = secNone
    elif t.startsWith("deprecated_by:"):
      result.meta.deprecated_by = t["deprecated_by:".len .. ^1].strip()
      section = secNone
    elif t.startsWith("deprecated_reason:"):
      result.meta.deprecated_reason = t["deprecated_reason:".len .. ^1].strip()
      section = secNone
    elif t == "ranks:":
      section = secRanks
    elif t == "links:":
      section = secLinks
    elif t.startsWith("- {"):
      let pairs = parseInline(t)
      case section
      of secRanks:
        var r = Rank()
        for (k, v) in pairs:
          case k
          of "by":     r.by = v
          of "nc":     r.nc = v
          of "score":
            try: r.score = parseInt(v) except CatchableError: discard
          of "reason": r.reason = v
          of "at":     r.at = v
          else: discard
        if r.nc.len > 0 or r.by.len > 0:
          result.meta.ranks.add(r)
      of secLinks:
        var lk = Link()
        for (k, v) in pairs:
          case k
          of "to":     lk.to = v
          of "reason": lk.reason = v
          of "by":     lk.by = v
          else: discard
        if lk.to.len > 0:
          result.meta.links.add(lk)
      else: discard
    elif not t.startsWith("- "):
      section = secNone
  result.body = body

proc escapeYamlValue(v: string): string =
  ## Minimal — replace double-quote with escaped, no further sanitization.
  ## The reason field can contain free text; we only need to keep the
  ## one-line shape valid.
  result = v.replace("\"", "\\\"")
  # Strip newlines from the reason field — frontmatter is one line per pair.
  result = result.replace("\n", " ").replace("\r", "")

proc serializeFrontmatter(m: TopicMeta): string =
  result = "---\n"
  if m.created.len > 0:
    result.add("created: " & m.created & "\n")
  if m.deprecated:
    result.add("deprecated: true\n")
    if m.deprecated_at.len > 0:
      result.add("deprecated_at: " & m.deprecated_at & "\n")
    if m.deprecated_by.len > 0:
      result.add("deprecated_by: " & m.deprecated_by & "\n")
    if m.deprecated_reason.len > 0:
      result.add("deprecated_reason: " & m.deprecated_reason & "\n")
  if m.ranks.len > 0:
    result.add("ranks:\n")
    for r in m.ranks:
      result.add("  - {by: \"" & escapeYamlValue(r.by) &
                 "\", nc: \"" & escapeYamlValue(r.nc) &
                 "\", score: " & $r.score &
                 ", reason: \"" & escapeYamlValue(r.reason) &
                 "\", at: \"" & escapeYamlValue(r.at) & "\"}\n")
  if m.links.len > 0:
    result.add("links:\n")
    for lk in m.links:
      result.add("  - {to: \"" & escapeYamlValue(lk.to) &
                 "\", reason: \"" & escapeYamlValue(lk.reason) &
                 "\", by: \"" & escapeYamlValue(lk.by) & "\"}\n")
  result.add("---\n\n")

proc rankSummary(meta: TopicMeta): tuple[avg: float, count: int, displayed: bool] =
  if meta.ranks.len == 0: return (0.0, 0, false)
  var sum = 0
  for r in meta.ranks: sum += r.score
  let avg = sum.float / meta.ranks.len.float
  # Display threshold: ≥ 2 votes. Single-rated topics are flagged but
  # don't drive sort order — operators see "rated by 1 agent" hint.
  (avg, meta.ranks.len, meta.ranks.len >= 2)

# ── filesystem prep ─────────────────────────────────────────────────

proc ensureKnowledgeDir(workspace: string): string =
  let dir = workspace / "knowledge"
  if not dirExists(dir):
    try: createDir(dir)
    except CatchableError as e:
      warnCF("knowledge", "Failed to create knowledge/",
             {"path": dir, "error": e.msg}.toTable)
  dir

# ── action handlers ─────────────────────────────────────────────────

proc doConsolidate(t: KnowledgeTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("topic"): return "Error: 'topic' is required"
  if not args.hasKey("insight"): return "Error: 'insight' is required"
  if t.workspace.len == 0:
    return "Error: tool not bound to an office workspace"
  let topic = args["topic"].getStr().strip()
  let insight = stripEntityIdentifiers(args["insight"].getStr().strip())
  if topic.len == 0: return "Error: 'topic' must not be empty"
  if insight.len < 10: return "Error: 'insight' must be at least 10 chars"
  if not isKebabSafe(topic):
    return "Error: 'topic' must be kebab-case (lowercase letters, digits, " &
           "hyphens; no leading/trailing/double hyphens). Got: '" & topic & "'"
  let source = if args.hasKey("source"): args["source"].getStr().strip() else: ""
  let dir = ensureKnowledgeDir(t.workspace)
  let path = dir / topic & ".md"
  let isNew = not fileExists(path)

  let now = now().format("yyyy-MM-dd HH:mm")
  let agentLabel = if t.agentLabel.len > 0: t.agentLabel else: "agent"

  if isNew:
    # New topic — write frontmatter (with `created`) + heading + entry.
    var meta = TopicMeta(created: now)
    var content = serializeFrontmatter(meta)
    content.add("# " & topic & "\n\n")
    content.add("## " & now & " (added by " & agentLabel & ")\n\n")
    content.add(insight & "\n")
    if source.len > 0: content.add("\n**Source**: " & source & "\n")
    content.add("\n")
    try: writeFile(path, content)
    except CatchableError as e:
      return "Error: failed to write knowledge entry: " & e.msg
    return "Created new knowledge entry at `knowledge/" & topic &
           ".md`. Lookup later via `knowledge lookup topic=" & topic & "`."

  # Existing topic — preserve frontmatter (if any) and append a new
  # entry to the body.
  let raw = readFile2(path)
  let (meta, body) = parseFrontmatter(raw)
  var newBody = body
  if not newBody.endsWith("\n"): newBody.add("\n")
  newBody.add("## " & now & " (added by " & agentLabel & ")\n\n")
  newBody.add(insight & "\n")
  if source.len > 0: newBody.add("\n**Source**: " & source & "\n")
  newBody.add("\n")
  let composed =
    if meta.created.len > 0 or meta.ranks.len > 0:
      serializeFrontmatter(meta) & newBody
    else:
      # Legacy file (no frontmatter); add one now so future ranks have
      # a place to land.
      var lifted = TopicMeta(created: now)  # don't know real created date; stamp now
      serializeFrontmatter(lifted) & newBody
  try: writeFile(path, composed)
  except CatchableError as e:
    return "Error: failed to write knowledge entry: " & e.msg
  return "Appended to existing knowledge at `knowledge/" & topic &
         ".md`. Lookup later via `knowledge lookup topic=" & topic & "`."

proc doLookup(t: KnowledgeTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("topic"): return "Error: 'topic' is required"
  if t.workspace.len == 0: return "Error: tool not bound to an office workspace"
  let topic = args["topic"].getStr().strip()
  let path = t.workspace / "knowledge" / topic & ".md"
  if not fileExists(path):
    return "Error: no knowledge entry for topic '" & topic & "'. " &
           "Use `knowledge list` to see what's there, or `knowledge " &
           "consolidate` to write a new fact."
  let raw = readFile2(path)
  let (meta, body) = parseFrontmatter(raw)
  let summary = rankSummary(meta)
  var header = "# " & topic & "\n"
  if meta.deprecated:
    header.add("⚠️  DEPRECATED on " & meta.deprecated_at & " by " &
               meta.deprecated_by & ". Reason: " & meta.deprecated_reason &
               "\n   (Content preserved below for provenance.)\n")
  if meta.created.len > 0: header.add("Created: " & meta.created & "\n")
  if summary.displayed:
    header.add("Rank: " & formatFloat(summary.avg, ffDecimal, 1) &
               "/10 (avg of " & $summary.count & " ratings)\n")
  elif summary.count == 1:
    let r = meta.ranks[0]
    header.add("Rank: " & $r.score & "/10 (rated by 1 agent: " &
               r.by & "; needs more votes to display aggregate)\n")
  else:
    header.add("Rank: unrated (use `knowledge rank topic=" & topic &
               " score=N` to add your judgment)\n")
  if meta.links.len > 0:
    header.add("Related: ")
    var refs: seq[string]
    for lk in meta.links:
      refs.add(lk.to & (if lk.reason.len > 0: " (" & lk.reason & ")" else: ""))
    header.add(refs.join(", ") & "\n")
  header.add("\n")
  return header & body.strip()

proc doList(t: KnowledgeTool): string =
  if t.workspace.len == 0: return "Error: tool not bound to an office workspace"
  let dir = t.workspace / "knowledge"
  if not dirExists(dir):
    return "(no knowledge wiki yet — use `knowledge consolidate topic=… insight=…` to write the first fact)"
  var rows: seq[string]
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let name = path.extractFilename
    if not name.endsWith(".md"): continue
    let topic = name[0 ..< name.len - 3]
    if topic.startsWith("."): continue  # .gitignore etc
    let raw = readFile2(path)
    let (meta, _) = parseFrontmatter(raw)
    let summary = rankSummary(meta)
    let rankCol = if summary.displayed:
                    formatFloat(summary.avg, ffDecimal, 1) & "/10 (" & $summary.count & ")"
                  elif summary.count == 1: "rated 1x"
                  else: "unrated"
    rows.add("  " & topic & "  —  " & rankCol)
  if rows.len == 0:
    return "(no knowledge entries — use `knowledge consolidate` to add the first)"
  rows.sort()
  return "Knowledge topics:\n" & rows.join("\n")

proc doRank(t: KnowledgeTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("topic"): return "Error: 'topic' is required"
  if not args.hasKey("score"): return "Error: 'score' is required (1-10)"
  if t.workspace.len == 0: return "Error: tool not bound to an office workspace"
  let topic = args["topic"].getStr().strip()
  let score = args["score"].getInt()
  if score < 1 or score > 10:
    return "Error: 'score' must be 1-10. Got: " & $score
  let reason = if args.hasKey("reason"): args["reason"].getStr().strip() else: ""
  let path = t.workspace / "knowledge" / topic & ".md"
  if not fileExists(path):
    return "Error: no knowledge entry for topic '" & topic &
           "'. Consolidate it first."

  let agentLabel = if t.agentLabel.len > 0: t.agentLabel else: "agent"
  let nc = if t.logicalUserID.len > 0: t.logicalUserID else: "anonymous"
  let now = now().format("yyyy-MM-dd HH:mm")

  let raw = readFile2(path)
  var (meta, body) = parseFrontmatter(raw)
  if meta.created.len == 0: meta.created = now  # back-fill for legacy files

  # One vote per agent (by nc:id) — replace any prior vote from this agent.
  var found = false
  for i, r in meta.ranks:
    if r.nc == nc:
      meta.ranks[i] = Rank(by: agentLabel, nc: nc, score: score,
                            reason: reason, at: now)
      found = true; break
  if not found:
    meta.ranks.add(Rank(by: agentLabel, nc: nc, score: score,
                        reason: reason, at: now))

  let composed = serializeFrontmatter(meta) & body
  try: writeFile(path, composed)
  except CatchableError as e:
    return "Error: failed to write rank: " & e.msg

  let summary = rankSummary(meta)
  let aggLine = if summary.displayed:
                  "; new aggregate: " & formatFloat(summary.avg, ffDecimal, 1) &
                  "/10 across " & $summary.count & " votes"
                elif summary.count == 1:
                  "; aggregate displayed once ≥ 2 agents have voted"
                else: ""
  let action = if found: "Updated your rank" else: "Added your rank"
  return action & " on `" & topic & "`: " & $score & "/10" &
         (if reason.len > 0: " (" & reason & ")" else: "") & aggLine & "."

proc doTop(t: KnowledgeTool, args: Table[string, JsonNode]): string =
  if t.workspace.len == 0: return "Error: tool not bound to an office workspace"
  let limit = if args.hasKey("limit"): args["limit"].getInt(10) else: 10
  let dir = t.workspace / "knowledge"
  if not dirExists(dir): return "(no knowledge wiki yet)"
  type Row = object
    topic: string
    avg: float
    count: int
  var rated: seq[Row]
  var partial: seq[string]   # rated only by 1 (don't sort, mention separately)
  var unrated: seq[string]
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let name = path.extractFilename
    if not name.endsWith(".md"): continue
    let topic = name[0 ..< name.len - 3]
    if topic.startsWith("."): continue
    let raw = readFile2(path)
    let (meta, _) = parseFrontmatter(raw)
    let summary = rankSummary(meta)
    if summary.displayed:
      rated.add(Row(topic: topic, avg: summary.avg, count: summary.count))
    elif summary.count == 1:
      partial.add(topic)
    else:
      unrated.add(topic)
  rated.sort(proc(a, b: Row): int =
    if b.avg < a.avg: -1
    elif b.avg > a.avg: 1
    else: cmp(a.topic, b.topic))
  if rated.len > limit: rated.setLen(limit)

  if rated.len == 0 and partial.len == 0 and unrated.len == 0:
    return "(no knowledge entries to rank — use `knowledge consolidate` first)"

  var lines: seq[string]
  if rated.len > 0:
    lines.add("Top " & $rated.len & " by aggregate rank:")
    for r in rated:
      lines.add("  " & formatFloat(r.avg, ffDecimal, 1) & "/10 (" &
                $r.count & ")  —  " & r.topic)
  if partial.len > 0:
    lines.add("")
    lines.add("Rated by 1 agent only (need ≥2 to display aggregate): " &
              partial.join(", "))
  if unrated.len > 0:
    lines.add("")
    lines.add("Unrated (" & $unrated.len & "): " & unrated.join(", "))
  lines.join("\n")

# ── update: append a refinement entry tagged as UPDATE ──────────────

proc doUpdate(t: KnowledgeTool, args: Table[string, JsonNode]): string =
  ## Like consolidate but explicitly marks the new entry as a refinement
  ## of prior content (preserves the prior in the file's append-only
  ## history; lookup readers see the most-recent UPDATE entry first).
  ## Used when a fact gets sharper / more accurate / more nuanced and
  ## you want the wiki to reflect that without erasing what came before.
  if not args.hasKey("topic"): return "Error: 'topic' is required"
  if not args.hasKey("insight"): return "Error: 'insight' is required"
  if t.workspace.len == 0: return "Error: tool not bound to an office workspace"
  let topic = args["topic"].getStr().strip()
  let insight = stripEntityIdentifiers(args["insight"].getStr().strip())
  if insight.len < 10: return "Error: 'insight' must be at least 10 chars"
  if not isKebabSafe(topic):
    return "Error: 'topic' must be kebab-case. Got: '" & topic & "'"
  let path = t.workspace / "knowledge" / topic & ".md"
  if not fileExists(path):
    return "Error: no knowledge entry for '" & topic &
           "'. Use `consolidate` to create it first."
  let source = if args.hasKey("source"): args["source"].getStr().strip() else: ""
  let raw = readFile2(path)
  var (meta, body) = parseFrontmatter(raw)
  let now = now().format("yyyy-MM-dd HH:mm")
  let agentLabel = if t.agentLabel.len > 0: t.agentLabel else: "agent"
  if not body.endsWith("\n"): body.add("\n")
  body.add("## " & now & " (UPDATE by " & agentLabel & ")\n\n")
  body.add(insight & "\n")
  if source.len > 0: body.add("\n**Source**: " & source & "\n")
  body.add("\n")
  let composed = serializeFrontmatter(meta) & body
  try: writeFile(path, composed)
  except CatchableError as e:
    return "Error: failed to write update: " & e.msg
  return "Refinement appended to `knowledge/" & topic & ".md` (tagged " &
         "UPDATE; prior entries preserved). Lookup shows the most recent " &
         "context first."

# ── deprecate: mark stale via frontmatter flag ──────────────────────

proc doDeprecate(t: KnowledgeTool, args: Table[string, JsonNode]): string =
  ## Mark a fact stale without erasing it. Lookups display a deprecation
  ## banner; lists annotate the topic. Provenance preserved (when, who,
  ## why) in the frontmatter. Use when a fact turns out wrong, gets
  ## superseded by a newer fact, or applies only to a now-obsolete
  ## context.
  if not args.hasKey("topic"): return "Error: 'topic' is required"
  if t.workspace.len == 0: return "Error: tool not bound to an office workspace"
  let topic = args["topic"].getStr().strip()
  let path = t.workspace / "knowledge" / topic & ".md"
  if not fileExists(path):
    return "Error: no knowledge entry for '" & topic & "'."
  let reason = if args.hasKey("reason"): args["reason"].getStr().strip() else: ""
  if reason.len == 0:
    return "Error: 'reason' is required for deprecate (why is this stale? " &
           "What replaces it? — preserves provenance)."
  let raw = readFile2(path)
  var (meta, body) = parseFrontmatter(raw)
  let now = now().format("yyyy-MM-dd HH:mm")
  let agentLabel = if t.agentLabel.len > 0: t.agentLabel else: "agent"
  meta.deprecated = true
  meta.deprecated_at = now
  meta.deprecated_by = agentLabel
  meta.deprecated_reason = reason
  let composed = serializeFrontmatter(meta) & body
  try: writeFile(path, composed)
  except CatchableError as e:
    return "Error: failed to mark deprecated: " & e.msg
  return "Marked `" & topic & "` deprecated. Reason: " & reason &
         ". (Content preserved; lookups will show the deprecation banner.)"

# ── link: cross-reference two topics ────────────────────────────────

proc doLink(t: KnowledgeTool, args: Table[string, JsonNode]): string =
  ## Record a directed cross-reference from `topic` to `to`. Builds the
  ## citation graph (one per future PageRank-style scoring; for now,
  ## displayed in lookup as 'Related topics'). Reason explains the
  ## connection — operators reading the link can decide if it still
  ## holds when content changes.
  if not args.hasKey("topic"): return "Error: 'topic' is required (the source)"
  if not args.hasKey("to"): return "Error: 'to' is required (the target topic)"
  if t.workspace.len == 0: return "Error: tool not bound to an office workspace"
  let topic = args["topic"].getStr().strip()
  let target = args["to"].getStr().strip()
  if topic == target:
    return "Error: cannot link a topic to itself."
  if not isKebabSafe(topic) or not isKebabSafe(target):
    return "Error: both topics must be kebab-case slugs."
  let path = t.workspace / "knowledge" / topic & ".md"
  if not fileExists(path):
    return "Error: source topic '" & topic & "' doesn't exist."
  let targetPath = t.workspace / "knowledge" / target & ".md"
  if not fileExists(targetPath):
    return "Error: target topic '" & target & "' doesn't exist. Consolidate it first."
  let reason = if args.hasKey("reason"): args["reason"].getStr().strip() else: ""
  let raw = readFile2(path)
  var (meta, body) = parseFrontmatter(raw)
  let agentLabel = if t.agentLabel.len > 0: t.agentLabel else: "agent"
  # Idempotent: if same (topic→target) link exists, replace it; else add.
  var found = false
  for i, lk in meta.links:
    if lk.to == target:
      meta.links[i] = Link(to: target, reason: reason, by: agentLabel)
      found = true; break
  if not found:
    meta.links.add(Link(to: target, reason: reason, by: agentLabel))
  let composed = serializeFrontmatter(meta) & body
  try: writeFile(path, composed)
  except CatchableError as e:
    return "Error: failed to record link: " & e.msg
  let action = if found: "Updated" else: "Recorded"
  return action & " link: `" & topic & "` → `" & target & "`" &
         (if reason.len > 0: " (" & reason & ")" else: "") & "."

# ── dispatch ────────────────────────────────────────────────────────

method execute*(t: KnowledgeTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("method"):
    return "Error: 'method' is required (consolidate | lookup | list | " &
           "rank | top | update | deprecate | link)"
  let action = getMethodArg(args).toLowerAscii()
  case action
  of "consolidate": return doConsolidate(t, args)
  of "lookup":      return doLookup(t, args)
  of "list":        return doList(t)
  of "rank":        return doRank(t, args)
  of "top":         return doTop(t, args)
  of "update":      return doUpdate(t, args)
  of "deprecate":   return doDeprecate(t, args)
  of "link":        return doLink(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: consolidate | lookup | list | rank | top | " &
           "update | deprecate | link"
