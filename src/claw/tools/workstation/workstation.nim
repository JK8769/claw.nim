## workstation — the navigator of the system / shell / workstation trio.
##
## Per-agent GitHub-like local platform. Each agent's office contains
## their own workstation: repos (code containers) and projects (work
## trackers), with cross-cutting overview + audit.
##
## Per the discussion that led here: this tool is THIN by design. Where
## a primitive (shell+git+fs) does the job, we don't wrap it. Where
## structured storage is genuinely needed (project items with typed
## fields, activity log, multi-project overview), this tool owns the
## storage layer.
##
## Actions:
##
##   overview         — workstation dashboard (repos + projects + recent activity)
##   repo             — repository metadata (op: create | list | archive | info | pin)
##   project          — work tracker (op: create | list | open | close | archive)
##   item             — items in projects (op: add | list | update | remove | move)
##   audit            — health check (scope: project | workstation)
##
## Storage layout:
##
##   <office>/workstation/
##     repos/<name>/              # code containers
##       .git/, src/, README.md, ...
##       .workstation.json        # description, archived, pinned, linked_projects
##     projects/<name>/           # work trackers
##       PROJECT.json             # name, description, default_view, etc.
##       items/<id>.json          # one item per file (schemaless JSON)
##       activity.jsonl           # event stream
##     active/<name>/             # LEGACY — old verify_project location;
##                                  audit still scans here for back-compat
##
## Sibling tools:
##   system  — sea  (host machine substrate)
##   shell   — ship (process invocation primitive)

import std/[asyncdispatch, json, tables, strutils, os, osproc,
              sequtils, sets, times, algorithm, oids]
import ../types
import ../spec

const ToolSpec* = spec(
  name = "workstation",
  description = "Per-agent GitHub-like local platform. overview/repo/project/item/audit. Repos = code containers (workstation-level metadata); projects = work trackers with schemaless items (status/priority/etc); audit = health check (project or workstation scope).",
  tags = @["agent", "core", "workstation"],
  searchKeywords = @["workstation", "project", "repo", "repository",
                      "kanban", "board", "tracker", "items", "issues",
                      "github", "audit", "verify", "drift",
                      "overview", "dashboard", "pin", "archive"],
  domain = "agent",
  default = true,
  heartbeatSafe = true,
  category = "self-management",
)

type
  WorkstationTool* = ref object of ContextualTool
    officeDir*: string

proc newWorkstationTool*(officeDir: string): WorkstationTool =
  WorkstationTool(officeDir: officeDir)

method name*(t: WorkstationTool): string = "workstation"

method description*(t: WorkstationTool): string =
  "Per-agent GitHub-like local platform — the navigator of the system " &
  "/ shell / workstation trio.\n\n" &
  "Actions:\n" &
  "  overview  — dashboard (repos + projects + recent activity)\n" &
  "  repo      — code containers (op: create | list | archive | info | pin)\n" &
  "  project   — work trackers (op: create | list | open | close | archive)\n" &
  "  item      — items in projects (op: add | list | update | remove | move)\n" &
  "  audit     — health check (scope: project | workstation)\n\n" &
  "Storage: <office>/workstation/{repos,projects}/<name>/. Items are " &
  "schemaless JSON — any field keys you set on them are stored as-is. " &
  "For ops not yet implemented, response says so explicitly (Phase 2).\n\n" &
  "Sibling tools: `system` (host substrate), `shell` (process primitive). " &
  "Heartbeat hygiene lives in the `workstation-keeper` competency."

method parameters*(t: WorkstationTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["overview", "repo", "project", "item", "audit"],
        "description": "Top-level action. Most take a sub `op` arg."
      },
      "op": {
        "type": "string",
        "description": "Sub-operation for repo/project/item. e.g. repo op=create, project op=list, item op=add."
      },
      "name": {
        "type": "string",
        "description": "Resource name (repo, project, or item title)."
      },
      "id": {
        "type": "string",
        "description": "Item id (for item op=update / op=remove / op=move)."
      },
      "project": {
        "type": "string",
        "description": "Project name (for item ops)."
      },
      "description": {
        "type": "string",
        "description": "repo/project create — optional description."
      },
      "scope": {
        "type": "string",
        "enum": ["project", "workstation"],
        "description": "audit — project (single project audit) or workstation (cross-project tidiness)."
      },
      "title": {
        "type": "string",
        "description": "item op=add — title (required)."
      },
      "status": {
        "type": "string",
        "description": "item op=add/update — status (default: todo)."
      },
      "fields": {
        "type": "object",
        "description": "item op=add/update — additional fields as JSON object (priority, due, assignee, etc.). Schemaless."
      },
      "filter": {
        "type": "string",
        "description": "list ops — substring/key=value filter (e.g. status=in_progress)."
      }
    },
    "required": %["method"]
  }.toTable

