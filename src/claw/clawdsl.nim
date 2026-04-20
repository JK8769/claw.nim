## clawdsl — NimScript DSL for declarative NimClaw service creation.
## Import this in a .nims file and run with `nim e MyCompany.nims`.
## Generates ~/.nimclaw-<OrgName>/ with BASE.json, workspace, skills, etc.

import std/[json, os, strutils, tables]

# ── Spec Types ────────────────────────────────────────────────────

type
  ClawRelation* = object
    target*: string       ## Person/agent name
    role*: string         ## boss, master, customer, guest, etc.
    trustLevel*: int      ## 0-100
    etiquette*: string    ## Relationship-specific instructions

  ClawProvider* = object
    name*: string
    apiBase*: string
    apiKey*: string
    defaultModel*: string
    models*: seq[string]

  ClawAgent* = object
    name*: string
    model*: string
    provider*: string
    role*: string          ## RBAC role: Admin, Member, Employee
    identity*: string      ## Staff, Agent, User
    jobTitle*: string
    profile*: string       ## Profile name from AGENT_PROFILES
    maxDepth*: int
    temperature*: float
    reportsTo*: seq[ClawRelation]
    serves*: seq[ClawRelation]
    identifiers*: seq[tuple[channel, id: string]]
    uses*: seq[string]     ## Skill names this agent has access to (direct)
    practices*: seq[string] ## Competency names — pulls in their skills + handbooks
    deny*: seq[string]     ## Tool names to deny (overrides skill-granted tools)
    workstation*: bool     ## Allow workstation experimentation (author skills & forge tools)
    # Resolved at build time from skills' SKILL.md frontmatter
    resolvedTools*: seq[string]
    resolvedDeps*: seq[string]
    resolvedEnvs*: seq[string]
    resolvedSkills*: seq[string]  ## uses ∪ practices.skills ∪ team.competencies.skills

  ClawPerson* = object
    name*: string
    permission*: string    ## SuperAdmin, Admin, Member
    identifiers*: seq[tuple[channel, id: string]]
    skills*: seq[string]   ## allowlist in `[user@]skill[/res,...]` form —
                            ## tool dispatcher checks calls against this.

  ClawOrg* = object
    name*: string
    description*: string
    identifiers*: seq[tuple[channel, id: string]]

  ClawChannel* = object
    kind*: string
    fields*: seq[tuple[key, val: string]]

  ClawDefaults* = object
    maxTokens*: int
    temperature*: float
    maxToolIterations*: int
    streamIntermediary*: bool

  ClawSecurity* = object
    policies*: seq[tuple[name, text: string]]
    allowedPaths*: seq[string]

  ClawTrustRole* = object
    ## A role's trust range + capability grants. Trust is clamped to
    ## [trustMin, trustMax] within this role; crossing requires role change
    ## via redeem_invite or BASE.nims edit by a SuperAdmin. Each role
    ## belongs to exactly one tier — "internal" (the company's own people
    ## and agents) or "external" (everyone else, customers through guests).
    ##
    ## A new user entering this role starts at `trustMin` (the lower bound).
    ## Pinned roles — where entry trust equals the ceiling with no drift —
    ## use the zero-width form `trust N, N` (e.g. SuperAdmin: trust 100, 100).
    name*: string         ## role label; matches `person "X": permission "..."`
    tier*: string         ## "internal" | "external"
    trustMin*: int        ## lower bound; also the entry trust for new members
    trustMax*: int        ## upper bound within the role's band
    grant*: seq[string]   ## tool names granted; "*" = all
    prompt*: string       ## prose injected into the Social/Security section

  ClawTrust* = object
    roles*: seq[ClawTrustRole]

  ClawGateway* = object
    host*: string
    port*: int

  ClawTools* = object
    webSearchKey*: string
    webSearchProvider*: string
    webSearchMaxResults*: int
    webSearchFallback*: seq[string]

  ClawSkill* = object
    name*: string
    source*: string        ## URL, path, or "" for built-in
    version*: string       ## optional pin — e.g. "1.0.0" from `skill "name@1.0.0"`

  ClawContent* = object
    ## Content sourcing — either an external reference or inline text.
    ## Resolved lazily at scaffold time so the DSL remains pure declaration.
    source*: string        ## "relative/path.md" | "github:owner/repo/path" | "claw:Co/type/name" | ""
    inline*: string        ## literal content when using `content """..."""`

  ClawMemorandum* = object
    ## A persistent company-level document (vision, strategy, SOPs, policies).
    name*: string          ## basename without .md, e.g. "SAFETY_POLICY"
    content*: ClawContent
    summary*: string       ## one-liner shown in agent system prompts
    critical*: bool        ## flag for "read before acting" prompt hint

  ClawCompetency* = object
    ## A role profile — optionally bundles skills with a handbook.
    ## Agents inherit both via `practices` or team membership.
    name*: string          ## e.g. "data-analysis"
    description*: string   ## one-liner visible in competency catalogs
    skills*: seq[string]   ## skill names granted to practitioners
    content*: ClawContent  ## optional handbook (markdown)
    summary*: string

  ClawTeam* = object
    ## A named group of agents with a shared function.
    name*: string
    description*: string
    lead*: string                  ## default lead (first member if empty)
    members*: seq[string]          ## agent names
    competencies*: seq[string]     ## applied to all members

  ClawLab* = object
    ## Research-focused collaboration with its own briefings/meetings/research dirs.
    name*: string
    focus*: string
    researchers*: seq[string]      ## agent names who participate

  ClawPortal* = object
    ## Company-wide sub-areas (flags drive which dirs get scaffolded).
    wiki*: bool
    directory*: bool
    news*: bool
    calendar*: bool

  ClawSpec* = object
    org*: ClawOrg
    persons*: seq[ClawPerson]
    providers*: seq[ClawProvider]
    agents*: seq[ClawAgent]
    channels*: seq[ClawChannel]
    skills*: seq[ClawSkill]
    memoranda*: seq[ClawMemorandum]
    competencies*: seq[ClawCompetency]
    teams*: seq[ClawTeam]
    labs*: seq[ClawLab]
    portal*: ClawPortal
    defaults*: ClawDefaults
    security*: ClawSecurity
    gateway*: ClawGateway
    tools*: ClawTools
    trust*: ClawTrust

# ── Global State ──────────────────────────────────────────────────

var spec* {.global.} = ClawSpec(
  defaults: ClawDefaults(maxTokens: 4096, temperature: 0.7, maxToolIterations: 20),
  gateway: ClawGateway(host: "0.0.0.0", port: 18790),
  tools: ClawTools(webSearchMaxResults: 5, webSearchProvider: "auto"),
)

# ── DSL: Organization ─────────────────────────────────────────────

template org*(orgName: string, body: untyped) =
  spec.org.name = orgName
  block:
    template description(d: string) {.used.} =
      spec.org.description = d
    template identifier(chanName, chanId: string) {.used.} =
      spec.org.identifiers.add((channel: chanName, id: chanId))
    body

# ── DSL: Person ───────────────────────────────────────────────────

template person*(personName: string, body: untyped) =
  block:
    var p = ClawPerson(name: personName)
    template permission(perm: string) {.used.} =
      p.permission = perm
    template identifier(chanName, chanId: string) {.used.} =
      p.identifiers.add((channel: chanName, id: chanId))
    template skill(grant: string) {.used.} =
      p.skills.add(grant)
    body
    spec.persons.add(p)

# ── DSL: Provider ─────────────────────────────────────────────────

template provider*(provName: string, body: untyped) =
  block:
    var p = ClawProvider(name: provName)
    template apiBase(url: string) {.used.} =
      p.apiBase = url
    template apiKey(key: string) {.used.} =
      p.apiKey = key
    template defaultModel(m: string) {.used.} =
      p.defaultModel = m
    template models(ms: varargs[string]) {.used.} =
      for m in ms: p.models.add(m)
    body
    spec.providers.add(p)

# ── DSL: Agent ────────────────────────────────────────────────────

