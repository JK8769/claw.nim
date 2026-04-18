import std/[asyncdispatch, json, tables, os, strutils, times]
import types, registry, ../config

type
  PersistTool* = ref object of ContextualTool
    registry: ToolRegistry
    
proc newPersistTool*(registry: ToolRegistry): PersistTool =
  PersistTool(registry: registry)

method name*(t: PersistTool): string = "persist_mcp_tool"
method description*(t: PersistTool): string = "Promote a forged MCP tool to a persistent library. Moves both source and binary to a persistent tool directory and injects version history."
method parameters*(t: PersistTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "name": {
        "type": "string",
        "description": "The name of the forged tool to persist (e.g. 'project-analyzer')"
      },
      "version": {
        "type": "string",
        "description": "Version number for this promotion (e.g. '1.0.0')"
      },
      "comment": {
        "type": "string",
        "description": "Optional comment about changes or purpose"
      }
    },
    "required": %["name"]
  }.toTable

method execute*(t: PersistTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let name = args["name"].getStr().strip()
  let version = if args.hasKey("version"): args["version"].getStr() else: "1.0.0"
  let comment = if args.hasKey("comment"): args["comment"].getStr() else: "Initial promotion"
  
  let forgeBase = getTempDir() / "nimclaw_forge"
  let forgeDir = forgeBase / name
  let srcFile = forgeDir / (name & ".nim")
  let binFile = if hostOS == "windows": forgeDir / (name & ".exe") else: forgeDir / name
  
  if not fileExists(srcFile):
    return "Error: Forged source not found at " & srcFile
  
  let persistBase = getNimClawDir() / "mcp" / "tools"
  let targetDir = persistBase / name
  if not dirExists(targetDir):
    createDir(targetDir)
    
  let targetSrc = targetDir / (name & ".nim")
  let targetBin = targetDir / (if hostOS == "windows": name & ".exe" else: name)
  
  # Inject version history into source
  try:
    let now = now().format("yyyy-MM-dd HH:mm:ss")
    let historyLine = "\n## Version: " & version & " (Promoted: " & now & ")\n## Comment: " & comment & "\n"
    let originalCode = readFile(srcFile)
    
    # We prepend the history line to the beginning of the file as top-level docstring
    let updatedCode = historyLine & originalCode
    writeFile(targetSrc, updatedCode)
    
    # Copy binary
    if fileExists(binFile):
      copyFile(binFile, targetBin)
      # set executable bit just in case
      when hostOS != "windows":
        discard execShellCmd("chmod +x " & quoteShell(targetBin))
    else:
      return "Error: Compiled binary not found at " & binFile & ". Did you forge it successfully first?"

    return "Successfully promoted '" & name & "' to persistent library at " & targetDir & ". It will be automatically loaded in future sessions."
  except Exception as e:
    return "Error during promotion: " & e.msg

type
  PersistSkillTool* = ref object of ContextualTool
    registry: ToolRegistry

proc newPersistSkillTool*(registry: ToolRegistry): PersistSkillTool =
  PersistSkillTool(registry: registry)

method name*(t: PersistSkillTool): string = "persist_skill"
method description*(t: PersistSkillTool): string = "Promote a specialized expertise (Competency) to the competencies directory. Moves SKILL.md and associated resources."
method parameters*(t: PersistSkillTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "skill_name": {
        "type": "string",
        "description": "Folder name for the skill"
      },
      "source_path": {
        "type": "string",
        "description": "Path to the SKILL.md or the skill folder"
      }
    },
    "required": %["skill_name", "source_path"]
  }.toTable

method execute*(t: PersistSkillTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let skillName = args["skill_name"].getStr().strip()
  let sourcePath = args["source_path"].getStr().strip()
  
  # Promote to Tier 2 company skills. This is the graduation destination from
  # a Tier 3 workstation skill — puts a curated copy at the company level
  # where every agent with matching `uses` in ClawDSL will see it.
  let targetDir = getNimClawDir() / "workspace" / "skills" / skillName
  if not dirExists(targetDir):
    createDir(targetDir)
    
  try:
    if fileExists(sourcePath):
      # If just a file, assume it's the SKILL.md
      copyFile(sourcePath, targetDir / "SKILL.md")
    elif dirExists(sourcePath):
      # If directory, copy contents
      copyDir(sourcePath, targetDir)
    else:
      return "Error: Source path not found: " & sourcePath
      
    return "Successfully promoted skill '" & skillName & "' to " & targetDir
  except Exception as e:
    return "Error promoting skill: " & e.msg
