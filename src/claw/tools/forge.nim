import std/[asyncdispatch, json, tables, os, osproc, strutils, streams, sequtils]
import types, registry
import ../logger

type
  ForgeTool* = ref object of ContextualTool
    registry: ToolRegistry
    workspace: string

proc newForgeTool*(registry: ToolRegistry, workspace: string): ForgeTool =
  ## `workspace` here is the agent's officeDir. Forged MCP binaries live under
  ## `<officeDir>/workstation/mcp/<name>/` — Tier 3 artifacts sit together with
  ## agent-authored SKILL.md files under `workstation/skills/`.
  ForgeTool(
    registry: registry,
    workspace: workspace / "workstation" / "mcp"
  )

method name*(t: ForgeTool): string = "forge_mcp_tool"
method description*(t: ForgeTool): string = "Create a new MCP tool at runtime. Provide COMPLETE Nim code using: import mcp; let server = mcpServer(\"name\", \"1.0.0\"): mcpTool: proc tool_name(arg: string): string = ## desc \\n ## - arg: desc \\n return \"result\"; when isMainModule: let transport = newStdioTransport(); transport.serve(server). Read the forge_nim_expert skill FIRST."
method parameters*(t: ForgeTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "name": {
        "type": "string",
        "description": "Short name for the tool/server (e.g. 'project-analyzer')"
      },
      "code": {
        "type": "string",
        "description": "The COMPLETE Nim implementation of the MCP server"
      },
      "description": {
        "type": "string",
        "description": "What the newly forged tools will do"
      },
      "logic_only": {
        "type": "boolean",
        "description": "If true, provide ONLY the proc definitions. The tool will wrap them in MCP boilerplate automatically."
      }
    },
    "required": %["name"]
  }.toTable

