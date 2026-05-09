import std/[os, json, asyncdispatch, tables, strutils]
import ../types
import ../spec
import ../path_security
import ../iam_policies

const ToolSpec* = spec(
  name = "list_dir",
  description = "list directory contents",
  tags = @["filesystem", "data", "core"],
  domain = "file",
  default = true,
  heartbeatSafe = true,
  category = "files",
)

type
  ListDirTool* = ref object of ContextualTool
    workspaceDir*: string
    officeDir*: string
    allowedPaths*: seq[string]

proc newListDirTool*(workspaceDir: string, officeDir: string = "",
                     allowedPaths: seq[string] = @[]): ListDirTool =
  ListDirTool(workspaceDir: workspaceDir, officeDir: officeDir,
               allowedPaths: allowedPaths)

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

  let checkResult = resolveAndCheckPath(paramPath, t.workspaceDir,
                                         t.allowedPaths, t.officeDir)
  if checkResult.startsWith("Error:"): return checkResult

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
