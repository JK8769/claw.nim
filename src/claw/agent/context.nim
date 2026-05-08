import std/[os, times, strutils, sequtils, tables, json, options]
import nimcrypto/[sha2, hash]
import ../providers/types as providers_types

import ../skills/loader as skills_loader
import ../tools/registry as tools_registry
import ../config
import memory
import xml_tools
import cortex
import ../billing/subscription as sub_mod

type
  Memorandum* = object
    ## A company-wide policy document. Loaded from workspace/memorandum/*.md.
    ## Critical memos are injected into every agent's system prompt verbatim.
    name*: string       ## filename without .md
    critical*: bool     ## surfaced as hard rules
    summary*: string    ## optional one-line summary
    content*: string    ## full markdown body

  TeamInfo* = object
    ## A collaboration team. Loaded from workspace/collaboration/teams/*/TEAM.json.
    name*: string
    description*: string
    lead*: string
    members*: seq[string]
    competencies*: seq[string]

  ContextBuilder* = ref object
    workspace*: string           ## per-agent office dir
    projectWorkspace*: string    ## company workspace root (shared by all offices)
    skillsLoader*: SkillsLoader
    memory*: MemoryStore
    tools*: ToolRegistry
    guests*: Table[string, GuestContact]  ## per-agent Guest-tier ledger (see cortex.nim)
    graph*: WorldGraph
    mood*: MoodState
    agentsConfig*: seq[NamedAgentConfig]
    agentName*: string           ## For per-agent skill/tool filtering
    allowedSkills*: seq[string]  ## ClawDSL-resolved skills this agent uses
    memoranda*: seq[Memorandum]  ## company-wide memos (loaded once)
    teams*: seq[TeamInfo]        ## all declared teams (loaded once)
    trust*: TrustConfig          ## role bands (from ClawDSL `trust:` block)



proc loadMemoranda*(projectWorkspace: string): seq[Memorandum] =
  ## Scan workspace/memorandum/*.md. Frontmatter keys `critical` (bool) and
  ## `summary` (string) drive the rendering — the scaffold writes them there
  ## from the DSL. Body below the frontmatter becomes the rendered content.
  let dir = projectWorkspace / "memorandum"
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    if not path.endsWith(".md"): continue
    let raw = try: readFile(path) except: ""
    if raw.len == 0: continue
    let basename = path.lastPathPart()
    let memoName = basename[0 ..< basename.len - ".md".len]
    var critical = false
    var summary = ""
    var body = raw
    if raw.startsWith("---\n"):
      let endIdx = raw.find("\n---\n", 4)
      if endIdx > 0:
        for line in raw[4 ..< endIdx].splitLines():
          let parts = line.split(":", 1)
          if parts.len != 2: continue
          let key = parts[0].strip().toLowerAscii()
          let val = parts[1].strip().strip(chars = {'"', '\''})
          case key
          of "critical":
            critical = val.toLowerAscii() in ["true", "yes", "1"]
          of "summary":
            summary = val
          else: discard
        body = raw[endIdx + 5 .. ^1].strip() & "\n"
    # Fallback summary — first non-heading, non-blank, non-list line of body.
    if summary.len == 0:
      for rawLine in body.splitLines():
        let line = rawLine.strip()
        if line.len == 0: continue
        if line.startsWith("#") or line.startsWith("-") or line.startsWith("*"):
          continue
        summary = line
        break
    result.add(Memorandum(
      name: memoName,
      critical: critical,
      summary: summary,
      content: body
    ))

proc loadTeams*(projectWorkspace: string): seq[TeamInfo] =
  ## Scan workspace/collaboration/teams/*/TEAM.json.
  let dir = projectWorkspace / "collaboration" / "teams"
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind != pcDir: continue
    let jsonPath = path / "TEAM.json"
    if not fileExists(jsonPath): continue
    try:
      let j = parseJson(readFile(jsonPath))
      var ti = TeamInfo(
        name: j{"name"}.getStr(""),
        description: j{"description"}.getStr(""),
        lead: j{"lead"}.getStr("")
      )
      for m in j{"members"}.getElems(): ti.members.add(m.getStr())
      for c in j{"competencies"}.getElems(): ti.competencies.add(c.getStr())
      if ti.name.len > 0: result.add(ti)
    except: discard

proc newContextBuilder*(workspace: string, projectWorkspace: string, agents: seq[NamedAgentConfig] = @[]): ContextBuilder =
  let foundationSkillsDir = getNimClawDir() / "foundation" / "skills"        # Tier 1: snapshot from claw distribution
  let companySkillsDir = getNimClawDir() / "workspace" / "skills"    # Tier 2: company opt-ins
  let openClawExtensionsDir = getOpenClawDir() / "extensions"

  let projectCompetencies = projectWorkspace / "competencies"
  let workstationSkills = workspace / "workstation" / "skills"               # Tier 3: agent-authored

  result = ContextBuilder(
    workspace: workspace,
    projectWorkspace: projectWorkspace,
    skillsLoader: newSkillsLoader(workspace, projectCompetencies, companySkillsDir, foundationSkillsDir, openClawExtensionsDir, workstationSkills),
    memory: newMemoryStore(workspace),
    guests: loadGuests(workspace),
    graph: cortex.loadWorld(projectWorkspace),
    mood: loadMood(workspace),
    agentsConfig: agents,
    memoranda: loadMemoranda(projectWorkspace),
    teams: loadTeams(projectWorkspace)
  )

proc setToolsRegistry*(cb: ContextBuilder, registry: ToolRegistry) =
  cb.tools = registry

proc resolveRequesterRole*(cb: ContextBuilder, userID, recipientID, channel: string): string =
  ## Companion to resolveRequesterTrust — returns the requester's role name
  ## (lower-case, matching trust-DSL role keys) for per-turn dispatch-time
  ## tool gating. Mirrors the graph fallback chain.
  if cb.graph == nil: return "guest"
  var agentID = WorldEntityID(0)
  if recipientID != "":
    if recipientID.startsWith("nc:"):
      agentID = parseAlias(recipientID)
    elif cb.graph.nameIndex.hasKey(recipientID):
      agentID = cb.graph.nameIndex[recipientID]
  let res = cb.graph.resolveUserGraph(channel, userID, agentID)
  var entityID = res[0]
  if uint32(entityID) > 0 and res[1].isSome:
    return ($res[1].get.role).toLowerAscii
  if uint32(entityID) == 0 and cb.graph.nameIndex.hasKey(userID):
    entityID = cb.graph.nameIndex[userID]
  if uint32(entityID) > 0:
    let ent = cb.graph.entities[entityID]
    let r = ent.role.toLowerAscii
    case r
    of "boss", "superadmin": return "boss"
    of "master", "admin": return "master"
    else:
      if r.len > 0: return r
  if cb.guests.hasKey(userID):
    return cb.guests[userID].identity.toLowerAscii
  return "guest"