method execute*(t: ForgeTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let name = args["name"].getStr().strip()
  if name.contains("/") or name.contains(".."):
    return "Error: Invalid tool name (security check failed)."
  
  var code = ""
  if args.hasKey("code"):
    code = args["code"].getStr()
    
  let logicOnly = args.getOrDefault("logic_only", %false).getBool()
  
  if code == "":
    # Try to find existing source if no code provided
    let existingPath = t.workspace / name / "src" / (name & ".nim")
    if fileExists(existingPath):
      code = readFile(existingPath)
      infoCF("forge", "Using existing source code from disk", {"path": existingPath}.toTable)
    else:
      return "Error: No source code provided and no existing source found at " & existingPath
  
  if logicOnly:
    # Extract any `import` lines from the agent's code — these must be hoisted
    # to top level because `import` is not allowed inside `mcpServer(...):` block.
    var extraImports: seq[string]
    var bodyLines: seq[string]
    for line in code.splitLines():
      let stripped = line.strip()
      if stripped.startsWith("import ") or stripped.startsWith("from "):
        extraImports.add(stripped)
      else:
        bodyLines.add(line)
    let importBlock = if extraImports.len > 0:
      extraImports.join("\n") & "\n"
    else: ""

    # Auto-wrap top-level procs in `mcpTool:` blocks if the agent forgot.
    # A bare `proc` inside `mcpServer(...):` is syntactically valid Nim but
    # registers NO tool — the server ends up empty. This caused a silent
    # regression where forged binaries reported zero tools via tools/list.
    # We detect top-level procs (lines that START with "proc ") and, unless
    # the previous non-blank line is already `mcpTool:`, inject the wrapper
    # and indent the proc (and its body) by 2 spaces.
    var processedLines: seq[string]
    var autoWrapped = 0
    var i = 0
    while i < bodyLines.len:
      let line = bodyLines[i]
      let isTopLevelProc = line.len > 0 and
                           not (line[0] == ' ' or line[0] == '\t') and
                           (line.startsWith("proc ") or line.startsWith("func "))
      if isTopLevelProc:
        # Look at the last non-blank output line — was it `mcpTool:` already?
        var prevStripped = ""
        for k in countdown(processedLines.len - 1, 0):
          let s = processedLines[k].strip()
          if s.len > 0:
            prevStripped = s
            break
        if prevStripped == "mcpTool:":
          # Agent wrote `mcpTool:` themselves; respect it
          processedLines.add(line)
          inc i
        else:
          processedLines.add("mcpTool:")
          processedLines.add("  " & line)
          inc i
          # Indent the proc body (every line until we hit another top-level line or EOF)
          while i < bodyLines.len:
            let next = bodyLines[i]
            if next.len == 0 or next.strip().len == 0:
              processedLines.add(next)
              inc i
            elif next[0] == ' ' or next[0] == '\t':
              processedLines.add("  " & next)
              inc i
            else:
              break
          inc autoWrapped
      else:
        processedLines.add(line)
        inc i
    let bodyCode = processedLines.join("\n")

    if autoWrapped > 0:
      infoCF("forge", "Auto-wrapped bare procs in mcpTool: blocks",
        {"count": $autoWrapped, "hint": "agent omitted mcpTool: wrapper — wrapped automatically"}.toTable)

    # Wrap in boilerplate.
    # NOTE: `$3` is placed at column 0 so that `bodyCode.indent(2)` produces
    # uniformly 2-space-indented lines. The earlier template had `  $3` which
    # caused the first body line to be indented 4 spaces (2 from template +
    # 2 from indent()) while the rest got 2, triggering Nim indentation errors.
    let wrappedCode = """
import std/[asyncdispatch, json, tables, os, strutils]
import mcp
$1
let server = mcpServer("$2", "1.0.0"):
$3

when isMainModule:
  let transport = newStdioTransport()
  transport.serve(server)
""".format(importBlock, name, bodyCode.indent(2))
    code = wrappedCode
  else:
    # Proactive check for MCP boilerplate to guide agents
    if "mcpServer" notin code:
      return "Error: Missing 'mcpServer' macro. You MUST provide a full Nim script OR set 'logic_only: true'. See the forge-tool skill for the required boilerplate."
    # Sanity check: full-code mode must contain at least one `mcpTool:` or the
    # resulting server will register zero tools.
    if "mcpTool" notin code:
      return "Error: Code contains no `mcpTool:` block — the server would register zero tools. Wrap each exposed proc in a `mcpTool:` block, or set `logic_only: true` and let forge auto-wrap."
  
  # Use a dedicated, isolated workspace for forge (in officeDir/workstation/mcp)
  let forgeBase = t.workspace
  if not dirExists(forgeBase):
    createDir(forgeBase)
    
  let forgeDir = forgeBase / name
  if not dirExists(forgeDir):
    createDir(forgeDir)
    
  # Build Protection: Use temporary source and binary paths
  let tempSourcePath = forgeDir / (name & "_build.nim")
  let tempBinaryPath = if hostOS == "windows": tempSourcePath.changeFileExt("exe") else: tempSourcePath.changeFileExt("")
  
  writeFile(tempSourcePath, code)
  
  infoCF("forge", "Forging new tool", {"name": name, "path": tempSourcePath, "logic_only": $logicOnly}.toTable)

  # Use 'nim c' then run binary for better process control
  let compileCmd = "nim"
  
  # Dynamic path resolution for portability (especially for nimble install)
  let compileTimePath = currentSourcePath().parentDir().parentDir().absolutePath()
  var nimclawPath = getEnv("NIMCLAW_PATH", "")
  
  if nimclawPath == "":
    # Try relative to the app binary if we are in a dev environment
    let appDir = getAppDir()
    if dirExists(appDir / "src" / "nimclaw"):
      nimclawPath = appDir / "src" / "nimclaw"
    elif dirExists(appDir.parentDir / "src" / "nimclaw"):
      nimclawPath = appDir.parentDir / "src" / "nimclaw"
    elif dirExists(compileTimePath):
      nimclawPath = compileTimePath
  
  var compileArgs = @["c", "--hints:off", "--threads:on", "--mm:orc", "-d:debug", "-d:ssl"]
  if nimclawPath != "":
    compileArgs.add("--path:" & nimclawPath)
    compileArgs.add("--path:" & nimclawPath.parentDir())
  
  compileArgs.add("-o:" & tempBinaryPath)
  compileArgs.add(tempSourcePath)
  
  infoCF("forge", "Compiling new tool", {"command": compileCmd & " " & compileArgs.join(" "), "mcp": (if nimclawPath != "": nimclawPath / "mcp.nim" else: "system-wide")}.toTable)
  let p = startProcess(compileCmd, args = compileArgs, options = {poUsePath, poStdErrToStdOut})
  let exitCode = p.waitForExit()
  
  if exitCode != 0:
    let output = p.outputStream.readAll()
    # Cleanup failed build artifacts
    if fileExists(tempSourcePath): removeFile(tempSourcePath)
    if fileExists(tempBinaryPath): removeFile(tempBinaryPath)
    return "Failed to compile forged tool. JUNK DELETED. Error output:\n" & output

  # Successful build: Promote temp files to final paths
  let finalSourceDir = forgeDir / "src"
  let finalBinDir = forgeDir / "bin"
  createDir(finalSourceDir)
  createDir(finalBinDir)
  
  let finalSourcePath = finalSourceDir / (name & ".nim")
  let finalBinaryPath = if hostOS == "windows": finalBinDir / (name & ".exe") else: finalBinDir / name
  
  if fileExists(finalBinaryPath): removeFile(finalBinaryPath)
  moveFile(tempBinaryPath, finalBinaryPath)
  moveFile(tempSourcePath, finalSourcePath)

  let cmd = finalBinaryPath
  let cmdArgs: seq[string] = @[]
  
  # Sandbox for macOS
  var sandbox: seq[string] = @[]
  when hostOS == "macosx":
    # Allow write to the tool's isolated folder
    let profile = "(version 1) (allow default) (deny file-write* (subpath \"/\")) (allow file-write* (subpath \"$1\")) (allow file-write* (subpath \"/tmp\"))".format(forgeDir)
    sandbox = @["sandbox-exec", "-p", profile]

  try:
    await t.registry.registerMcpServer(cmd, cmdArgs, t.sessionKey, sandbox)
    return "Successfully forged and registered MCP server '" & name & "'. Logic-only: " & $logicOnly & ". New tools are now available. Previous versions replaced."
  except Exception as e:
    return "Failed to start forged tool: " & e.msg

type
  PurgeMcpTool* = ref object of ContextualTool
    registry: ToolRegistry
    officeDir: string

proc newPurgeMcpTool*(registry: ToolRegistry, officeDir: string): PurgeMcpTool =
  PurgeMcpTool(registry: registry, officeDir: officeDir)

method name*(t: PurgeMcpTool): string = "purge_mcp_tool"
method description*(t: PurgeMcpTool): string = "Unregister and uninstall a previously forged MCP server. Removes the binary and stops the process, but PRESERVES source code by default."
method parameters*(t: PurgeMcpTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "name": {
        "type": "string",
        "description": "The name used when forging the tool (e.g. 'project-analyzer')"
      },
      "delete_source": {
        "type": "boolean",
        "description": "If true, also PERMANENTLY DELETE the source code in the src/ directory. Default: false (keep source)."
      }
    },
    "required": %["name"]
  }.toTable