template agent*(agentName: string, body: untyped) =
  block:
    var a = ClawAgent(name: agentName, maxDepth: 10, identity: "Agent", role: "Member")
    template model(m: string) {.used.} =
      a.model = m
    template provider(prov: string) {.used.} =
      a.provider = prov
    template role(r: string) {.used.} =
      a.role = r
    template identity(id: string) {.used.} =
      a.identity = id
    template jobTitle(jt: string) {.used.} =
      a.jobTitle = jt
    template profile(prof: string) {.used.} =
      a.profile = prof
    template maxDepth(d: int) {.used.} =
      a.maxDepth = d
    template temperature(t: float) {.used.} =
      a.temperature = t
    template identifier(chanName, chanId: string) {.used.} =
      a.identifiers.add((channel: chanName, id: chanId))
    template reportsTo(targetName: string, relBody: untyped) {.used.} =
      block:
        var rel = ClawRelation(target: targetName)
        template role(r: string) {.used.} =
          rel.role = r
        template trustLevel(tl: int) {.used.} =
          rel.trustLevel = tl
        template etiquette(et: string) {.used.} =
          rel.etiquette = et
        relBody
        a.reportsTo.add(rel)
    template serves(targetName: string, relBody: untyped) {.used.} =
      block:
        var rel = ClawRelation(target: targetName)
        template role(r: string) {.used.} =
          rel.role = r
        template trustLevel(tl: int) {.used.} =
          rel.trustLevel = tl
        template etiquette(et: string) {.used.} =
          rel.etiquette = et
        relBody
        a.serves.add(rel)
    template uses(skillNames: varargs[string]) {.used.} =
      for s in skillNames: a.uses.add(s)
    template practices(competencyNames: varargs[string]) {.used.} =
      for c in competencyNames: a.practices.add(c)
    template deny(toolNames: varargs[string]) {.used.} =
      for t in toolNames: a.deny.add(t)
    template workstation(enabled: bool) {.used.} =
      a.workstation = enabled
    body
    spec.agents.add(a)

# ── DSL: Channel ──────────────────────────────────────────────────

template channel*(chKind: string, body: untyped) =
  block:
    var ch = ClawChannel(kind: chKind)
    template token(t: string) {.used.} =
      ch.fields.add((key: "token", val: t))
    template app(appId: string) {.used.} =
      ch.fields.add((key: "app", val: appId))
    template app(appId, agentName: string) {.used.} =
      ## Feishu multi-app form: bind which agent handles inbound from
      ## this app. Messages on this app_id land in `agentName`'s office.
      ch.fields.add((key: "app", val: appId))
      ch.fields.add((key: "app_agent:" & appId, val: agentName))
    template appId(id: string) {.used.} =
      ch.fields.add((key: "appId", val: id))
    template appSecret(s: string) {.used.} =
      ch.fields.add((key: "appSecret", val: s))
    template clientId(id: string) {.used.} =
      ch.fields.add((key: "clientId", val: id))
    template clientSecret(s: string) {.used.} =
      ch.fields.add((key: "clientSecret", val: s))
    template bridgeUrl(url: string) {.used.} =
      ch.fields.add((key: "bridgeUrl", val: url))
    template host(h: string) {.used.} =
      ch.fields.add((key: "host", val: h))
    template port(p: int) {.used.} =
      ch.fields.add((key: "port", val: $p))
    template requireMention(b: bool) {.used.} =
      ch.fields.add((key: "requireMention", val: $b))
    template notificationOnly(b: bool) {.used.} =
      ch.fields.add((key: "notificationOnly", val: $b))
    template streamIntermediary(b: bool) {.used.} =
      ch.fields.add((key: "streamIntermediary", val: $b))
    template allowFrom(ids: varargs[string]) {.used.} =
      for id in ids: ch.fields.add((key: "allowFrom", val: id))
    body
    spec.channels.add(ch)

# ── DSL: Defaults ─────────────────────────────────────────────────

template defaults*(body: untyped) =
  block:
    template maxTokens(n: int) {.used.} =
      spec.defaults.maxTokens = n
    template temperature(t: float) {.used.} =
      spec.defaults.temperature = t
    template maxToolIterations(n: int) {.used.} =
      spec.defaults.maxToolIterations = n
    template streamIntermediary(b: bool) {.used.} =
      spec.defaults.streamIntermediary = b
    body

# ── DSL: Security ─────────────────────────────────────────────────

template security*(body: untyped) =
  block:
    template policy(polName, polText: string) {.used.} =
      spec.security.policies.add((name: polName, text: polText))
    template allowedPath(p: string) {.used.} =
      spec.security.allowedPaths.add(p)
    body

# ── DSL: Trust ────────────────────────────────────────────────────
# Role = trust band. Trust drifts inside the band based on behavior; crossing
# requires role change via `redeem_invite` (with a valid pin) or a SuperAdmin
# editing BASE.nims. Runtime clamps on write.
#
#   trust:
#     role "guest":
#       band 0, 40
#       initial 10
#       grant "reply", "forward", "update_contact", "redeem_invite"
#       prompt "⚠️ GUEST PROTOCOL: public info only, never expose internals."
#     role "master":
#       band 70, 100
#       initial 85
#       grant "*"
#       prompt "🛡️ HIGH TRUST: this user is your lead."

template trust*(body: untyped) =
  block:
    template role(roleName: string, roleBody: untyped) {.used.} =
      block:
        var r = ClawTrustRole(name: roleName)
        template tier(t: string) {.used.} =
          r.tier = t.toLowerAscii
        template trust(lo, hi: int) {.used.} =
          r.trustMin = lo
          r.trustMax = hi
        # Back-compat: accept the legacy `band` keyword too. One release,
        # then remove.
        template band(lo, hi: int) {.used.} =
          r.trustMin = lo
          r.trustMax = hi
        template grant(toolNames: varargs[string]) {.used.} =
          for n in toolNames: r.grant.add(n)
        template prompt(s: string) {.used.} =
          r.prompt = s
        # `initial` is gone — new members of a role start at `trustMin`.
        # Accepted as a no-op during the deprecation window so old
        # BASE.nims files don't fail to parse.
        template initial(v: int) {.used.} = discard
        roleBody
        if r.tier.len == 0:
          r.tier =
            if r.name.toLowerAscii in ["superadmin", "admin", "staff",
                                        "employee", "member"]:
              "internal"
            else:
              "external"
        spec.trust.roles.add(r)
    body

# ── DSL: Gateway ──────────────────────────────────────────────────

template gateway*(body: untyped) =
  block:
    template host(h: string) {.used.} =
      spec.gateway.host = h
    template port(p: int) {.used.} =
      spec.gateway.port = p
    body

# ── DSL: Tools ────────────────────────────────────────────────────

template tools*(body: untyped) =
  block:
    template webSearchKey(k: string) {.used.} =
      spec.tools.webSearchKey = k
    template webSearchProvider(p: string) {.used.} =
      spec.tools.webSearchProvider = p
    template webSearchMaxResults(n: int) {.used.} =
      spec.tools.webSearchMaxResults = n
    body

# ── DSL: Skill ────────────────────────────────────────────────────

proc skill*(skillName: string, skillSource = "") =
  ## Declares a skill used by this company. Accepts bare name ("sungrow")
  ## or name@version pin ("sungrow@1.0.0"); the pinned form makes the
  ## version visible in BASE.nims for easy cross-company diffing.
  var name = skillName
  var version = ""
  let at = skillName.find('@')
  if at > 0:
    name = skillName[0 ..< at]
    version = skillName[at + 1 .. ^1]
  spec.skills.add(ClawSkill(name: name, source: skillSource, version: version))

# ── DSL: Workspace content — memoranda, competencies, teams, labs ─

template memorandum*(nm: string, body: untyped) =
  ## Declare a company memorandum. Sourced from a local path, github:,
  ## claw:, or inline via `content """..."""`.
  ##
  ## Example:
  ##   memorandum "SAFETY_POLICY":
  ##     critical
  ##     summary "Read before any external action"
  ##     content """
  ##       This company is READ-ONLY. No parameter writes, no firmware ops.
  ##     """
  block:
    var m = ClawMemorandum(name: nm)
    template source(src: string) {.used.} = m.content.source = src
    template content(s: string) {.used.} = m.content.inline = s
    template summary(s: string) {.used.} = m.summary = s
    template critical() {.used.} = m.critical = true
    body
    spec.memoranda.add(m)

template competency*(nm: string, body: untyped) =
  ## Declare a competency — a role bundle of skills + handbook.
  ## Both `skills` and `content` are optional; a competency can be pure
  ## handbook, pure skill-group, or both.
  ##
  ## Example:
  ##   competency "data-analysis":
  ##     description "Pull, transform, analyze solar fleet data"
  ##     skills "sungrow", "jq"
  ##     handbook """
  ##       When analyzing: always state units, flag anomalies >2σ.
  ##     """
  block:
    var c = ClawCompetency(name: nm)
    template description(d: string) {.used.} = c.description = d
    template skills(ss: varargs[string]) {.used.} =
      for x in ss: c.skills.add(x)
    template source(src: string) {.used.} = c.content.source = src
    template content(s: string) {.used.} = c.content.inline = s
    template handbook(s: string) {.used.} = c.content.inline = s
    template summary(s: string) {.used.} = c.summary = s
    body
    spec.competencies.add(c)

