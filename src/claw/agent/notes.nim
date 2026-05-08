## Per-agent notes.org — org-mode-in-markdown for the agent's
## curated future-state (scheduled TODOs, drafts, plans, backlog).
##
## Layout:
##
##   <office>/notes/notes.org
##
## Format: a small subset of org-mode syntax, embedded in markdown.
## Recognised patterns:
##
##   * TODO <summary> <date> [recurrence]
##   * DONE <summary> <date>
##   ** TODO <summary> <date>
##
## - Headlines start with one or more `*` followed by a space.
## - State markers `TODO` and `DONE` are uppercase tokens immediately
##   after the leading `*`s.
## - `<date>` tags are inline patterns like:
##     <2026-08-01>           (date only)
##     <2026-08-01 09:00>     (date + time, local zone)
##     <2026-08-01 09:00 ++1d>   (recurring, daily)
##     <2026-08-01 09:00 ++1w>   (weekly)
##     <2026-08-01 09:00 ++3mo>  (every 3 months)
## - Content between headlines is free-form prose; the parser ignores
##   it. The agent uses long-form content as her own draft / research
##   space; only TODO/DONE headlines drive scheduling.
##
## **Writers**: the agent (via `add_note_todo` / `mark_note_done`
## tools) and the operator (direct filesystem edit). The system
## never writes here — system-appended batch items go to todo.jsonl.
##
## **Readers**: the heartbeat dispatcher (extracts past-due items
## for the next-heartbeat prompt) and the notes-watcher service
## (registers exact-time-future items as scheduler entries).

import std/[os, times, strutils, options, tables]
import ../logger

type
  NoteState* = enum
    nsTodo = "TODO"
    nsDone = "DONE"

  NoteRecurrence* = object
    ## Empty when the entry is one-off. When set, fired notes are
    ## rescheduled by adding `intervalSec` to their `due` time.
    intervalSec*: int      ## seconds; 0 = no recurrence

  NoteEntry* = object
    headlineLevel*: int    ## number of leading `*` (1, 2, ...)
    state*: NoteState
    summary*: string       ## first line after state token, with date stripped
    rawLine*: string       ## the original headline line (for edit-in-place ops)
    lineNum*: int          ## 0-indexed line in notes.org
    due*: Option[DateTime] ## from <date> tag, if any
    recur*: NoteRecurrence

  NotesStore* = ref object
    path*: string          ## <office>/notes/notes.org

proc newNotesStore*(workspace: string): NotesStore =
  ## `workspace` is the agent's office dir.
  let notesDir = workspace / "notes"
  if not dirExists(notesDir): createDir(notesDir)
  NotesStore(path: notesDir / "notes.org")

# ── Parsing ─────────────────────────────────────────────────────────

# Headline: leading * one or more, space, optional state, summary.
# We don't use re for this — simple string ops.

proc parseRecurrence(s: string): NoteRecurrence =
  ## Parse `++Nu` where u is `d` (days), `w` (weeks), `mo` (months).
  ## Returns intervalSec=0 if not a valid recurrence pattern.
  if not s.startsWith("++"): return
  let rest = s[2..^1]
  if rest.len < 2: return
  # Find unit suffix
  var n = ""
  var unit = ""
  for ch in rest:
    if ch in {'0'..'9'}: n.add(ch)
    else: unit.add(ch)
  if n.len == 0: return
  let count = try: parseInt(n) except ValueError: 0
  if count <= 0: return
  let mul = case unit
    of "d":  86400
    of "w":  604800
    of "mo": 2592000   # 30 days approximation
    of "y":  31536000  # 365 days
    else:    0
  if mul <= 0: return
  result.intervalSec = count * mul

proc extractDateTag(line: string): tuple[due: Option[DateTime],
                                          recur: NoteRecurrence,
                                          stripped: string] =
  ## Find a `<date ...>` tag in the line; if present, return parsed
  ## DateTime + recurrence + the line with the tag removed (so the
  ## caller can use the remainder as the headline summary).
  ## Manual scan rather than regex — simple lexical pattern, avoids
  ## the std/re Nim-2.x API friction. Looks for the first `<...>`
  ## span whose inner content starts with `YYYY-MM-DD`.
  let openIdx = line.find('<')
  if openIdx < 0:
    return (none(DateTime), NoteRecurrence(), line)
  let closeIdx = line.find('>', start = openIdx + 1)
  if closeIdx < 0:
    return (none(DateTime), NoteRecurrence(), line)
  let inner = line[openIdx + 1 ..< closeIdx]
  # First token must look like YYYY-MM-DD (10 chars, dashes at 4,7)
  if inner.len < 10 or inner[4] != '-' or inner[7] != '-':
    return (none(DateTime), NoteRecurrence(), line)
  var parts: seq[string] = @[]
  for p in inner.split(' '):
    if p.len > 0: parts.add(p)
  if parts.len == 0:
    return (none(DateTime), NoteRecurrence(), line)
  var dt: DateTime
  try:
    if parts.len >= 2 and parts[1].len == 5 and parts[1][2] == ':':
      dt = parse(parts[0] & " " & parts[1], "yyyy-MM-dd HH:mm", local())
    else:
      dt = parse(parts[0], "yyyy-MM-dd", local())
  except CatchableError:
    return (none(DateTime), NoteRecurrence(), line)
  var rec = NoteRecurrence()
  for p in parts:
    if p.startsWith("++"):
      rec = parseRecurrence(p)
      break
  let stripped = (line[0 ..< openIdx] & line[closeIdx + 1 ..^ 1]).strip()
  result = (some(dt), rec, stripped)