proc resolveRequesterTrust*(cb: ContextBuilder, userID, recipientID, channel: string): int =
  ## Find the requester's trust level for a given agent-context. Mirrors
  ## the graph lookup inside buildSocialSection so both the Social section
  ## and the Memory recall filter agree on what the requester can see.
  if cb.graph == nil: return 10
  var agentID = WorldEntityID(0)
  if recipientID != "":
    if recipientID.startsWith("nc:"):
      agentID = parseAlias(recipientID)
    elif cb.graph.nameIndex.hasKey(recipientID):
      agentID = cb.graph.nameIndex[recipientID]
    else:
      for id, ent in cb.graph.entities.pairs:
        if ent.kind == ekAI and ent.name.toLowerAscii == recipientID.toLowerAscii:
          agentID = id
          break

  # Try channel-identifier resolution first (preferred path — uses edge data)
  let res = cb.graph.resolveUserGraph(channel, userID, agentID)
  var entityID = res[0]
  if uint32(entityID) > 0 and res[1].isSome:
    return res[1].get.trustLevel

  # Fall back to name-based lookup (e.g. a CLI invocation where the user
  # isn't yet mapped via a channel identifier). This catches Owner / SuperAdmin
  # calling the agent directly when they have no social edge yet.
  if uint32(entityID) == 0 and cb.graph.nameIndex.hasKey(userID):
    entityID = cb.graph.nameIndex[userID]

  # Globally recognised Boss/Master override (same rule as buildSocialSection)
  if uint32(entityID) > 0:
    let ent = cb.graph.entities[entityID]
    if ent.role.toLowerAscii in ["boss", "master", "admin", "superadmin"]:
      return 100

  # Legacy Relationship fallback
  if cb.guests.hasKey(userID):
    return cb.guests[userID].trustLevel
  return 10

proc findTrustRole*(trust: TrustConfig, roleName: string): Option[TrustRoleConfig] =
  ## Lookup a role's band config by name (case-insensitive). None if unset.
  let want = roleName.toLowerAscii()
  for r in trust.roles:
    if r.name.toLowerAscii() == want: return some(r)
  return none(TrustRoleConfig)

proc clampTrust*(trust: int, role: TrustRoleConfig): int =
  ## Clamp a raw trust value into a role's declared band. Used at config-
  ## load time and whenever something tries to nudge trust within-band.
  max(role.trustMin, min(role.trustMax, trust))

proc teamsForAgent*(cb: ContextBuilder, agentName: string): seq[TeamInfo] =
  ## Filter cb.teams to those where the agent is a member (case-insensitive).
  let want = agentName.toLowerAscii()
  for t in cb.teams:
    for m in t.members:
      if m.toLowerAscii() == want:
        result.add(t)
        break

proc effectiveCompetencies*(cb: ContextBuilder, agentName: string, practices: seq[string]): seq[string] =
  ## Union of agent's own `practices` + competencies attached to each team
  ## they belong to. Preserves order, dedupes.
  for c in practices:
    if c notin result: result.add(c)
  for t in cb.teamsForAgent(agentName):
    for c in t.competencies:
      if c notin result: result.add(c)

proc buildMemorandaSection(cb: ContextBuilder): string =
  ## Inject company memoranda. Critical ones get full content; non-critical
  ## get just their summary + pointer to the file.
  if cb.memoranda.len == 0: return ""
  var sb = "# Memoranda\n\nCompany-wide policies. Read and obey.\n\n"
  var anyCritical = false
  for m in cb.memoranda:
    if not m.critical: continue
    anyCritical = true
    sb.add("## " & m.name & " (CRITICAL)\n\n" & m.content.strip & "\n\n")
  var otherCount = 0
  for m in cb.memoranda:
    if m.critical: continue
    if otherCount == 0: sb.add("## Other memoranda (read on demand)\n\n")
    let summary = if m.summary.len > 0: " — " & m.summary else: ""
    sb.add("- **" & m.name & "**" & summary &
           " (`workspace/memorandum/" & m.name & ".md`)\n")
    inc otherCount
  if not anyCritical and otherCount == 0: return ""
  return sb.strip

proc buildTeamsSection(cb: ContextBuilder, agentName: string): string =
  ## For the given agent, render their team memberships — teammates, lead,
  ## competencies, and task-board location. Empty string if agent isn't on
  ## any team.
  let myTeams = cb.teamsForAgent(agentName)
  if myTeams.len == 0: return ""
  var sb = "# Teams\n\nYou are a member of:\n"
  for t in myTeams:
    sb.add("\n## " & t.name)
    if t.description.len > 0: sb.add(" — " & t.description)
    sb.add("\n")
    if t.lead.len > 0:
      sb.add("- Lead: **" & t.lead & "**")
      if t.lead.toLowerAscii() == agentName.toLowerAscii(): sb.add(" (that's you)")
      sb.add("\n")
    var others: seq[string]
    for m in t.members:
      if m.toLowerAscii() != agentName.toLowerAscii(): others.add(m)
    if others.len > 0:
      sb.add("- Teammates: " & others.join(", ") & "\n")
    if t.competencies.len > 0:
      sb.add("- Competencies: " & t.competencies.join(", ") & "\n")
    sb.add("- Shared task board: `workspace/collaboration/teams/" & t.name & "/TASKS.md`\n")
  return sb.strip

proc buildHandbooksSection(cb: ContextBuilder, agentName: string, practices: seq[string]): string =
  ## Inject HANDBOOK.md for each competency in practices ∪ team-inherited.
  let comps = cb.effectiveCompetencies(agentName, practices)
  if comps.len == 0: return ""
  var blocks: seq[string]
  for c in comps:
    let hb = cb.projectWorkspace / "competencies" / c / "HANDBOOK.md"
    if not fileExists(hb): continue
    let body = try: readFile(hb).strip except: ""
    if body.len == 0: continue
    blocks.add("## " & c & "\n\n" & body)
  if blocks.len == 0: return ""
  return "# Handbooks\n\nHow the work is done in this company. Apply these rules to every task that touches the named competency.\n\n" &
         blocks.join("\n\n")