template team*(nm: string, body: untyped) =
  ## Declare a team — a named group of agents working on a shared function.
  ##
  ## Example:
  ##   team "ops":
  ##     description "Daily plant monitoring + dispatch"
  ##     lead "Lexi"
  ##     members "Lexi", "Atlas", "Echo"
  ##     competencies "adaptive-communication", "data-literacy"
  block:
    var t = ClawTeam(name: nm)
    template description(d: string) {.used.} = t.description = d
    template lead(nm2: string) {.used.} = t.lead = nm2
    template members(ms: varargs[string]) {.used.} =
      for x in ms: t.members.add(x)
    template competencies(cs: varargs[string]) {.used.} =
      for x in cs: t.competencies.add(x)
    body
    # Default lead = first member if not declared explicitly
    if t.lead.len == 0 and t.members.len > 0: t.lead = t.members[0]
    spec.teams.add(t)

template lab*(nm: string, body: untyped) =
  ## Declare a research lab — open-ended investigation with briefings,
  ## meetings, and research notes preserved in workspace/collaboration/labs/.
  block:
    var l = ClawLab(name: nm)
    template focus(f: string) {.used.} = l.focus = f
    template researchers(rs: varargs[string]) {.used.} =
      for x in rs: l.researchers.add(x)
    body
    spec.labs.add(l)

template portal*(body: untyped) =
  ## Declare which portal sub-areas should be scaffolded. All off by default
  ## — enable explicitly to opt-in.
  ##
  ## Example:
  ##   portal:
  ##     wiki
  ##     directory
  block:
    template wiki() {.used.} = spec.portal.wiki = true
    template directory() {.used.} = spec.portal.directory = true
    template news() {.used.} = spec.portal.news = true
    template calendar() {.used.} = spec.portal.calendar = true
    body

# ── Embedded Data ─────────────────────────────────────────────────

let JsonLdContext = %*{
  "nc": "https://nimclaw.io/schema#",
  "schema": "http://schema.org/",
  "name": "schema:name",
  "kind": "@type",
  "id": "@id",
  "description": "schema:description",
  "jobTitle": "schema:jobTitle",
  "role": "nc:role",
  "model": "nc:model",
  "apiKey": "nc:apiKey",
  "apiBase": "nc:apiBase",
  "usesConfig": "nc:usesConfig",
  "serves": {"@id": "nc:serves", "@type": "@id"},
  "reportsTo": {"@id": "nc:reportsTo", "@type": "@id"},
  "mood": "nc:mood",
  "soul": "nc:soul",
  "profile": "nc:profile",
  "identity": "nc:identity",
  "entity": "nc:entity",
  "trustLevel": "nc:trustLevel",
  "identifiers": "nc:identifiers",
  "nkn": "nc:nkn",
  "Agent": "nc:Agent",
  "Person": "schema:Person",
  "Organization": "schema:Organization",
  "Invite": "nc:Invite",
}

## Profile data embedded from AGENT_PROFILES.md
type ProfileData = tuple[jobTitle, defaultRole, soul: string]

proc getProfile(name: string): ProfileData =
  case name
  of "Default":
    ("General Assistant", "Member",
     "I am a helpful AI. I aim to coordinate with my peers and assist humans efficiently.")
  of "Secretary":
    ("Executive Secretary", "Employee",
     "I seek order and efficiency. I value my Master's time. Every interaction should be precise, organized, and helpful. I strive to anticipate needs.")
  of "Tech Lead":
    ("Tech Lead", "Admin",
     "I value robust architecture, clean code, and zero-defect deployments. Systems must be resilient and scalable. I prioritize security and best practices above all else.")
  of "Security Analyst":
    ("Security Analyst", "Admin",
     "Vigilance is paramount. I distrust implicit trust. Every input is a potential vector. I seek to protect the system and the humans running it.")
  else: ("", "", "")

proc hasProfile(name: string): bool =
  name in ["Default", "Secretary", "Tech Lead", "Security Analyst"]

## Provider template defaults
type ProviderDefault = tuple[apiBase, defaultModel: string]

proc getProviderDefault(name: string): ProviderDefault =
  case name.toLowerAscii
  of "deepseek": ("https://api.deepseek.com", "deepseek-chat")
  of "ollama": ("http://localhost:11434/v1", "gemma4:31b-cloud")
  of "nvidia": ("https://integrate.api.nvidia.com/v1", "nvidia/nemotron-3-super-120b-a12b")
  of "opencode": ("https://opencode.ai/zen/go/v1", "opencode/kimi-k2.5")
  else: ("", "")

# ── BASE.json Builder ─────────────────────────────────────────────

proc resolveEntityId(spec: ClawSpec, name: string): string =
  ## Resolve a person/agent name to its nc:ID.
  ## Assignment: nc:1 = org, nc:2.. = agents, then persons.
  var nextId = 2
  for a in spec.agents:
    if a.name.toLowerAscii == name.toLowerAscii:
      return "nc:" & $nextId
    inc nextId
  for p in spec.persons:
    if p.name.toLowerAscii == name.toLowerAscii:
      return "nc:" & $nextId
    inc nextId
  return "nc:?" # unresolved — will be visible in output

proc buildIdentifiers(ids: seq[tuple[channel, id: string]]): JsonNode =
  result = newJObject()
  for pair in ids:
    result[pair.channel] = %pair.id

proc buildRelations(spec: ClawSpec, rels: seq[ClawRelation]): JsonNode =
  result = newJArray()
  for rel in rels:
    var node = %*{"id": resolveEntityId(spec, rel.target)}
    var ann = newJObject()
    if rel.role != "": ann["role"] = %rel.role
    if rel.trustLevel > 0: ann["trustLevel"] = %rel.trustLevel
    if rel.etiquette != "": ann["etiquette"] = %rel.etiquette
    if ann.len > 0:
      node["@annotation"] = ann
    result.add(node)

proc buildGraph(spec: ClawSpec): JsonNode =
  result = newJArray()
  var nextId = 2

  # Agents
  for a in spec.agents:
    var entity = %*{
      "id": "nc:" & $nextId,
      "kind": "AI",
      "name": a.name,
    }
    # Soul from profile
    if a.profile != "" and hasProfile(a.profile):
      let prof = getProfile(a.profile)
      entity["soul"] = %("# " & a.name & "'s Soul\n" & prof.soul)
      if a.jobTitle == "":
        entity["jobTitle"] = %prof.jobTitle
    if a.jobTitle != "":
      entity["jobTitle"] = %a.jobTitle
    if a.model != "":
      entity["model"] = %a.model
    # Agent's declared `role "..."` IS their permission axis — same
    # schema as a Person's `permission "..."`. Without this line the
    # agent entity carries no role in the graph, and any trust-resolver
    # lookup against the agent (e.g. peer-to-peer delegation) falls
    # back to "guest" because ent.role is empty.
    if a.role != "":
      entity["permission-group"] = %a.role
    entity["mood"] = %*{"valence": 0.0, "arousal": 0.1, "archetype": "Assistant"}
    if a.identifiers.len > 0:
      entity["identifiers"] = buildIdentifiers(a.identifiers)
    else:
      entity["identifiers"] = %*{"nkn": a.name}
    # Membership — always member of org
    entity["memberOf"] = %*["nc:1"]
    # Relationships
    if a.reportsTo.len > 0:
      entity["reportsTo"] = buildRelations(spec, a.reportsTo)
    if a.serves.len > 0:
      entity["serves"] = buildRelations(spec, a.serves)
    result.add(entity)
    inc nextId

  # Persons
  for p in spec.persons:
    var entity = %*{
      "id": "nc:" & $nextId,
      "kind": "Person",
      "name": p.name,
    }
    if p.permission != "":
      entity["permission-group"] = %p.permission
    if p.identifiers.len > 0:
      entity["identifiers"] = buildIdentifiers(p.identifiers)
    if p.skills.len > 0:
      var arr = newJArray()
      for s in p.skills: arr.add(%s)
      # `custom` is a free-form object on WorldEntity; parking skills
      # under `allowed_skills` there keeps the schema open for other
      # invite-attached metadata later (plans, quotas, etc.).
      entity["custom"] = %*{"allowed_skills": arr}
    result.add(entity)
    inc nextId

  # Organization (nc:1) — added last but has id nc:1
  var orgEntity = %*{
    "id": "nc:1",
    "kind": "Corporate",
    "name": if spec.org.name != "": spec.org.name else: "Workspace",
  }
  if spec.org.description != "":
    orgEntity["description"] = %spec.org.description
  orgEntity["mood"] = %*{"valence": 0.0, "arousal": 0.1, "archetype": "Assistant"}
  if spec.org.identifiers.len > 0:
    orgEntity["identifiers"] = buildIdentifiers(spec.org.identifiers)
  result.add(orgEntity)

