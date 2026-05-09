import std/[os, json, asyncdispatch, tables, strutils]
import ../types
import ../spec
import ../path_security
import ../iam_policies

const ToolSpec* = spec(
  name = "append_file",
  description = "append content to existing files",
  tags = @["filesystem", "data"],
  domain = "file",
  default = true,
  heartbeatSafe = false,
  category = "files",
)

type
  AppendFileTool* = ref object of ContextualTool
    workspaceDir*: string
    allowedPaths*: seq[string]

proc newAppendFileTool*(workspaceDir: string,
                        allowedPaths: seq[string] = @[]): AppendFileTool =
  AppendFileTool(workspaceDir: workspaceDir, allowedPaths: allowedPaths)

method name*(t: AppendFileTool): string = "append_file"
method description*(t: AppendFileTool): string = "Append content to the end of a file. Use this for logging or modifying code. Do NOT use this for reminders (use cron) or for storing long-term abstract facts (use memory_store). If writing to user memory/notes directly, ensure the path is correctly prefixed with 'memory/' or 'notes/'."
method parameters*(t: AppendFileTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {"type": "string", "description": "The file path to append to"},
      "content": {"type": "string", "description": "The content to append"}
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
