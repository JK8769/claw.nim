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
    companySkills*: string         ## Tier 2: <co>/workspace/skills/
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

proc parseListValue(val: string): seq[string] =
  ## Parse a YAML list field of the form `[a, b, c]` or `a, b, c` into
  ## a trimmed seq. Used for inline-list frontmatter values like
  ## `channels: [feishu]`. Block-list form (one-per-line dashed) is
  ## not supported here — the SKILL.md schema convention is inline.
  var s = val.strip()
  if s.len >= 2 and s[0] == '[' and s[^1] == ']':
    s = s[1 .. ^2]
  result = @[]
  for p in s.split(","):
    let t = p.strip()
    if t.len > 0:
      result.add(t)

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
            result.requires_tools = parseListValue(val)
          elif key == "channels":
            result.channels = parseListValue(val)

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
        requires_tools: meta.requires_tools,
        channels: meta.channels
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
    # Current: <co>/workspace/skills/
    # Legacy:  <co>/workspace/lab/skills/ (pre-lab-rename), <co>/lab/skills/, <co>/skills/
    let companyRoot = sl.companySkills.parentDir.parentDir  # strip /workspace/skills
    for legacy in [companyRoot / "workspace" / "lab" / "skills",
                   companyRoot / "lab" / "skills",
                   companyRoot / "skills"]:
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


proc buildSkillsSummary*(sl: SkillsLoader, allowedNames: seq[string] = @[],
                         currentChannel: string = ""): string =
  ## Build an XML summary of available skills.
  ## If allowedNames is non-empty, only include skills whose name (or sanitized
  ## name with hyphens replaced by underscores) matches — EXCEPT workstation
  ## skills (Tier 3), which are always visible to their authoring agent.
  ##
  ## Channel-aware ordering:
  ##   - When `currentChannel` is non-empty, skills tagged with that
  ##     channel are emitted FIRST (top of the list, where the LLM
  ##     attends most), with a `<active_for_channel>` flag.
  ##   - Skills tagged with OTHER channels (and the current channel
  ##     isn't in their list) are SKIPPED — they're not relevant to
  ##     this delivery surface.
  ##   - Skills with no `channels:` declaration are channel-agnostic
  ##     and emitted after the channel-specific block.
  ##   - When `currentChannel` is empty (e.g. the CLI introspection
  ##     path with no active message), all skills are emitted in
  ##     discovery order — same behavior as before this change.
  let skills = sl.listSkills()
  if skills.len == 0: return ""

  proc isAllowed(s: SkillInfo): bool =
    if allowedNames.len == 0 or s.source == "workstation": return true
    let nameHyphen = s.name.replace("_", "-")
    return s.name in allowedNames or nameHyphen in allowedNames

  proc matchesChannel(s: SkillInfo, ch: string): bool =
    if ch.len == 0 or s.channels.len == 0: return false
    for c in s.channels:
      if c.toLowerAscii() == ch.toLowerAscii(): return true
    return false

  proc emitOne(s: SkillInfo, lines: var seq[string], activeForChannel: bool) =
    lines.add("  <skill>")
    lines.add("    <name>" & escapeXML(s.name) & "</name>")
    lines.add("    <description>" & escapeXML(s.description) & "</description>")
    lines.add("    <location>" & escapeXML(s.location) & "</location>")
    lines.add("    <source>" & s.source & "</source>")
    if s.channels.len > 0:
      lines.add("    <channels>" & s.channels.join(", ") & "</channels>")
    if activeForChannel:
      lines.add("    <active_for_channel>true</active_for_channel>")
    if s.requires_tools.len > 0:
      lines.add("    <requires_tools>" & s.requires_tools.join(", ") & "</requires_tools>")
    lines.add("  </skill>")

  var lines = @["<skills>"]
  let ch = currentChannel
  # Treat "social" as introspection-only (the CLI `claw agent prompt`
  # default for buildSystemPrompt's channel parameter). It's not a real
  # delivery surface, so don't filter — operators inspecting the prompt
  # want to see every skill the agent has been granted.
  let realChannel = ch.len > 0 and ch.toLowerAscii() != "social"
  if realChannel:
    # Pass 1: skills explicitly tagged for the current channel.
    for s in skills:
      if not s.isAllowed: continue
      if not s.matchesChannel(ch): continue
      s.emitOne(lines, activeForChannel = true)
    # Pass 2: channel-agnostic skills (no channels declaration).
    # Skills tagged for OTHER channels are skipped — they're noise on
    # this delivery surface.
    for s in skills:
      if not s.isAllowed: continue
      if s.channels.len > 0: continue   # tagged → already in pass 1 or filtered
      s.emitOne(lines, activeForChannel = false)
  else:
    # Introspection / system task / no real channel: emit all allowed
    # skills in discovery order, no filtering.
    for s in skills:
      if not s.isAllowed: continue
      s.emitOne(lines, activeForChannel = false)
  lines.add("</skills>")
  return lines.join("\n")

proc buildChannelActiveSkillRecipes*(sl: SkillsLoader,
                                      allowedNames: seq[string],
                                      currentChannel: string): string =
  ## Inline the FULL SKILL.md body (frontmatter stripped) for any skill
  ## tagged for the current channel. Returned as a top-level prompt
  ## section so the agent has the decision matrix always-on, not behind
  ## a `read_file` round-trip.
  ##
  ## Why: `<active_for_channel>true</active_for_channel>` plus a handbook
  ## clause saying "consult the SKILL.md before delivering" was not
  ## strong enough on its own to override the model's default
  ## inline-markdown bias. Inlining the recipes eliminates the extra
  ## tool call AND puts the patterns where the model's attention is
  ## strongest (top-level system-prompt sections).
  ##
  ## Cost: ~2-3K tokens per channel-active skill, paid once per turn.
  ## Empty when channel is unspecified, "social" (introspection), or
  ## no allowed skill matches the channel.
  if currentChannel.len == 0 or currentChannel.toLowerAscii() == "social":
    return ""
  let skills = sl.listSkills()
  if skills.len == 0: return ""
  var blocks: seq[string]
  for s in skills:
    # Allowedness gate matches buildSkillsSummary's logic.
    if allowedNames.len > 0 and s.source != "workstation":
      let nameHyphen = s.name.replace("_", "-")
      if s.name notin allowedNames and nameHyphen notin allowedNames:
        continue
    # Channel match.
    if s.channels.len == 0: continue
    var matches = false
    for c in s.channels:
      if c.toLowerAscii() == currentChannel.toLowerAscii():
        matches = true; break
    if not matches: continue
    # Inline content.
    if not fileExists(s.path): continue
    let content = stripFrontmatter(readFile(s.path)).strip()
    if content.len == 0: continue
    blocks.add("## " & s.name & " (active for `" & currentChannel & "`)\n\n" & content)
  if blocks.len == 0: return ""
  return "# Channel-Active Skill Recipes\n\nThe following skill " &
         "content is INLINED below because the skill is tagged for " &
         "the current channel (`" & currentChannel & "`). You do NOT " &
         "need to call `read_file` to access these recipes — apply " &
         "the decision matrices and patterns below DIRECTLY when " &
         "planning Phase C delivery.\n\n" &
         blocks.join("\n\n---\n\n")
