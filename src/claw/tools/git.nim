import std/[os, json, tables, osproc, strutils, asyncdispatch]
import types
import path_security
import iam_policies

type
  GitTool* = ref object of ContextualTool
    workspaceDir*: string
    allowedPaths*: seq[string]
    officeDir*: string


proc newGitTool*(workspaceDir: string, allowedPaths: seq[string] = @[], officeDir: string = ""): GitTool =
  GitTool(workspaceDir: workspaceDir, allowedPaths: allowedPaths, officeDir: officeDir)

method name*(t: GitTool): string = "git_operations"

method description*(t: GitTool): string = "Perform structured Git operations (status, diff, log, branch, commit, add, checkout, stash)."

method parameters*(t: GitTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "operation": {
        "type": "string",
        "enum": ["status", "diff", "log", "branch", "commit", "add", "checkout", "stash"],
        "description": "Git operation to perform"
      },
      "message": {"type": "string", "description": "Commit message (for commit)"},
      "paths": {
        "oneOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}],
        "description": "File paths (for add). Prefer array for multiple files."
      },
      "branch": {"type": "string", "description": "Branch name (for checkout)"},
      "files": {
        "oneOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}],
        "description": "Files to diff. Prefer array for multiple files."
      },
      "cached": {"type": "boolean", "description": "Show staged changes (diff)"},
      "limit": {"type": "integer", "description": "Log entry count (default: 10)"},
      "cwd": {
        "type": "string", 
        "description": "Repository directory (absolute path within allowed paths; defaults to workspace)"
      }
    },
    "required": %["operation"]
  }.toTable

proc sanitizeGitArgs*(args: string): bool =
  ## Returns false if the git arguments contain dangerous patterns.
  const dangerousPrefixes = [
    "--exec=", "--upload-pack=", "--receive-pack=", "--pager=", "--editor="
  ]
  const dangerousExact = ["--no-verify"]
  const dangerousSubstrings = ["$(", "`"]
  const dangerousChars = ['|', ';', '>']

  for argRaw in strutils.splitWhitespace(args):
    let arg = argRaw.strip()
    if arg.len == 0: continue
    
    let lowerArg = arg.toLowerAscii()
    for prefix in dangerousPrefixes:
      if lowerArg.startsWith(prefix): return false
      
    for exact in dangerousExact:
      if lowerArg == exact: return false
      
    for sub in dangerousSubstrings:
      if arg.contains(sub): return false
      
    for c in arg:
      if c in dangerousChars: return false
      
    if arg.len == 2 and arg[0] == '-' and (arg[1] == 'c' or arg[1] == 'C'): return false
    if arg.len > 2 and arg[0] == '-' and (arg[1] == 'c' or arg[1] == 'C') and arg[2] == '=': return false

  return true

proc truncateCommitMessage*(msg: string, maxBytes: int): string =
  if msg.len <= maxBytes: return msg
  var i = maxBytes
  while i > 0 and (uint8(msg[i]) and 0xC0) == 0x80: dec i
  return msg[0 ..< i]

proc runGitOp(t: GitTool, cwd: string, args: openArray[string]): string =
  var cmdArgs = @["git"]
  for a in args: cmdArgs.add(a)

  try:
    let (output, exitCode) = execCmdEx(cmdArgs.join(" "), {poStdErrToStdOut, poUsePath}, workingDir = cwd)
    if exitCode != 0:
      return "Error: Git operation failed:\n" & output
    return output
  except Exception as e:
    return "Error: " & e.msg

method execute*(t: GitTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("operation"):
    return "Error: Missing 'operation' parameter"
    
  let operation = args["operation"].getStr()
  
  # Sanitize string args
  for field in ["message", "paths", "branch", "files", "action"]:
    if args.hasKey(field) and args[field].kind == JString:
      if not sanitizeGitArgs(args[field].getStr()):
        return "Error: Unsafe git arguments detected"
        
  # Sanitize array args
  for field in ["paths", "files"]:
    if args.hasKey(field) and args[field].kind == JArray:
      for item in args[field].getElems():
        if item.kind == JString:
          if not sanitizeGitArgs(item.getStr()):
             return "Error: Unsafe git arguments detected"

  var cwd = t.workspaceDir
  if args.hasKey("cwd") and args["cwd"].kind == JString:
    let reqCwd = args["cwd"].getStr()
    if not isResolvedPathAllowed(reqCwd, t.workspaceDir, t.allowedPaths, t.officeDir):
      return "Error: cwd is outside allowed areas"
    cwd = reqCwd

  # IAM Policy Check
  let wsResolved = expandFilename(t.workspaceDir)
  let accessRequested = if operation in ["status", "diff", "log", "branch", "stash"]: akRead else: akWrite
  if not checkAccess(t.role, t.agentName, cwd, wsResolved, accessRequested):
    return "Error: IAM Permission Denied ($1) for repository at: $2".format($accessRequested, cwd)


  case operation
  of "status":
    return t.runGitOp(cwd, ["status", "--porcelain=2", "--branch"])
  of "branch":
    return t.runGitOp(cwd, ["branch", "--format=%(refname:short)|%(HEAD)"])
  of "log":
    let limit = if args.hasKey("limit"): max(1, min(1000, args["limit"].getInt())) else: 10
    return t.runGitOp(cwd, ["log", "-" & $limit, "--pretty=format:%H|%an|%ae|%ad|%s", "--date=iso"])
  of "diff":
    var diffArgs = @["diff", "--unified=3"]
    if args.hasKey("cached") and args["cached"].getBool():
      diffArgs.add("--cached")
    diffArgs.add("--")
    var added = 0
    if args.hasKey("files"):
      if args["files"].kind == JArray:
        for f in args["files"].getElems():
          diffArgs.add(f.getStr())
          inc added
      elif args["files"].kind == JString:
        diffArgs.add(args["files"].getStr())
        inc added
    if added == 0: diffArgs.add(".")
    return t.runGitOp(cwd, diffArgs)
  of "checkout":
    if not args.hasKey("branch"): return "Error: Missing 'branch' parameter for checkout"
    return t.runGitOp(cwd, ["checkout", args["branch"].getStr()])
  of "add":
    var addArgs = @["add", "--"]
    var added = 0
    if args.hasKey("paths"):
      if args["paths"].kind == JArray:
        for p in args["paths"].getElems():
          addArgs.add(p.getStr())
          inc added
      elif args["paths"].kind == JString:
        addArgs.add(args["paths"].getStr())
        inc added
    if added == 0: return "Error: Missing 'paths' parameter for add"
    return t.runGitOp(cwd, addArgs)
  of "commit":
    if not args.hasKey("message"): return "Error: Missing 'message' parameter for commit"
    let rawMsg = args["message"].getStr()
    if rawMsg.len == 0: return "Error: Commit message cannot be empty"
    let safeMsg = truncateCommitMessage(rawMsg, 2000)
    # We must quote the message for execCmdEx shell execution
    return t.runGitOp(cwd, ["commit", "-m", "\"" & safeMsg.replace("\"", "\\\"") & "\""])
  of "stash":
    let action = if args.hasKey("action"): args["action"].getStr() else: "push"
    if action in ["push", "save"]:
      return t.runGitOp(cwd, ["stash", "push", "-m", "auto-stash"])
    elif action == "pop":
      return t.runGitOp(cwd, ["stash", "pop"])
    elif action == "list":
      return t.runGitOp(cwd, ["stash", "list"])
    else:
      return "Error: Unknown stash action"
  else:
    return "Error: Unknown operation: " & operation