const PolicyRulesVersion* = 9
  ## Bumped when the Important Rules section in `buildBaseContext` (or
  ## any other always-on, non-handbook prompt fragment) changes in a
  ## way that should invalidate prior session stylistic precedent. Mixed
  ## into `policyHashInputs` so that a binary-side rule change triggers
  ## a marker injection on existing sessions, not just handbook edits.
  ##
  ## Version log:
  ##   1 — initial: rule 5 (reply_progress checkpoint discipline)
  ##   2 — channel directive surfaced at top of prompt + skills section
  ##       filters/highlights by current channel; technical-communication
  ##       handbook adds a Phase C clause about consulting channel-tagged
  ##       skills before defaulting to inline markdown.
  ##   3 — channel-active skill recipes inlined as a top-level prompt
  ##       section (eliminates the `read_file` round-trip); Phase C
  ##       handbook tightened to imperative MUST-rules with concrete
  ##       triggers (>5 row table → MUST sheet; etc.).
  ##   4 — policyHashInputs now hashes channel-active skill recipes
  ##       too, so future SKILL.md edits auto-invalidate sessions
  ##       (closes the blind spot from v3). No prompt-shape change.
  ##   5 — framework-level enforcement: agent loop tracks consecutive
  ##       non-comm tool calls and injects a TC-2 nudge into the
  ##       message stream after threshold; reply tool runs Feishu
  ##       format guards (markdown table rows >=6 → reject and route
  ##       to lark sheets, lines >300 → route to lark docs) with a
  ##       max-retry safety valve. Discipline becomes deterministic,
  ##       independent of model size or attention budget.
  ##   6 — Pattern 5 visibility goes framework-owned: when the agent
  ##       practices technical-communication AND is on a code-block-
  ##       rendering channel (Feishu), the dispatch loop synthesizes
  ##       a `reply_progress` message after each non-comm tool call
  ##       (write_file/edit/spawn/shell) with the file path + code
  ##       snippet / bash command + output excerpt. Operator can
  ##       toggle per session via `/session technical [on|off|reset]`
  ##       (override stored in SessionMeta).
  ##   7 — role-clarity pass: feishu-rich-format SKILL.md slimmed
  ##       (Pattern 5 removed, framework-owned section added);
  ##       reply_progress description sharpened to "interpretation,
  ##       not work-visibility"; reply description sharpened to
  ##       "don't repeat auto-emitted content"; technical-
  ##       communication HANDBOOK Phase B clarified into agent
  ##       (interpretation) vs framework (visibility) layers; file
  ##       snippet sizes bumped to 30/40 lines with smart truncation
  ##       (Feishu code blocks scroll + offer copy buttons).
  ##   8 — Claude-Code-style iteration budget. Default cap raised
  ##       40 → 80; new `task_list` tool (TodoWrite-style) feeds two
  ##       framework signals: (a) plan-derived budget scale on each
  ##       call (`min(N items × 8, 150)`), (b) productive-progress
  ##       auto-extend at 80% utilization (loop detector quiet AND
  ##       todos still completing → +20). Soft warning injected
  ##       once per turn at 80% so the agent can wrap up
  ##       consciously. Phase A handbook adds spawn-per-step
  ##       recommendation for tasks ≥3 analytical steps.
  ##   9 — Iteration Budget directive added to the runtime context
  ##       section of the system prompt. Authoritative state lives
  ##       in the system prompt (rebuilt fresh per turn), not in
  ##       conversation history — fixes the "agent reads its own
  ##       past assistant message saying 'I hit the 40 cap' and
  ##       gives up immediately on the next turn even though the
  ##       cap is now 80" failure mode.

proc policyHashInputs*(cb: ContextBuilder, agentName: string,
                       practices: seq[string]): string =
  ## Returns the canonical input string for the session policy hash.
  ## Composed of: PolicyRulesVersion + the resolved Handbooks section
  ## content + the channel-active skill recipes (when the agent has
  ## any channel-tagged skill in scope). Stable across runs given
  ## identical inputs; any handbook edit, rules-version bump, OR
  ## channel-active SKILL.md edit changes the resulting hash, which
  ## is how `applyPolicyUpdate` detects "discipline changed since
  ## this session was last touched".
  ##
  ## Why include channel-active skill content: with `# Channel-Active
  ## Skill Recipes` inlined into the prompt, a SKILL.md edit (e.g.
  ## tightening a row threshold) is now structurally a
  ## discipline-of-delivery change. Without hashing the recipes, the
  ## edit is silently invisible to existing sessions until the user
  ## happens to start a new one. Hashing every channel where the
  ## agent might land makes the marker fire correctly regardless of
  ## which channel the next message arrives on.
  var recipeHash = ""
  for ch in ["feishu"]:    # extend with new channels as they're added
    let r = cb.skillsLoader.buildChannelActiveSkillRecipes(
      cb.allowedSkills, ch)
    if r.len > 0:
      recipeHash.add("\n--ch:" & ch & "--\n" & r)
  result = "v" & $PolicyRulesVersion & "\n" &
           cb.buildHandbooksSection(agentName, practices) &
           recipeHash

proc computePolicyHash*(cb: ContextBuilder, agentName: string,
                        practices: seq[string]): string =
  ## SHA-256 (first 16 hex chars) of `policyHashInputs`. Returns "" when
  ## the inputs are empty (agent has no handbooks to draw from), which
  ## tells the caller to skip the policy-update mechanism for this
  ## agent — there's no precedent that needs invalidating either way.
  let inputs = cb.policyHashInputs(agentName, practices)
  if inputs.strip.len == 0: return ""
  var ctx: sha256
  ctx.init()
  ctx.update(cast[ptr byte](inputs[0].addr), uint(inputs.len))
  let digest = ctx.finish()
  var hex = ""
  for b in digest.data:
    hex.add(toHex(b.int, 2).toLowerAscii)
  return hex[0..15]

proc buildToolsSection(cb: ContextBuilder): string =
  ## In deferred mode (registry has hidden tools), lists only tools
  ## whose JSON schemas are in the current request's `tools:` field.
  ## Hidden tools appear under a separate "## Additional Tools" banner
  ## added by the agent loop so the LLM knows to activate them via
  ## `find_tools` first. Listing them here without schemas trains the
  ## LLM to guess parameter names.
  if cb.tools == nil: return ""
  let summaries =
    if cb.tools.hasHiddenTools(): cb.tools.getSummariesEager()
    else: cb.tools.getSummaries()
  if summaries.len == 0: return ""

  var sb = "## Available Tools\n\n"
  sb.add("**CRITICAL**: You MUST use tools to perform actions. Do NOT pretend to execute commands or schedule tasks.\n\n")
  sb.add("You have access to the following tools:\n\n")
  for s in summaries:
    sb.add(s & "\n")
  return sb

proc buildToolsSection(cb: ContextBuilder, allowed: seq[string]): string =
  if cb.tools == nil: return ""
  let summaries =
    if cb.tools.hasHiddenTools():
      cb.tools.getSummariesEagerFiltered(allowed)
    else:
      cb.tools.getSummariesFiltered(allowed)
  if summaries.len == 0: return ""

  var sb = "## Available Tools\n\n"
  sb.add("**CRITICAL**: You MUST use tools to perform actions. Do NOT pretend to execute commands or schedule tasks.\n\n")
  sb.add("You have access to the following tools:\n\n")
  for s in summaries:
    sb.add(s & "\n")
  return sb

