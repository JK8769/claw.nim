## finder — single tool for discovery across the workspace (the "navigator").
##
## Two actions:
##
##   method=files   — glob-style path search. Example:
##                      finder method=files pattern="**/*.csv"
##                    Returns workspace-relative paths, newline-separated.
##
##   method=content — content search. Shells out to `rg` (ripgrep) when
##                    available for speed + regex; falls back to a pure-Nim
##                    recursive walk + substring match. Example:
##                      finder method=content pattern="TODO" in="**/*.nim"
##                    Returns matches as `path:line:matched_text`.
##                    Capped at 200 matches.
##
## Implementation notes:
##
##   - POSIX `glob(3)` (used by std/os::walkPattern) does NOT support `**`
##     for recursive matching. We detect `**` in the pattern and switch to
##     a custom recursive walker with a small glob-segment matcher.
##     Single-segment patterns (e.g. `*.csv`, `notes/*.md`) defer to
##     walkPattern for native speed.
##
##   - All returned paths are workspace-relative (or office-relative when
##     the agent has an office root). Absolute paths are never leaked.
##
##   - Path safety: every yielded path is validated against
##     `isResolvedPathAllowed` before being returned, so even if an `**`
##     walk would naively cross a symlink out of the workspace, the
##     gate refuses it.
##
##   - The `content` ripgrep fallback uses simple substring matching only
##     (no regex). Operators who need regex should either ensure `rg` is
##     installed or accept the limitation.
##
## ---------------------------------------------------------------------------
## Registration changes for src/claw/agent/loop.nim
## ---------------------------------------------------------------------------
##
## See `fs_unified.nim` header for the consolidated remove/add list.
##
## TODO (v2):
##   - `content` regex when rg is missing (port a tiny regex matcher, or
##     fall back to `grep -RE` if available before pure-Nim).
##   - Honor .gitignore in the pure-Nim fallback (rg honors it natively).
##   - Brace expansion `{a,b}` in glob patterns (rg supports it via
##     `--iglob`; current fallback doesn't).

import std/[os, json, asyncdispatch, tables, strutils, osproc, streams]
import ./types
import ./spec
import ./path_security
import ./iam_policies

const ToolSpec* = spec(
  name = "finder",
  description = "Discover files (by path glob) and content (ripgrep-style)",
  tags = @["filesystem", "search", "data", "core"],
  searchKeywords = @["find", "search", "grep", "rg", "ripgrep", "glob",
                     "locate", "discover", "scan"],
  domain = "file",
  default = true,
  heartbeatSafe = true,  # both actions are read-only
  category = "files",
)

const MaxContentMatches = 200
  ## Cap matches per search to keep the context window sane. The LLM can
  ## always narrow `in` to scope the next call.

type
  FinderTool* = ref object of ContextualTool
    workspaceDir*: string
    officeDir*: string
    allowedPaths*: seq[string]

proc newFinderTool*(workspaceDir: string, officeDir: string = "",
                    allowedPaths: seq[string] = @[]): FinderTool =
  FinderTool(workspaceDir: workspaceDir, officeDir: officeDir,
             allowedPaths: allowedPaths)

method name*(t: FinderTool): string = "finder"

method description*(t: FinderTool): string =
  "Discovery across the workspace (the 'navigator'). Use for finding files " &
  "by name pattern or content by text/regex.\n\n" &
  "Actions:\n" &
  "  files   — glob-style path search, e.g. pattern=\"**/*.csv\". " &
  "Returns workspace-relative paths.\n" &
  "  content — content search. Shells out to ripgrep when available; " &
  "otherwise falls back to a pure-Nim recursive walker with substring " &
  "matching. Optional `in` restricts to a glob (default: whole workspace). " &
  "Returns matches as 'path:line:text' (capped at " & $MaxContentMatches & ")."

method parameters*(t: FinderTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["files", "content"],
        "description": "Operation to perform"
      },
      "pattern": {
        "type": "string",
        "description":
          "files: glob pattern to match (e.g. '**/*.nim', 'notes/*.md'). " &
          "content: text or regex to search for. The fallback path uses " &
          "literal substring matching; ripgrep treats it as regex."
      },
      "in": {
        "type": "string",
        "description":
          "content only — glob restricting search scope (e.g. '**/*.nim'). " &
          "Omit to scan from the workspace root."
      }
    },
    "required": %["action", "pattern"]
  }.toTable