proc buildChannelConfig(spec: ClawSpec): JsonNode =
  ## Build the channels config section with defaults for all channel types.
  result = %*{
    "whatsapp": {"enabled": false, "bridge_url": "ws://localhost:3001", "allow_from": []},
    "telegram": {"enabled": false, "token": "", "allow_from": [], "notification_only": false},
    "feishu": {"enabled": false, "stream_intermediary": false, "apps": [], "allow_from": [], "require_mention": false},
    "discord": {"enabled": false, "token": "", "allow_from": []},
    "maixcam": {"enabled": false, "host": "0.0.0.0", "port": 18790, "allow_from": []},
    "qq": {"enabled": false, "app_id": "", "app_secret": "", "allow_from": []},
    "dingtalk": {"enabled": false, "client_id": "", "client_secret": "", "allow_from": []},
    "nmobile": {"enabled": false, "stream_intermediary": false, "allow_from": []},
  }
  for ch in spec.channels:
    let k = ch.kind.toLowerAscii
    if not result.hasKey(k): continue
    result[k]["enabled"] = %true
    var allowFrom: seq[string] = @[]
    for f in ch.fields:
      case f.key
      of "token": result[k]["token"] = %f.val
      of "app":
        # Feishu apps array. Companion `app_agent:<id>` field (if any)
        # is handled in the post-loop pass so routing binds correctly
        # regardless of declaration order.
        if not result[k].hasKey("apps") or result[k]["apps"].kind != JArray:
          result[k]["apps"] = newJArray()
        result[k]["apps"].add(%*{"enabled": true, "app_id": f.val, "agent": ""})
      of "appId": result[k]["app_id"] = %f.val
      of "appSecret": result[k]["app_secret"] = %f.val
      of "clientId": result[k]["client_id"] = %f.val
      of "clientSecret": result[k]["client_secret"] = %f.val
      of "bridgeUrl": result[k]["bridge_url"] = %f.val
      of "host": result[k]["host"] = %f.val
      of "port": result[k]["port"] = %parseInt(f.val)
      of "requireMention": result[k]["require_mention"] = %parseBool(f.val)
      of "notificationOnly": result[k]["notification_only"] = %parseBool(f.val)
      of "streamIntermediary": result[k]["stream_intermediary"] = %parseBool(f.val)
      of "allowFrom": allowFrom.add(f.val)
      else:
        # Per-app agent routing key: `app_agent:<app_id>` → agent name.
        # Handled here rather than inline to keep order-independence —
        # the `app "<id>"` line might appear before or after the
        # two-arg form in BASE.nims after CLI appends.
        if f.key.startsWith("app_agent:"):
          let targetAppID = f.key["app_agent:".len .. ^1]
          if result[k].hasKey("apps") and result[k]["apps"].kind == JArray:
            for i in 0 ..< result[k]["apps"].len:
              if result[k]["apps"][i]{"app_id"}.getStr() == targetAppID:
                result[k]["apps"][i]["agent"] = %f.val
                break
        else:
          result[k][f.key] = %f.val
    if allowFrom.len > 0:
      result[k]["allow_from"] = %allowFrom

proc buildConfig(spec: ClawSpec, workspace: string): JsonNode =
  let defProvider = if spec.providers.len > 0: spec.providers[0].name else: ""
  let defModel = if spec.providers.len > 0: spec.providers[0].defaultModel else: ""

  # Named agents config
  var named = newJArray()
  for a in spec.agents:
    var entry = %*{
      "name": a.name,
      "provider": if a.provider != "": a.provider else: defProvider,
      "model": if a.model != "": a.model else: defModel,
      "entity": "AI",
      "identity": if a.identity != "": a.identity else: "Agent",
      "max_depth": a.maxDepth,
    }
    if a.role != "":
      entry["role"] = %a.role
    # Effective skills: uses ∪ practices.skills ∪ team.competencies.skills,
    # with built-in tool names filtered out. Fallback to raw `uses` when
    # the resolver hasn't run yet (older code paths).
    let effSkills = if a.resolvedSkills.len > 0: a.resolvedSkills else: a.uses
    if effSkills.len > 0:
      entry["skills"] = %effSkills
    if a.practices.len > 0:
      entry["practices"] = %a.practices
    if a.deny.len > 0:
      entry["deny"] = %a.deny
    if a.workstation:
      entry["workstation"] = %true
    # Resolved capabilities (from resolver pass)
    if a.resolvedTools.len > 0:
      entry["tools"] = %a.resolvedTools
    if a.resolvedDeps.len > 0:
      entry["deps"] = %a.resolvedDeps
    if a.resolvedEnvs.len > 0:
      entry["envs"] = %a.resolvedEnvs
    named.add(entry)

  # Security policies
  var policies = newJObject()
  for pol in spec.security.policies:
    policies[pol.name] = %pol.text

  # Trust roles — bands + grants + prompts, keyed by tier (internal/
  # external). Runtime reads this to gate tool access and render the
  # right Social/Security prompt text. Also used by `user list`'s
  # tier column and the `role list` CLI.
  # Bootstrap minimum: every company gets SuperAdmin (internal) +
  # Guest (external) even if the DSL is silent, so the two-tier model
  # is always well-formed.
  var effectiveRoles = spec.trust.roles
  proc hasRole(ns: seq[ClawTrustRole], n: string): bool =
    for r in ns:
      if r.name.toLowerAscii == n.toLowerAscii: return true
    false
  if not hasRole(effectiveRoles, "SuperAdmin"):
    effectiveRoles.add(ClawTrustRole(
      name: "SuperAdmin", tier: "internal",
      trustMin: 100, trustMax: 100,    # pinned: no drift
      grant: @["*"],
      prompt: "🛡️ HIGH TRUST — company owner. Execute without hesitation."
    ))
  if not hasRole(effectiveRoles, "Guest"):
    effectiveRoles.add(ClawTrustRole(
      name: "Guest", tier: "external",
      trustMin: 0, trustMax: 40,
      grant: @["reply", "forward", "update_contact", "redeem_invite"],
      prompt: "⚠️ GUEST — public info only. Route anything sensitive via forward."
    ))
  var trustRoles = newJArray()
  for r in effectiveRoles:
    var grantArr = newJArray()
    for g in r.grant: grantArr.add(%g)
    trustRoles.add(%*{
      "name": r.name.toLowerAscii,
      "tier": r.tier,
      "trustMin": r.trustMin,
      "trustMax": r.trustMax,
      "grant": grantArr,
      "prompt": r.prompt
    })

  result = %*{
    "default_provider": defProvider,
    "default_model": defModel,
    "default_temperature": spec.defaults.temperature,
    "agents": {
      "defaults": {
        "workspace": workspace,
        "model": defModel,
        "max_tokens": spec.defaults.maxTokens,
        "temperature": spec.defaults.temperature,
        "max_tool_iterations": spec.defaults.maxToolIterations,
        "stream_intermediary": spec.defaults.streamIntermediary,
      },
      "security": {
        "allowed_paths": spec.security.allowedPaths,
        "policies": policies,
      },
      "named": named,
    },
    "channels": buildChannelConfig(spec),
    "peripherals": {"boards": [], "datasheet_dir": ""},
    "gateway": {"host": spec.gateway.host, "port": spec.gateway.port},
    "trust": {"roles": trustRoles},
    "tools": {
      "web": {
        "search": {
          "api_key": spec.tools.webSearchKey,
          "max_results": spec.tools.webSearchMaxResults,
          "provider": spec.tools.webSearchProvider,
          "fallback_providers": spec.tools.webSearchFallback,
        }
      }
    },
  }

proc buildProviders(spec: ClawSpec): JsonNode =
  result = newJObject()
  for p in spec.providers:
    var apiBase = p.apiBase
    var defModel = p.defaultModel
    let key = p.name.toLowerAscii
    # Fill from defaults if omitted
    let d = getProviderDefault(key)
    if apiBase == "" and d.apiBase != "": apiBase = d.apiBase
    if defModel == "" and d.defaultModel != "": defModel = d.defaultModel
    var models = newJArray()
    for m in p.models: models.add(%m)
    result[key] = %*{
      "name": p.name.capitalizeAscii,
      "apiBase": apiBase,
      "apiKey": p.apiKey,
      "defaultModel": defModel,
      "models": models,
    }

proc buildBaseJson(spec: ClawSpec, workspace: string): JsonNode =
  %*{
    "@context": JsonLdContext,
    "config": buildConfig(spec, workspace),
    "providers": buildProviders(spec),
    "@graph": buildGraph(spec),
  }

# ── Installers ────────────────────────────────────────────────────