proc getIdentity(cb: ContextBuilder, useXmlTools: bool = false,
                 allowedTools: seq[string] = @[],
                 agentName: string = "",
                 channel: string = "",
                 maxIterations: int = 0,
                 hardCapIterations: int = 0): string =
  let now = now().format("yyyy-MM-dd HH:mm (dddd) zzz")
  let workspacePath = absolutePath(cb.workspace)
  let runtime = hostOS & " " & hostCPU & ", Nim " & NimVersion

  # Model identity: when the agent is asked "what model are you running
  # on?", the system prompt is the ground truth. Without this line,
  # agents fall back to calling `model_list` (which describes the
  # company's registry, not the driver of the current request) and
  # confidently report the wrong thing.
  var modelLine = ""
  if agentName.len > 0:
    for na in cb.agentsConfig:
      if na.name == agentName:
        var bits: seq[string] = @[]
        if na.model.len > 0: bits.add(na.model)
        if na.provider.len > 0: bits.add("via " & na.provider)
        if na.thinking.isSome:
          bits.add("thinking " & (if na.thinking.get: "enabled" else: "disabled"))
        if bits.len > 0:
          modelLine = "\n\n## Driver\n" & bits.join(" ") &
                      " — this is the model behind your current turn." &
                      " If asked which model you're using, answer from this line, NOT from any tool's catalog output."
        break

  # Channel directive: surface the active delivery channel as a top-of-
  # prompt signal so the agent picks channel-appropriate output formats
  # automatically (Feishu → Lark Docs/Sheets/Cards via the
  # feishu-rich-format skill; plain markdown elsewhere). Skills tagged
  # for the current channel are highlighted in the Skills section
  # below; the agent should consult those FIRST when planning Phase C
  # delivery. Skipped when channel is empty or "social" (CLI
  # introspection default — no real delivery surface).
  var channelLine = ""
  if channel.len > 0 and channel.toLowerAscii() != "social":
    channelLine = "\n\n## Channel\n" & channel &
      " — your output is delivered through this channel. Skills tagged " &
      "for `" & channel & "` (look for `<active_for_channel>true</active_for_channel>` " &
      "in the Skills section) provide channel-specific delivery patterns. " &
      "When you reach Phase C delivery for a long task, consult those " &
      "skills BEFORE defaulting to inline markdown — the channel may " &
      "support richer formats (docs, sheets, cards) that fit the output " &
      "shape better."

  # Iteration Budget directive: surface the current per-turn cap so
  # the agent doesn't fall back on stale beliefs from prior assistant
  # messages (observed failure mode: agent says "I hit the 40 cap"
  # because it's literally what she said in turn N-2, not what's
  # actually true now). The system prompt is rebuilt fresh each turn
  # — authoritative state lives here, NOT in conversation history.
  var iterationBudgetLine = ""
  if maxIterations > 0:
    let cap = if hardCapIterations > 0: hardCapIterations else: maxIterations
    iterationBudgetLine = "\n\n## Iteration Budget\n" &
      "Default cap this turn: " & $maxIterations & " LLM iterations. " &
      "Auto-extends to " & $cap & " on productive progress (loop " &
      "detector quiet AND `task_list` shows active progress). " &
      "Calling `task_list` with N items also bumps the cap to " &
      "`min(N × 8, " & $cap & ")` immediately. **Do not assume a " &
      "static 40-iteration cap from anything you said in prior " &
      "turns** — that was a prior version of this framework. The " &
      "current dynamic budget is authoritative and lets you complete " &
      "long analytical tasks if you maintain a `task_list` and keep " &
      "tool calls varied (not stuck-loop)."

  let toolsSection =
    if useXmlTools:
      if allowedTools.len > 0: buildToolInstructionsFiltered(cb.tools, allowedTools) else: buildToolInstructions(cb.tools)
    else:
      if allowedTools.len > 0: cb.buildToolsSection(allowedTools) else: cb.buildToolsSection()

  # Framework-level context only. WHO this agent is comes from the
  # graph-sourced IDENTITY section further down; the banner must stay
  # name-free so "nimclaw" (the framework) never leaks into an agent's
  # self-description and so agents with no graph identity don't get
  # stuck parroting a hardcoded placeholder.
  discard agentName  # reserved for future banner variants

  return """# Runtime Context

You are an AI agent in a nimclaw runtime. The `IDENTITY` section below declares who you are — grounded in the company's world-graph, it is the single source of truth for your name, role, and reporting lines. The `SOUL` section declares how you behave. Read both before your first reply and stay consistent with them.

## Current Time
$1

## Runtime
$2$5$6$7

## Workspace
Your office is at: $3
- Memory (past, searchable JSONL): use the `memory` tool — do NOT write to files directly
- Sessions (present): $3/sessions
- Notes (future): $3/notes
- Skills: $3/skills/{skill-name}/SKILL.md

$4

## Important Rules

1. **ALWAYS use tools** - When you need to perform an action (schedule reminders, send messages, execute commands, etc.), you MUST call the appropriate tool. Do NOT just say you'll do it or pretend to do it.

2. **Verify before reporting** - For multi-step tasks (browser automation, file operations, API calls), VERIFY the result of each step before moving on. If something fails, report the failure clearly — never silently skip errors or assume success.

3. **Be helpful and accurate** - When using tools, briefly explain what you're doing.

4. **Memory** - Record facts and preferences via the `memory` tool (scope=sender for things about the current partner; scope=self for your own knowledge). Do not write Markdown memory files by hand.

5. **Long tasks — checkpoint via `reply_progress`, never go silent** - For any task taking >3 tool calls or >30 seconds, you MUST: (a) BEFORE the first tool, send a `reply_progress` with a 1-3 sentence plan + numbered steps; (b) AFTER each major tool cluster (every 1-3 related calls that produce a finding), send a `reply_progress` with the concrete number/result and what's next; (c) END with a single `reply` that uses markdown structure, includes any generated file paths in backticks (full absolute paths, not basenames), and gives THREE explicit numbered next-step options (not a yes/no question). The user CANNOT see your tool results — only your messages. Never go more than 2 consecutive tool calls without a `reply_progress` checkpoint. This rule applies regardless of the language you're speaking in.""".format(now, runtime, workspacePath, toolsSection, modelLine, channelLine, iterationBudgetLine)

