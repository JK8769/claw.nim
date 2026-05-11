import std/[os, strutils, sequtils, json, options, sets, algorithm]
import openclaw_compat, skill_types
export skill_types
import ../logger
import std/tables



type
  SkillsLoader* = ref object
    ## 3-tier skill discovery:
    ##   Tier 1 Foundation  — universal skills from the claw distribution (e.g. `tools`)
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
    loadedLazySkills*: HashSet[string]
      ## Session-scoped: names of `loading: lazy` skills the agent has called
      ## `skill action=load` on. The prompt builder inlines their bodies on
      ## subsequent turns until `skill action=unload` removes them. Per
      ## SkillsLoader (which is per-agent), so different agents have
      ## independent activation sets. Sticky: not auto-evicted — the agent
      ## owns lifecycle to avoid mid-procedure context loss.
    loadedLazyHandbooks*: HashSet[string]
      ## Session-scoped: names of `loading: lazy` competency handbooks the
      ## agent has explicitly loaded. Same mechanism as loadedLazySkills,
      ## but for the Tier-2 procedural-discipline surface (HANDBOOK.md
      ## bodies inlined by `buildHandbooksSection`). A competency in the
      ## agent's `practices` list with loading=lazy stays as a stub until
      ## loaded; loading a competency NOT in practices still inlines its
      ## body (explicit load is the strongest signal).

