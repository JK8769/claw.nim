import std/[os, json, asyncdispatch, tables, strutils]
import ../types
import ../spec
import ../path_security
import ../iam_policies

const ToolSpec* = spec(
  name = "edit_file",
  description = "edit files with find and replace",
  tags = @["filesystem", "data", "core"],
  domain = "file",
  default = true,
  heartbeatSafe = false,
  category = "files",
)

type
  EditFileTool* = ref object of ContextualTool
    workspaceDir*: string
    allowedPaths*: seq[string]

proc newEditFileTool*(workspaceDir: string,
                      allowedPaths: seq[string] = @[]): EditFileTool =
  EditFileTool(workspaceDir: workspaceDir, allowedPaths: allowedPaths)

method name*(t: EditFileTool): string = "edit_file"
method description*(t: EditFileTool): string = "Edit a file by replacing old_text with new_text. The old_text must exist exactly in the file."
method parameters*(t: EditFileTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {"type": "string", "description": "The file path to edit"},
      "old_text": {"type": "string", "description": "The exact text to find and replace"},
      "new_text": {"type": "string", "description": "The text to replace with"}
    },
    "required": %["path", "old_text", "new_text"]
  }.toTable

method execute*(t: EditFileTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("path"): return "Error: path is required"
  if not args.hasKey("old_text"): return "Error: old_text is required"
  if not args.hasKey("new_text"): return "Error: new_text is required"

  let path = args["path"].getStr()
  let oldText = args["old_text"].getStr()
  let newText = args["new_text"].getStr()

  let resolvedPath = resolveAndCheckPath(path, t.workspaceDir, t.allowedPaths)
  if resolvedPath.startsWith("Error:"): return resolvedPath

  let wsResolved = expandFilename(t.workspaceDir)
  if not checkAccess(t.role, t.agentName, resolvedPath, wsResolved, akWrite):
    return "Error: IAM Permission Denied (Edit/Write) for path: " & path

  if not fileExists(resolvedPath):
    return "Error: file not found: " & path

  try:
    let content = readFile(resolvedPath)
    if not content.contains(oldText):
      return "Error: old_text not found in file. Make sure it matches exactly"

    let count = content.count(oldText)
    if count > 1:
      return "Error: old_text appears $1 times. Please provide more context to make it unique".format(count)

    let newContent = content.replace(oldText, newText)
    writeFile(resolvedPath, newContent)
    return "Successfully edited " & path
  except Exception as e:
    return "Error: failed to edit file: " & e.msg