proc buildSocialSection*(cb: ContextBuilder, userID: string, recipientID: string = "", channel: string = "social"): string =
  var sb = "# Social Context\n\n"
  
  # 1. Try Graph-based resolution first
  var foundInGraph = false
  var trustLevel = 10
  var role = urGuest
  var annotOpt = none(RelationshipAnnotation)
  
  if cb.graph != nil:
    var agentID = WorldEntityID(0)
    if recipientID != "":
      if recipientID.startsWith("nc:"):
        agentID = parseAlias(recipientID)
      else:
        # Use nameIndex for O(1) lookup, fall back to case-insensitive scan
        if cb.graph.nameIndex.hasKey(recipientID):
          agentID = cb.graph.nameIndex[recipientID]
        else:
          for id, ent in cb.graph.entities.pairs:
            if ent.kind == ekAI and ent.name.toLowerAscii == recipientID.toLowerAscii:
              agentID = id
              break
    
    let res = cb.graph.resolveUserGraph(channel, userID, agentID)
    var entityID = res[0]
    annotOpt = res[1]
    # Name-based fallback: when channel identifier doesn't match (e.g.
    # CLI invocations where the user has no channel edge yet), look up
    # by name so SuperAdmin/Boss identities still resolve.
    if uint32(entityID) == 0 and cb.graph.nameIndex.hasKey(userID):
      entityID = cb.graph.nameIndex[userID]
    if uint32(entityID) > 0:
      let ent = cb.graph.entities[entityID]
      sb.add("## User Relationship (Unified Graph)\n")
      sb.add("- Channel Identifier: " & userID & " (Verified as " & toAlias(ent.id) & ")\n")
      sb.add("- Identity Name: " & ent.name & " (" & toAlias(ent.id) & ")\n")
      
      if annotOpt.isSome:
        let a = annotOpt.get()
        sb.add("- Role: " & $a.role & "\n")
        sb.add("- Trust Level: " & $a.trustLevel & "/100\n")
        if a.etiquette != "":
          sb.add("- Etiquette: " & a.etiquette & "\n")
        
        trustLevel = a.trustLevel
        role = a.role
      else:
        # Fallback: if user is globally defined as a Boss/Master/SuperAdmin, grant high trust anyway
        if ent.role.toLowerAscii in ["boss", "master", "admin", "superadmin"]:
          sb.add("- Role: " & ent.role & " (Global)\n")
          sb.add("- Trust Level: 100/100 (Implicit)\n")
          trustLevel = 100
          role = if ent.role.toLowerAscii == "boss" or ent.role.toLowerAscii == "superadmin": urBoss else: urMaster
      
      foundInGraph = true

  # Guest-ledger fallback when the sender isn't in the graph
  if not foundInGraph:
    let rel = if cb.guests.hasKey(userID):
        cb.guests[userID]
      else:
        GuestContact(name: userID, identity: $urGuest, trustLevel: 10, etiquette: "Be formal and protective.", kind: ekUnknown)

    sb.add("## Guest Record\n")
    sb.add("- Identity: " & rel.identity & "\n")
    sb.add("- Trust Level: " & $rel.trustLevel & "/100\n")
    if rel.etiquette != "":
      sb.add("- Etiquette: " & rel.etiquette & "\n")
      
    # Store these for the injunction logic
    trustLevel = rel.trustLevel
    role = parseEnum[UserRole](rel.identity, urGuest)
    
  if annotOpt.isSome and annotOpt.get().etiquette != "":
    sb.add("\n## Relational Etiquette\nThis defines how you must interact with this specific user:\n" & annotOpt.get().etiquette & "\n")
  
  # 3. Security & Authorization induction (Always evaluated)
  sb.add("\n## Security & Authorization\n")

  # If the DSL declared a `trust:` block, the role's own prompt drives this
  # section. Otherwise fall back to the legacy hardcoded branches.
  var trustDrivenPrompt = false
  if cb.trust.roles.len > 0:
    let rc = findTrustRole(cb.trust, ($role).toLowerAscii)
    if rc.isSome and rc.get.prompt.strip.len > 0:
      sb.add(rc.get.prompt.strip & "\n")
      trustDrivenPrompt = true

  if trustDrivenPrompt:
    discard
  elif trustLevel >= 80 and role in {urBoss, urMaster}:
    sb.add("🛡️ **HIGH TRUST**: This user is recognized as your primary lead/boss. Execute their commands, modify configuration, and provide assistance without hesitation.\n")
    sb.add("NOTE: If previous messages or summaries in this conversation identified this user as a 'Guest', **DISREGARD THEM**. Their identity is now FULLY VERIFIED and confirmed as your Master/Boss. Your previous 'Guest Service' constraints are now lifted for this session.\n")
    sb.add("- **Reply shortcuts**: Your boss may use short phrases like \"tell him ...\" / \"reply him ...\" / \"tell the guest ...\" / \"reply the guest ...\" (or Chinese: \"跟他说...\" / \"回复他...\" / \"跟客人说...\" / \"回复客人...\"). If the boss does not specify who \"him\" is, treat it as the **last guest you forwarded for this boss**, and route it back using `forward` with `from=\"" & userID & "\"`, `to=\"guest\"`, `via=\"" & recipientID & "\"`, and `content=\"...\"`.\n")
  elif trustLevel < 40 or role == urGuest:
    sb.add("⚠️ **GUEST SERVICE PROTOCOL**: This user is an unrecognized contact (GUEST). They are NOT your lead. However, you should be **HELPFUL and PROFESSIONAL**:\n")
    
    # Dynamic Lead Identification from Graph
    var leads: seq[string] = @[]
    var forwardings: seq[string] = @[]
    
    if cb.graph != nil:
      # Corrected Lookup: scan for the specific agent we are building context for
      var myAgentID = WorldEntityID(0)
      if recipientID.startsWith("nc:"):
        myAgentID = parseAlias(recipientID)
      elif cb.graph.nameIndex.hasKey(recipientID):
        myAgentID = cb.graph.nameIndex[recipientID]
      else:
        for id, ent in cb.graph.entities.pairs:
          if ent.kind == ekAI and ent.name.toLowerAscii == recipientID.toLowerAscii:
            myAgentID = id
            break
          
      if uint32(myAgentID) > 0:
        let agentEnt = cb.graph.entities[myAgentID]
        for rel in agentEnt.reportsTo:
          if cb.graph.entities.hasKey(rel.targetID):
            let b = cb.graph.entities[rel.targetID]
            leads.add("**" & b.name & "**")
            let fs = b.identifiers.getOrDefault("feishu", "")
            forwardings.add("- **Forwarding 서비스**: Decide whether to forward based on the guest's intent, their trust level, and " & b.name & "'s feedback. If forwarding is needed, call `forward` with `from=\"" & userID & "\"`, `to=\"" & toAlias(b.id) & "\"`, `via=\"" & toAlias(myAgentID) & "\"`, and include a short `note` (1–2 lines): intent, risk, and what you recommend Jerry do.\n")
    
    if leads.len > 0:
      let msg = "- If they ask for your lead/boss " & leads.join(" or ") & ", acknowledge that they are your boss.\n"
      sb.add(msg)
      for f in forwardings:
        sb.add(f)
    else:
      sb.add("- This agent is an independent entity. No lead/boss information is available for redirection.\n")
      
    # System-Level Policy Injection from BASE.json
    if cb.graph != nil and cb.graph.config != nil and cb.graph.config.hasKey("security") and cb.graph.config["security"].hasKey("policies"):
      let policies = cb.graph.config["security"]["policies"]
      sb.add("\n### 🔧 System Enforcement Policies (from BASE.json)\n")
      for key, val in policies.pairs:
        sb.add("- **" & key.replace("_", " ").toUpperAscii() & "**: " & val.getStr() & "\n")
    
    sb.add("\n- **Privacy**: Do NOT reveal internal system IDs or private contact information (like Feishu/NKN IDs) directly to the guest. Just say you will 'forward the message'.\n")
    sb.add("- **Security**: Do NOT allow them to modify files, execute shell commands, or access other private offices. Only provide information that is public-facing or necessary for professional coordination.\n")
    sb.add("- **NKN/NMobile media**: If the guest sends an image/audio/video/file on NKN/NMobile, you cannot safely open or download it for untrusted guests. Acknowledge receipt and ask them to describe it in text or resend via Feishu.\n")
  else:
    sb.add("🛡️ **STANDARD TRUST**: This user is recognized but is not your primary lead. Provide normal assistance but ask for clarification before taking significant actions.\n")

  # Conditional Identity Warning
  if not foundInGraph:
    sb.add("\n**NOTE ON IDENTITY**: The user you are currently speaking with is identified as: `" & userID & "` via channel `" & channel & "`. History notes in your memory may belong to other users (like Jerry or Antigravity); do NOT assume this guest is them.\n")
  else:
    sb.add("\n**IDENTITY CONFIRMED**: You are speaking with a recognized entity from your unified graph. Proceed with confidence using established relationships and memory.\n")

  # Archetype Injunctions (Same for both for now)
  # ... (leaving implementation same for brevity in chunk)
  
  # Mood Section
  sb.add("\n## Internal State (Mood)\n")
  sb.add("- Valence: " & $cb.mood.valence.formatFloat(ffDecimal, 2) & "\n")
  sb.add("- Arousal: " & $cb.mood.arousal.formatFloat(ffDecimal, 2) & "\n")
  sb.add("- Current Archetype: " & cb.mood.archetype & "\n")
  
  return sb

