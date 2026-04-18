import std/[os, json, asyncdispatch, tables, strutils]
import types
import path_security
import iam_policies

type
  ReadFileTool* = ref object of ContextualTool
    workspaceDir*: string
    officeDir*: string
    allowedPaths*: seq[string]
  
  WriteFileTool* = ref object of ContextualTool
    workspaceDir*: string
    officeDir*: string
    allowedPaths*: seq[string]
    
  ListDirTool* = ref object of ContextualTool
    workspaceDir*: string
    officeDir*: string
    allowedPaths*: seq[string]


proc newReadFileTool*(workspaceDir: string, officeDir: string = "", allowedPaths: seq[string] = @[]): ReadFileTool =
  ReadFileTool(workspaceDir: workspaceDir, officeDir: officeDir, allowedPaths: allowedPaths)

proc newWriteFileTool*(workspaceDir: string, officeDir: string = "", allowedPaths: seq[string] = @[]): WriteFileTool =
  WriteFileTool(workspaceDir: workspaceDir, officeDir: officeDir, allowedPaths: allowedPaths)

proc newListDirTool*(workspaceDir: string, officeDir: string = "", allowedPaths: seq[string] = @[]): ListDirTool =
  ListDirTool(workspaceDir: workspaceDir, officeDir: officeDir, allowedPaths: allowedPaths)

# ReadFileTool
method name*(t: ReadFileTool): string = "read_file"
method description*(t: ReadFileTool): string = "Read the contents of a file"
method parameters*(t: ReadFileTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {
        "type": "string",
        "description": "Path to the file to read"
      }
    },
    "required": %["path"]
  }.toTable

method execute*(t: ReadFileTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("path"): return "Error: path is required"
  
  let checkResult = resolveAndCheckPath(args["path"].getStr(), t.workspaceDir, t.allowedPaths, t.officeDir)
  if checkResult.startsWith("Error:"): return checkResult
  
  # IAM Policy Check
  let wsResolved = expandFilename(t.workspaceDir)
  if not checkAccess(t.role, t.agentName, checkResult, wsResolved, akRead):
    return "Error: IAM Permission Denied (Read) for path: " & args["path"].getStr()

  
  try:
    return readFile(checkResult)
  except Exception as e:
    return "Error: failed to read file: " & e.msg

# WriteFileTool
method name*(t: WriteFileTool): string = "write_file"
method description*(t: WriteFileTool): string = "Write content to a file"
method parameters*(t: WriteFileTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {
        "type": "string",
        "description": "Path to the file to write"
      },
      "content": {
        "type": "string",
        "description": "Content to write to the file"
      }
    },
    "required": %["path", "content"]
  }.toTable

method execute*(t: WriteFileTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("path"): return "Error: path is required"
  if not args.hasKey("content"): return "Error: content is required"
  
  let checkResult = resolveAndCheckPath(args["path"].getStr(), t.workspaceDir, t.allowedPaths, t.officeDir)
  if checkResult.startsWith("Error:"): return checkResult
  
  # IAM Policy Check
  let wsResolved = expandFilename(t.workspaceDir)
  if not checkAccess(t.role, t.agentName, checkResult, wsResolved, akWrite):
    return "Error: IAM Permission Denied (Write) for path: " & args["path"].getStr()

  
  let content = args["content"].getStr()
  let dir = parentDir(checkResult)
  try:
    if dir != "" and not dirExists(dir):
      createDir(dir)
    writeFile(checkResult, content)
    return "File written successfully"
  except Exception as e:
    return "Error: failed to write file: " & e.msg

# ListDirTool
method name*(t: ListDirTool): string = "list_dir"
method description*(t: ListDirTool): string = "List files and directories in a path"
method parameters*(t: ListDirTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {
        "type": "string",
        "description": "Path to list"
      }
    },
    "required": %["path"]
  }.toTable

method execute*(t: ListDirTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let paramPath = if args.hasKey("path"): args["path"].getStr() else: "."
  
  let checkResult = resolveAndCheckPath(paramPath, t.workspaceDir, t.allowedPaths, t.officeDir)
  if checkResult.startsWith("Error:"): return checkResult
  
  # IAM Policy Check
  let wsResolved = expandFilename(t.workspaceDir)
  if not checkAccess(t.role, t.agentName, checkResult, wsResolved, akRead):
    return "Error: IAM Permission Denied (List) for path: " & paramPath

  
  try:
    var result = ""
    for kind, entry in walkDir(checkResult):
      if kind == pcDir or kind == pcLinkToDir:
        result.add("DIR:  " & lastPathPart(entry) & "\n")
      else:
        result.add("FILE: " & lastPathPart(entry) & "\n")
    return result
  except Exception as e:
    return "Error: failed to read directory: " & e.msg