# ---------------------------------------------------------------------------
# helpers — path roots + workspace-relative formatting
# ---------------------------------------------------------------------------

proc baseRoot(t: FinderTool): string =
  ## Discovery anchors at workspace root. (Office is a subdir of workspace
  ## in normal layouts, so walking the workspace already includes it.)
  expandFilename(t.workspaceDir)

proc relPath(t: FinderTool, absPath: string): string =
  ## Render `absPath` relative to the workspace root for the LLM's eyes,
  ## or fall back to the absolute path if it doesn't sit under the root
  ## (shouldn't happen given the path-safety gate, but defensive).
  let root = baseRoot(t)
  let normalized =
    try: expandFilename(absPath)
    except OSError: absPath
  if pathStartsWith(normalized, root):
    let stripped = normalized[root.len .. ^1]
    if stripped.startsWith("/") or stripped.startsWith("\\"):
      return stripped[1 .. ^1]
    return stripped
  normalized

# ---------------------------------------------------------------------------
# glob matcher — segment-by-segment, supporting `*`, `?`, and `**`
# ---------------------------------------------------------------------------

proc matchSegment(pat, name: string): bool =
  ## Match a single path segment against `*`/`?`/literal pattern. No `**`
  ## here — `**` is handled at the path-walking level (matches zero or
  ## more directory components).
  var i, j = 0
  var starI = -1
  var starJ = -1
  while j < name.len:
    if i < pat.len and (pat[i] == name[j] or pat[i] == '?'):
      inc i; inc j
    elif i < pat.len and pat[i] == '*':
      starI = i
      starJ = j
      inc i
    elif starI >= 0:
      i = starI + 1
      inc starJ
      j = starJ
    else:
      return false
  while i < pat.len and pat[i] == '*':
    inc i
  i == pat.len

proc matchGlob(pattern, relPath: string): bool =
  ## Match a workspace-relative path against a glob. `**` in pattern
  ## matches zero or more path segments.
  let patSegs = pattern.split({'/', '\\'})
  let pathSegs = relPath.split({'/', '\\'})

  proc go(pi, qi: int): bool =
    if pi >= patSegs.len:
      return qi >= pathSegs.len
    if patSegs[pi] == "**":
      # Zero or more segments — try every suffix consumption.
      if pi + 1 >= patSegs.len:
        return true  # trailing ** matches everything remaining
      for k in qi .. pathSegs.len:
        if go(pi + 1, k): return true
      return false
    if qi >= pathSegs.len:
      return false
    if not matchSegment(patSegs[pi], pathSegs[qi]):
      return false
    go(pi + 1, qi + 1)

  go(0, 0)

# ---------------------------------------------------------------------------
# method=files
# ---------------------------------------------------------------------------

proc isPathGated(t: FinderTool, absPath: string): bool =
  ## Re-check path-safety + IAM for each yielded entry. Cheap insurance
  ## against symlinks that point out of the workspace. Returns true ONLY
  ## when the path passes BOTH gates (path-safety AND IAM read).
  let wsResolved = baseRoot(t)
  let officeResolved =
    if t.officeDir != "": expandFilename(t.officeDir) else: ""
  if not isResolvedPathAllowed(absPath, wsResolved, t.allowedPaths, officeResolved):
    return false
  return checkAccess(t.role, t.agentName, absPath, wsResolved, akRead)

proc doFiles(t: FinderTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("pattern"):
    return "Error: pattern is required"
  let pattern = args["pattern"].getStr().strip()
  if pattern.len == 0:
    return "Error: pattern must be non-empty"

  let root = baseRoot(t)
  if not dirExists(root):
    return "Error: workspace root does not exist: " & root

  var results: seq[string] = @[]

  if not pattern.contains("**"):
    # Single-level pattern → defer to native POSIX glob, anchored at root.
    let anchored = root / pattern
    try:
      for hit in walkPattern(anchored):
        if not isPathGated(t, hit): continue
        results.add(relPath(t, hit))
    except Exception as e:
      return "Error: glob failed: " & e.msg
  else:
    # Recursive pattern → custom walker. Walk the whole tree, match each
    # entry against the glob. This is O(N) over the workspace — fine
    # because the workspace is bounded by the path-safety gate.
    try:
      for path in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile, pcDir, pcLinkToDir}):
        if not isPathGated(t, path): continue
        let rel = relPath(t, path)
        if matchGlob(pattern, rel):
          results.add(rel)
    except Exception as e:
      return "Error: recursive walk failed: " & e.msg

  if results.len == 0:
    return "(no matches for pattern: " & pattern & ")"
  results.join("\n")

