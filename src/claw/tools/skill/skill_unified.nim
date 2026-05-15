## skill — single tool for skill management.
##
## Replaces split tools: install_skill, learn_skill, plus session-scoped
## list/load/unload added for lazy-skill activation.
##
## Actions:
##
##   list     — Enumerate skills available to this agent. Optional
##              `query` (substring match against name/description) and
##              `scope` (active|available|all; default all). Returns a
##              compact JSON array.
##
##   load     — Activate a `loading: lazy` skill for this session.
##              The skill body inlines into the system prompt on the
##              next turn. Sticky — stays loaded until `unload` or
##              session restart.
##
##   unload   — Drop a previously-loaded lazy skill from the session
##              prompt. Catalog stub remains visible.
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

import std/[asyncdispatch, json, tables, strutils, options, os, sets]
import ../types, ../registry
import ../spec
import ../../skills/installer
import ../../skills/loader as skill_loader
import ../../skills/skill_types
import ../../logger

const ToolSpec* = spec(
  name = "skill",
  description = "skill management (method=list|load|unload session skills, install plugins, learn workstation skills)",
  tags = @["admin", "skills", "workstation"],
  searchKeywords = @["load skill", "unload skill", "list skills",
                      "playbook", "procedure", "consult skill",
                      "install plugin", "learn workflow"],
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
    skillsLoader: SkillsLoader  ## shared with the prompt builder so list/load/unload
                                ## reads + mutates the same `loadedLazySkills` set
                                ## the system-prompt path consults.
    allowedSkillsAccessor: proc (): seq[string] {.closure.}
                                ## resolves at-call-time (per-agent allowedSkills
                                ## lives on ContextBuilder, set when the agent's
                                ## scope is applied — read freshly each call so
                                ## tool grants/revokes apply without restart).

proc newSkillTool*(installer: SkillInstaller, officeDir: string,
                   registryRef: ToolRegistry,
                   skillsLoader: SkillsLoader = nil,
                   allowedSkillsAccessor: proc (): seq[string] {.closure.} = nil): SkillTool =
  SkillTool(installer: installer, officeDir: officeDir,
            registryRef: registryRef,
            skillsLoader: skillsLoader,
            allowedSkillsAccessor: allowedSkillsAccessor)

method name*(t: SkillTool): string = "skill"

method description*(t: SkillTool): string =
  "Skill management. Operates on BOTH SKILL.md skills and competency " &
  "HANDBOOK.md procedural content — they share the load/unload surface.\n\n" &
  "Actions:\n" &
  "  list     — enumerate available skills + handbooks (optional query, scope=active|available|all)\n" &
  "  load     — activate a `loading: lazy` skill or handbook body for this session (sticky)\n" &
  "  unload   — drop a previously-loaded body from the session prompt\n" &
  "  install  — install a skill plugin (requires name; supports " &
  "registry name, GitHub URL, or owner/repo shorthand)\n" &
  "  learn    — author a workstation skill from a repeated workflow " &
  "(requires name, description, triggers, workflow, tools)"

method parameters*(t: SkillTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["list", "load", "unload", "install", "learn"],
        "description": "Operation to perform"
      },
      "name": {
        "type": "string",
        "description": "Skill name. Required for load/unload/install/learn. install: registry name or GitHub URL/owner-repo. learn: kebab-case identifier. list: omit."
      },
      "query": {
        "type": "string",
        "description": "list only — substring filter against name+description (case-insensitive)."
      },
      "scope": {
        "type": "string",
        "enum": ["active", "available", "all"],
        "description": "list only — `active` = currently loaded lazy skills; `available` = all granted skills; `all` (default) = both with state flags."
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
    "required": %*["method"]
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

proc parseStringList(node: JsonNode): seq[string] =
  ## Tolerant parser for list-of-string args. Accepts:
  ##   - JArray of JString:    ["a", "b"]            (canonical)
  ##   - JArray of mixed:      auto-stringified
  ##   - JString JSON-encoded: "[\"a\", \"b\"]"     (LLM serialization quirk)
  ##   - JString CSV:          "a, b, c"             (LLM frequently does this)
  ##   - JString single:       "a"                   (one-element list)
  ## Returns empty seq for null / missing / unrecognized shapes.
  result = @[]
  if node.isNil or node.kind == JNull: return
  if node.kind == JArray:
    for item in node:
      let s = if item.kind == JString: item.getStr() else: $item
      let stripped = s.strip()
      if stripped.len > 0: result.add(stripped)
    return
  if node.kind == JString:
    let raw = node.getStr().strip()
    if raw.len == 0: return
    # Try parsing as JSON first (handles "[\"a\",\"b\"]")
    if raw.startsWith("["):
      try:
        let parsed = parseJson(raw)
        if parsed.kind == JArray:
          for item in parsed:
            let s = if item.kind == JString: item.getStr() else: $item
            let stripped = s.strip()
            if stripped.len > 0: result.add(stripped)
          return
      except CatchableError: discard
    # CSV fallback
    if "," in raw:
      for part in raw.split(','):
        let stripped = part.strip()
        if stripped.len > 0: result.add(stripped)
      return
    # Single string
    result.add(raw)

proc doLearn(t: SkillTool, args: Table[string, JsonNode]): string =
  let name = args["name"].getStr().strip()
  let descr = if args.hasKey("description"): args["description"].getStr().strip() else: ""
  let triggers = if args.hasKey("triggers"): parseStringList(args["triggers"]) else: @[]
  let workflow = if args.hasKey("workflow"): parseStringList(args["workflow"]) else: @[]
  let claimedTools = if args.hasKey("tools"): parseStringList(args["tools"]) else: @[]
  let examples = if args.hasKey("examples"): parseStringList(args["examples"]) else: @[]

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

# ── list / load / unload ─────────────────────────────────────────

proc allowedSet(t: SkillTool): HashSet[string] =
  ## Resolve the agent's allowed-skill set, tolerating both kebab-case
  ## (`solar-analysis`) and underscore-sanitized (`solar_analysis`) forms.
  result = initHashSet[string]()
  if t.allowedSkillsAccessor.isNil: return
  for n in t.allowedSkillsAccessor():
    result.incl(n)
    result.incl(n.replace("-", "_"))
    result.incl(n.replace("_", "-"))

proc isSkillAllowed(t: SkillTool, s: SkillInfo): bool =
  ## Workstation-tier skills are always visible to their authoring agent.
  ## Otherwise the skill must be in the resolved scope.
  if s.source == "workstation": return true
  let allowed = t.allowedSet
  if allowed.len == 0: return true   # no scope set → unrestricted (CLI introspection)
  s.name in allowed or s.name.replace("_", "-") in allowed

proc isLoaded(t: SkillTool, s: SkillInfo): bool =
  if t.skillsLoader.isNil: return false
  s.name in t.skillsLoader.loadedLazySkills or
    s.name.replace("_", "-") in t.skillsLoader.loadedLazySkills

proc isHandbookLoaded(t: SkillTool, c: CompetencyInfo): bool =
  if t.skillsLoader.isNil: return false
  c.name in t.skillsLoader.loadedLazyHandbooks or
    c.name.replace("-", "_") in t.skillsLoader.loadedLazyHandbooks

proc doList(t: SkillTool, args: Table[string, JsonNode]): string =
  if t.skillsLoader.isNil:
    return "Error: skill listing unavailable — tool not bound to a SkillsLoader."
  let scope = if args.hasKey("scope"): args["scope"].getStr().toLowerAscii() else: "all"
  let query = if args.hasKey("query"): args["query"].getStr().toLowerAscii() else: ""
  var rows = newJArray()
  # Skills first (the existing surface)
  for s in t.skillsLoader.listSkills():
    if not t.isSkillAllowed(s): continue
    let loaded = t.isLoaded(s)
    if scope == "active" and not loaded: continue
    if query.len > 0:
      let hay = (s.name & " " & s.description).toLowerAscii()
      if query notin hay: continue
    var entry = newJObject()
    entry["kind"] = %"skill"
    entry["name"] = %s.name
    entry["description"] = %s.description
    entry["source"] = %s.source
    entry["loading"] = %(if s.loading == "lazy": "lazy" else: "always")
    entry["loaded"] = %loaded
    rows.add(entry)
  # Then competency handbooks — same shape, kind="handbook". No allowedness
  # gate: every handbook is listed so the agent sees what's loadable beyond
  # their declared practices. (Loading is the gate, not visibility.)
  for c in t.skillsLoader.listCompetencies():
    if not c.hasHandbook: continue
    let loaded = t.isHandbookLoaded(c)
    if scope == "active" and not loaded: continue
    if query.len > 0:
      let hay = (c.name & " " & c.description).toLowerAscii()
      if query notin hay: continue
    var entry = newJObject()
    entry["kind"] = %"handbook"
    entry["name"] = %c.name
    entry["description"] = %c.description
    entry["source"] = %"competency"
    entry["loading"] = %c.loading
    entry["loaded"] = %loaded
    rows.add(entry)
  result = $rows

proc resolveSkillName(t: SkillTool, name: string): Option[SkillInfo] =
  ## Find a skill by either the sanitized or hyphenated form. Mirrors
  ## the loader's match logic so `solar-analysis` and `solar_analysis`
  ## both resolve to the same skill.
  if t.skillsLoader.isNil: return
  let target = name.toLowerAscii()
  let targetUnder = target.replace("-", "_")
  let targetHyph = target.replace("_", "-")
  for s in t.skillsLoader.listSkills():
    let nl = s.name.toLowerAscii()
    if nl == target or nl == targetUnder or nl == targetHyph:
      return some(s)
  none(SkillInfo)

proc doLoad(t: SkillTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("name") or args["name"].getStr().strip().len == 0:
    return "Error: 'name' is required for load"
  if t.skillsLoader.isNil:
    return "Error: skill loading unavailable — tool not bound to a SkillsLoader."
  let name = args["name"].getStr().strip()
  # Try skill first
  let skillHit = t.resolveSkillName(name)
  if skillHit.isSome:
    let s = skillHit.get
    if not t.isSkillAllowed(s):
      return "Error: skill '" & s.name & "' is not in your scope."
    if s.loading != "lazy":
      return "Note: skill '" & s.name & "' has loading=always — its catalog stub is " &
             "already in your prompt and (when channel-tagged) the body inlines automatically. " &
             "Read it with `read_file` at " & s.location & "/SKILL.md if you need the body now."
    t.skillsLoader.loadedLazySkills.incl(s.name)
    infoCF("tool", "Lazy skill loaded for session",
           {"skill": s.name, "path": s.path}.toTable)
    return "Loaded skill '" & s.name & "' — its body will appear in your system " &
           "prompt starting next turn. Stays loaded until `skill method=unload`."
  # Then handbook (competency)
  let hbHit = t.skillsLoader.competencyByName(name)
  if hbHit.isSome:
    let c = hbHit.get
    if not c.hasHandbook:
      return "Note: competency '" & c.name & "' has no HANDBOOK.md to load."
    if c.loading != "lazy":
      return "Note: handbook '" & c.name & "' has loading=always — its body is " &
             "already inlined in your prompt under # Handbooks (when you practice " &
             "this competency). Mark `loading: lazy` in COMPETENCY.json to opt into " &
             "the load/unload mechanism."
    t.skillsLoader.loadedLazyHandbooks.incl(c.name)
    infoCF("tool", "Lazy handbook loaded for session",
           {"competency": c.name, "path": c.handbookPath}.toTable)
    return "Loaded handbook '" & c.name & "' — its body will appear in your system " &
           "prompt under # Handbooks starting next turn. Stays loaded until " &
           "`skill method=unload`."
  return "Error: '" & name & "' not found as a skill or competency handbook. " &
         "Call `skill method=list` to see what's available."

proc doUnload(t: SkillTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("name") or args["name"].getStr().strip().len == 0:
    return "Error: 'name' is required for unload"
  if t.skillsLoader.isNil:
    return "Error: skill unloading unavailable — tool not bound to a SkillsLoader."
  let name = args["name"].getStr().strip()
  var dropped = false
  var dropKind = ""
  for variant in [name, name.replace("-", "_"), name.replace("_", "-")]:
    if variant in t.skillsLoader.loadedLazySkills:
      t.skillsLoader.loadedLazySkills.excl(variant)
      dropped = true
      dropKind = "skill"
    if variant in t.skillsLoader.loadedLazyHandbooks:
      t.skillsLoader.loadedLazyHandbooks.excl(variant)
      dropped = true
      dropKind = if dropKind.len > 0: "skill+handbook" else: "handbook"
  if not dropped:
    return "Note: '" & name & "' was not loaded as a skill or handbook — nothing to unload."
  infoCF("tool", "Lazy " & dropKind & " unloaded from session",
         {"name": name}.toTable)
  return "Unloaded " & dropKind & " '" & name & "'. Catalog stub remains visible; " &
         "load again with `skill method=load name=" & name & "`."

method execute*(t: SkillTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("method"):
    return "Error: 'method' is required (list | load | unload | install | learn)"
  let action = getMethodArg(args)
  case action
  of "list":    return doList(t, args)
  of "load":    return doLoad(t, args)
  of "unload":  return doUnload(t, args)
  of "install":
    if not args.hasKey("name"):
      return "Error: 'name' is required for install"
    return await doInstall(t, args)
  of "learn":
    if not args.hasKey("name"):
      return "Error: 'name' is required for learn"
    return doLearn(t, args)
  else:
    return "Error: Unknown action '" & action & "'. Use: list | load | unload | install | learn"
