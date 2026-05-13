## fs — single tool for structural filesystem operations (the "sea").
##
## Consolidates the directory/structural operations that previously lived
## across multiple small tools, and adds 6 new structural capabilities
## the framework was missing (exists, info, mkdir, delete, move, copy).
##
## Actions:
##
##   action=list   — list directory entries (preserves list_dir verbatim)
##   action=exists — bool check on a file or directory          [NEW]
##   action=info   — size, mtime, type, permissions             [NEW]
##   action=mkdir  — create directory (optional `parents=true`) [NEW]
##   action=delete — remove file/dir (optional `recursive=true` [NEW]
##                   for non-empty directories)
##   action=move   — rename or move a path                      [NEW]
##   action=copy   — copy a file or directory                   [NEW]
##
## Dependency surface:
##   • workspaceDir  — company workspace root (path-safety boundary)
##   • officeDir     — per-agent office root (alt path-safety boundary)
##   • allowedPaths  — explicit absolute paths the agent may access
##
## Every action routes paths through `resolveAndCheckPath` + `checkAccess`
## from `path_security` / `iam_policies` so the workspace/office boundary
## is preserved verbatim from the legacy file tools.
##
## Replaces the prior `tools/file/{read_file,write_file,list_dir,edit_file,
## append_file}.nim` quintet; see registration in `agent/loop.nim` next to
## the exec + clock block.

import std/[os, json, asyncdispatch, tables, strutils, times, options]
import ./types
import ./spec
import ./path_security
import ./iam_policies
import ./visual/image_info  # imageMetaForFile — fs info auto-detects
                             # image files and includes format + dims

const ToolSpec* = spec(
  name = "fs",
  description = "Structural filesystem ops: list/exists/info/mkdir/delete/move/copy",
  tags = @["filesystem", "data", "core"],
  searchKeywords = @["directory", "folder", "mkdir", "rmdir", "rm", "mv", "cp",
                     "stat", "lstat", "exists", "remove", "rename", "move",
                     "copy", "list", "ls"],
  domain = "file",
  default = true,
  heartbeatSafe = true,  # list/exists/info are read-only; write actions
                          # self-gate via checkAccess inside the action
  category = "files",
)

type
  FsTool* = ref object of ContextualTool
    workspaceDir*: string
    officeDir*: string
    allowedPaths*: seq[string]

proc newFsTool*(workspaceDir: string, officeDir: string = "",
                allowedPaths: seq[string] = @[]): FsTool =
  FsTool(workspaceDir: workspaceDir, officeDir: officeDir,
         allowedPaths: allowedPaths)

method name*(t: FsTool): string = "fs"

method description*(t: FsTool): string =
  "Structural filesystem operations (the 'sea'). Use for layout — listing, " &
  "checking existence, getting metadata, creating/removing directories, " &
  "moving and copying paths.\n\n" &
  "Actions:\n" &
  "  list   — list directory entries (DIR:/FILE: prefixed)\n" &
  "  exists — true/false for path existence\n" &
  "  info   — size, mtime, kind (file|dir|symlink), permissions\n" &
  "  mkdir  — create a directory (parents=true → create intermediate dirs)\n" &
  "  delete — remove file or directory (recursive=true for non-empty dirs)\n" &
  "  move   — rename or move (from → to)\n" &
  "  copy   — copy file or directory (from → to)"

method parameters*(t: FsTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["list", "exists", "info", "mkdir", "delete", "move", "copy"],
        "description": "Operation to perform"
      },
      "path": {
        "type": "string",
        "description": "list/exists/info/mkdir/delete only — target path"
      },
      "from": {
        "type": "string",
        "description": "move/copy only — source path"
      },
      "to": {
        "type": "string",
        "description": "move/copy only — destination path"
      },
      "parents": {
        "type": "boolean",
        "description": "mkdir only — create intermediate directories (default true)"
      },
      "recursive": {
        "type": "boolean",
        "description": "delete only — remove non-empty directories recursively (default false)"
      }
    },
    "required": %["action"]
  }.toTable

# ---------------------------------------------------------------------------
# helpers — path resolution + IAM gating
# ---------------------------------------------------------------------------