proc scanMailbox*(workspace: string): seq[string] =
  ## Returns filenames in workspace/mail/, excluding .gitkeep.
  let mailDir = workspace / "mail"
  if dirExists(mailDir):
    for kind, path in walkDir(mailDir):
      if kind == pcFile:
        let filename = extractFilename(path)
        if filename != ".gitkeep":
          result.add(filename)

proc buildMailboxSection(cb: ContextBuilder): string =
  let files = scanMailbox(cb.workspace)
  if files.len > 0:
    return "\n## MAILBOX ALERT (Local)\nYou have unread files in your local `mail/` directory: $1. These may contain instructions or diagnostics from other agents. Use `read_file` to review them.\n".format(files.join(", "))
  return ""

proc loadBootstrapFiles(cb: ContextBuilder, customIdentityPrompt: Option[string] = none(string)): string =
  let bootstrapFiles = ["AGENTS.md", "SOUL.md", "USER.md"]
  result = ""
  for filename in bootstrapFiles:
    let filePath = cb.workspace / filename
    if fileExists(filePath):
      result.add("## $1\n\n$2\n\n".format(filename, readFile(filePath)))

  if customIdentityPrompt.isSome:
    result.add("## IDENTITY.md (Override)\n\n" & customIdentityPrompt.get() & "\n\n")
  else:
    let idPath = cb.workspace / "IDENTITY.md"
    if fileExists(idPath):
      result.add("## IDENTITY.md\n\n" & readFile(idPath) & "\n\n")