method execute*(t: PurgeMcpTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let name = args["name"].getStr().strip()
  let deleteSource = args.getOrDefault("delete_source", %false).getBool()
  
  # 1. Unregister first
  t.registry.unregisterMcpServer(name)
  
  # Give the process a moment to exit before trying to delete files
  await sleepAsync(500)
  
  # 2. Cleanup binary — check workstation/mcp first, then legacy paths
  var forgeDir = t.officeDir / "workstation" / "mcp" / name
  if not dirExists(forgeDir):
    let legacyLab = t.officeDir / "lab" / "mcp" / name
    let legacyRoot = t.officeDir / "mcp" / name
    if dirExists(legacyLab):
      forgeDir = legacyLab
    elif dirExists(legacyRoot):
      forgeDir = legacyRoot
  let binDir = forgeDir / "bin"
  let binaryPath = if hostOS == "windows": binDir / (name & ".exe") else: binDir / name
  
  var status = "Successfully unregistered MCP server '" & name & "'."
  
  if fileExists(binaryPath):
    try:
      removeFile(binaryPath)
      status &= " Binary uninstalled."
      # Also try to remove empty bin dir
      if dirExists(binDir) and walkDirRec(binDir).toSeq.len == 0:
        removeDir(binDir)
    except Exception as e:
      status &= " (Warning: failed to delete binary: " & e.msg & ")"
  else:
    # Fallback for old structure (binary in root)
    let oldBinaryPath = if hostOS == "windows": forgeDir / (name & ".exe") else: forgeDir / name
    if fileExists(oldBinaryPath):
      try:
        removeFile(oldBinaryPath)
        status &= " Binary uninstalled (legacy location)."
      except Exception as e:
        status &= " (Warning: failed to delete legacy binary: " & e.msg & ")"

  # 3. Handle source deletion
  if deleteSource:
    if dirExists(forgeDir):
      try:
        removeDir(forgeDir)
        status &= " FULL WORKSPACE DELETED."
      except Exception as e:
        status &= " (Error: failed to delete workspace: " & e.msg & ")"
  else:
    status &= " Source code PRESERVED at " & (forgeDir / "src")
  
  return status

# Specialized Forge for Nim analysis
proc newNimForgeTool*(registry: ToolRegistry, workspace: string): ForgeTool =
  # Similar to ForgeTool but with a pre-defined system prompt or templates?
  # For now, one tool is enough.
  return newForgeTool(registry, workspace)
