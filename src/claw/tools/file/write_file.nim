import std/[os, json, asyncdispatch, tables, strutils]
import ../types
import ../spec
import ../path_security
import ../iam_policies

const ToolSpec* = spec(
  name = "write_file",
  description = "write or create files on disk",
  tags = @["filesystem", "data", "core"],
  domain = "file",
  default = true,
  heartbeatSafe = false,
  category = "files",
)

type
  WriteFileTool* = ref object of ContextualTool
    workspaceDir*: string
    officeDir*: string
    allowedPaths*: seq[string]

proc newWriteFileTool*(workspaceDir: string, officeDir: string = "",
                       allowedPaths: seq[string] = @[]): WriteFileTool =
  WriteFileTool(workspaceDir: workspaceDir, officeDir: officeDir,
                 allowedPaths: allowedPaths)

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

  let checkResult = resolveAndCheckPath(args["path"].getStr(), t.workspaceDir,
                                         t.allowedPaths, t.officeDir)
  if checkResult.startsWith("Error:"): return checkResult

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
