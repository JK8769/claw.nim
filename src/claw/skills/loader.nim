import std/[os, strutils, sequtils]
import openclaw_compat, skill_types



type
  SkillsLoader* = ref object
    ## 3-tier skill discovery:
    ##   Tier 1 Foundation  — universal skills from the claw distribution (forge-tool)
    ##   Tier 2 Company     — opt-in skills curated per company (declared via ClawDSL)
    ##   Tier 3 Workstation — agent-authored at runtime
    ## Discovery order: workstation → lab → foundation → openclaw (later layers
    ## shadow earlier ones by name — a lab customization overrides the foundation
    ## default).
    workspace*: string
    projectCompetencies*: string   ## workspace-level competencies (shared by all offices)
    companySkills*: string         ## Tier 2: <co>/workspace/lab/skills/
    foundationSkills*: string      ## Tier 1: <co>/foundation/skills/ (snapshot of claw distribution)
    openClawExtensions*: string    ## third-party OpenClaw plugins
    workstationSkills*: string     ## Tier 3: <officeDir>/workstation/skills/

proc newSkillsLoader*(workspace, projectCompetencies, companySkills, foundationSkills, openClawExtensions: string, workstationSkills: string = ""): SkillsLoader =
  SkillsLoader(
    workspace: workspace,
    projectCompetencies: projectCompetencies,
    companySkills: companySkills,
    foundationSkills: foundationSkills,
    openClawExtensions: openClawExtensions,
    workstationSkills: workstationSkills
  )

proc parseFrontmatter(content: string): SkillMetadata =
  ## Simple YAML frontmatter parser for name: and description:
  result = SkillMetadata()
  if content.startsWith("---\n"):
    let nextIdx = content.find("\n---\n", 4)
    if nextIdx != -1:
      let fm = content[4 .. nextIdx]
      for line in fm.splitLines():
        let parts = line.split(":", 1)
        if parts.len == 2:
          let key = parts[0].strip().toLowerAscii()
          let val = parts[1].strip()
          if key == "name": result.name = val
          elif key == "description": result.description = val
          elif key == "requires_tools":
            result.requires_tools = val.split(",").mapIt(it.strip())

proc getSkillMetadata(sl: SkillsLoader, dir: string): SkillMetadata =
  ## Extract metadata from SKILL.md or openclaw.plugin.json.
  let skillFile = dir / "SKILL.md"
  let pluginFile = dir / "openclaw.plugin.json"

  if fileExists(skillFile):
    let content = readFile(skillFile)
    result = parseFrontmatter(content)
  elif fileExists(pluginFile):
    let content = readFile(pluginFile)
    result = parseOpenClawManifest(content)
  
  if result.name == "":
    result.name = lastPathPart(dir)

proc escapeXML(s: string): string =
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

proc stripFrontmatter(content: string): string =
  # Simple version: if it starts with ---, find next ---
  if content.startsWith("---\n"):
    let nextIdx = content.find("\n---\n", 4)
    if nextIdx != -1:
      return content[nextIdx + 5 .. ^1]
  return content