proc newSkillsLoader*(workspace, projectCompetencies, companySkills, foundationSkills, openClawExtensions: string, workstationSkills: string = ""): SkillsLoader =
  SkillsLoader(
    workspace: workspace,
    projectCompetencies: projectCompetencies,
    companySkills: companySkills,
    foundationSkills: foundationSkills,
    openClawExtensions: openClawExtensions,
    workstationSkills: workstationSkills,
    loadedLazySkills: initHashSet[string](),
    loadedLazyHandbooks: initHashSet[string]()
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
          elif key == "loading":
            # Strip optional surrounding quotes; lower-case for tolerant matching
            var v = val
            if v.len >= 2 and v[0] == '"' and v[^1] == '"': v = v[1 .. ^2]
            result.loading = v.toLowerAscii()

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
        channels: meta.channels,
        loading: meta.loading
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

proc readCompetencyJson(path: string): JsonNode =
  ## Tolerant COMPETENCY.json reader — returns nil on parse failure
  ## rather than crashing the prompt build.
  if not fileExists(path): return nil
  try: parseJson(readFile(path))
  except CatchableError: nil

proc listCompetencies*(sl: SkillsLoader): seq[CompetencyInfo] =
  ## Walk projectCompetencies/ enumerating each subdir's COMPETENCY.json +
  ## HANDBOOK.md presence. Used by the `skill` tool's list action and by
  ## the prompt builder when deciding whether to inline a handbook body.
  let root = sl.projectCompetencies
  if root.len == 0 or not dirExists(root): return
  for kind, entry in walkDir(root):
    if kind != pcDir: continue
    let name = lastPathPart(entry)
    if name.startsWith("."): continue
    let compFile = entry / "COMPETENCY.json"
    let hb = entry / "HANDBOOK.md"
    var info = CompetencyInfo(
      name: name,
      hasHandbook: fileExists(hb),
      handbookPath: hb,
      loading: "always"
    )
    let j = readCompetencyJson(compFile)
    if j != nil and j.kind == JObject:
      if j.hasKey("description") and j["description"].kind == JString:
        info.description = j["description"].getStr()
      if j.hasKey("loading") and j["loading"].kind == JString:
        let v = j["loading"].getStr().toLowerAscii()
        if v == "lazy": info.loading = "lazy"
    result.add(info)

proc competencyByName*(sl: SkillsLoader, name: string): Option[CompetencyInfo] =
  ## Resolve a competency by exact name OR hyphen/underscore variant —
  ## same tolerance as the skill resolver so agents don't have to know
  ## the canonical form.
  let target = name.toLowerAscii()
  let underscore = target.replace("-", "_")
  let hyphen = target.replace("_", "-")
  for c in sl.listCompetencies():
    let nl = c.name.toLowerAscii()
    if nl == target or nl == underscore or nl == hyphen:
      return some(c)
  none(CompetencyInfo)

type
  SkillScheduleDecl* = object
    ## A single scheduled-task declaration loaded from a skill's
    ## `SCHEDULES.json`. Translation to a CronJob happens in gateway.nim
    ## (which holds the scheduler instance) so this module stays free
    ## of scheduler-specific types.
    skillName*: string         ## resolved owning skill (sanitised)
    name*: string              ## stable id within the skill
    description*: string
    everySeconds*: int         ## 0 if not periodic
    atIso*: string             ## empty if not one-shot
    atHour*: int               ## 0–23 = pin first fire to that local hour
                               ## (interval continues at the same time
                               ## thereafter). -1 = unset, falls back to
                               ## "first fire shortly after registration."
                               ## Use this for jobs whose underlying data
                               ## needs settlement time (e.g. sungrow
                               ## history finalises a few hours after
                               ## midnight — sync at 09:00 not 02:00).
    enabled*: bool
    kind*: string              ## "tool_call" | "agent_tick"
    # tool_call fields
    tool*: string
    args*: JsonNode            ## JObject; nil ok
    runAs*: string             ## empty → caller defaults to nc:1
    # agent_tick fields
    agent*: string
    message*: string

proc parseSchedulesFile(path, skillName: string): seq[SkillScheduleDecl] =
  ## Parse a skill's SCHEDULES.json into typed declarations. Tolerates
  ## missing fields with sane defaults; logs and skips malformed
  ## entries rather than failing the whole skill load.
  if not fileExists(path): return
  var raw: JsonNode
  try:
    raw = parseFile(path)
  except CatchableError as e:
    warnCF("skills_loader", "Failed to parse SCHEDULES.json — ignoring",
           {"path": path, "error": e.msg}.toTable)
    return
  if raw.kind != JArray:
    warnCF("skills_loader", "SCHEDULES.json must be a JSON array — ignoring",
           {"path": path, "kind": $raw.kind}.toTable)
    return
  for entry in raw:
    if entry.kind != JObject: continue
    var d = SkillScheduleDecl(
      skillName: skillName,
      name: entry{"name"}.getStr(""),
      description: entry{"description"}.getStr(""),
      everySeconds: entry{"every_seconds"}.getInt(0),
      atIso: entry{"at_iso"}.getStr(""),
      atHour: entry{"at_hour"}.getInt(-1),
      enabled: entry{"enabled"}.getBool(true),
      kind: entry{"kind"}.getStr("tool_call"),
      tool: entry{"tool"}.getStr(""),
      runAs: entry{"run_as"}.getStr(""),
      agent: entry{"agent"}.getStr(""),
      message: entry{"message"}.getStr(""),
    )
    if entry.hasKey("args") and entry["args"].kind == JObject:
      d.args = entry["args"]
    if d.name.len == 0:
      warnCF("skills_loader", "Skipping unnamed schedule entry",
             {"skill": skillName, "path": path}.toTable)
      continue
    if d.kind == "tool_call" and d.tool.len == 0:
      warnCF("skills_loader", "Skipping tool_call schedule with no tool",
             {"skill": skillName, "schedule": d.name}.toTable)
      continue
    if d.kind == "agent_tick" and d.agent.len == 0:
      warnCF("skills_loader", "Skipping agent_tick schedule with no agent",
             {"skill": skillName, "schedule": d.name}.toTable)
      continue
    if d.everySeconds <= 0 and d.atIso.len == 0:
      warnCF("skills_loader", "Skipping schedule with no every_seconds or at_iso",
             {"skill": skillName, "schedule": d.name}.toTable)
      continue
    result.add(d)

proc listAllSkillSchedules*(sl: SkillsLoader): seq[SkillScheduleDecl] =
  ## Walk all known skills, read each SCHEDULES.json if present, and
  ## return the union of declarations. Caller (gateway boot) groups
  ## by `skillName` and feeds each group to scheduler.reconcileSkillJobs
  ## so removal of a skill cleanly drops its scheduled jobs.
  let skills = sl.listSkills()
  for s in skills:
    let path = s.location / "SCHEDULES.json"
    if not fileExists(path): continue
    let decls = parseSchedulesFile(path, s.name)
    if decls.len > 0:
      infoCF("skills_loader", "Loaded skill schedules",
             {"skill": s.name, "count": $decls.len}.toTable)
      result.add(decls)

proc loadSkillsForContext*(sl: SkillsLoader, skillNames: seq[string]): string =
  if skillNames.len == 0: return ""
  var parts: seq[string] = @[]
  for name in skillNames:
    let (content, ok) = sl.loadSkill(name)
    if ok:
      parts.add("### Skill: " & name & "\n\n" & content)
  return parts.join("\n\n---\n\n")


proc tierOrder(source: string): int =
  ## Maps the `source` field to a tier-priority for prompt-display
  ## ordering. Foundation (Tier 1) is universal disciplines and surfaces
  ## first so the agent sees the broadest-scoped skills at the top of
  ## the catalog; company (Tier 2) next; workstation (Tier 3) last
  ## because it's per-agent and the agent already knows what they
  ## authored. The legacy variants sort with their canonical tier.
  case source
  of "foundation", "foundation-legacy": 1
  of "company", "company-legacy": 2
  of "workstation": 3
  of "workspace": 4
  of "openclaw": 5
  else: 99

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
  ##
  ## Within each pass, skills are sorted by tier (foundation → company
  ## → workstation → workspace → openclaw) so the agent's prompt
  ## surfaces the four-layer architecture visibly — Tier 1 universal
  ## disciplines (e.g. `tools`) appear first, then per-company workflows,
  ## then the agent's own authored skills. Matches the 4-layer principle
  ## taught by the `tools` foundation skill.
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
    if s.loading == "lazy":
      let active = s.name in sl.loadedLazySkills or
                   s.name.replace("_", "-") in sl.loadedLazySkills
      lines.add("    <loading>lazy</loading>")
      lines.add("    <loaded>" & (if active: "true" else: "false") & "</loaded>")
      if not active:
        lines.add("    <hint>call `skill action=load name=" & s.name &
                  "` to inline this skill's body for this session</hint>")
    if s.requires_tools.len > 0:
      lines.add("    <requires_tools>" & s.requires_tools.join(", ") & "</requires_tools>")
    lines.add("  </skill>")

  # Stable sort by tier within each pass — preserves discovery order
  # within a tier (matters for shadowing semantics) while grouping
  # foundation/company/workstation visually.
  proc emitGroup(group: seq[SkillInfo], lines: var seq[string],
                  activeForChannel: bool) =
    var sorted = group
    sorted.sort(proc (a, b: SkillInfo): int = cmp(tierOrder(a.source), tierOrder(b.source)))
    var lastTier = -1
    for s in sorted:
      let t = tierOrder(s.source)
      if t != lastTier:
        case t
        of 1: lines.add("  <!-- Foundation (Tier 1) — universal disciplines -->")
        of 2: lines.add("  <!-- Company (Tier 2) — this company's workflows -->")
        of 3: lines.add("  <!-- Workstation (Tier 3) — your own authored -->")
        of 4: lines.add("  <!-- Workspace — shared cross-office -->")
        of 5: lines.add("  <!-- OpenClaw — third-party plugins -->")
        else: discard
        lastTier = t
      s.emitOne(lines, activeForChannel = activeForChannel)

  var lines = @["<skills>"]
  let ch = currentChannel
  # Treat "social" as introspection-only (the CLI `claw agent prompt`
  # default for buildSystemPrompt's channel parameter). It's not a real
  # delivery surface, so don't filter — operators inspecting the prompt
  # want to see every skill the agent has been granted.
  let realChannel = ch.len > 0 and ch.toLowerAscii() != "social"
  if realChannel:
    # Pass 1: skills explicitly tagged for the current channel.
    var channelTagged: seq[SkillInfo]
    for s in skills:
      if not s.isAllowed: continue
      if not s.matchesChannel(ch): continue
      channelTagged.add(s)
    emitGroup(channelTagged, lines, activeForChannel = true)
    # Pass 2: channel-agnostic skills (no channels declaration).
    # Skills tagged for OTHER channels are skipped — they're noise on
    # this delivery surface.
    var agnostic: seq[SkillInfo]
    for s in skills:
      if not s.isAllowed: continue
      if s.channels.len > 0: continue
      agnostic.add(s)
    emitGroup(agnostic, lines, activeForChannel = false)
  else:
    # Introspection / system task / no real channel: emit all allowed
    # skills, sorted by tier so the layering is visible.
    var all: seq[SkillInfo]
    for s in skills:
      if not s.isAllowed: continue
      all.add(s)
    emitGroup(all, lines, activeForChannel = false)
  lines.add("</skills>")
  return lines.join("\n")

proc buildLoadedLazySkillBodies*(sl: SkillsLoader,
                                  allowedNames: seq[string]): string =
  ## Inline the FULL body of any `loading: lazy` skill the agent has
  ## activated this session via `skill action=load name=<n>`. Mirrors
  ## `buildChannelActiveSkillRecipes` but the trigger is per-session
  ## activation rather than channel matching. Sticky: stays inlined
  ## until `skill action=unload`.
  ##
  ## Why: lazy skills appear as stubs in the catalog by default. When
  ## the agent decides one is relevant to the task at hand, loading
  ## inlines the body so subsequent turns don't need a `read_file`
  ## round-trip per consultation.
  if sl.loadedLazySkills.len == 0: return ""
  let skills = sl.listSkills()
  if skills.len == 0: return ""
  var blocks: seq[string]
  for s in skills:
    if s.loading != "lazy": continue
    # Match by either the sanitized name or the hyphenated original
    let nameHyphen = s.name.replace("_", "-")
    if s.name notin sl.loadedLazySkills and
       nameHyphen notin sl.loadedLazySkills: continue
    # Allowedness gate matches the catalog's logic
    if allowedNames.len > 0 and s.source != "workstation":
      if s.name notin allowedNames and nameHyphen notin allowedNames:
        continue
    if not fileExists(s.path): continue
    let content = stripFrontmatter(readFile(s.path)).strip()
    if content.len == 0: continue
    blocks.add("## " & s.name & " (loaded for this session)\n\n" & content)
  if blocks.len == 0: return ""
  return "# Loaded Skill Bodies\n\nThe following skill content is " &
         "INLINED below because you called `skill action=load` on it. " &
         "Apply the patterns directly — no `read_file` round-trip needed. " &
         "Call `skill action=unload name=<n>` when the task is done to free " &
         "context.\n\n" & blocks.join("\n\n---\n\n")

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
