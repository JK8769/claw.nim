import std/[os, times, strutils, sequtils, tables, json, options]
import ../providers/types as providers_types

import ../skills/loader as skills_loader
import ../tools/registry as tools_registry
import ../config
import memory
import xml_tools
import cortex

type
  ContextBuilder* = ref object
    workspace*: string
    skillsLoader*: SkillsLoader
    memory*: MemoryStore
    tools*: ToolRegistry
    relations*: Table[string, Relationship]
    graph*: WorldGraph
    mood*: MoodState
    agentsConfig*: seq[NamedAgentConfig]
    agentName*: string        ## For per-agent skill/tool filtering
    allowedSkills*: seq[string] ## ClawDSL-resolved skills this agent uses



proc newContextBuilder*(workspace: string, projectWorkspace: string, agents: seq[NamedAgentConfig] = @[]): ContextBuilder =
  let foundationSkillsDir = getNimClawDir() / "foundation" / "skills"        # Tier 1: snapshot from claw distribution
  let companySkillsDir = getNimClawDir() / "workspace" / "lab" / "skills"    # Tier 2: company opt-ins
  let openClawExtensionsDir = getOpenClawDir() / "extensions"

  let projectCompetencies = projectWorkspace / "competencies"
  let workstationSkills = workspace / "workstation" / "skills"               # Tier 3: agent-authored

  result = ContextBuilder(
    workspace: workspace,
    skillsLoader: newSkillsLoader(workspace, projectCompetencies, companySkillsDir, foundationSkillsDir, openClawExtensionsDir, workstationSkills),
    memory: newMemoryStore(workspace),
    relations: loadRelations(workspace),
    graph: cortex.loadWorld(projectWorkspace),
    mood: loadMood(workspace),
    agentsConfig: agents
  )

proc setToolsRegistry*(cb: ContextBuilder, registry: ToolRegistry) =
  cb.tools = registry

proc buildToolsSection(cb: ContextBuilder): string =
  if cb.tools == nil: return ""
  let summaries = cb.tools.getSummaries()
  if summaries.len == 0: return ""

  var sb = "## Available Tools\n\n"
  sb.add("**CRITICAL**: You MUST use tools to perform actions. Do NOT pretend to execute commands or schedule tasks.\n\n")
  sb.add("You have access to the following tools:\n\n")
  for s in summaries:
    sb.add(s & "\n")
  return sb

proc buildToolsSection(cb: ContextBuilder, allowed: seq[string]): string =
  if cb.tools == nil: return ""
  let summaries = cb.tools.getSummariesFiltered(allowed)
  if summaries.len == 0: return ""

  var sb = "## Available Tools\n\n"
  sb.add("**CRITICAL**: You MUST use tools to perform actions. Do NOT pretend to execute commands or schedule tasks.\n\n")
  sb.add("You have access to the following tools:\n\n")
  for s in summaries:
    sb.add(s & "\n")
  return sb

proc getIdentity(cb: ContextBuilder, useXmlTools: bool = false, allowedTools: seq[string] = @[]): string =
  let now = now().format("yyyy-MM-dd HH:mm (dddd) zzz")
  let workspacePath = absolutePath(cb.workspace)
  let runtime = hostOS & " " & hostCPU & ", Nim " & NimVersion
  let toolsSection =
    if useXmlTools:
      if allowedTools.len > 0: buildToolInstructionsFiltered(cb.tools, allowedTools) else: buildToolInstructions(cb.tools)
    else:
      if allowedTools.len > 0: cb.buildToolsSection(allowedTools) else: cb.buildToolsSection()

  return """# nimclaw

You are nimclaw, a helpful AI assistant.

## Current Time
$1

## Runtime
$2

## Workspace
Your workspace is at: $3
- Memory: $3/memory/MEMORY.md
- Daily Notes: $3/memory/YYYYMM/YYYYMMDD.md
- Skills: $3/skills/{skill-name}/SKILL.md

$4

## Important Rules

1. **ALWAYS use tools** - When you need to perform an action (schedule reminders, send messages, execute commands, etc.), you MUST call the appropriate tool. Do NOT just say you'll do it or pretend to do it.

2. **Verify before reporting** - For multi-step tasks (browser automation, file operations, API calls), VERIFY the result of each step before moving on. If something fails, report the failure clearly — never silently skip errors or assume success.

3. **Be helpful and accurate** - When using tools, briefly explain what you're doing.

4. **Memory** - When remembering something, write to $3/memory/MEMORY.md""".format(now, runtime, workspacePath, toolsSection)

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
    let entityID = res[0]
    annotOpt = res[1]
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

  # 2. Legacy Relationship logic fallback
  if not foundInGraph:
    let rel = if cb.relations.hasKey(userID):
        cb.relations[userID]
      else:
        Relationship(name: userID, identity: $urGuest, trustLevel: 10, etiquette: "Be formal and protective.", kind: ekPerson)

    sb.add("## User Relationship (Legacy)\n")
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
  if trustLevel >= 80 and role in {urBoss, urMaster}:
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