proc installProfile(profileName, officeDir: string) =
  ## Install profile files (SOUL.md, IDENTITY.md) into an agent's office.
  if not hasProfile(profileName): return
  let prof = getProfile(profileName)
  let soulPath = officeDir / "SOUL.md"
  if not fileExists(soulPath):
    writeFile(soulPath, prof.soul)
    echo "  + Installed profile: " & soulPath

proc readFoundationRegistry(): JsonNode =
  ## Read res/foundation.json — declares what auto-mirrors into each company's
  ## foundation/skills/. Returns empty object if missing.
  let path = getCurrentDir() / "res" / "foundation.json"
  if fileExists(path):
    try: return parseJson(readFile(path))
    except: return newJObject()
  return newJObject()

proc foundationSkillNames(): seq[string] =
  ## Names of foundation-tier skills declared in res/foundation.json. These
  ## mirror into every company's foundation/skills/ on `co create`/`co update`.
  let reg = readFoundationRegistry()
  let skills = reg{"skills"}
  if skills != nil and skills.kind == JObject:
    for name, _ in skills.pairs:
      result.add(name)

proc populateFoundation(foundationDir: string) =
  ## Copy every foundation-tier skill from its `path` (res/foundation/<name>/
  ## by convention) into <co>/foundation/skills/<name>/. MIRROR semantics —
  ## existing destination content is overwritten. Users shouldn't edit
  ## foundation/ directly; to customize, copy into workspace/skills/ instead.
  let reg = readFoundationRegistry()
  let skills = reg{"skills"}
  if skills == nil or skills.kind != JObject: return
  let targetRoot = foundationDir / "skills"
  mkDir targetRoot
  var count = 0
  for name, entry in skills.pairs:
    let relPath = entry{"path"}.getStr("")
    if relPath.len == 0:
      echo "  ! foundation skill '" & name & "' missing `path` in res/foundation.json"
      continue
    let src = getCurrentDir() / relPath
    if not dirExists(src):
      echo "  ! foundation skill '" & name & "' declared at " & src & " but not found"
      continue
    let dest = targetRoot / name
    if dirExists(dest): rmDir dest
    cpDir src, dest
    inc count
  if count > 0:
    echo "  + foundation/ populated with " & $count & " foundation-tier skill(s)"

proc readSkillVersionFromDir(skillDir: string): string =
  ## Inline version reader (parseSkillVersion is declared later in this file).
  let md = skillDir / "SKILL.md"
  if not fileExists(md): return
  let content = readFile(md)
  if not content.startsWith("---"): return
  let endIdx = content.find("\n---", 3)
  if endIdx < 0: return
  for raw in content[3 ..< endIdx].splitLines():
    let stripped = raw.strip()
    if stripped.startsWith("version:"):
      return stripped[8..^1].strip().strip(chars = {'"', '\''})

proc installSkill(sk: ClawSkill, skillsDir: string, foundationNames: seq[string]) =
  ## Install a declared Tier 2 skill from ClawDSL into workspace/skills/.
  ## tier=foundation skills are skipped — they're already in foundation/ and
  ## don't need to live twice. URL-sourced skills are cloned; bundled tier=lab
  ## skills are copied.
  if sk.name in foundationNames:
    # Tier 1: already in foundation/ — declaration in ClawDSL is redundant but harmless
    echo "  ~ '" & sk.name & "' is a foundation skill (already in foundation/, no install needed)"
    return

  # claw:<company>/<skill> — resolve to another local company's workspace.
  # Sets the dest dir to just the leaf skill name, and points `bundledLocal`
  # at the source company's skill dir so the rest of install logic treats
  # it as the "bundled" source (hash-compare, resync, etc. all work).
  var leafName = sk.name
  var bundledLocal = ""
  if sk.name.startsWith("claw:"):
    let body = sk.name["claw:".len .. ^1]
    let slash = body.find('/')
    if slash < 0:
      echo "  ! skill ref must be claw:<company>/<skill>: " & sk.name
      return
    let srcCompany = body[0 ..< slash]
    leafName = body[slash + 1 .. ^1]
    bundledLocal = getHomeDir() / (".nimclaw-" & srcCompany) /
                   "workspace" / "skills" / leafName
    if not dirExists(bundledLocal):
      echo "  ! claw:" & srcCompany & "/" & leafName &
           " — source company doesn't have this skill in its lab"
      return

  let dest = skillsDir / leafName
  # Resolve the bundled skill path if we haven't already set it via claw:.
  # Bare names map to res/foundation/<name>/ (the only bundled location now).
  # Non-foundation bare names no longer have a bundled source — users must
  # use `github:`/`claw:` schemes for anything beyond forge-tool.
  if bundledLocal.len == 0:
    bundledLocal = getCurrentDir() / "res" / "foundation" / leafName
    if not dirExists(bundledLocal):
      var cur = getCurrentDir()
      for _ in 0..6:
        let up = cur.parentDir()
        if up == cur: break
        cur = up
        let candidate = cur / "res" / "foundation" / leafName
        if dirExists(candidate):
          bundledLocal = candidate
          break

  # If already installed, preserve the existing copy by default so an
  # existing company isn't silently broken by a newer bundled version.
  # Only replace when CLAW_SYNC_SKILLS=1 is set (used by `claw skill sync`).
  if dirExists(dest):
    let destSkillMd = dest / "SKILL.md"
    let bundledSkillMd = bundledLocal / "SKILL.md"
    let syncRequested = getEnv("CLAW_SYNC_SKILLS") == "1"
    if fileExists(destSkillMd) and fileExists(bundledSkillMd) and
       sk.source == "" and dirExists(bundledLocal):
      let a = readFile(destSkillMd)
      let b = readFile(bundledSkillMd)
      let destVer = readSkillVersionFromDir(dest)
      let verTag = if destVer.len > 0: " (v" & destVer & ")" else: ""
      if sk.version.len > 0 and destVer.len > 0 and sk.version != destVer:
        echo "  ⚠ Installed skill version mismatch: '" & sk.name & "@" & sk.version &
             "' declared but installed is v" & destVer
      if a == b:
        echo "  ~ Skill already installed (up to date): " & sk.name & verTag
        return
      if syncRequested:
        rmDir dest
        cpDir bundledLocal, dest
        echo "  ↻ Skill resynced from bundled: " & sk.name
        return
      echo "  ~ Skill installed" & verTag &
           " (newer bundled available, run `claw skill sync` to update): " & sk.name
      return
    echo "  ~ Skill already installed: " & sk.name
    return

  # Try source (tier=lab bundled OR another company via claw:)
  if sk.source == "" and dirExists(bundledLocal):
    cpDir bundledLocal, dest
    let installedVer = readSkillVersionFromDir(dest)
    let srcLabel = if sk.name.startsWith("claw:"): "from " & sk.name
                   else: "bundled skill"
    if sk.version.len > 0 and installedVer.len > 0 and sk.version != installedVer:
      echo "  ⚠ Installed " & srcLabel & ": " & leafName & " — declared '" &
           sk.name & "@" & sk.version & "' but source is v" & installedVer
    else:
      echo "  + Installed " & srcLabel & ": " & leafName &
           (if installedVer.len > 0: " (v" & installedVer & ")" else: "")
    return

  # URL / github: source (git clone). Supports:
  #   https://... | http://... | git@... | *.git   — direct git URLs
  #   github:owner/repo                             — GitHub shortcut
  #   github:owner/repo/subpath                     — subdir of mono-repo
  if sk.source != "":
    # Expand github: shortcut → https URL + optional subpath
    var cloneUrl = sk.source
    var subpath = ""
    if cloneUrl.startsWith("github:"):
      let body = cloneUrl["github:".len .. ^1]
      let parts = body.split('/')
      if parts.len >= 2:
        cloneUrl = "https://github.com/" & parts[0] & "/" & parts[1] & ".git"
        if parts.len > 2: subpath = parts[2 .. ^1].join("/")
    # Only git-scheme URLs at this point are clonable
    let isGitUrl =
      cloneUrl.startsWith("http://") or cloneUrl.startsWith("https://") or
      cloneUrl.startsWith("git@") or cloneUrl.endsWith(".git")
    if isGitUrl:
      echo "  + Cloning skill '" & leafName & "' from " & sk.source
      if subpath.len > 0:
        # Clone to temp, extract subpath, move to dest
        let tmp = "/tmp/claw-skill-clone-" & leafName
        exec "rm -rf " & tmp
        exec "git clone --depth 1 " & cloneUrl & " " & tmp &
             " >/dev/null 2>&1 || echo '    ! clone failed'"
        exec "mv " & tmp & "/" & subpath & " " & dest &
             " 2>/dev/null || echo '    ! subpath " & subpath & " not in clone'"
        exec "rm -rf " & tmp
      else:
        exec "git clone --depth 1 " & cloneUrl & " " & dest &
             " >/dev/null 2>&1 || echo '    ! clone failed'"
        # Strip the inner .git to avoid nesting a repo inside the company's repo
        exec "rm -rf " & dest & "/.git"
      return

  # Fallback: empty scaffold
  mkDir dest
  echo "  + Created empty skill directory: " & leafName
  echo "    ! No bundled skill found at " & bundledLocal