proc resolveRead(t: FsTool, path: string,
                 label: string): (string, string) =
  ## Resolve `path` and gate it for READ access. Returns (resolved, "") on
  ## success, or ("", "Error: ...") on failure — caller short-circuits on
  ## the error string.
  let checkResult = resolveAndCheckPath(path, t.workspaceDir,
                                         t.allowedPaths, t.officeDir)
  if checkResult.startsWith("Error:"): return ("", checkResult)
  let wsResolved = expandFilename(t.workspaceDir)
  if not checkAccess(t.role, t.agentName, checkResult, wsResolved, akRead):
    return ("", "Error: IAM Permission Denied (" & label &
            ") for path: " & path)
  (checkResult, "")

proc resolveWrite(t: FsTool, path: string,
                  label: string): (string, string) =
  ## Resolve `path` and gate it for WRITE access. Same return shape as
  ## resolveRead.
  let checkResult = resolveAndCheckPath(path, t.workspaceDir,
                                         t.allowedPaths, t.officeDir)
  if checkResult.startsWith("Error:"): return ("", checkResult)
  let wsResolved = expandFilename(t.workspaceDir)
  if not checkAccess(t.role, t.agentName, checkResult, wsResolved, akWrite):
    return ("", "Error: IAM Permission Denied (" & label &
            ") for path: " & path)
  (checkResult, "")

# ---------------------------------------------------------------------------
# list — preserves list_dir behavior verbatim
# ---------------------------------------------------------------------------

proc doList(t: FsTool, args: Table[string, JsonNode]): string =
  let paramPath = if args.hasKey("path"): args["path"].getStr() else: "."
  let (resolved, err) = resolveRead(t, paramPath, "List")
  if err.len > 0: return err
  try:
    var output = ""
    for kind, entry in walkDir(resolved):
      if kind == pcDir or kind == pcLinkToDir:
        output.add("DIR:  " & lastPathPart(entry) & "\n")
      else:
        output.add("FILE: " & lastPathPart(entry) & "\n")
    return output
  except Exception as e:
    return "Error: failed to read directory: " & e.msg

# ---------------------------------------------------------------------------
# exists — NEW
# ---------------------------------------------------------------------------

