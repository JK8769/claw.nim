## workstation — agent's project lifecycle tool.
##
## Initially scoped to verify_project: audits a project under
## <office>/workstation/active/<name>/ for README ↔ disk drift,
## broken symlinks, dirty git state, and empty scaffold dirs.
## Returns a structured verdict the agent can read OR cite as
## evidence in a reply-progress verification field.
##
## Designed to be called from a heartbeat duty (workstation-keeper
## competency) — every active project gets audited on each tick;
## any `needs_attention` result surfaces in the reflection so the
## agent decides: fix the README, port the missing files, or
## remove dead scaffolding.
##
## Future actions (out of scope for this iteration): create_project,
## archive_project. Add when there's a real workflow demanding them.

import std/[asyncdispatch, json, tables, strutils, os, osproc, sequtils, sets]
import ../types
import ../spec

const ToolSpec* = spec(
  name = "workstation",
  description = "audit a project under workstation/active/ for README↔disk drift, broken symlinks, dirty git, empty scaffolds (action=verify_project)",
  tags = @["agent", "core", "workstation"],
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
  "Project lifecycle audits.\n\n" &
  "Actions:\n" &
  "  verify_project — audit a project under workstation/active/<name>/. " &
  "Returns JSON verdict: clean | needs_attention | missing, plus " &
  "structured drift lists (readme_drift, broken_symlinks, git_dirty, " &
  "empty_dirs). Cite the verdict as evidence when marking " &
  "reply-progress items verified_done.\n\n" &
  "Use it before claiming a project setup is finished, and as a " &
  "heartbeat duty to catch drift between the README and disk."

method parameters*(t: WorkstationTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["verify_project"],
        "description": "Operation to perform"
      },
      "name": {
        "type": "string",
        "description": "Project name under workstation/active/. Basename only — refuses path traversal."
      }
    },
    "required": %*["action", "name"]
  }.toTable

# ── helpers ──────────────────────────────────────────────────────

proc isDigits(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'0'..'9'}: return false
  return true

proc looksLikePath(s: string): bool =
  ## Path-shaped: contains `/` or has a typical extension. Skip URLs,
  ## absolute paths, directories, globs, symlink syntax, anything with
  ## whitespace.
  if s.len == 0: return false
  if s.startsWith("http://") or s.startsWith("https://"): return false
  if s.startsWith("/"): return false
  if s.endsWith("/"): return false
  if "*" in s or "?" in s: return false
  if "->" in s: return false
  for c in s:
    if c in {' ', '\t', '\n'}: return false
  if "/" in s: return true
  # Accept bare-filename-with-extension: `foo.md`, `bar.py`
  let dotIdx = s.rfind('.')
  if dotIdx > 0 and dotIdx < s.len - 1:
    let ext = s[dotIdx + 1 .. ^1]
    if ext.len <= 6 and ext.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9'}):
      return true
  return false

proc extractReadmePaths(readme: string): seq[string] =
  ## Walk char by char; collect content between matched backticks. Filter
  ## by `looksLikePath`. Trims optional `:line` suffixes.
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
        # strip `:lineNum` suffix
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
  ## A dir "has content" if it contains anything that isn't filesystem noise.
  for kind, path in walkDir(dir):
    let bn = path.extractFilename
    if bn in NoiseFiles: continue
    return true
  return false

proc walkEmptyDirs(root: string): seq[string] =
  ## Recursively find empty directories (except .gitkeep-marked ones)
  ## under the project root, skipping common heavy dirs. Returns paths
  ## relative to root.
  result = @[]
  for kind, path in walkDir(root):
    if kind != pcDir: continue
    let bn = path.extractFilename
    if bn in SkipDirs: continue
    if not dirHasContent(path):
      result.add(path.relativePath(root))
    else:
      # Recurse one level — catches `src/models/` style empties without
      # walking deep into populated trees.
      for ck, cp in walkDir(path):
        if ck != pcDir: continue
        let cbn = cp.extractFilename
        if cbn in SkipDirs: continue
        if not dirHasContent(cp):
          result.add(cp.relativePath(root))

# ── verify_project ───────────────────────────────────────────────

proc doVerifyProject(t: WorkstationTool, args: Table[string, JsonNode]): string =
  let nameRaw = args["name"].getStr().strip()
  if nameRaw.len == 0:
    return "Error: 'name' must not be empty"
  let basename = extractFilename(nameRaw)
  if basename != nameRaw or basename in ["", ".", ".."]:
    return "Error: 'name' must be a single project basename (got: '" &
           nameRaw & "')"

  let projectRoot = t.officeDir / "workstation" / "active" / basename
  if not dirExists(projectRoot):
    let envelope = %*{
      "project": basename,
      "path": projectRoot,
      "verdict": "missing",
      "readme_drift": newJArray(),
      "broken_symlinks": newJArray(),
      "git_dirty": newJArray(),
      "empty_dirs": newJArray()
    }
    return envelope.pretty()

  var readmeDrift: seq[string] = @[]
  let readmePath = projectRoot / "README.md"
  if fileExists(readmePath):
    let content = readFile(readmePath)
    for candidate in extractReadmePaths(content):
      if not (fileExists(projectRoot / candidate) or
              dirExists(projectRoot / candidate)):
        readmeDrift.add(candidate)

  var brokenSymlinks: seq[string] = @[]
  for (link, target) in walkSymlinks(projectRoot):
    if not isSymlinkResolved(link, target):
      brokenSymlinks.add(link.relativePath(projectRoot) & " -> " & target)

  let gitDirty = gitDirtyFiles(projectRoot)
  let emptyDirs = walkEmptyDirs(projectRoot).deduplicate()

  let needsAttention = readmeDrift.len > 0 or brokenSymlinks.len > 0 or
                       gitDirty.len > 0 or emptyDirs.len > 0
  let verdict = if needsAttention: "needs_attention" else: "clean"

  let envelope = %*{
    "project": basename,
    "path": projectRoot,
    "verdict": verdict,
    "readme_drift": readmeDrift,
    "broken_symlinks": brokenSymlinks,
    "git_dirty": gitDirty,
    "empty_dirs": emptyDirs
  }
  return envelope.pretty()

method execute*(t: WorkstationTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.officeDir.len == 0:
    return "Error: tool not bound to an office workspace"
  if not args.hasKey("action"):
    return "Error: 'action' is required (verify_project)"
  if not args.hasKey("name"):
    return "Error: 'name' is required"
  let action = args["action"].getStr()
  case action
  of "verify_project": return doVerifyProject(t, args)
  else:
    return "Error: Unknown action '" & action & "'. Use: verify_project"
