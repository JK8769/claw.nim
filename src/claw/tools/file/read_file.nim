import std/[os, json, asyncdispatch, tables, strutils]
import ../types
import ../spec
import ../path_security
import ../iam_policies

const ToolSpec* = spec(
  name = "read_file",
  description = "read file contents from disk",
  tags = @["filesystem", "data", "core"],
  domain = "file",
  default = true,
  heartbeatSafe = true,
  category = "files",
)

type
  ReadFileTool* = ref object of ContextualTool
    workspaceDir*: string
    officeDir*: string
    allowedPaths*: seq[string]

proc newReadFileTool*(workspaceDir: string, officeDir: string = "",
                      allowedPaths: seq[string] = @[]): ReadFileTool =
  ReadFileTool(workspaceDir: workspaceDir, officeDir: officeDir,
                allowedPaths: allowedPaths)

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

  let checkResult = resolveAndCheckPath(args["path"].getStr(), t.workspaceDir,
                                         t.allowedPaths, t.officeDir)
  if checkResult.startsWith("Error:"): return checkResult

  let wsResolved = expandFilename(t.workspaceDir)
  if not checkAccess(t.role, t.agentName, checkResult, wsResolved, akRead):
    return "Error: IAM Permission Denied (Read) for path: " & args["path"].getStr()

  try:
    return readFile(checkResult)
  except Exception as e:
    return "Error: failed to read file: " & e.msg
