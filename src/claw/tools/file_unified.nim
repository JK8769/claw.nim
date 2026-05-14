## file — single tool for content I/O on ONE file (the "ship").
##
## Consolidates the 4 existing per-file content tools:
##
##   method=read   — read file contents (preserves read_file; ADD
##                   optional offset/limit for line-based chunking)
##   method=write  — create or replace a file (preserves write_file)
##   method=edit   — find/replace one occurrence (preserves edit_file;
##                   ADD replace_all flag for global substitution)
##   method=append — append content to end of file (preserves
##                   append_file)
##
## Dependency surface:
##   • workspaceDir  — company workspace root (path-safety boundary)
##   • officeDir     — per-agent office root (alt path-safety boundary)
##   • allowedPaths  — explicit absolute paths the agent may access
##
## Path safety + IAM gating is preserved verbatim from the legacy file
## tools — every action routes paths through `resolveAndCheckPath` and
## `checkAccess`.
##
## ---------------------------------------------------------------------------
## Registration changes for src/claw/agent/loop.nim
## ---------------------------------------------------------------------------
##
## See `fs_unified.nim` header for the consolidated remove/add list — the
## 5 deletes + 3 adds are shared across all three new unified files; we
## just register all 3 here.
##
## TODO (v2): multimodal read — handle PDF (use anthropic-skills:pdf
## pipeline or shell out to `pdftotext`) and image (return inline as
## base64 with mime-type for vision-capable LLMs). Today, method=read
## treats every file as plain UTF-8 text. Until multimodal lands,
## callers should use `capability method=invoke tag=vision input=<path>`
## for images and the PDF skill for PDFs.

import std/[os, json, asyncdispatch, tables, strutils]
import ./types
import ./spec
import ./path_security
import ./iam_policies

const ToolSpec* = spec(
  name = "file",
  description = "Single-file content I/O: read/write/edit/append",
  tags = @["filesystem", "data", "core"],
  searchKeywords = @["read", "write", "edit", "append", "modify", "change",
                     "update", "rewrite", "replace", "patch", "fix", "open",
                     "load", "save", "create"],
  domain = "file",
  default = true,
  heartbeatSafe = true,  # read action is heartbeat-safe; write/edit/append
                          # self-gate via checkAccess inside the action
  category = "files",
)

type
  FileTool* = ref object of ContextualTool
    workspaceDir*: string
    officeDir*: string
    allowedPaths*: seq[string]

proc newFileTool*(workspaceDir: string, officeDir: string = "",
                  allowedPaths: seq[string] = @[]): FileTool =
  FileTool(workspaceDir: workspaceDir, officeDir: officeDir,
           allowedPaths: allowedPaths)

method name*(t: FileTool): string = "file"

method description*(t: FileTool): string =
  "Single-file content I/O (the 'ship'). Use for the contents of one " &
  "specific file at a time — read, write, edit (find/replace), append. " &
  "Do NOT use append for reminders (use cron) or long-term abstract " &
  "facts (use memory_store). When writing to user memory/notes directly, " &
  "ensure the path is correctly prefixed with 'memory/' or 'notes/'.\n\n" &
  "Actions:\n" &
  "  read   — read contents; optional offset/limit for line-based chunking\n" &
  "  write  — create or replace a file\n" &
  "  edit   — find/replace; default single-occurrence (replace_all=true for global)\n" &
  "  append — append to end of file"

method parameters*(t: FileTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["read", "write", "edit", "append"],
        "description": "Operation to perform"
      },
      "path": {
        "type": "string",
        "description": "File path (all actions)"
      },
      # --- method=read ---
      "offset": {
        "type": "integer",
        "description": "read only — 1-based line offset to start reading from (default 1 = top of file)"
      },
      "limit": {
        "type": "integer",
        "description": "read only — max number of lines to return (default: all)"
      },
      # --- method=write / method=append ---
      "content": {
        "type": "string",
        "description": "write/append only — content to write or append"
      },
      # --- method=edit ---
      "old": {
        "type": "string",
        "description": "edit only — exact text to find and replace"
      },
      "new": {
        "type": "string",
        "description": "edit only — replacement text"
      },
      "replace_all": {
        "type": "boolean",
        "description": "edit only — replace every occurrence (default false: refuses if old appears >1 time)"
      }
    },
    "required": %["action", "path"]
  }.toTable

# ---------------------------------------------------------------------------
# helpers — path resolution + IAM gating
# ---------------------------------------------------------------------------

proc resolveForRead(t: FileTool, path: string,
                    label: string): (string, string) =
  let checkResult = resolveAndCheckPath(path, t.workspaceDir,
                                         t.allowedPaths, t.officeDir)
  if checkResult.startsWith("Error:"): return ("", checkResult)
  let wsResolved = expandFilename(t.workspaceDir)
  if not checkAccess(t.role, t.agentName, checkResult, wsResolved, akRead):
    return ("", "Error: IAM Permission Denied (" & label &
            ") for path: " & path)
  (checkResult, "")