# ── Path helpers ──────────────────────────────────────────────────

proc workstationDir(t: WorkstationTool): string = t.officeDir / "workstation"
proc reposDir(t: WorkstationTool): string = t.workstationDir / "repos"
proc projectsDir(t: WorkstationTool): string = t.workstationDir / "projects"
proc activeDir(t: WorkstationTool): string = t.workstationDir / "active"  # legacy

proc ensureDirs(t: WorkstationTool) =
  for d in [t.workstationDir, t.reposDir, t.projectsDir]:
    if not dirExists(d):
      try: createDir(d) except: discard

proc validBasename(s: string): bool =
  if s.len == 0: return false
  if s in [".", ".."]: return false
  for c in s:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}: return false
  true

# ── repo actions ──────────────────────────────────────────────────

proc repoMetadataPath(t: WorkstationTool, name: string): string =
  t.reposDir / name / ".workstation.json"

proc doRepoCreate(t: WorkstationTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("name"): return "Error: 'name' is required for repo create"
  let name = args["name"].getStr().strip()
  if not validBasename(name):
    return "Error: 'name' must be a valid basename (letters/digits/-/_/.). Got: '" & name & "'"
  ensureDirs(t)
  let dest = t.reposDir / name
  if dirExists(dest):
    return "Error: repo '" & name & "' already exists at " & dest
  try: createDir(dest) except CatchableError as e:
    return "Error: failed to create repo dir: " & e.msg

  # git init
  let (_, gitExit) = execCmdEx("git -C " & quoteShell(dest) & " init -b main")
  if gitExit != 0:
    return "Warning: dir created but git init failed. Repo at " & dest

  # README scaffold
  let desc = if args.hasKey("description"): args["description"].getStr() else: ""
  let readme = "# " & name & "\n\n" & desc & "\n"
  try: writeFile(dest / "README.md", readme) except: discard

  # workstation metadata
  let meta = %*{
    "name": name,
    "description": desc,
    "created": now().format("yyyy-MM-dd HH:mm:ss"),
    "archived": false,
    "pinned": false,
    "linked_projects": newJArray()
  }
  try: writeFile(t.repoMetadataPath(name), pretty(meta, 2))
  except CatchableError as e:
    return "Warning: dir + git initialized but metadata write failed: " & e.msg

  return "Created repo `" & name & "` at " & dest & "\n" &
         "  - git initialized (branch: main)\n" &
         "  - README.md scaffolded\n" &
         "  - .workstation.json metadata recorded"

proc doRepoList(t: WorkstationTool, args: Table[string, JsonNode]): string =
  ensureDirs(t)
  if not dirExists(t.reposDir):
    return "(no repos yet — use `workstation repo op=create name=…` to scaffold)"
  let filter = if args.hasKey("filter"): args["filter"].getStr() else: ""
  var rows: seq[string]
  for kind, path in walkDir(t.reposDir):
    if kind != pcDir: continue
    let name = path.extractFilename
    if name.startsWith("."): continue
    if filter.len > 0 and not name.toLowerAscii.contains(filter.toLowerAscii):
      continue
    let metaPath = t.repoMetadataPath(name)
    var status = ""
    if fileExists(metaPath):
      try:
        let m = parseJson(readFile(metaPath))
        let archived = m{"archived"}.getBool(false)
        let pinned = m{"pinned"}.getBool(false)
        let desc = m{"description"}.getStr("")
        var tags: seq[string]
        if pinned: tags.add("📌")
        if archived: tags.add("archived")
        let tagStr = if tags.len > 0: " [" & tags.join(",") & "]" else: ""
        let descPart = if desc.len > 0: " — " & desc else: ""
        status = tagStr & descPart
      except: discard
    rows.add("  " & name & status)
  if rows.len == 0:
    return "(no repos matching filter: '" & filter & "')"
  rows.sort()
  return "Repos in " & t.reposDir & ":\n" & rows.join("\n")

proc phase2Stub(action, op: string): string =
  let opStr = if op.len > 0: " op='" & op & "'" else: ""
  "Error: '" & action & opStr & "' is in the action set but not yet " &
  "implemented (planned for Phase 2). The surface is locked so agents " &
  "can plan against the future API."

proc doRepo(t: WorkstationTool, args: Table[string, JsonNode]): string =
  let op = if args.hasKey("op"): args["op"].getStr().strip().toLowerAscii() else: ""
  case op
  of "create": return doRepoCreate(t, args)
  of "list":   return doRepoList(t, args)
  of "archive", "info", "pin", "unpin", "link":
    return phase2Stub("repo", op)
  of "":
    return "Error: 'op' is required for repo. Use: create | list (Phase 1) | archive | info | pin | unpin | link (Phase 2)"
  else:
    return "Error: unknown repo op '" & op & "'. Use: create | list | archive | info | pin | unpin | link"

# ── project actions ───────────────────────────────────────────────

proc projectConfigPath(t: WorkstationTool, name: string): string =
  t.projectsDir / name / "PROJECT.json"

proc projectItemsDir(t: WorkstationTool, name: string): string =
  t.projectsDir / name / "items"

proc projectActivityPath(t: WorkstationTool, name: string): string =
  t.projectsDir / name / "activity.jsonl"

proc doProjectCreate(t: WorkstationTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("name"): return "Error: 'name' is required for project create"
  let name = args["name"].getStr().strip()
  if not validBasename(name):
    return "Error: 'name' must be a valid basename. Got: '" & name & "'"
  ensureDirs(t)
  let dest = t.projectsDir / name
  if dirExists(dest):
    return "Error: project '" & name & "' already exists"
  try:
    createDir(dest)
    createDir(t.projectItemsDir(name))
  except CatchableError as e:
    return "Error: failed to create project dirs: " & e.msg

  let desc = if args.hasKey("description"): args["description"].getStr() else: ""
  let cfg = %*{
    "name": name,
    "description": desc,
    "created": now().format("yyyy-MM-dd HH:mm:ss"),
    "status": "open",
    "default_view": "board"
  }
  try: writeFile(t.projectConfigPath(name), pretty(cfg, 2))
  except CatchableError as e:
    return "Warning: dirs created but PROJECT.json write failed: " & e.msg

  try:
    writeFile(t.projectActivityPath(name),
              $(%*{"event": "project.created", "at": now().format("yyyy-MM-dd HH:mm:ss")}) & "\n")
  except: discard

  return "Created project `" & name & "` at " & dest & "\n" &
         "  - PROJECT.json scaffolded (status=open, default_view=board)\n" &
         "  - items/ ready for `workstation item op=add project=" & name & " ...`"

proc doProjectList(t: WorkstationTool, args: Table[string, JsonNode]): string =
  ensureDirs(t)
  if not dirExists(t.projectsDir):
    return "(no projects yet — use `workstation project op=create name=…`)"
  let filter = if args.hasKey("filter"): args["filter"].getStr() else: ""
  var rows: seq[string]
  for kind, path in walkDir(t.projectsDir):
    if kind != pcDir: continue
    let name = path.extractFilename
    if name.startsWith("."): continue
    if filter.len > 0 and not name.toLowerAscii.contains(filter.toLowerAscii):
      continue
    var status = "open"
    var desc = ""
    var itemCount = 0
    let cfg = t.projectConfigPath(name)
    if fileExists(cfg):
      try:
        let c = parseJson(readFile(cfg))
        status = c{"status"}.getStr("open")
        desc = c{"description"}.getStr("")
      except: discard
    let itemsDir = t.projectItemsDir(name)
    if dirExists(itemsDir):
      for k, _ in walkDir(itemsDir):
        if k == pcFile: inc itemCount
    let descPart = if desc.len > 0: " — " & desc else: ""
    rows.add("  " & name & " [" & status & ", " & $itemCount & " items]" & descPart)
  if rows.len == 0:
    return "(no projects matching filter: '" & filter & "')"
  rows.sort()
  return "Projects in " & t.projectsDir & ":\n" & rows.join("\n")

proc doProject(t: WorkstationTool, args: Table[string, JsonNode]): string =
  let op = if args.hasKey("op"): args["op"].getStr().strip().toLowerAscii() else: ""
  case op
  of "create": return doProjectCreate(t, args)
  of "list":   return doProjectList(t, args)
  of "open", "close", "archive":
    return phase2Stub("project", op)
  of "":
    return "Error: 'op' is required. Use: create | list (Phase 1) | open | close | archive (Phase 2)"
  else:
    return "Error: unknown project op '" & op & "'. Use: create | list | open | close | archive"

# ── item actions ──────────────────────────────────────────────────

proc generateItemId(): string =
  ## i-<short oid> for items
  "i-" & ($genOid())[0 ..< 8]

proc itemPath(t: WorkstationTool, project, id: string): string =
  t.projectItemsDir(project) / (id & ".json")

proc appendActivity(t: WorkstationTool, project: string, event: JsonNode) =
  try:
    let path = t.projectActivityPath(project)
    let f = open(path, fmAppend)
    defer: f.close()
    f.writeLine($event)
  except: discard

proc doItemAdd(t: WorkstationTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("project"): return "Error: 'project' is required for item add"
  if not args.hasKey("title"): return "Error: 'title' is required for item add"
  let project = args["project"].getStr().strip()
  if not dirExists(t.projectsDir / project):
    return "Error: project '" & project & "' does not exist. Create it first via `workstation project op=create name=" & project & "`"
  let title = args["title"].getStr().strip()
  if title.len == 0: return "Error: 'title' must not be empty"
  let id = generateItemId()
  let status = if args.hasKey("status"): args["status"].getStr() else: "todo"
  var item = %*{
    "id": id,
    "title": title,
    "status": status,
    "created": now().format("yyyy-MM-dd HH:mm:ss"),
    "updated": now().format("yyyy-MM-dd HH:mm:ss")
  }
  if args.hasKey("fields") and args["fields"].kind == JObject:
    for k, v in args["fields"].pairs:
      item[k] = v

  try: writeFile(t.itemPath(project, id), pretty(item, 2))
  except CatchableError as e:
    return "Error: failed to write item: " & e.msg

  appendActivity(t, project, %*{
    "event": "item.added", "id": id, "title": title, "status": status,
    "at": now().format("yyyy-MM-dd HH:mm:ss")
  })
  return "Added item `" & id & "` to project `" & project & "`: " & title &
         " (status=" & status & ")"

proc doItemList(t: WorkstationTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("project"): return "Error: 'project' is required for item list"
  let project = args["project"].getStr().strip()
  let itemsDir = t.projectItemsDir(project)
  if not dirExists(itemsDir):
    return "Error: project '" & project & "' has no items dir."
  let filter = if args.hasKey("filter"): args["filter"].getStr() else: ""
  # filter format: "key=value" — simple substring match if no =
  var filterKey, filterVal: string
  let eqIdx = filter.find('=')
  if eqIdx > 0:
    filterKey = filter[0 ..< eqIdx]
    filterVal = filter[eqIdx + 1 .. ^1]

  var rows: seq[string]
  for kind, path in walkDir(itemsDir):
    if kind != pcFile: continue
    if not path.endsWith(".json"): continue
    try:
      let item = parseJson(readFile(path))
      if filterKey.len > 0:
        if item{filterKey}.getStr("") != filterVal: continue
      elif filter.len > 0:
        let title = item{"title"}.getStr("")
        if not title.toLowerAscii.contains(filter.toLowerAscii): continue
      let id = item{"id"}.getStr("")
      let status = item{"status"}.getStr("?")
      let title = item{"title"}.getStr("")
      rows.add("  " & id & "  [" & status & "]  " & title)
    except: continue

  if rows.len == 0:
    let filterMsg = if filter.len > 0: " matching filter '" & filter & "'" else: ""
    return "(no items in `" & project & "`" & filterMsg & ")"
  rows.sort()
  return "Items in `" & project & "`:\n" & rows.join("\n")

proc doItemUpdate(t: WorkstationTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("project"): return "Error: 'project' is required for item update"
  if not args.hasKey("id"): return "Error: 'id' is required for item update"
  let project = args["project"].getStr().strip()
  let id = args["id"].getStr().strip()
  let path = t.itemPath(project, id)
  if not fileExists(path):
    return "Error: item '" & id & "' in project '" & project & "' does not exist"
  var item: JsonNode
  try: item = parseJson(readFile(path))
  except CatchableError as e: return "Error: failed to read item: " & e.msg

  var changedFields: seq[string]
  for fieldKey in ["title", "status"]:
    if args.hasKey(fieldKey):
      item[fieldKey] = args[fieldKey]
      changedFields.add(fieldKey)
  if args.hasKey("fields") and args["fields"].kind == JObject:
    for k, v in args["fields"].pairs:
      item[k] = v
      changedFields.add(k)
  item["updated"] = %now().format("yyyy-MM-dd HH:mm:ss")

  try: writeFile(path, pretty(item, 2))
  except CatchableError as e: return "Error: failed to write item: " & e.msg

  appendActivity(t, project, %*{
    "event": "item.updated", "id": id, "fields": changedFields,
    "at": now().format("yyyy-MM-dd HH:mm:ss")
  })
  return "Updated item `" & id & "` in project `" & project & "` (fields: " &
         changedFields.join(", ") & ")"

proc doItem(t: WorkstationTool, args: Table[string, JsonNode]): string =
  let op = if args.hasKey("op"): args["op"].getStr().strip().toLowerAscii() else: ""
  case op
  of "add":    return doItemAdd(t, args)
  of "list":   return doItemList(t, args)
  of "update": return doItemUpdate(t, args)
  of "remove", "move":
    return phase2Stub("item", op)
  of "":
    return "Error: 'op' is required. Use: add | list | update (Phase 1) | remove | move (Phase 2)"
  else:
    return "Error: unknown item op '" & op & "'. Use: add | list | update | remove | move"

# ── overview ──────────────────────────────────────────────────────

proc doOverview(t: WorkstationTool): string =
  ensureDirs(t)
  var lines: seq[string]
  lines.add("# Workstation overview")
  lines.add("Path: " & t.workstationDir)
  lines.add("")

  # Repos
  var repoCount = 0
  var pinnedRepos: seq[string]
  for kind, path in walkDir(t.reposDir):
    if kind != pcDir: continue
    inc repoCount
    let name = path.extractFilename
    let metaPath = t.repoMetadataPath(name)
    if fileExists(metaPath):
      try:
        let m = parseJson(readFile(metaPath))
        if m{"pinned"}.getBool(false):
          pinnedRepos.add(name)
      except: discard
  lines.add("## Repos (" & $repoCount & " total)")
  if pinnedRepos.len > 0:
    lines.add("Pinned: " & pinnedRepos.join(", "))
  lines.add("")

  # Projects
  var openProjectCount = 0
  var totalItemCount = 0
  var openItems = 0
  for kind, path in walkDir(t.projectsDir):
    if kind != pcDir: continue
    let name = path.extractFilename
    let cfg = t.projectConfigPath(name)
    if fileExists(cfg):
      try:
        let c = parseJson(readFile(cfg))
        if c{"status"}.getStr("open") == "open":
          inc openProjectCount
      except: discard
    let itemsDir = t.projectItemsDir(name)
    if dirExists(itemsDir):
      for k, ip in walkDir(itemsDir):
        if k != pcFile: continue
        if not ip.endsWith(".json"): continue
        inc totalItemCount
        try:
          let it = parseJson(readFile(ip))
          let st = it{"status"}.getStr("")
          if st in ["todo", "in_progress"]: inc openItems
        except: discard
  lines.add("## Projects (" & $openProjectCount & " open)")
  lines.add("Items: " & $openItems & " open / " & $totalItemCount & " total")
  lines.add("")

  # Recent activity (look at most recent activity.jsonl across projects)
  var recentLines: seq[string]
  for kind, path in walkDir(t.projectsDir):
    if kind != pcDir: continue
    let actPath = t.projectActivityPath(path.extractFilename)
    if not fileExists(actPath): continue
    try:
      let content = readFile(actPath)
      let actLines = content.splitLines()
      for line in actLines:
        if line.len > 0: recentLines.add(line)
    except: discard
  if recentLines.len > 0:
    lines.add("## Recent activity (last 5)")
    let tail = if recentLines.len > 5: recentLines[^5 .. ^1] else: recentLines
    for l in tail:
      try:
        let e = parseJson(l)
        let event = e{"event"}.getStr("")
        let at = e{"at"}.getStr("")
        let id = e{"id"}.getStr("")
        lines.add("  [" & at & "] " & event & " " & id)
      except: lines.add("  " & l)

  lines.join("\n")

# ── audit ─────────────────────────────────────────────────────────

# Helpers for project audit (ported from old verify_project)

proc isDigits(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'0'..'9'}: return false
  return true

proc looksLikePath(s: string): bool =
  if s.len == 0: return false
  if s.startsWith("http://") or s.startsWith("https://"): return false
  if s.startsWith("/"): return false
  if s.endsWith("/"): return false
  if "*" in s or "?" in s: return false
  if "->" in s: return false
  for c in s:
    if c in {' ', '\t', '\n'}: return false
  if "/" in s: return true
  let dotIdx = s.rfind('.')
  if dotIdx > 0 and dotIdx < s.len - 1:
    let ext = s[dotIdx + 1 .. ^1]
    if ext.len <= 6 and ext.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9'}):
      return true
  return false

proc extractReadmePaths(readme: string): seq[string] =
  result = @[]
  var seen = initHashSet[string]()
  var i = 0
  while i < readme.len:
    if readme[i] == '`':
      let start = i + 1
      var j = start
      while j < readme.len and readme[j] != '`' and readme[j] != '\n':
        inc j
      if j < readme.len and readme[j] == '`' and j > start:
        var s = readme[start ..< j]
        let colonIdx = s.find(':')
        if colonIdx > 0 and isDigits(s[colonIdx + 1 .. ^1]):
          s = s[0 ..< colonIdx]
        if looksLikePath(s) and s notin seen:
          result.add(s)
          seen.incl(s)
        i = j + 1
        continue
    inc i

proc walkSymlinks(root: string): seq[tuple[link, target: string]] =
  result = @[]
  for path in walkDirRec(root, relative = false, checkDir = false):
    let info = try: getFileInfo(path, followSymlink = false)
               except CatchableError: continue
    if info.kind notin {pcLinkToFile, pcLinkToDir}: continue
    let target = try: expandSymlink(path) except CatchableError: ""
    result.add((path, target))

proc isSymlinkResolved(linkPath, target: string): bool =
  if target.len == 0: return false
  let absTarget =
    if target.isAbsolute: target
    else: parentDir(linkPath) / target
  fileExists(absTarget) or dirExists(absTarget)

proc gitDirtyFiles(projectRoot: string): seq[string] =
  result = @[]
  let gitDir = projectRoot / ".git"
  if not (dirExists(gitDir) or fileExists(gitDir)): return
  let (output, exit) = execCmdEx("git -C " & quoteShell(projectRoot) &
                                  " status --porcelain")
  if exit != 0: return
  for line in output.splitLines():
    let s = line.strip()
    if s.len > 3:
      result.add(s[3 .. ^1])

const SkipDirs = ["node_modules", "__pycache__", ".venv", "venv",
                  ".pytest_cache", "dist", "build", "target", ".git"]
const NoiseFiles = [".gitkeep", ".DS_Store", "Thumbs.db"]

proc dirHasContent(dir: string): bool =
  for kind, path in walkDir(dir):
    let bn = path.extractFilename
    if bn in NoiseFiles: continue
    return true
  return false

proc walkEmptyDirs(root: string): seq[string] =
  result = @[]
  for kind, path in walkDir(root):
    if kind != pcDir: continue
    let bn = path.extractFilename
    if bn in SkipDirs: continue
    if not dirHasContent(path):
      result.add(path.relativePath(root))
    else:
      for ck, cp in walkDir(path):
        if ck != pcDir: continue
        let cbn = cp.extractFilename
        if cbn in SkipDirs: continue
        if not dirHasContent(cp):
          result.add(cp.relativePath(root))

proc auditProjectInternal(t: WorkstationTool, name, root: string): JsonNode =
  ## Returns audit envelope for a project at <root>.
  if not dirExists(root):
    return %*{
      "project": name, "path": root, "verdict": "missing",
      "readme_drift": newJArray(), "broken_symlinks": newJArray(),
      "git_dirty": newJArray(), "empty_dirs": newJArray()
    }

  var readmeDrift: seq[string]
  let readmePath = root / "README.md"
  if fileExists(readmePath):
    let content = readFile(readmePath)
    for candidate in extractReadmePaths(content):
      if not (fileExists(root / candidate) or dirExists(root / candidate)):
        readmeDrift.add(candidate)

  var brokenSymlinks: seq[string]
  for (link, target) in walkSymlinks(root):
    if not isSymlinkResolved(link, target):
      brokenSymlinks.add(link.relativePath(root) & " -> " & target)

  let gitDirty = gitDirtyFiles(root)
  let emptyDirs = walkEmptyDirs(root).deduplicate()
  let needsAttention = readmeDrift.len > 0 or brokenSymlinks.len > 0 or
                       gitDirty.len > 0 or emptyDirs.len > 0
  let verdict = if needsAttention: "needs_attention" else: "clean"
  return %*{
    "project": name, "path": root, "verdict": verdict,
    "readme_drift": readmeDrift, "broken_symlinks": brokenSymlinks,
    "git_dirty": gitDirty, "empty_dirs": emptyDirs
  }

proc resolveProjectRoot(t: WorkstationTool, name: string): string =
  ## Returns first existing of: projects/<name>/ → repos/<name>/ → active/<name>/
  let candidates = @[t.projectsDir / name, t.reposDir / name, t.activeDir / name]
  for c in candidates:
    if dirExists(c): return c
  return ""

proc doAudit(t: WorkstationTool, args: Table[string, JsonNode]): string =
  ensureDirs(t)
  let scope = if args.hasKey("scope"): args["scope"].getStr().toLowerAscii() else: "project"

  case scope
  of "project":
    if not args.hasKey("name"):
      return "Error: 'name' is required for audit scope=project"
    let name = args["name"].getStr().strip()
    if not validBasename(name):
      return "Error: 'name' must be a valid basename"
    let root = resolveProjectRoot(t, name)
    if root.len == 0:
      let env = %*{
        "project": name, "path": "(not found)", "verdict": "missing",
        "readme_drift": newJArray(), "broken_symlinks": newJArray(),
        "git_dirty": newJArray(), "empty_dirs": newJArray()
      }
      return env.pretty()
    return auditProjectInternal(t, name, root).pretty()

  of "workstation":
    var results: seq[JsonNode]
    let scanRoots = @[t.projectsDir, t.reposDir, t.activeDir]
    for root in scanRoots:
      if not dirExists(root): continue
      for kind, path in walkDir(root):
        if kind != pcDir: continue
        let name = path.extractFilename
        if name.startsWith("."): continue
        results.add(auditProjectInternal(t, name, path))

    var clean = 0
    var attention = 0
    var drift_total = 0
    for r in results:
      let v = r{"verdict"}.getStr("")
      if v == "clean": inc clean
      elif v == "needs_attention": inc attention
      drift_total += r{"readme_drift"}.elems.len +
                      r{"broken_symlinks"}.elems.len +
                      r{"git_dirty"}.elems.len +
                      r{"empty_dirs"}.elems.len

    let summary = %*{
      "scope": "workstation",
      "scanned": results.len,
      "clean": clean,
      "needs_attention": attention,
      "missing": results.len - clean - attention,
      "total_drift_items": drift_total,
      "details": results
    }
    return summary.pretty()

  else:
    return "Error: scope must be 'project' or 'workstation' (got: '" & scope & "')"

# ── dispatch ──────────────────────────────────────────────────────

method execute*(t: WorkstationTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.officeDir.len == 0:
    return "Error: tool not bound to an office workspace"
  if not (args.hasKey("method") or args.hasKey("action")):
    return "Error: 'action' is required (overview | repo | project | item | audit)"
  let action = getMethodArg(args).toLowerAscii()
  case action
  of "overview": return doOverview(t)
  of "repo":     return doRepo(t, args)
  of "project":  return doProject(t, args)
  of "item":     return doItem(t, args)
  of "audit":    return doAudit(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: overview | repo | project | item | audit"