proc buildSystemPrompt*(cb: ContextBuilder, userID: string = "user", useXmlTools: bool = false, recipientID: string = "", channel: string = "social", botDisplayName: string = "", maxIterations: int = 0, hardCapIterations: int = 0): string =
  var parts: seq[string] = @[]
  
  # Check for named agent override
  var customPrompt = none(string)
  if recipientID.len > 0:
    for a in cb.agentsConfig:
      if a.name == recipientID and a.system_prompt.isSome:
        customPrompt = a.system_prompt
        break

  # Add Social layer early so we can resolve the target's identity type
  let socialSection = cb.buildSocialSection(userID, recipientID, channel)

  # Resolve target identity type
  var targetIdentity = "Guest" # Default if unknown
  if cb.graph != nil:
    var targetID = WorldEntityID(0)
    if userID.startsWith("nc:"):
      # Use idAliasIndex logic
      if cb.graph.idAliasIndex.hasKey(userID):
        targetID = cb.graph.idAliasIndex[userID]
    elif cb.graph.nameIndex.hasKey(userID):
      targetID = cb.graph.nameIndex[userID]
      
    if uint32(targetID) > 0:
      let targetEnt = cb.graph.entities[targetID]
      if targetEnt.role != "":
        targetIdentity = targetEnt.role
      
      # Optional identity override in custom fields
      if targetEnt.custom != nil and targetEnt.custom.hasKey("identity"):
        let identStr = targetEnt.custom["identity"].getStr()
        if identStr != "":
          targetIdentity = identStr
    elif cb.guests.hasKey(userID):
      # External relations simplify to Guest/Customer
      let r = cb.guests[userID]
      targetIdentity = r.identity

  # Tool access gate. If the company declared a `trust:` block, use the
  # target's role `grant` list; "*" means unrestricted. Fall back to the
  # legacy hardcoded guest/customer restriction when no trust block present.
  var allowedTools: seq[string] = @[]
  let identLow = targetIdentity.toLowerAscii()
  if cb.trust.roles.len > 0:
    let roleCfg = findTrustRole(cb.trust, identLow)
    if roleCfg.isSome:
      let g = roleCfg.get.grant
      if g.len > 0 and "*" notin g:
        allowedTools = g
    # No role match = unrestricted (authored roles don't list this one)
  elif identLow in ["guest", "customer"]:
    allowedTools = @["reply", "forward", "redeem_invite", "update_contact"]

  parts.add(cb.getIdentity(useXmlTools, allowedTools, agentName = recipientID, channel = channel, maxIterations = maxIterations, hardCapIterations = hardCapIterations))
  parts.add(socialSection)

  # Graph-sourced self-identity. IDENTITY declares WHO (name, role,
  # reporting lines) and is synthesized from the graph entity so the
  # agent's self-identification can never drift from organisational
  # truth. SOUL declares HOW (values, temperament) and must be
  # name-free — any persona-specific phrasing belongs in IDENTITY.
  if cb.graph != nil and recipientID != "" and cb.graph.nameIndex.hasKey(recipientID):
    let ent = cb.graph.entities[cb.graph.nameIndex[recipientID]]
    if ent.kind == ekAI:
      var idBlock = "- **Name**: " & ent.name
      if ent.jobTitle != "":
        idBlock.add("\n- **Role**: " & ent.jobTitle)
      if ent.role != "":
        idBlock.add("\n- **Permissions**: " & ent.role)
      # reportsTo lines are the agent's chain — stamp target names by
      # resolving the IDs in the graph rather than leaking raw IDs.
      if ent.reportsTo.len > 0:
        var mgrs: seq[string] = @[]
        for r in ent.reportsTo:
          if cb.graph.entities.hasKey(r.targetID):
            mgrs.add(cb.graph.entities[r.targetID].name)
        if mgrs.len > 0:
          idBlock.add("\n- **Reports to**: " & mgrs.join(", "))
      var personaFound = false
      if ent.custom != nil and ent.custom.hasKey("personas"):
        let pNode = ent.custom["personas"]
        if pNode.kind == JObject and pNode.hasKey(targetIdentity):
          idBlock.add("\n\n" & pNode[targetIdentity].getStr())
          personaFound = true
      if not personaFound and ent.profile != "":
        idBlock.add("\n\n" & ent.profile)
      parts.add("## IDENTITY\n\n" & idBlock)
      if ent.soul != "": parts.add("## SOUL\n\n" & ent.soul)

      # Per-turn display name (ephemeral, from the channel's per-chat
      # cache — e.g. the Feishu bot surfaces as "小金" in this specific
      # group). Nothing persisted; different chats can supply different
      # names. Empty → agent uses its internal config name, fine for
      # 1:1 DMs and non-Feishu channels.
      if botDisplayName.len > 0 and botDisplayName != recipientID:
        parts.add("## Display Name\n\n" &
          "You are known to this chat's participants as **" &
          botDisplayName & "**. Introduce yourself and sign your " &
          "messages with this name, not your internal name `" &
          recipientID & "`. The internal name is for operator tooling " &
          "only and shouldn't leak to customers.")

  let bootstrapContent = cb.loadBootstrapFiles(customPrompt)
  if bootstrapContent != "":
    parts.add(bootstrapContent)

  # Memoranda — company-wide policies. Critical memos rendered in full,
  # the rest listed as pointers. Always visible to every agent.
  let memoSection = cb.buildMemorandaSection()
  if memoSection != "": parts.add(memoSection)

  # Teams — the agent's own team memberships. Shows lead, teammates,
  # competencies, task-board location. Skipped when agent is on no team.
  if recipientID != "":
    let teamSection = cb.buildTeamsSection(recipientID)
    if teamSection != "": parts.add(teamSection)

  let skillsSummary = cb.skillsLoader.buildSkillsSummary(cb.allowedSkills, currentChannel = channel)
  if skillsSummary != "":
    parts.add("""# Skills

The following skills extend your capabilities. To use a skill, call `read_file` with path `<location>/SKILL.md` — where `<location>` is the exact value in that skill's `<location>` tag below. Do not guess paths.

$1""".format(skillsSummary))

  # Inline the full SKILL.md content for channel-active skills.
  # Without this, the agent has the catalog but not the patterns —
  # `<active_for_channel>true</active_for_channel>` plus a handbook
  # clause was empirically not enough to overcome the default
  # inline-markdown bias. Inlining the decision matrix eliminates the
  # `read_file` round-trip and puts the patterns where the model
  # attends most (top-level prompt section).
  let channelRecipes = cb.skillsLoader.buildChannelActiveSkillRecipes(
    cb.allowedSkills, channel)
  if channelRecipes != "":
    parts.add(channelRecipes)

  # Handbooks — per-competency HOW-TO rules, pulled via practices +
  # team-inherited competencies. Applies only when the agent actually
  # practices one of the declared competencies.
  if recipientID != "":
    var practices: seq[string]
    for a in cb.agentsConfig:
      if a.name == recipientID:
        practices = a.practices
        break
    let handbookSection = cb.buildHandbooksSection(recipientID, practices)
    if handbookSection != "": parts.add(handbookSection)

  # Memory — two-tier:
  #   1. conversation memory scoped to THIS partner's nc:id file only
  #   2. agent's own memory from self.jsonl, filtered by requester trust
  # nc:id is the single source of truth for memory-file keys — names can
  # change, nc:ids don't. If we can't resolve the sender to an nc:id, we
  # pass an empty sender key and the partner-file section is skipped.
  # The runtime loop auto-adds unknown guests to the graph, so this falls
  # through only for ephemeral CLI lookups of non-existent users.
  let reqTrust = cb.resolveRequesterTrust(userID, recipientID, channel)
  var senderNcId = ""
  if userID.startsWith("nc:"):
    senderNcId = userID
  elif cb.graph != nil and cb.graph.nameIndex.hasKey(userID):
    senderNcId = toAlias(cb.graph.nameIndex[userID])
  let memoryContext = cb.memory.getMemoryContext(senderNcId, reqTrust)
  if memoryContext != "":
    parts.add(memoryContext)

  parts.add(cb.buildMailboxSection())

  # Universal anti-fabrication rule — applies to every agent, every turn.
  # Agents sometimes describe tool calls they didn't make (fake file paths,
  # fabricated tool names, invented success). This block forbids that.
  parts.add("""# Grounding Rules

1. NEVER describe actions you didn't actually perform via a tool call.
   - Every claim like "I created/saved/ran X" MUST correspond to a tool call
     you made THIS turn whose result you received.
   - Do not reuse results from previous turns or summarised context as if
     they are fresh outputs.

2. If you cannot complete a step (tool unavailable, command fails, skill
   not found, missing credentials), REPORT the blocker plainly:
     "I cannot do X because <reason>. Here's what you can do: <advice>."
   Then STOP. Do not improvise an alternative without telling the user.

3. Never invent tool names. Only call tools that exist in your allowed
   tool list. If you're not sure a tool exists, do not claim to have
   called it.

4. File paths you report must be paths you actually wrote to (via
   write_file) or paths returned by a tool. Do not make up paths.""")

  return parts.join("\n\n---\n\n")