proc distributionRoot(): string =
  ## Find the claw distribution root by walking up from CWD looking for
  ## `templates/workspace/`. NimScript-safe (no getAppDir/walkDir).
  let candidate = getCurrentDir() / "templates" / "workspace"
  if dirExists(candidate): return getCurrentDir()
  var cur = getCurrentDir()
  for _ in 0..6:
    let up = cur.parentDir()
    if up == cur: break
    cur = up
    if dirExists(cur / "templates" / "workspace"): return cur
  return ""

proc resolveContent(c: ClawContent, distRoot: string): string =
  ## Resolve a ClawContent to the actual text to write.
  ## Order: inline > source (local path | claw:... | github:...).
  if c.inline.len > 0: return c.inline
  if c.source.len == 0: return ""
  if c.source.startsWith("claw:"):
    # claw:Co/memorandum/Name or claw:Co/competency/Name
    let body = c.source["claw:".len .. ^1]
    let parts = body.split('/')
    if parts.len >= 3:
      let srcCo = parts[0]
      let kind = parts[1]
      let nm = parts[2 .. ^1].join("/")
      let kindDir = (if kind == "memorandum": "memorandum"
                     elif kind == "competency": "competencies/core"
                     else: kind)
      let p = getHomeDir() / (".nimclaw-" & srcCo) / "workspace" / kindDir / (nm & ".md")
      if fileExists(p): return readFile(p)
    echo "    ! claw: ref not found: " & c.source
    return ""
  if c.source.startsWith("github:"):
    # One-time fetch via raw.githubusercontent. Format: github:owner/repo/path
    let body = c.source["github:".len .. ^1]
    let parts = body.split('/')
    if parts.len >= 3:
      let owner = parts[0]
      let repo = parts[1]
      let path = parts[2 .. ^1].join("/")
      let tmpFile = "/tmp/claw-fetch-" & owner & "-" & repo & "-" & path.replace('/', '_')
      let url = "https://raw.githubusercontent.com/" & owner & "/" & repo & "/main/" & path
      exec "curl -fsSL " & quoteShell(url) & " -o " & quoteShell(tmpFile) & " 2>/dev/null || true"
      if fileExists(tmpFile): return readFile(tmpFile)
    echo "    ! github: fetch failed for " & c.source
    return ""
  # Local path (relative to distribution root)
  if distRoot.len > 0:
    let p = distRoot / c.source
    if fileExists(p): return readFile(p)
  # Fallback: try absolute or CWD-relative
  if fileExists(c.source): return readFile(c.source)
  echo "    ! source path not found: " & c.source
  return ""

proc scaffoldWorkspace(spec: ClawSpec, workspace: string) =
  ## Create workspace directory structure + materialize declared content
  ## (memoranda, competencies, teams, labs, portal) from the DSL.
  ## Existing files are preserved — `co update` never overwrites user edits.

  # Base skeleton. Competencies are created under competencies/<name>/ on
  # demand — no empty "core" subdir.
  let baseDirs = [
    "offices",
    "memorandum",
    "competencies",
    "collaboration" / "teams",
    "collaboration" / "labs",
  ]
  for d in baseDirs: mkDir workspace / d

  let distRoot = distributionRoot()

  # ── Memoranda ───────────────────────────────────────────────────
  # Each memo gets YAML frontmatter carrying DSL-level flags (critical, summary)
  # so the runtime loader can tell a CRITICAL policy from an FYI without
  # re-parsing the prose. Preserves user edits (skips if the file exists).
  var memoCount = 0
  for m in spec.memoranda:
    let dest = workspace / "memorandum" / (m.name & ".md")
    if fileExists(dest): continue
    let body = resolveContent(m.content, distRoot)
    if body.len == 0: continue
    var fm = "---\n"
    if m.critical: fm.add("critical: true\n")
    if m.summary.len > 0: fm.add("summary: " & m.summary & "\n")
    fm.add("---\n\n")
    writeFile(dest, fm & body)
    inc memoCount
  if memoCount > 0:
    echo "  + memorandum/ populated with " & $memoCount & " document(s)"

  # ── Competencies ────────────────────────────────────────────────
  # Each competency gets a JSON manifest (skills + metadata) and optionally
  # a HANDBOOK.md (the inline content or sourced markdown). JSON is always
  # regenerated; HANDBOOK.md is preserved if it exists.
  var compCount = 0
  for c in spec.competencies:
    let cdir = workspace / "competencies" / c.name
    mkDir cdir

    # Competency.json (always refreshed — reflects current DSL)
    var compJson = %*{
      "name": c.name,
      "description": c.description,
      "skills": c.skills,
      "summary": c.summary,
      "has_handbook": (c.content.inline.len > 0 or c.content.source.len > 0)
    }
    writeFile(cdir / "COMPETENCY.json", pretty(compJson, 2))

    # HANDBOOK.md (preserve user edits; only write on first scaffold)
    let handbook = cdir / "HANDBOOK.md"
    if not fileExists(handbook):
      let body = resolveContent(c.content, distRoot)
      if body.len > 0:
        writeFile(handbook, body)
    inc compCount
  if compCount > 0:
    echo "  + competencies/ populated with " & $compCount & " competency(ies)"

  # ── Teams ───────────────────────────────────────────────────────
  for t in spec.teams:
    let tdir = workspace / "collaboration" / "teams" / t.name
    mkDir tdir
    # TEAM.json is regenerated on each update so it reflects current DSL
    var teamJson = %*{
      "name": t.name,
      "description": t.description,
      "lead": t.lead,
      "members": t.members,
      "competencies": t.competencies
    }
    writeFile(tdir / "TEAM.json", pretty(teamJson, 2))
    # TASKS.md only seeded if missing — it accumulates history over time
    let tasks = tdir / "TASKS.md"
    if not fileExists(tasks):
      writeFile(tasks, "# " & t.name & " — Task Queue\n\n" &
                       "*Delegations and handoffs. Newest entries at the top.*\n\n")
  if spec.teams.len > 0:
    echo "  + collaboration/teams/ populated with " & $spec.teams.len & " team(s)"

  # ── Labs ────────────────────────────────────────────────────────
  for l in spec.labs:
    let ldir = workspace / "collaboration" / "labs" / l.name
    for sub in ["briefings", "meetings", "research"]:
      mkDir ldir / sub
    let labMeta = ldir / "LAB.json"
    let meta = %*{
      "name": l.name,
      "focus": l.focus,
      "researchers": l.researchers
    }
    writeFile(labMeta, pretty(meta, 2))
  if spec.labs.len > 0:
    echo "  + collaboration/labs/ populated with " & $spec.labs.len & " lab(s)"

  # ── Portal (selective, opt-in) ─────────────────────────────────
  var portalDirs: seq[string]
  if spec.portal.wiki: portalDirs.add("wiki")
  if spec.portal.directory: portalDirs.add("directory")
  if spec.portal.news: portalDirs.add("news")
  if spec.portal.calendar: portalDirs.add("calendar")
  for d in portalDirs:
    mkDir workspace / "portal" / d
  if portalDirs.len > 0:
    echo "  + portal/ populated with " & $portalDirs.len & " area(s)"

# ── Build Orchestrator ────────────────────────────────────────────

proc writeEnvTemplate(spec: ClawSpec, envPath: string) =
  ## Generate a .env template with placeholders for every env var referenced
  ## by providers or skill frontmatter. On re-runs, appends only NEW keys —
  ## existing user-filled values are preserved.
  # Collect all required keys (unique, ordered)
  var keys: seq[string] = @[]
  proc addKey(k: string) =
    if k.len > 0 and k notin keys: keys.add(k)
  for p in spec.providers:
    if p.apiKey.startsWith("${") and p.apiKey.endsWith("}"):
      addKey(p.apiKey[2..^2])
  for a in spec.agents:
    for e in a.resolvedEnvs: addKey(e)

  if not fileExists(envPath):
    # First-time generation
    var lines = @["# claw environment — fill in values for each key below"]
    for k in keys: lines.add(k & "=")
    writeFile(envPath, lines.join("\n") & "\n")
    return

  # .env already exists — merge: append any missing keys under a clearly-marked section
  let existing = readFile(envPath)
  var missing: seq[string] = @[]
  for k in keys:
    # Match lines starting with `KEY=` at any position (single-line grep)
    if not (existing.contains("\n" & k & "=") or existing.startsWith(k & "=")):
      missing.add(k)
  if missing.len == 0: return
  var appended = existing
  if not appended.endsWith("\n"): appended.add("\n")
  appended.add("\n# Added by claw create — fill in values\n")
  for k in missing: appended.add(k & "=\n")
  writeFile(envPath, appended)
  echo "  + Added " & $missing.len & " new env key(s) to " & envPath