proc listSkills*(sl: SkillsLoader): seq[SkillInfo] =
  ## Lists all skills from workspace, global, and OpenClaw extension directories.
  result = @[]

  proc findSkillsRecursive(dir: string, source: string, results: var seq[SkillInfo], depth: int) =
    if not dirExists(dir) or depth > 3: return
    
    let skillFile = dir / "SKILL.md"
    let pluginFile = dir / "openclaw.plugin.json"
    
    if fileExists(skillFile) or fileExists(pluginFile):
      let meta = sl.getSkillMetadata(dir)
      let primaryFile = if fileExists(skillFile): skillFile else: pluginFile
      let sanitizedName = meta.name.replace("-", "_")
      results.add(SkillInfo(
        name: sanitizedName,
        path: primaryFile,
        source: source,
        description: meta.description,
        location: absolutePath(dir),
        requires_tools: meta.requires_tools
      ))
      # If we found a skill/plugin, we don't necessarily stop, 
      # but usually subdirs won't contain more skills unless it's a "skills" folder
      
    for kind, path in walkDir(dir):
      if kind == pcDir:
        let base = lastPathPart(path)
        if base == "node_modules" or base.startsWith("."): continue
        findSkillsRecursive(path, source, results, depth + 1)

  # Discovery order — later layers shadow earlier ones by name:
  # Tier 3 (workstation) — this agent's personal authored skills
  # Tier 2 (company lab) — opt-in curated per company (ClawDSL-declared)
  # Tier 1 (foundation)  — universal skills from the claw distribution
  # Workspace            — shared competencies across the workspace
  # OpenClaw             — third-party plugins
  if sl.workstationSkills.len > 0:
    findSkillsRecursive(sl.workstationSkills, "workstation", result, 0)
  if sl.companySkills.len > 0:
    findSkillsRecursive(sl.companySkills, "company", result, 0)
    # Backward compat — scan previous-generation Tier 2 paths.
    # companySkills = <co>/workspace/lab/skills/ (current).
    let companyRoot = sl.companySkills.parentDir.parentDir.parentDir  # strip /workspace/lab/skills
    for legacy in [companyRoot / "lab" / "skills", companyRoot / "skills"]:
      if legacy != sl.companySkills and dirExists(legacy):
        findSkillsRecursive(legacy, "company-legacy", result, 0)
  if sl.foundationSkills.len > 0:
    findSkillsRecursive(sl.foundationSkills, "foundation", result, 0)
    # Backward compat: legacy base/ path
    let foundationRoot = sl.foundationSkills.parentDir.parentDir  # strip /foundation/skills
    let legacyBase = foundationRoot / "base" / "skills"
    if legacyBase != sl.foundationSkills and dirExists(legacyBase):
      findSkillsRecursive(legacyBase, "foundation-legacy", result, 0)
  findSkillsRecursive(sl.projectCompetencies, "workspace", result, 0)
  if sl.openClawExtensions != "":
    findSkillsRecursive(sl.openClawExtensions, "openclaw", result, 0)

proc loadSkill*(sl: SkillsLoader, name: string): (string, bool) =
  ## Loads a specific skill by name, searching through all discovered skills.
  let skills = sl.listSkills()
  for s in skills:
    if s.name == name or lastPathPart(s.path) == name:
      return (readFile(s.path).stripFrontmatter(), true)
  return ("", false)

proc loadSkillsForContext*(sl: SkillsLoader, skillNames: seq[string]): string =
  if skillNames.len == 0: return ""
  var parts: seq[string] = @[]
  for name in skillNames:
    let (content, ok) = sl.loadSkill(name)
    if ok:
      parts.add("### Skill: " & name & "\n\n" & content)
  return parts.join("\n\n---\n\n")


proc buildSkillsSummary*(sl: SkillsLoader, allowedNames: seq[string] = @[]): string =
  ## Build an XML summary of available skills.
  ## If allowedNames is non-empty, only include skills whose name (or sanitized
  ## name with hyphens replaced by underscores) matches — EXCEPT workstation
  ## skills (Tier 3), which are always visible to their authoring agent.
  let skills = sl.listSkills()
  if skills.len == 0: return ""
  var lines = @["<skills>"]
  for s in skills:
    if allowedNames.len > 0 and s.source != "workstation":
      # Match against both hyphenated and underscore-sanitized names
      let nameHyphen = s.name.replace("_", "-")
      if s.name notin allowedNames and nameHyphen notin allowedNames:
        continue
    lines.add("  <skill>")
    lines.add("    <name>" & escapeXML(s.name) & "</name>")
    lines.add("    <description>" & escapeXML(s.description) & "</description>")
    lines.add("    <location>" & escapeXML(s.location) & "</location>")
    lines.add("    <source>" & s.source & "</source>")
    if s.requires_tools.len > 0:
      lines.add("    <requires_tools>" & s.requires_tools.join(", ") & "</requires_tools>")
    lines.add("  </skill>")
  lines.add("</skills>")
  return lines.join("\n")
