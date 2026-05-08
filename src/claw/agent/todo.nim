## Per-agent todo store — append-only JSONL queue of items the agent
## will process at her next heartbeat tick.
##
## Layout (lives in the agent's office):
##
##   <office>/
##     notes/
##       todo.jsonl          ← this module owns
##       notes.org           ← long-form content (sub-commit 5 territory)
##
## Schema: one JSON object per line.
##
##   {"id":"t-001","source":"mail","sourceID":"nc:5",
##    "summary":"Reply to Jerry's question about Plant 荣鑫",
##    "body":"<optional verbatim mail snippet>",
##    "priority":"normal","addedAt":1778312345.0,
##    "done":false,"doneAt":0.0}
##
## **Append-only with last-wins semantics**: marking an item done
## appends a NEW line with the same `id` and `done: true`. Readers
## walk the file, group by id, keep the latest. This avoids any
## file-mutation under concurrent writers — the system can append
## from the bus dispatcher (mail-arrival), peer agents can append
## via `delegate(deferred=true)`, and the agent can append via
## `defer_to_todo` or `mark_todo_done` tools, all without locks.
## POSIX guarantees atomic line-sized appends in O_APPEND mode.
##
## Sources are free-form strings (`mail`, `delegated`, `self_deferred`,
## `scheduled`, etc.) rather than a closed enum so future surfaces
## (notes-watcher converting due tags, peer-system events) can append
## without a schema bump.

import std/[os, json, times, strutils, tables, random]
import ../logger

type
  TodoEntry* = object
    id*: string
    source*: string         ## free-form: "mail", "delegated", "self_deferred", ...
    sourceID*: string       ## extra source context (e.g. partner nc:id)
    summary*: string        ## one-line description (shown in heartbeat prompt)
    body*: string           ## optional longer context
    priority*: string       ## "urgent" | "normal" | "low"; defaults to "normal"
    addedAt*: float64       ## epoch seconds, when this id was first appended
    done*: bool             ## tombstone: true means the item has been processed
    doneAt*: float64        ## epoch seconds when marked done; 0 if not done

  TodoStore* = ref object
    path*: string           ## <office>/notes/todo.jsonl

proc newTodoStore*(workspace: string): TodoStore =
  ## `workspace` is the agent's office dir.
  let notesDir = workspace / "notes"
  if not dirExists(notesDir): createDir(notesDir)
  TodoStore(path: notesDir / "todo.jsonl")

# ── Internals ───────────────────────────────────────────────────────

proc randomId(): string =
  ## Short, sortable-ish random id. Format: `t-<8 lowercase hex>`. The
  ## addedAt timestamp serves as the actual sortable key; this is just
  ## for uniqueness across same-second appends (rare but possible).
  randomize()
  result = "t-"
  for _ in 0 ..< 8:
    let n = rand(0..15)
    result.add(if n < 10: chr(ord('0') + n) else: chr(ord('a') + n - 10))

proc appendLine(path, line: string) =
  ## Atomic single-line append. Falls through silently on IO error
  ## (the dispatcher logs through its own channel).
  try:
    let f = open(path, fmAppend)
    f.writeLine(line)
    f.close()
  except CatchableError as e:
    warnCF("agent_todo", "Failed to append to todo.jsonl",
           {"path": path, "error": e.msg}.toTable)

# ── Public API ──────────────────────────────────────────────────────

proc append*(ts: TodoStore, source, sourceID, summary, body, priority: string):
             string =
  ## Append a new todo. Returns the new id. Caller (system, peer,
  ## agent self-defer tool) provides source + summary; body is
  ## optional, priority defaults to "normal".
  if ts == nil or summary.strip().len == 0: return ""
  let id = randomId()
  let entry = TodoEntry(
    id: id,
    source: source,
    sourceID: sourceID,
    summary: summary,
    body: body,
    priority: (if priority.len > 0: priority else: "normal"),
    addedAt: epochTime(),
    done: false,
    doneAt: 0.0,
  )
  appendLine(ts.path, $(%entry))
  return id

proc markDone*(ts: TodoStore, id: string): bool =
  ## Append a tombstone line for `id`. Idempotent: re-marking an
  ## already-done item just adds another tombstone (last-wins, no
  ## state corruption). Returns true iff a line was written.
  if ts == nil or id.len == 0: return false
  let entry = TodoEntry(
    id: id,
    done: true,
    doneAt: epochTime(),
  )
  appendLine(ts.path, $(%entry))
  return true

proc loadAll*(ts: TodoStore): seq[TodoEntry] =
  ## Walk the JSONL, group by id with last-wins semantics. Returns
  ## the resolved current state of every id ever seen. Done items
  ## are included; caller filters as needed.
  if ts == nil or not fileExists(ts.path): return
  var byId = initOrderedTable[string, TodoEntry]()
  try:
    for line in lines(ts.path):
      let trimmed = line.strip()
      if trimmed.len == 0: continue
      try:
        let parsed = parseJson(trimmed).to(TodoEntry)
        if parsed.id.len == 0: continue
        if byId.hasKey(parsed.id):
          # Last-wins: merge — later line's done flag overwrites,
          # but earlier line's summary/source/etc. preserved if the
          # later line is a tombstone (which only sets id+done+doneAt).
          var merged = byId[parsed.id]
          if parsed.done:
            merged.done = true
            merged.doneAt = parsed.doneAt
          else:
            merged = parsed   # full re-write (rare; only if same id reused)
          byId[parsed.id] = merged
        else:
          byId[parsed.id] = parsed
      except CatchableError: discard
  except IOError: discard
  for _, v in byId: result.add(v)

proc pending*(ts: TodoStore): seq[TodoEntry] =
  ## Undone items only, oldest-first (preserving append order — keeps
  ## priority sort downstream simple: items at the head are the ones
  ## that have been waiting longest).
  for entry in ts.loadAll():
    if not entry.done: result.add(entry)

# ── Rendering helper for heartbeat prompts ──────────────────────────

proc renderPendingForPrompt*(ts: TodoStore): string =
  ## Format pending items as a markdown block for inclusion in the
  ## heartbeat prompt. Returns empty string when nothing pending —
  ## caller treats that as "skip this section."
  let items = ts.pending()
  if items.len == 0: return ""
  var lines: seq[string] = @[]
  for it in items:
    var bits = @["[" & it.priority & "]"]
    if it.source.len > 0 and it.sourceID.len > 0:
      bits.add("from " & it.source & ":" & it.sourceID)
    elif it.source.len > 0:
      bits.add("from " & it.source)
    if it.id.len > 0:
      bits.add("id=" & it.id)
    let prefix = bits.join(" · ")
    lines.add("- " & prefix & "\n  " & it.summary)
    if it.body.len > 0:
      let preview = if it.body.len > 200: it.body[0 ..< 200] & "…"
                    else: it.body
      lines.add("    > " & preview.replace("\n", "\n    > "))
  return lines.join("\n")