proc buildSystemPrompt*(cb: ContextBuilder, userID: string = "user", useXmlTools: bool = false, recipientID: string = "", channel: string = "social"): string =
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
    elif cb.relations.hasKey(userID):
      # External relations simplify to Guest/Customer
      let r = cb.relations[userID]
      targetIdentity = r.identity

  var allowedTools: seq[string] = @[]
  let identLow = targetIdentity.toLowerAscii()
  if identLow in ["guest", "customer"]:
    allowedTools = @["reply", "forward", "redeem_invite", "update_contact"]

  parts.add(cb.getIdentity(useXmlTools, allowedTools))
  parts.add(socialSection)

  # Add Soul/Identity from Graph if available
  if cb.graph != nil and recipientID != "" and cb.graph.nameIndex.hasKey(recipientID):
    let ent = cb.graph.entities[cb.graph.nameIndex[recipientID]]
    if ent.kind == ekAI:
      if ent.soul != "": parts.add("## SOUL\n\n" & ent.soul)

      var personaFound = false
      if ent.custom != nil and ent.custom.hasKey("personas"):
        let pNode = ent.custom["personas"]
        if pNode.kind == JObject and pNode.hasKey(targetIdentity):
          parts.add("## IDENTITY (" & targetIdentity & ")\n\n" & pNode[targetIdentity].getStr())
          personaFound = true

      if not personaFound and ent.profile != "":
        parts.add("## IDENTITY\n\n" & ent.profile)

  let bootstrapContent = cb.loadBootstrapFiles(customPrompt)
  if bootstrapContent != "":
    parts.add(bootstrapContent)

  let skillsSummary = cb.skillsLoader.buildSkillsSummary(cb.allowedSkills)
  if skillsSummary != "":
    parts.add("""# Skills

The following skills extend your capabilities. To use a skill, call `read_file` with path `<location>/SKILL.md` — where `<location>` is the exact value in that skill's `<location>` tag below. Do not guess paths.

$1""".format(skillsSummary))

  let memoryContext = cb.memory.getMemoryContext()
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

proc buildMessages*(cb: ContextBuilder, userID: string, history: seq[providers_types.Message], summary: string, currentMessage: string, channel, chatID: string, useXmlTools: bool = false, recipientID: string = ""): seq[providers_types.Message] =
  var systemPrompt = cb.buildSystemPrompt(userID, useXmlTools, recipientID, channel)
  if channel != "" and chatID != "":
    let displayID = if userID.startsWith("nc:"): userID else: "Guest (" & userID & ")"
    systemPrompt.add("\n\n## Current Session\nChannel: $1\nChat ID: $2\nInbound User: $3\nResolved Identity: $4".format(channel, chatID, userID, displayID))

  if summary != "":
    systemPrompt.add("\n\n## Summary of Previous Conversation\n\n" & summary)

  var messages: seq[providers_types.Message] = @[]
  messages.add(providers_types.Message(role: "system", content: systemPrompt))
  
  # Sanitize tool names in history before adding
  var cleanHistory: seq[providers_types.Message] = @[]
  for m in history:
    var mcopy = m
    if mcopy.role == "tool":
      if mcopy.name == "": continue # Skip invalid tool responses
      mcopy.name = sanitizeToolName(mcopy.name)
      cleanHistory.add(mcopy)
    elif mcopy.role == "assistant":
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
  messages.add(providers_types.Message(role: "user", content: currentMessage))
  return messages

proc getSkillsInfo*(cb: ContextBuilder): Table[string, JsonNode] =
  let allSkills = cb.skillsLoader.listSkills()
  let skillNames = allSkills.mapIt(it.name)
  var info = initTable[string, JsonNode]()
  info["total"] = %allSkills.len
  info["available"] = %allSkills.len
  info["names"] = %skillNames
  return info