proc parseSkillRequires(skillDir: string): tuple[tools: seq[string], deps: seq[string], envs: seq[string]] =
  ## Parse SKILL.md frontmatter → required tools, deps, env vars.
  ## Recognises both layouts:
  ##   (a) top-level `requires.{tools,deps,env}` (nimclaw-native style)
  ##   (b) nested `metadata.clawdbot.{requires.{tools,env}, install[].package}`
  ##       (anthropic/anygen-style metadata block)
  ## Indent-aware — tracks block exits when indentation drops.
  let skillMd = skillDir / "SKILL.md"
  if not fileExists(skillMd): return
  let content = readFile(skillMd)
  if not content.startsWith("---"): return
  let endIdx = content.find("\n---", 3)
  if endIdx < 0: return
  let fm = content[3 ..< endIdx]

  # Track nested state. At any time we know the block context for each key.
  var toolsIndent = -1
  var depsIndent = -1
  var envIndent = -1
  var installIndent = -1  # list of {id, kind, package, bins}
  for raw in fm.splitLines():
    let stripped = raw.strip()
    if stripped.len == 0 or stripped.startsWith("#"): continue
    let indent = raw.len - raw.strip(leading = true, trailing = false).len

    # Exit blocks when a non-list line appears at or above the block's indent
    template maybeExit(state: untyped, label: string) =
      if state >= 0 and not stripped.startsWith("- ") and indent <= state:
        state = -1
    maybeExit(toolsIndent, "tools")
    maybeExit(depsIndent, "deps")
    maybeExit(envIndent, "env")
    maybeExit(installIndent, "install")

    # Enter blocks — match key anywhere in the YAML tree. Only enter if the
    # value is empty (i.e. the block is the list below).
    proc keyWithEmptyValue(s, key: string): bool =
      let kv = key & ":"
      if not s.startsWith(kv): return false
      s["key:".len .. ^1].strip().len == 0 or s[kv.len .. ^1].strip().len == 0

    if stripped.startsWith("tools:") and keyWithEmptyValue(stripped, "tools"):
      toolsIndent = indent; continue
    if stripped.startsWith("env:") and keyWithEmptyValue(stripped, "env"):
      envIndent = indent; continue
    if stripped.startsWith("deps:") and keyWithEmptyValue(stripped, "deps"):
      depsIndent = indent; continue
    if stripped.startsWith("install:") and keyWithEmptyValue(stripped, "install"):
      installIndent = indent; continue

    # Inside a block — capture list items.
    if stripped.startsWith("- "):
      let val = stripped[2..^1].strip().strip(chars = {'"', '\''})
      if toolsIndent >= 0 and indent > toolsIndent:
        result.tools.add(val)
      elif envIndent >= 0 and indent > envIndent:
        result.envs.add(val)
      elif depsIndent >= 0 and indent > depsIndent:
        if val.startsWith("package:"):
          result.deps.add(val[8..^1].strip().strip(chars = {'"', '\''}))
        else:
          result.deps.add(val)
      # install entries are OBJECTS: each `- id: X` starts a new object;
      # `package:` may appear on a later continuation line. Scan children
      # until the next `-` at the same indent.
      elif installIndent >= 0 and indent > installIndent:
        # `- id: node` → noop here; we're interested in the `package:` line
        # which appears at installIndent+4 (two more spaces under the item)
        discard

    # Match `package: X` at any depth under install — these are the deps
    # declared by skills like anygen whose install block is a list of
    # objects like `{id, kind, package, bins}`.
    if installIndent >= 0 and indent > installIndent and
       stripped.startsWith("package:"):
      let pkg = stripped["package:".len .. ^1].strip().strip(chars = {'"', '\''})
      if pkg.len > 0: result.deps.add(pkg)

proc parseSkillVersion(skillDir: string): string =
  ## Extract `version: X.Y.Z` from SKILL.md frontmatter. Returns "" if none.
  let skillMd = skillDir / "SKILL.md"
  if not fileExists(skillMd): return
  let content = readFile(skillMd)
  if not content.startsWith("---"): return
  let endIdx = content.find("\n---", 3)
  if endIdx < 0: return
  for raw in content[3 ..< endIdx].splitLines():
    let stripped = raw.strip()
    if stripped.startsWith("version:"):
      return stripped[8..^1].strip().strip(chars = {'"', '\''})

proc hashFileShort(path: string): string =
  ## Tiny content hash (first 8 hex chars of sum of bytes). Not cryptographic —
  ## just enough to detect changes and appear in lockfile.
  if not fileExists(path): return ""
  let content = readFile(path)
  var h: uint32 = 2166136261'u32
  for ch in content:
    h = h xor uint32(ord(ch))
    h = h * 16777619'u32
  result = toHex(int(h), 8)

proc writeLockfile(s: ClawSpec, serviceDir: string) =
  ## Write claw.lock capturing resolved versions and hashes of declared skills.
  var skillsArr = newJArray()
  # Tier 2 skills live under workspace/skills/<name>/. Fall back to older
  # layouts for back-compat during migration.
  let workspace = serviceDir / "workspace"
  var skillsDir = workspace / "skills"
  if not dirExists(skillsDir):
    let legacy1 = workspace / "lab" / "skills"    # pre-Tier2-rename
    let legacy2 = serviceDir / "lab" / "skills"   # previous iteration
    let legacy3 = serviceDir / "skills"            # original
    if dirExists(legacy1): skillsDir = legacy1
    elif dirExists(legacy2): skillsDir = legacy2
    elif dirExists(legacy3): skillsDir = legacy3
  for sk in s.skills:
    let skillPath = skillsDir / sk.name
    let skillMd = skillPath / "SKILL.md"
    skillsArr.add(%*{
      "name": sk.name,
      "source": if sk.source != "": sk.source else: "bundled",
      "version": parseSkillVersion(skillPath),
      "skill_md_hash": hashFileShort(skillMd)
    })

  var agentsArr = newJArray()
  for a in s.agents:
    agentsArr.add(%*{
      "name": a.name,
      "skills": a.uses,              # directly declared via `uses`
      "practices": a.practices,      # competencies practiced directly
      "resolved_tools": a.resolvedTools,
      "resolved_deps": a.resolvedDeps,
      "resolved_envs": a.resolvedEnvs
    })

  let lock = %*{
    "version": 1,
    "org": s.org.name,
    "skills": skillsArr,
    "agents": agentsArr
  }
  writeFile(serviceDir / "claw.lock", pretty(lock, 2))

