import std/[os, json, asyncdispatch, tables, strutils]
import types
import path_security
import iam_policies

type
  EditFileTool* = ref object of ContextualTool
    workspaceDir*: string
    allowedPaths*: seq[string]


proc newEditFileTool*(workspaceDir: string, allowedPaths: seq[string] = @[]): EditFileTool =
  EditFileTool(workspaceDir: workspaceDir, allowedPaths: allowedPaths)

method name*(t: EditFileTool): string = "edit_file"
method description*(t: EditFileTool): string = "Edit a file by replacing old_text with new_text. The old_text must exist exactly in the file."
method parameters*(t: EditFileTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {
        "type": "string",
        "description": "The file path to edit"
      },
      "old_text": {
        "type": "string",
        "description": "The exact text to find and replace"
      },
      "new_text": {
        "type": "string",
        "description": "The text to replace with"
      }
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

  # IAM Policy Check
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

type
  AppendFileTool* = ref object of ContextualTool
    workspaceDir*: string
    allowedPaths*: seq[string]


proc newAppendFileTool*(workspaceDir: string, allowedPaths: seq[string] = @[]): AppendFileTool =
  AppendFileTool(workspaceDir: workspaceDir, allowedPaths: allowedPaths)

method name*(t: AppendFileTool): string = "append_file"
method description*(t: AppendFileTool): string = "Append content to the end of a file. Use this for logging or modifying code. Do NOT use this for reminders (use cron) or for storing long-term abstract facts (use memory_store). If writing to user memory/notes directly, ensure the path is correctly prefixed with 'memory/' or 'notes/'."
method parameters*(t: AppendFileTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {
        "type": "string",
        "description": "The file path to append to"
      },
      "content": {
        "type": "string",
        "description": "The content to append"
      }
    },
    "required": %["path", "content"]
  }.toTable

method execute*(t: AppendFileTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("path"): return "Error: path is required"
  if not args.hasKey("content"): return "Error: content is required"

  let path = args["path"].getStr()
  let content = args["content"].getStr()

  let resolvedPath = resolveAndCheckPath(path, t.workspaceDir, t.allowedPaths)
  if resolvedPath.startsWith("Error:"): return resolvedPath

  # IAM Policy Check
  let wsResolved = expandFilename(t.workspaceDir)
  if not checkAccess(t.role, t.agentName, resolvedPath, wsResolved, akWrite):
    return "Error: IAM Permission Denied (Append/Write) for path: " & path


  try:
    let f = open(resolvedPath, fmAppend)
    f.write(content)
    f.close()
    return "Successfully appended to " & path
  except Exception as e:
    return "Error: failed to append to file: " & e.msg
