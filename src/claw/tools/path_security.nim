import std/[os, strutils]

const SYSTEM_BLOCKED_PREFIXES_UNIX = [
  "/System", "/Library", "/bin", "/sbin", "/usr/bin", "/usr/sbin",
  "/usr/lib", "/usr/libexec", "/etc", "/private/etc", "/private/var",
  "/dev", "/boot", "/proc", "/sys"
]

const SYSTEM_BLOCKED_PREFIXES_WINDOWS = [
  "C:\\Windows", "C:\\Program Files", "C:\\Program Files (x86)",
  "C:\\ProgramData", "C:\\System32", "C:\\Recovery"
]

when defined(windows):
  const SYSTEM_BLOCKED_PREFIXES* = SYSTEM_BLOCKED_PREFIXES_WINDOWS
else:
  const SYSTEM_BLOCKED_PREFIXES* = SYSTEM_BLOCKED_PREFIXES_UNIX

proc pathStartsWith*(path, prefix: string): bool =
  let p = path.normalizedPath()
  let pref = prefix.normalizedPath()

  if p == pref: return true

  when defined(windows):
    let pl = p.toLowerAscii()
    let prefl = pref.toLowerAscii()
    if pl.startsWith(prefl):
      let remain = pl[prefl.len .. ^1]
      if remain.startsWith("/") or remain.startsWith("\\") or remain == "": return true
  else:
    if p.startsWith(pref):
      let remain = p[pref.len .. ^1]
      if remain.startsWith("/") or remain.startsWith("\\") or remain == "": return true
  return false

proc isPathSafe*(path: string): bool =
  if isAbsolute(path): return false
  if path.contains("\x00"): return false

  let parts = path.split({ '/', '\\' })
  for part in parts:
    if part == "..": return false

  let lower = path.toLowerAscii()
  if lower.contains("..%2f") or lower.contains("%2f..") or lower.contains("..%5c") or lower.contains("%5c.."):
    return false

  return true

proc isResolvedPathAllowed*(resolved, ws_resolved: string, allowed_paths: seq[string], office_dir: string = ""): bool =
  for prefix in SYSTEM_BLOCKED_PREFIXES:
    if pathStartsWith(resolved, prefix): return false

  if pathStartsWith(resolved, ws_resolved): return true
  if office_dir != "" and pathStartsWith(resolved, office_dir): return true

  for ap in allowed_paths:
    let trimmed = ap.strip()
    if trimmed == "": continue
    if trimmed == "*": return true
    try:
      let ap_resolved = absolutePath(trimmed)
      if pathStartsWith(resolved, ap_resolved): return true
    except Exception:
      continue

  return false

proc resolveAndCheckPath*(path, workspaceDir: string, allowedPaths: seq[string], officeDir: string = ""): string =
  ## Resolves a path and checks it against security policies.
  ## Returns the resolved path on success, or an error string starting with "Error:".
  var fullPath = path
  if not isAbsolute(path):
    if not isPathSafe(path): return "Error: path not allowed (contains traversal or invalid chars)"

    if officeDir != "":
      fullPath = officeDir / path
      if path.startsWith("competencies") or path.startsWith("portal") or path.startsWith("memos") or path.startsWith("handbook"):
        fullPath = workspaceDir / path
    else:
      fullPath = workspaceDir / path
  else:
    if allowedPaths.len == 0: return "Error: absolute paths not allowed (no allowed paths configured)"

  var resolved = ""
  try:
    resolved = absolutePath(fullPath)
    if fileExists(fullPath) or dirExists(fullPath):
      resolved = expandFilename(fullPath)
  except OSError:
    discard

  let wsResolved = expandFilename(workspaceDir)
  let officeResolved = if officeDir != "": expandFilename(officeDir) else: ""

  if not isResolvedPathAllowed(resolved, wsResolved, allowedPaths, officeResolved):
    return "Error: Path is outside allowed areas or blocked by security policy. Path: " & resolved

  return resolved
