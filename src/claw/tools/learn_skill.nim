## learn_skill — author a Tier-3 workstation SKILL.md from structured inputs.
##
## Problem: agents consistently skip invariants (frontmatter, `workstation/` path,
## kebab-case, exact tool names) when asked to write a SKILL.md via free-form `write_file`.
## This tool enforces those invariants in code.
##
## The agent provides structured fields; the tool renders the SKILL.md and writes
## it to `<officeDir>/workstation/skills/<name>/SKILL.md`. The agent cannot get the
## path or frontmatter wrong — the tool handles both.

import std/[asyncdispatch, json, tables, strutils, os]
import types, registry
import ../logger

type
  LearnSkillTool* = ref object of Tool
    officeDir*: string          ## where the skill file lands
    registryRef*: ToolRegistry  ## for validating tools[] entries

proc newLearnSkillTool*(officeDir: string, registryRef: ToolRegistry): LearnSkillTool =
  LearnSkillTool(officeDir: officeDir, registryRef: registryRef)

method name*(t: LearnSkillTool): string = "learn_skill"

method description*(t: LearnSkillTool): string =
  "Capture a repeated workflow as a workstation skill (Tier 3, private to you). Use when you've run the same tool sequence 3+ times, or when the user asks the same class of question repeatedly. Writes a SKILL.md that future sessions auto-discover — no need to construct the file yourself."

method parameters*(t: LearnSkillTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "name": {
        "type": "string",
        "description": "Skill name in kebab-case (e.g. 'financial-projection'). Must not collide with an existing skill."
      },
      "description": {
        "type": "string",
        "description": "One trigger-oriented sentence, under 200 chars. This is what future-you reads to decide whether to invoke the skill."
      },
      "triggers": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Concrete 'when to use' phrases — e.g. 'user asks what $X at Y% for Z years is worth'. At least one required."
      },
      "workflow": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Numbered steps describing the workflow — e.g. 'Call compound_interest with principal, rate, years'. At least two required (a one-step skill isn't worth capturing)."
      },
      "tools": {
        "type": "array",
        "items": {"type": "string"},
        "description": "EXACT tool names used in the workflow — the sanitized names visible in your tools list (e.g. 'mcp_finance_calculator_compound_interest', not 'compound_interest'). Validated against your current toolbox."
      },
      "examples": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Optional user-query → tool-call → reply examples. Strongly recommended — anchors the skill for future you."
      }
    },
    "required": %*["name", "description", "triggers", "workflow", "tools"]
  }.toTable

# ─── Validation helpers ─────────────────────────────────────────

proc isKebabCase(s: string): bool =
  if s.len == 0 or s[0] == '-' or s[^1] == '-': return false
  for c in s:
    if not (c in {'a'..'z', '0'..'9', '-'}): return false
  if "--" in s: return false
  return true

proc renderYamlList(items: seq[string], indent: string): string =
  ## Render a YAML array as a bullet list under a key.
  var lines: seq[string] = @[]
  for item in items:
    # Escape quotes by wrapping in double quotes and doubling internal quotes
    let escaped = item.replace("\"", "\\\"")
    lines.add(indent & "- \"" & escaped & "\"")
  return lines.join("\n")

proc titleCase(s: string): string =
  ## Convert 'financial-projection' -> 'Financial Projection'
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

# ─── Execute ────────────────────────────────────────────────────

method execute*(t: LearnSkillTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  # --- Extract ---
  let name = if args.hasKey("name"): args["name"].getStr().strip() else: ""
  let descr = if args.hasKey("description"): args["description"].getStr().strip() else: ""
  let triggers = if args.hasKey("triggers"): args["triggers"].to(seq[string]) else: @[]
  let workflow = if args.hasKey("workflow"): args["workflow"].to(seq[string]) else: @[]
  let claimedTools = if args.hasKey("tools"): args["tools"].to(seq[string]) else: @[]
  let examples = if args.hasKey("examples"): args["examples"].to(seq[string]) else: @[]

  # --- Validate ---
  if name.len == 0: return "Error: 'name' is required"
  if not isKebabCase(name):
    return "Error: 'name' must be kebab-case (lowercase letters/digits/hyphens, no leading/trailing/double hyphens). Got: '" & name & "'"
  if descr.len == 0: return "Error: 'description' is required"
  if descr.len > 300:
    return "Error: 'description' must be under 300 chars (got " & $descr.len & "). Keep it trigger-oriented and short."
  if triggers.len == 0: return "Error: 'triggers' must contain at least one 'when to use' phrase"
  if workflow.len < 2:
    return "Error: 'workflow' must have at least two steps — a one-step skill isn't worth capturing, just call the tool directly"
  if claimedTools.len == 0: return "Error: 'tools' must list at least one tool used in the workflow"

  # Validate tool names exist in registry
  var unknown: seq[string] = @[]
  for toolName in claimedTools:
    let (_, ok) = t.registryRef.get(toolName)
    if not ok:
      unknown.add(toolName)
  if unknown.len > 0:
    return "Error: unknown tool name(s): " & unknown.join(", ") &
           ". Use the EXACT sanitized names from your tools list (e.g. 'mcp_finance_calculator_compound_interest', not 'compound_interest')."

  # Check office dir is set
  if t.officeDir.len == 0:
    return "Error: officeDir not configured — workstation-skill authoring requires an agent-scoped office"

  # Check collision
  let skillDir = t.officeDir / "workstation" / "skills" / name
  let skillFile = skillDir / "SKILL.md"
  if fileExists(skillFile):
    return "Error: a workstation skill named '" & name & "' already exists at " & skillFile &
           ". Choose a different name or delete the existing file first."

  # --- Render ---
  var buf = "---\n"
  buf.add("name: " & name & "\n")
  buf.add("version: 0.1.0\n")
  # Quote the description to survive YAML
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

  # --- Write ---
  try:
    createDir(skillDir)
    writeFile(skillFile, buf)
  except Exception as e:
    return "Error: failed to write SKILL.md: " & e.msg

  infoCF("tool", "Lab skill authored",
    {"name": name, "path": skillFile, "tools_count": $claimedTools.len}.toTable)

  return "Authored workstation skill '" & name & "' at " & skillFile &
         "\n  - " & $claimedTools.len & " tool(s) in requires.tools" &
         "\n  - " & $triggers.len & " trigger(s), " & $workflow.len & " workflow step(s)" &
         "\n  - Future sessions will auto-discover this skill in your <skills> block."
