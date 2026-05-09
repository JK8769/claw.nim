## skill — single tool for skill management.
##
## Replaces two split tools: install_skill, learn_skill.
##
## Actions:
##
##   install  — Install a skill plugin from a registry name, GitHub
##              URL, or owner/repo shorthand. Optional env_vars for
##              skills that need API keys.
##
##   learn    — Author a Tier-3 workstation skill (private to this
##              agent) from a repeated workflow. Enforces SKILL.md
##              invariants in code: kebab-case name, frontmatter,
##              tool-name validation against the live registry, kept
##              under `<office>/workstation/skills/<name>/`.
##
## Note: persist_skill (used by mcp forge) is internal to mcp_unified
## and not exposed here.

import std/[asyncdispatch, json, tables, strutils, options, os]
import ../types, ../registry
import ../spec
import ../../skills/installer
import ../../logger

const ToolSpec* = spec(
  name = "skill",
  description = "skill management: action=install plugins or action=learn workstation skills",
  tags = @["admin", "skills", "workstation"],
  domain = "skill",
  default = false,
  heartbeatSafe = false,
  category = "skills",
)

type
  SkillTool* = ref object of Tool
    installer: SkillInstaller
    officeDir: string
    registryRef: ToolRegistry

proc newSkillTool*(installer: SkillInstaller, officeDir: string,
                   registryRef: ToolRegistry): SkillTool =
  SkillTool(installer: installer, officeDir: officeDir,
            registryRef: registryRef)

method name*(t: SkillTool): string = "skill"

method description*(t: SkillTool): string =
  "Skill management.\n\n" &
  "Actions:\n" &
  "  install  — install a skill plugin (requires name; supports " &
  "registry name, GitHub URL, or owner/repo shorthand)\n" &
  "  learn    — author a workstation skill from a repeated workflow " &
  "(requires name, description, triggers, workflow, tools)"

method parameters*(t: SkillTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["install", "learn"],
        "description": "Operation to perform"
      },
      "name": {
        "type": "string",
        "description": "Skill name. install: registry name or GitHub URL/owner-repo. learn: kebab-case identifier."
      },
      "env_vars": {
        "type": "object",
        "description": "install only — env vars for skills that need API keys (e.g. {\"ANYGEN_API_KEY\": \"sk-xxx\"})",
        "additionalProperties": {"type": "string"}
      },
      "acquisition_method": {
        "type": "string",
        "enum": ["auto", "git", "download"],
        "description": "install only — how to fetch the skill (default: auto)",
        "default": "auto"
      },
      "sub_path": {
        "type": "string",
        "description": "install only — subdirectory within the repo to install"
      },
      "description": {
        "type": "string",
        "description": "learn only — one trigger-oriented sentence under 300 chars"
      },
      "triggers": {
        "type": "array",
        "items": {"type": "string"},
        "description": "learn only — at least one 'when to use' phrase"
      },
      "workflow": {
        "type": "array",
        "items": {"type": "string"},
        "description": "learn only — at least two numbered workflow steps"
      },
      "tools": {
        "type": "array",
        "items": {"type": "string"},
        "description": "learn only — exact tool names used (validated against the registry)"
      },
      "examples": {
        "type": "array",
        "items": {"type": "string"},
        "description": "learn only — optional user-query → tool-call → reply examples"
      }
    },
    "required": %*["action", "name"]
  }.toTable

# ── install ──────────────────────────────────────────────────────