proc resolveForWrite(t: FileTool, path: string,
                     label: string): (string, string) =
  let checkResult = resolveAndCheckPath(path, t.workspaceDir,
                                         t.allowedPaths, t.officeDir)
  if checkResult.startsWith("Error:"): return ("", checkResult)
  let wsResolved = expandFilename(t.workspaceDir)
  if not checkAccess(t.role, t.agentName, checkResult, wsResolved, akWrite):
    return ("", "Error: IAM Permission Denied (" & label &
            ") for path: " & path)
  (checkResult, "")

# ---------------------------------------------------------------------------
# read — preserves read_file; adds offset/limit
# ---------------------------------------------------------------------------

proc doRead(t: FileTool, args: Table[string, JsonNode]): string =
  ## Preserves read_file behavior verbatim when neither offset nor limit
  ## is provided — full UTF-8 read. With offset/limit, returns a window of
  ## lines (1-based offset, like editors and `sed -n`).
  ##
  ## TODO (v2): handle images (return base64 + mime for vision LLMs) and
  ## PDFs (shell out to pdftotext or invoke the pdf skill). For v1 we
  ## treat every file as text — same as the legacy read_file.
  if not args.hasKey("path"): return "Error: path is required"
  let (resolved, err) = resolveForRead(t, args["path"].getStr(), "Read")
  if err.len > 0: return err

  let hasOffset = args.hasKey("offset")
  let hasLimit = args.hasKey("limit")
  try:
    # Fast path — no chunking → exact legacy behavior.
    if not hasOffset and not hasLimit:
      return readFile(resolved)
    let content = readFile(resolved)
    let lines = content.splitLines()
    var offset = if hasOffset: args["offset"].getInt(1) else: 1
    if offset < 1: offset = 1
    var limit = if hasLimit: args["limit"].getInt(0) else: 0
    let startIdx = offset - 1  # 1-based → 0-based
    if startIdx >= lines.len:
      return ""  # offset past EOF → empty
    var endIdx =
      if limit > 0: min(startIdx + limit, lines.len)
      else: lines.len
    return lines[startIdx ..< endIdx].join("\n")
  except Exception as e:
    return "Error: failed to read file: " & e.msg

# ---------------------------------------------------------------------------
# write — preserves write_file verbatim
# ---------------------------------------------------------------------------

proc doWrite(t: FileTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("content"): return "Error: content is required"
  let (resolved, err) = resolveForWrite(t, args["path"].getStr(), "Write")
  if err.len > 0: return err
  let content = args["content"].getStr()
  let dir = parentDir(resolved)
  try:
    if dir != "" and not dirExists(dir):
      createDir(dir)
    writeFile(resolved, content)
    return "File written successfully"
  except Exception as e:
    return "Error: failed to write file: " & e.msg

# ---------------------------------------------------------------------------
# edit — preserves edit_file; adds replace_all flag
# ---------------------------------------------------------------------------

proc doEdit(t: FileTool, args: Table[string, JsonNode]): string =
  ## Preserves edit_file logic verbatim under the default `replace_all=false`
  ## branch (find/replace a single unique occurrence; refuse multi-match).
  ## Adds an explicit opt-in `replace_all=true` that uses strutils.replace
  ## to substitute every occurrence — useful for variable renames where
  ## the LLM legitimately wants to update all sites.
  if not args.hasKey("old"): return "Error: old is required"
  if not args.hasKey("new"): return "Error: new is required"
  let path = args["path"].getStr()
  let oldText = args["old"].getStr()
  let newText = args["new"].getStr()
  let replaceAll = if args.hasKey("replace_all"): args["replace_all"].getBool(false) else: false

  let (resolved, err) = resolveForWrite(t, path, "Edit")
  if err.len > 0: return err
  if not fileExists(resolved):
    return "Error: file not found: " & path

  try:
    let content = readFile(resolved)
    if not content.contains(oldText):
      return "Error: old text not found in file. Make sure it matches exactly"
    if not replaceAll:
      let count = content.count(oldText)
      if count > 1:
        return "Error: old text appears $1 times. Please provide more context to make it unique, or pass replace_all=true".format(count)
    let newContent = content.replace(oldText, newText)
    writeFile(resolved, newContent)
    if replaceAll:
      let count = content.count(oldText)
      return "Successfully edited " & path & " (" & $count & " replacement" &
             (if count == 1: "" else: "s") & ")"
    return "Successfully edited " & path
  except Exception as e:
    return "Error: failed to edit file: " & e.msg

# ---------------------------------------------------------------------------
# append — preserves append_file verbatim
# ---------------------------------------------------------------------------

proc doAppend(t: FileTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("content"): return "Error: content is required"
  let path = args["path"].getStr()
  let content = args["content"].getStr()
  let (resolved, err) = resolveForWrite(t, path, "Append")
  if err.len > 0: return err
  try:
    let f = open(resolved, fmAppend)
    f.write(content)
    f.close()
    return "Successfully appended to " & path
  except Exception as e:
    return "Error: failed to append to file: " & e.msg

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

method execute*(t: FileTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not (args.hasKey("method") or args.hasKey("action")):
    return "Error: 'action' is required (read | write | edit | append)"
  if not args.hasKey("path"):
    return "Error: 'path' is required"
  let action = getMethodArg(args)
  case action
  of "read":   return doRead(t, args)
  of "write":  return doWrite(t, args)
  of "edit":   return doEdit(t, args)
  of "append": return doAppend(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: read | write | edit | append"