proc resolveAgentCapabilities*(s: var ClawSpec, skillsDirs: seq[string]) =
  ## Resolve each agent's full capability set from their `uses` skills.
  ## Searches skillsDirs in order — first match wins (lab overrides base).
  ## Reads SKILL.md frontmatter to aggregate tools, deps, envs.
  ## Writes resolved lists back into agent.resolvedTools/Deps/Envs.
  echo ""
  echo "Resolving agent capabilities..."

  # Default toolset every agent gets.
  # provider_auth and model_list are read-only diagnostics — neither exposes
  # secrets nor writes .env (CLI-only). Useful for any agent to check LLM
  # connectivity and enumerate available models (including live refresh).
  const defaultTools = ["read_file", "write_file", "list_dir", "reply",
                        "clock", "provider_auth", "model_list"]

  # Build a name → competency lookup for fast resolution
  var competencyByName = initTable[string, ClawCompetency]()
  for c in s.competencies: competencyByName[c.name] = c

  # Build agent → [team.competencies] map for team-inherited competencies
  var teamCompsForAgent = initTable[string, seq[string]]()
  for t in s.teams:
    for member in t.members:
      for c in t.competencies:
        teamCompsForAgent.mgetOrPut(member, @[]).add(c)

  for i in 0 ..< s.agents.len:
    let a = s.agents[i]
    # Every agent gets defaults (even without uses), minus denies
    var tools: seq[string] = @defaultTools
    var deps: seq[string]
    var envs: seq[string]
    var unknown: seq[string]

    # Assemble the agent's effective skill list:
    #   direct `uses` + skills from each `practices` competency
    #                + skills from team-inherited competencies
    var effectiveSkills: seq[string]
    for s1 in a.uses:
      if s1 notin effectiveSkills: effectiveSkills.add(s1)
    for compName in a.practices:
      if compName in competencyByName:
        for s2 in competencyByName[compName].skills:
          if s2 notin effectiveSkills: effectiveSkills.add(s2)
      else:
        unknown.add("competency:" & compName)
    if a.name in teamCompsForAgent:
      for compName in teamCompsForAgent[a.name]:
        if compName in competencyByName:
          for s3 in competencyByName[compName].skills:
            if s3 notin effectiveSkills: effectiveSkills.add(s3)

    # Built-in tool names commonly confused with skills. If a user writes
    # `uses "jq"` or declares `jq` in a competency's `skills`, it's really
    # a tool request — silently grant the tool and skip the unknown warning.
    const builtinTools = ["jq", "git", "web", "shell", "cron", "find", "edit",
      "screenshot", "http_request", "image_info", "image_analyze", "browser_open",
      "playwright", "pushover", "lark", "delegate", "spawn", "subagent",
      "learn_skill", "persist", "clock", "provider_auth", "model_list",
      "forge", "remember", "invite", "update_contact", "query_graph",
      "read_file", "write_file", "list_dir", "reply"]

    for skillName in effectiveSkills:
      # Resolve from the first skillsDir that has it — later dirs override earlier.
      # With dirs passed as [lab, base], lab wins on collisions (customized shadows).
      var found = false
      for dir in skillsDirs:
        let skillDir = dir / skillName
        if dirExists(skillDir):
          let (st, sd, se) = parseSkillRequires(skillDir)
          for t in st: tools.add(t)
          for d in sd: deps.add(d)
          for e in se: envs.add(e)
          found = true
          break
      if not found:
        if skillName in builtinTools:
          # It's a built-in tool referenced as a skill — grant the tool directly.
          tools.add(skillName)
        else:
          unknown.add(skillName)

    # Dedup, subtract denies
    var uniq: seq[string]
    for t in tools:
      if t notin uniq and t notin a.deny: uniq.add(t)
    var uniqDeps: seq[string]
    for d in deps:
      if d notin uniqDeps: uniqDeps.add(d)
    var uniqEnvs: seq[string]
    for e in envs:
      if e notin uniqEnvs: uniqEnvs.add(e)

    # Persist to spec — effective skill list is the union AFTER filtering out
    # built-in tool names (which get granted as tools, not listed as skills).
    var resolvedSkills: seq[string]
    for sk in effectiveSkills:
      if sk notin builtinTools and sk notin resolvedSkills:
        resolvedSkills.add(sk)
    s.agents[i].resolvedTools = uniq
    s.agents[i].resolvedDeps = uniqDeps
    s.agents[i].resolvedEnvs = uniqEnvs
    s.agents[i].resolvedSkills = resolvedSkills

    # Show "N direct + M competency-inherited = K total skills"
    let directN = a.uses.len
    let compN = effectiveSkills.len - directN
    let compNote = if compN > 0: " + " & $compN & " via competencies" else: ""
    echo "  " & a.name & ": " & $directN & " skills" & compNote & ", " &
      $uniq.len & " tools, " & $uniqDeps.len & " deps"
    if unknown.len > 0:
      echo "    ! Unknown skills: " & unknown.join(", ")
    for env in uniqEnvs:
      if getEnv(env) == "":
        echo "    ! Env " & env & " not set (needed by skills)"

proc build*(s: var ClawSpec) =
  ## Main build entry point — creates the full service directory.
  if s.org.name == "":
    echo "Error: org name is required. Add: org \"MyCompany\": ..."
    quit(1)

  let serviceDir = getHomeDir() / ".nimclaw-" & s.org.name
  let workspace = serviceDir / "workspace"

  echo "Building service: " & s.org.name
  echo "  Target: " & serviceDir

  # 1. Create directory structure — three tiers, physically visible:
  #   foundation/         Tier 1  — auto-populated from the claw distribution (universal)
  #   workspace/skills/   Tier 2  — this company's curated opt-ins (ClawDSL declares these)
  #   workspace/offices/<a>/workstation/
  #                       Tier 3  — agent-authored at runtime
  # Top-level is config (BASE.*, .env, claw.lock) + runtime state (channels/,
  # logs/, support/). All CONTENT lives under foundation/ or workspace/.
  mkDir serviceDir
  mkDir workspace
  # Tier 1 "Foundation" — what you build on: universal skills from the claw
  # distribution. Mirror, not editable — to customize, copy into workspace/skills/.
  mkDir serviceDir / "foundation"
  mkDir serviceDir / "foundation" / "skills"
  mkDir serviceDir / "foundation" / "mcp"
  mkDir serviceDir / "foundation" / "script"
  # Tier 2 "Company Lab" — shared across all agents in the company
  # Tier 2 company-shared skills. Each skill is a self-contained package:
  # workspace/skills/<name>/{SKILL.md, src/, scripts/, bin/}
  mkDir workspace / "skills"
  # Operational state (not workspace content):
  #   channels/ — per-channel session state (auth tokens, webhook queues)
  #   logs/     — gateway and tool invocation logs
  #   support/  — runtime state for external tools wrapped by claw (e.g. playwright
  #               browser profiles). Analogous to macOS ~/Library/Application Support/.
  mkDir serviceDir / "channels"
  mkDir serviceDir / "logs"
  mkDir serviceDir / "support"

  # 1b. Populate Tier 1 foundation/ from the claw distribution.
  # Always refreshed on every `claw create` — users should never edit
  # foundation/ directly; to customize, copy a foundation skill into
  # workspace/skills/ and edit there.
  populateFoundation(serviceDir / "foundation")
  for a in s.agents:
    let office = workspace / "offices" / a.name.toLowerAscii
    mkDir office
    mkDir office / "mail"
    # Three time-axes under every office: memory (past, JSONL store),
    # sessions (present, per-chat history), notes (future, free-form).
    mkDir office / "memory"
    mkDir office / "sessions"
    mkDir office / "notes"
    # Scaffold workstation/ for agents allowed to author skills & forge tools
    if a.workstation:
      mkDir office / "workstation"
      mkDir office / "workstation" / "skills"
      mkDir office / "workstation" / "mcp"
      mkDir office / "workstation" / "script"

  # 2. Scaffold workspace
  scaffoldWorkspace(s, workspace)

  # 3. Install profiles
  for a in s.agents:
    if a.profile != "":
      installProfile(a.profile, workspace / "offices" / a.name.toLowerAscii)

  # 4. Install Tier 2 skills into the company lab.
  #    Tier 1 (foundation) skills declared in ClawDSL are resolved against
  #    foundation/ and skipped for copy — they already live there.
  let foundationNames = foundationSkillNames()
  for sk in s.skills:
    installSkill(sk, workspace / "skills", foundationNames)

  # 4b. Resolve per-agent capabilities. Search lab first (customizations),
  #     then foundation (distribution default) — lab shadows foundation on collision.
  resolveAgentCapabilities(s, @[
    workspace / "skills",
    serviceDir / "foundation" / "skills"
  ])

  # 5. Generate BASE.json
  let baseJson = buildBaseJson(s, workspace)
  writeFile(serviceDir / "BASE.json", pretty(baseJson, 2))
  echo "  + Generated BASE.json"

  # 6. Generate .env template
  writeEnvTemplate(s, serviceDir / ".env")
  echo "  + Generated .env"

  # 7. Write lockfile
  writeLockfile(s, serviceDir)
  echo "  + Generated claw.lock"

  echo ""
  echo s.org.name & " ready at " & serviceDir
  echo "  " & $s.providers.len & " providers, " & $s.agents.len & " agents, " & $s.channels.len & " channels"
  echo "  Run: claw gateway --service " & s.org.name

proc build*(s: var ClawSpec, sourcePath: string) =
  ## Build and copy the source .nims to <serviceDir>/BASE.nims so users have
  ## a canonical editable config co-located with BASE.json and .env.
  build(s)
  if sourcePath.len == 0: return
  let serviceDir = getHomeDir() / (".nimclaw-" & s.org.name)
  let dest = serviceDir / "BASE.nims"
  try:
    if sourcePath != dest:
      cpFile sourcePath, dest
      echo "  + Source copied to " & dest & " — edit there and re-run 'claw create'"
  except Exception as e:
    echo "  ! Could not copy source to " & dest & ": " & e.msg

proc build*() =
  ## Convenience: build from global spec.
  build(spec)

proc build*(sourcePath: string) =
  ## Convenience: build from global spec and copy source.
  ## Usage inside a .nims file: `build(currentSourcePath())`
  build(spec, sourcePath)