proc parseHeadline(line: string, lineNum: int): Option[NoteEntry] =
  ## Parse one line as an org-mode headline if it matches the shape.
  ## Returns none for non-headline lines (regular content, blanks).
  let trimmed = line.strip(trailing = true, leading = false)
  if trimmed.len == 0 or trimmed[0] != '*': return
  var i = 0
  while i < trimmed.len and trimmed[i] == '*': i.inc
  if i == 0 or i >= trimmed.len: return
  if trimmed[i] != ' ': return
  let level = i
  let rest = trimmed[i+1 ..^ 1].strip(leading = true, trailing = false)
  # Detect state token (TODO or DONE)
  var state: NoteState
  var afterState: string
  if rest.startsWith("TODO ") or rest == "TODO":
    state = nsTodo
    afterState = if rest == "TODO": "" else: rest[5 ..^ 1]
  elif rest.startsWith("DONE ") or rest == "DONE":
    state = nsDone
    afterState = if rest == "DONE": "" else: rest[5 ..^ 1]
  else:
    return    # not a state-tagged headline; ignore
  let (due, recur, summary) = extractDateTag(afterState)
  result = some(NoteEntry(
    headlineLevel: level,
    state: state,
    summary: summary,
    rawLine: line,
    lineNum: lineNum,
    due: due,
    recur: recur,
  ))

proc loadAll*(ns: NotesStore): seq[NoteEntry] =
  ## Walk notes.org once, return every parsed headline (TODO/DONE).
  ## Returns empty seq when file doesn't exist.
  if ns == nil or not fileExists(ns.path): return
  try:
    var i = 0
    for line in lines(ns.path):
      let parsed = parseHeadline(line, i)
      if parsed.isSome: result.add(parsed.get())
      i.inc
  except IOError: discard

proc pendingTodos*(ns: NotesStore): seq[NoteEntry] =
  ## TODO entries (regardless of due time). Caller filters by due
  ## time as needed (past-due for heartbeat surface, future for the
  ## notes-watcher).
  for e in ns.loadAll():
    if e.state == nsTodo: result.add(e)

proc pastDueTodos*(ns: NotesStore, asOf: DateTime): seq[NoteEntry] =
  ## TODOs whose `due` is <= asOf (date passed). Untimed TODOs (no
  ## `<date>` tag) are NOT past-due — those are agent's untimed
  ## backlog, not heartbeat-actionable.
  for e in ns.pendingTodos():
    if e.due.isSome and e.due.get() <= asOf:
      result.add(e)

proc futureTimedTodos*(ns: NotesStore, asOf: DateTime): seq[NoteEntry] =
  ## TODOs whose `due` is > asOf — for the notes-watcher to register
  ## as scheduler entries.
  for e in ns.pendingTodos():
    if e.due.isSome and e.due.get() > asOf:
      result.add(e)

# ── Mutation (append-only at end-of-file; in-place edits via rewrite) ──

proc appendHeadline*(ns: NotesStore, headline: string, body: string = ""):
                     bool =
  ## Append a new TODO/DONE headline to the file. Used by
  ## `add_note_todo` tool. Caller is responsible for the org-mode
  ## syntax of `headline` (e.g. "* TODO Quarterly review <2026-08-01 09:00>").
  if ns == nil or headline.len == 0: return false
  try:
    let f = open(ns.path, fmAppend)
    f.writeLine(headline)
    if body.len > 0:
      f.writeLine(body.strip(leading = false))
    f.close()
    return true
  except CatchableError as e:
    warnCF("agent_notes", "Failed to append to notes.org",
           {"path": ns.path, "error": e.msg}.toTable)
    return false

proc rewriteFlippingState*(ns: NotesStore, lineNum: int,
                            from_state, to_state: NoteState): bool =
  ## Read the whole file, flip the state token on the headline at
  ## `lineNum`, write back. Only mutates if the state matches the
  ## expected `from_state` (defends against concurrent edits / bad
  ## line numbers from a stale parse). Used by `mark_note_done`.
  ##
  ## File rewrite is O(N) but notes.org is small (typically <1000
  ## lines for a long-running agent). Acceptable on the rare
  ## mark-done path; not on the hot heartbeat read path.
  if ns == nil or not fileExists(ns.path): return false
  var lines: seq[string] = @[]
  try:
    for line in ns.path.lines: lines.add(line)
  except IOError: return false
  if lineNum < 0 or lineNum >= lines.len: return false
  let target = lines[lineNum]
  let fromTok = $from_state    # "TODO" or "DONE"
  let toTok = $to_state
  if fromTok notin target:
    return false
  # Replace only the first occurrence of the state token in the
  # target line. Using `replace` once via slicing.
  let idx = target.find(fromTok)
  if idx < 0: return false
  lines[lineNum] = target[0 ..< idx] & toTok & target[idx + fromTok.len ..^ 1]
  try:
    let f = open(ns.path, fmWrite)
    for line in lines: f.writeLine(line)
    f.close()
    return true
  except CatchableError as e:
    warnCF("agent_notes", "Failed to rewrite notes.org",
           {"path": ns.path, "error": e.msg}.toTable)
    return false

# ── Render helpers for heartbeat prompts ────────────────────────────

proc renderPastDueForPrompt*(ns: NotesStore): string =
  ## Markdown bullet list of past-due TODOs for inclusion in the
  ## heartbeat prompt's `## Past-due notes` section. Empty string
  ## when nothing past-due.
  let nowDt = now()
  let due = ns.pastDueTodos(nowDt)
  if due.len == 0: return ""
  var lines: seq[string] = @[]
  for e in due:
    var line = "- TODO " & e.summary
    if e.due.isSome:
      line.add(" — due " & e.due.get().format("yyyy-MM-dd HH:mm"))
    if e.recur.intervalSec > 0:
      line.add(" (recurring)")
    lines.add(line)
  return lines.join("\n")