proc doInstall(t: SkillTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let name = args["name"].getStr().strip()
  if name.len == 0:
    return "Error: skill name cannot be empty"

  var envVars: seq[(string, string)]
  if args.hasKey("env_vars"):
    let envObj = args["env_vars"]
    if envObj.kind == JObject:
      for k, v in envObj.pairs:
        envVars.add((k, v.getStr()))

  try:
    let regOpt = findInRegistry(name)
    if regOpt.isSome or (not name.contains("/") and not name.contains("://")):
      return await t.installer.installByName(name, envVars)
    else:
      for (k, v) in envVars:
        if v.len > 0:
          discard storeEnvVar(k, v)
      let mode = if args.hasKey("acquisition_method"): args["acquisition_method"].getStr() else: "auto"
      let subPath = if args.hasKey("sub_path"): args["sub_path"].getStr() else: ""
      await t.installer.installFromGitHub(name, mode, subPath)
      return "Installed skill from: " & name
  except CatchableError as e:
    return "Error installing skill: " & e.msg

# ── learn ────────────────────────────────────────────────────────

proc isKebabCase(s: string): bool =
  if s.len == 0 or s[0] == '-' or s[^1] == '-': return false
  for c in s:
    if not (c in {'a'..'z', '0'..'9', '-'}): return false
  if "--" in s: return false
  return true

proc titleCase(s: string): string =
  result = ""
  var capNext = true
  for c in s:
    if c == '-':
      result.add(' ')
      capNext = true
    elif capNext:
      result.add(c.toUpperAscii())
      capNext = false
    else:
      result.add(c)

proc doLearn(t: SkillTool, args: Table[string, JsonNode]): string =
  let name = args["name"].getStr().strip()
  let descr = if args.hasKey("description"): args["description"].getStr().strip() else: ""
  let triggers = if args.hasKey("triggers"): args["triggers"].to(seq[string]) else: @[]
  let workflow = if args.hasKey("workflow"): args["workflow"].to(seq[string]) else: @[]
  let claimedTools = if args.hasKey("tools"): args["tools"].to(seq[string]) else: @[]
  let examples = if args.hasKey("examples"): args["examples"].to(seq[string]) else: @[]

  if not isKebabCase(name):
    return "Error: 'name' must be kebab-case (lowercase letters/digits/hyphens, no leading/trailing/double hyphens). Got: '" & name & "'"
  if descr.len == 0: return "Error: 'description' is required for learn"
  if descr.len > 300:
    return "Error: 'description' must be under 300 chars (got " & $descr.len & ")"
  if triggers.len == 0: return "Error: 'triggers' must contain at least one phrase"
  if workflow.len < 2:
    return "Error: 'workflow' must have at least two steps — a one-step skill isn't worth capturing"
  if claimedTools.len == 0: return "Error: 'tools' must list at least one tool used"

  var unknown: seq[string] = @[]
  for toolName in claimedTools:
    let (_, ok) = t.registryRef.get(toolName)
    if not ok:
      unknown.add(toolName)
  if unknown.len > 0:
    return "Error: unknown tool name(s): " & unknown.join(", ") &
           ". Use the EXACT sanitized names from your tools list."

  if t.officeDir.len == 0:
    return "Error: officeDir not configured — workstation-skill authoring requires an agent-scoped office"

  let skillDir = t.officeDir / "workstation" / "skills" / name
  let skillFile = skillDir / "SKILL.md"
  if fileExists(skillFile):
    return "Error: a workstation skill named '" & name & "' already exists at " & skillFile

  var buf = "---\n"
  buf.add("name: " & name & "\n")
  buf.add("version: 0.1.0\n")
  let escapedDescr = descr.replace("\"", "\\\"")
  buf.add("description: \"" & escapedDescr & "\"\n")
  buf.add("requires:\n")
  buf.add("  tools:\n")
  for toolName in claimedTools:
    buf.add("    - " & toolName & "\n")
  buf.add("  env: []\n")
  buf.add("---\n\n")

  buf.add("# " & titleCase(name) & "\n\n")
  buf.add(descr & "\n\n")

  buf.add("## When to use\n")
  for trig in triggers:
    buf.add("- " & trig & "\n")
  buf.add("\n")

  buf.add("## Workflow\n")
  for i, step in workflow:
    buf.add($(i + 1) & ". " & step & "\n")
  buf.add("\n")

  if examples.len > 0:
    buf.add("## Examples\n")
    for ex in examples:
      buf.add("- " & ex & "\n")
    buf.add("\n")

  try:
    createDir(skillDir)
    writeFile(skillFile, buf)
  except CatchableError as e:
    return "Error: failed to write SKILL.md: " & e.msg

  infoCF("tool", "Workstation skill authored",
    {"name": name, "path": skillFile,
     "tools_count": $claimedTools.len}.toTable)

  return "Authored workstation skill '" & name & "' at " & skillFile &
         "\n  - " & $claimedTools.len & " tool(s) in requires.tools" &
         "\n  - " & $triggers.len & " trigger(s), " & $workflow.len & " workflow step(s)" &
         "\n  - Future sessions will auto-discover this skill."

method execute*(t: SkillTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (install | learn)"
  if not args.hasKey("name"):
    return "Error: 'name' is required"
  let action = args["action"].getStr()
  case action
  of "install": return await doInstall(t, args)
  of "learn":   return doLearn(t, args)
  else:
    return "Error: Unknown action '" & action & "'. Use: install | learn"