# ---------------------------------------------------------------------------
# method=content — ripgrep + fallback
# ---------------------------------------------------------------------------

proc rgAvailable(): bool =
  findExe("rg").len > 0

proc runRipgrep(t: FinderTool, pattern, scope: string): string =
  ## Shell out to `rg`. Format is `path:line:text` — match rg's default
  ## --line-number --no-heading output. Caps at MaxContentMatches via
  ## `--max-count` per file is too coarse, so we slice ourselves.
  let root = baseRoot(t)
  var argv = @["--line-number", "--no-heading", "--color=never", "--max-columns=400",
               "-e", pattern]
  if scope.len > 0:
    argv.add("--glob")
    argv.add(scope)
  argv.add(root)
  let rg = findExe("rg")
  try:
    let p = startProcess(rg, args = argv,
                         options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    let outStream = p.outputStream
    var matches: seq[string] = @[]
    var line = ""
    while outStream != nil and outStream.readLine(line):
      # rg lines look like: <absPath>:<lineno>:<text>
      let firstColon = line.find(':')
      if firstColon <= 0:
        continue
      let absPath = line[0 ..< firstColon]
      let rest = line[firstColon + 1 .. ^1]
      if not isPathGated(t, absPath):
        continue
      matches.add(relPath(t, absPath) & ":" & rest)
      if matches.len >= MaxContentMatches:
        # We've got enough; SIGTERM the child by closing the stream.
        # `p.close()` (in defer) will reap it.
        break
    let exitCode = p.waitForExit()
    if matches.len == 0 and exitCode notin {0, 1}:
      # rg exit 0 = matches, 1 = no matches, other = real error.
      return "Error: ripgrep failed (exit " & $exitCode & ")"
    if matches.len == 0:
      return "(no matches for pattern: " & pattern & ")"
    var output = matches.join("\n")
    if matches.len >= MaxContentMatches:
      output.add("\n…capped at " & $MaxContentMatches & " matches; narrow `in` to see more.")
    return output
  except Exception as e:
    return "Error: failed to invoke ripgrep: " & e.msg

proc runFallback(t: FinderTool, pattern, scope: string): string =
  ## Pure-Nim fallback: recursive walk + substring match. No regex, no
  ## .gitignore awareness. Slow on big trees but always available.
  let root = baseRoot(t)
  var matches: seq[string] = @[]
  try:
    for path in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile}):
      if not isPathGated(t, path):
        continue
      let rel = relPath(t, path)
      if scope.len > 0 and not matchGlob(scope, rel):
        continue
      var lineNo = 0
      try:
        for line in lines(path):
          inc lineNo
          if line.contains(pattern):
            matches.add(rel & ":" & $lineNo & ":" & line)
            if matches.len >= MaxContentMatches:
              break
      except IOError:
        # Binary file or permission issue — skip silently. rg does the
        # same by default.
        continue
      if matches.len >= MaxContentMatches:
        break
  except Exception as e:
    return "Error: recursive walk failed: " & e.msg
  if matches.len == 0:
    return "(no matches for pattern: " & pattern & ")"
  var output = matches.join("\n")
  if matches.len >= MaxContentMatches:
    output.add("\n…capped at " & $MaxContentMatches & " matches; narrow `in` to see more.")
  output

proc doContent(t: FinderTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("pattern"):
    return "Error: pattern is required"
  let pattern = args["pattern"].getStr()
  if pattern.len == 0:
    return "Error: pattern must be non-empty"

  let scope =
    if args.hasKey("in"): args["in"].getStr().strip()
    else: ""

  # Existence check on workspace root. Per-path IAM is enforced inside
  # the walkers via `isPathGated` — no need to gate the root itself
  # (Admin agents may lack a directly-policy-matched rule for the bare
  # root path while having access to its contents, which would spuriously
  # short-circuit the entire search).
  let root = baseRoot(t)
  if not dirExists(root):
    return "Error: workspace root does not exist: " & root

  if rgAvailable():
    return runRipgrep(t, pattern, scope)
  runFallback(t, pattern, scope)

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

method execute*(t: FinderTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("method"):
    return "Error: 'method' is required (files | content)"
  let action = getMethodArg(args)
  case action
  of "files":   return doFiles(t, args)
  of "content": return doContent(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: files | content"