proc doExists(t: FsTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("path"): return "Error: path is required"
  let (resolved, err) = resolveRead(t, args["path"].getStr(), "Exists")
  if err.len > 0: return err
  if fileExists(resolved): return "true (file)"
  if dirExists(resolved): return "true (dir)"
  if symlinkExists(resolved): return "true (symlink)"
  "false"

# ---------------------------------------------------------------------------
# info — NEW
# ---------------------------------------------------------------------------

proc doInfo(t: FsTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("path"): return "Error: path is required"
  let (resolved, err) = resolveRead(t, args["path"].getStr(), "Info")
  if err.len > 0: return err
  if not (fileExists(resolved) or dirExists(resolved) or
          symlinkExists(resolved)):
    return "Error: path not found: " & args["path"].getStr()
  try:
    let info = getFileInfo(resolved, followSymlink = false)
    let kind = case info.kind
               of pcFile: "file"
               of pcDir: "dir"
               of pcLinkToFile: "symlink-to-file"
               of pcLinkToDir: "symlink-to-dir"
    var perms = ""
    for p in info.permissions:
      perms.add($p & " ")
    var lines: seq[string] = @[]
    lines.add("path: " & resolved)
    lines.add("kind: " & kind)
    lines.add("size: " & $info.size & " bytes")
    lines.add("mtime: " & info.lastWriteTime.format("yyyy-MM-dd HH:mm:ss"))
    lines.add("atime: " & info.lastAccessTime.format("yyyy-MM-dd HH:mm:ss"))
    lines.add("ctime: " & info.creationTime.format("yyyy-MM-dd HH:mm:ss"))
    lines.add("permissions: " & perms.strip())
    # Image-aware extension: when the file is an image (detected by
    # magic bytes), append format + dimensions. No-op for non-images.
    if info.kind == pcFile or info.kind == pcLinkToFile:
      let meta = imageMetaForFile(resolved)
      if meta.format != "unknown":
        lines.add("format: " & meta.format)
        if meta.dims.isSome:
          let (w, h) = meta.dims.get
          lines.add("dimensions: " & $w & "x" & $h)
    return lines.join("\n")
  except Exception as e:
    return "Error: failed to stat path: " & e.msg

# ---------------------------------------------------------------------------
# mkdir — NEW
# ---------------------------------------------------------------------------

proc doMkdir(t: FsTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("path"): return "Error: path is required"
  let path = args["path"].getStr()
  let (resolved, err) = resolveWrite(t, path, "Mkdir")
  if err.len > 0: return err
  let parents = if args.hasKey("parents"): args["parents"].getBool(true) else: true
  try:
    if parents:
      createDir(resolved)
    else:
      # Non-recursive mkdir: parent must already exist; createDir is
      # always recursive, so emulate single-level by checking parent.
      let parent = parentDir(resolved)
      if parent.len > 0 and not dirExists(parent):
        return "Error: parent directory does not exist (pass parents=true to create intermediates): " & parent
      createDir(resolved)
    return "Created directory: " & path
  except Exception as e:
    return "Error: failed to create directory: " & e.msg

# ---------------------------------------------------------------------------
# delete — NEW
# ---------------------------------------------------------------------------

proc doDelete(t: FsTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("path"): return "Error: path is required"
  let path = args["path"].getStr()
  let (resolved, err) = resolveWrite(t, path, "Delete")
  if err.len > 0: return err
  let recursive = if args.hasKey("recursive"): args["recursive"].getBool(false) else: false
  try:
    if fileExists(resolved) or symlinkExists(resolved):
      removeFile(resolved)
      return "Deleted file: " & path
    elif dirExists(resolved):
      # Empty-dir check — if non-empty and recursive=false, refuse.
      var hasChildren = false
      for _, _ in walkDir(resolved):
        hasChildren = true
        break
      if hasChildren and not recursive:
        return "Error: directory not empty (pass recursive=true to delete contents): " & path
      removeDir(resolved)
      return "Deleted directory: " & path
    else:
      return "Error: path not found: " & path
  except Exception as e:
    return "Error: failed to delete: " & e.msg

# ---------------------------------------------------------------------------
# move — NEW
# ---------------------------------------------------------------------------

proc doMove(t: FsTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("from"): return "Error: from is required"
  if not args.hasKey("to"): return "Error: to is required"
  let fromPath = args["from"].getStr()
  let toPath = args["to"].getStr()
  # Move requires write on BOTH source (removal) and destination (creation).
  let (srcResolved, srcErr) = resolveWrite(t, fromPath, "Move-src")
  if srcErr.len > 0: return srcErr
  let (dstResolved, dstErr) = resolveWrite(t, toPath, "Move-dst")
  if dstErr.len > 0: return dstErr
  if not (fileExists(srcResolved) or dirExists(srcResolved) or
          symlinkExists(srcResolved)):
    return "Error: source not found: " & fromPath
  try:
    # Ensure destination parent exists.
    let dstParent = parentDir(dstResolved)
    if dstParent.len > 0 and not dirExists(dstParent):
      createDir(dstParent)
    if dirExists(srcResolved):
      moveDir(srcResolved, dstResolved)
    else:
      moveFile(srcResolved, dstResolved)
    return "Moved: " & fromPath & " → " & toPath
  except Exception as e:
    return "Error: failed to move: " & e.msg

# ---------------------------------------------------------------------------
# copy — NEW
# ---------------------------------------------------------------------------

proc doCopy(t: FsTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("from"): return "Error: from is required"
  if not args.hasKey("to"): return "Error: to is required"
  let fromPath = args["from"].getStr()
  let toPath = args["to"].getStr()
  # Copy: source needs read, dest needs write.
  let (srcResolved, srcErr) = resolveRead(t, fromPath, "Copy-src")
  if srcErr.len > 0: return srcErr
  let (dstResolved, dstErr) = resolveWrite(t, toPath, "Copy-dst")
  if dstErr.len > 0: return dstErr
  if not (fileExists(srcResolved) or dirExists(srcResolved) or
          symlinkExists(srcResolved)):
    return "Error: source not found: " & fromPath
  try:
    let dstParent = parentDir(dstResolved)
    if dstParent.len > 0 and not dirExists(dstParent):
      createDir(dstParent)
    if dirExists(srcResolved):
      copyDir(srcResolved, dstResolved)
    else:
      copyFile(srcResolved, dstResolved)
    return "Copied: " & fromPath & " → " & toPath
  except Exception as e:
    return "Error: failed to copy: " & e.msg

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

method execute*(t: FsTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (list | exists | info | mkdir | delete | move | copy)"
  let action = args["action"].getStr()
  case action
  of "list":   return doList(t, args)
  of "exists": return doExists(t, args)
  of "info":   return doInfo(t, args)
  of "mkdir":  return doMkdir(t, args)
  of "delete": return doDelete(t, args)
  of "move":   return doMove(t, args)
  of "copy":   return doCopy(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: list | exists | info | mkdir | delete | move | copy"