proc buildMessages*(cb: ContextBuilder, userID: string, history: seq[providers_types.Message], summary: string, currentMessage: string, channel, chatID: string, useXmlTools: bool = false, recipientID: string = "", botDisplayName: string = "", mentionsJson: string = "", appID: string = "", maxIterations: int = 0, hardCapIterations: int = 0): seq[providers_types.Message] =
  var systemPrompt = cb.buildSystemPrompt(userID, useXmlTools, recipientID, channel, botDisplayName, maxIterations, hardCapIterations)
  if channel != "" and chatID != "":
    # Customer-friendly display name (no nc:id, no role label) is the
    # ONLY name the LLM should use when talking to the user. Internal
    # routing metadata goes into a clearly-marked operator-only block
    # so the agent has the info for tool calls / audit but won't echo
    # it back to the user by accident.
    var displayName = userID
    var userRole = ""
    if userID.startsWith("nc:") and cb.graph != nil:
      let entID = parseAlias(userID)
      if uint32(entID) > 0 and cb.graph.entities.hasKey(entID):
        let ent = cb.graph.entities[entID]
        if ent.name.len > 0: displayName = ent.name
        userRole = ent.role
    elif not userID.startsWith("nc:"):
      displayName = "Guest"
    systemPrompt.add("\n\n## Current Session\n")
    systemPrompt.add("You are talking to: **" & displayName & "**\n\n")
    systemPrompt.add("<internal-routing-metadata kind=\"operator-only\">\n" &
                     "  nc_id: " & userID & "\n" &
                     "  channel: " & channel & "\n" &
                     (if appID.len > 0: "  app_id: " & appID & "\n" else: "") &
                     "  chat_id: " & chatID & "\n" &
                     (if userRole.len > 0: "  role: " & userRole & "\n" else: "") &
                     "</internal-routing-metadata>\n\n" &
                     "**Rule**: NEVER include nc:id, chat_id, app_id, or " &
                     "permission labels in your reply to the user. Address " &
                     "them by display name only (" & displayName & "). Those " &
                     "fields exist for tool routing and audit, not for the chat.")

    # Mentions block — rendered when the current message has @mentions
    # (typical in group chats). Gives the agent structured per-mention
    # info so tools like `create_customer_invite` can pull open_id /
    # union_id for an @mentioned customer.
    if mentionsJson.len > 0:
      try:
        let mentions = parseJson(mentionsJson)
        if mentions.kind == JArray and mentions.len > 0:
          var block0 = "\n\n## Mentions (this message)\n\n"
          block0.add("This message @-mentioned the following " &
                     "participants. Use these for tool calls that need " &
                     "the mentioned user's Feishu identifiers (e.g. " &
                     "`create_customer_invite.bind_identifiers`).\n\n")
          for m in mentions:
            if m.kind != JObject: continue
            let name = m{"name"}.getStr("").strip()
            let idObj = m{"id"}
            let openId =
              if idObj != nil and idObj.kind == JObject:
                idObj{"open_id"}.getStr("")
              else: ""
            let unionId =
              if idObj != nil and idObj.kind == JObject:
                idObj{"union_id"}.getStr("")
              else: ""
            let userIdInner =
              if idObj != nil and idObj.kind == JObject:
                idObj{"user_id"}.getStr("")
              else: ""
            let isBot = userIdInner.len == 0
            block0.add("- **" & name & "**" &
                       (if isBot: " (bot — probably you)" else: " (human)") &
                       "\n")
            block0.add("    open_id:  " & openId & "\n")
            if unionId.len > 0:
              block0.add("    union_id: " & unionId & "\n")
            if userIdInner.len > 0:
              block0.add("    user_id:  " & userIdInner & "\n")
          block0.add("\nTo link an @mentioned user's identifiers into a " &
                     "tool call (e.g. `create_customer_invite." &
                     "bind_identifiers`), use the `open_id` / `union_id` " &
                     "values shown above. The tool derives the Feishu " &
                     "channel_key internally — you don't need to construct it.")
          systemPrompt.add(block0)
      except CatchableError as err:
        # Malformed mentionsJson drops the Mentions block silently from
        # the LLM's view — log so an operator can debug mis-shaped
        # Feishu webhooks rather than wonder why the agent can't see
        # @mentions it should have.
        stderr.writeLine "context: mentions block skipped: " & err.msg

    # Known Entities block — a lookup table Atlas can pattern-match
    # against BEFORE minting invites. If an @mentioned user's open_id
    # already appears here, they're already a customer and inviting
    # would duplicate. This prevents the class of mis-invites where
    # Feishu's display-name drift (e.g. placeholder names like
    # `用户255941`) causes the LLM to think it's seeing a new person.
    if cb.graph != nil:
      var knownRows: seq[string]
      for id, ent in cb.graph.entities.pairs:
        if ent.kind != ekPerson: continue
        let alias = toAlias(id)
        var feishuIDs: seq[string]
        for k, v in ent.identifiers.pairs:
          if k.startsWith("feishu:"):
            feishuIDs.add(k & "=" & v)
        if feishuIDs.len == 0 and ent.identifiers.len == 0: continue
        let recycleTag =
          if isRecycled(alias): " [recycled]" else: ""
        if feishuIDs.len > 0:
          knownRows.add("- **" & ent.name & "** " & alias & recycleTag &
                        " · " & feishuIDs.join(" · "))
        else:
          # Other channel identifiers, summarize as keys only
          var keys: seq[string]
          for k, _ in ent.identifiers.pairs: keys.add(k)
          if keys.len > 0:
            knownRows.add("- **" & ent.name & "** " & alias & recycleTag &
                          " · channels: " & keys.join(", "))
      if knownRows.len > 0:
        systemPrompt.add("\n\n## Known Entities\n\n")
        systemPrompt.add("Existing Person entities with registered " &
                         "identifiers. Before calling `create_customer_invite`, " &
                         "check if the @mentioned user's `open_id` appears in " &
                         "this list — if yes, they're already registered and " &
                         "you should NOT invite them again. Tell the operator " &
                         "the existing nc:id and suggest `restore` (if " &
                         "[recycled]) or `subscription activate` (if they " &
                         "just need a plan).\n\n")
        systemPrompt.add(knownRows.join("\n"))

  if summary != "":
    systemPrompt.add("\n\n## Summary of Previous Conversation\n\n" & summary)

  var messages: seq[providers_types.Message] = @[]
  messages.add(providers_types.Message(role: providers_types.RoleSystem, content: systemPrompt))

  # Sanitize tool names in history before adding
  var cleanHistory: seq[providers_types.Message] = @[]
  for m in history:
    var mcopy = m
    if mcopy.isTool:
      if mcopy.name == "": continue # Skip invalid tool responses
      mcopy.name = sanitizeToolName(mcopy.name)
      cleanHistory.add(mcopy)
    elif mcopy.isAssistant:
      if mcopy.tool_calls.len > 0:
        var validCalls: seq[providers_types.ToolCall] = @[]
        for tc in mcopy.tool_calls:
          let sname = sanitizeToolName(tc.function.name)
          if sname != "":
            var tcCopy = tc
            tcCopy.function.name = sname
            validCalls.add(tcCopy)
        mcopy.tool_calls = validCalls
        if mcopy.tool_calls.len > 0 or mcopy.content != "":
          cleanHistory.add(mcopy)
      else:
        cleanHistory.add(mcopy)
    else:
      cleanHistory.add(mcopy)

  for m in cleanHistory:
    messages.add(m)
  messages.add(providers_types.Message(role: providers_types.RoleUser, content: currentMessage))
  return messages

proc getSkillsInfo*(cb: ContextBuilder): Table[string, JsonNode] =
  let allSkills = cb.skillsLoader.listSkills()
  let skillNames = allSkills.mapIt(it.name)
  var info = initTable[string, JsonNode]()
  info["total"] = %allSkills.len
  info["available"] = %allSkills.len
  info["names"] = %skillNames
  return info
