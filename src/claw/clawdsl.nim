## clawdsl — NimScript DSL for declarative NimClaw service creation.
## Import this in a .nims file and run with `nim e MyCompany.nims`.
## Generates ~/.nimclaw-<OrgName>/ with BASE.json, workspace, skills, etc.

import std/[json, os, strutils, tables, options, sets, sequtils]
import tools/registry/manifest
import providers/registry as provider_registry

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
    model*: string             ## DEPRECATED. Phase 2 replaces this with
                               ## `models` (an ordered list). For now,
                               ## the post-parse hook copies `model` →
                               ## `models[0]` if `models` is empty so
                               ## existing BASE.nims files still work.
    provider*: string          ## DEPRECATED. Phase 2 derives the
                               ## provider for each model from the
                               ## company providers list (which provider
                               ## serves this model name?). The agent
                               ## itself doesn't care about providers.
    models*: seq[string]       ## Ordered list of preferred models.
                               ## models[0] is the agent's primary;
                               ## subsequent entries are fallbacks in
                               ## order. Empty → agent inherits the
                               ## company default chain (every provider
                               ## in declaration order with its own
                               ## defaultModel).
    role*: string          ## RBAC role: Admin, Member, Employee
    identity*: string      ## Staff, Agent, User
    jobTitle*: string
    profile*: string       ## Profile name from AGENT_PROFILES
    soul*: string          ## Authored values/temperament — overrides the
                           ## profile preset's soul when non-empty.
    maxDepth*: int
    temperature*: float
    thinking*: Option[bool]   ## DeepSeek-V4 thinking-mode override.
                              ## none → model default; some(false) →
                              ## disable thinking for fast cheap turns;
                              ## some(true) → force on (rarely needed,
                              ## v4 default is on).
    reportsTo*: seq[ClawRelation]
    serves*: seq[ClawRelation]
    identifiers*: seq[tuple[channel, id: string]]
    uses*: seq[string]     ## Skill names this agent has access to (direct)
    practices*: seq[string] ## Competency names — pulls in their skills + handbooks
    deny*: seq[string]     ## Tool names to deny (overrides skill-granted tools)
    workstation*: bool     ## Allow workstation experimentation (author skills & forge tools)
    external*: bool        ## true = identity exists in graph but the gateway
                           ## doesn't run the LLM loop. Cognition is provided
                           ## by an external runtime (another Claude Code
                           ## instance, Cursor, Aider, federated peer agent,
                           ## etc.) which puppeteers via `claw agent send
                           ## --from <name>` and reads the office's mail/
                           ## directly. Identity, mailbox, memory, and
                           ## relationships persist whether the flag is on
                           ## or off — flip back to internal when ready
                           ## for autonomous reasoning to resume.
    # Resolved at build time from skills' SKILL.md frontmatter
    resolvedTools*: seq[string]
    resolvedDeps*: seq[string]
    resolvedEnvs*: seq[string]
    resolvedSkills*: seq[string]  ## uses ∪ practices.skills ∪ team.competencies.skills
    heartbeatSeconds*: int        ## 0 = no heartbeat (default). Positive
                                  ## = the cadence in seconds at which a
                                  ## stateless tick fires for this agent.
                                  ## See `services/heartbeat_orchestrator.nim`
                                  ## for skip-if-busy + bloat policies the
                                  ## tick goes through.

  ClawPerson* = object
    name*: string
    permission*: string    ## SuperAdmin, Admin, Member
    identifiers*: seq[tuple[channel, id: string]]
    skills*: seq[string]   ## allowlist in `[user@]skill[/res,...]` form —
                            ## tool dispatcher checks calls against this.

  ClawOrg* = object
    name*: string           ## Internal codename. Drives NIMCLAW_DIR,
                            ## BASE.json key, git repo — do not change
                            ## lightly. Leaks only to operators.
    brand*: string          ## Customer-facing service name (e.g. "SolarIQ").
                            ## Shown in welcome messages and any other
                            ## external-facing surface. Defaults to `name`
                            ## when the DSL doesn't set it.
    support*: string        ## Name of a declared Person to show on
                            ## blocked/grace messages as "contact for
                            ## help". Resolved lazily at render time so
                            ## identifiers (Feishu/email/etc.) can change
                            ## without rewriting every stamped entity.
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

  ClawMode* = object
    ## A focus mode — temporary specialisation an agent can enter for
    ## a single subagent task. Distinct from `agent` (separate identity)
    ## and from `competency` (persistent role profile).
    ##
    ## A mode is "the same agent, different hat": Lexi-as-Plan still IS
    ## Lexi (her soul, role, reportsTo all preserved), but the spawn
    ## that runs in Plan mode gets a tool subset + prompt addendum
    ## that constrains her to the planning shape.
    ##
    ## Example:
    ##   mode "Plan":
    ##     description "Software architect — write step-by-step plans, no implementation."
    ##     uses "read_file", "find", "grep"
    ##     model "deepseek-v4-pro"
    ##     promptAddendum """
    ##       In this mode, your job is to PLAN, not implement. Output
    ##       step-by-step plans with explicit ordering and trade-offs.
    ##     """
    name*: string             ## e.g. "Plan", "Explore"
    description*: string      ## one-liner the LLM sees when picking a mode
    uses*: seq[string]        ## tool whitelist for this mode (intersected with parent's grants)
    deny*: seq[string]        ## additional denylist on top of `uses`
    model*: string            ## optional model override (same provider as parent's model)
    promptAddendum*: string   ## prepended to the parent agent's system prompt

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

  ClawUpdates* = object
    ## Phase 9 — auto-update from upstream claw repo. Default off (opt-in).
    enabled*: bool                ## false = no scheduled checks; manual `claw co upgrade` still works
    repo*: string                 ## upstream URL (informational; actual remote = git origin)
    branch*: string               ## "main" / "stable" / "release-1.x"; default "main"
    checkIntervalHours*: int      ## poll cadence; default 4 (i.e. check 6× per day)
    autoApply*: bool              ## true = pull+build+restart automatically; false = mail operator
    notifyAgent*: string          ## which agent gets notified (default first internal agent)

  ClawSpec* = object
    org*: ClawOrg
    persons*: seq[ClawPerson]
    providers*: seq[ClawProvider]
    agents*: seq[ClawAgent]
    channels*: seq[ClawChannel]
    skills*: seq[ClawSkill]
    memoranda*: seq[ClawMemorandum]
    competencies*: seq[ClawCompetency]
    focus_modes*: seq[ClawMode]
    teams*: seq[ClawTeam]
    labs*: seq[ClawLab]
    portal*: ClawPortal
    defaults*: ClawDefaults
    security*: ClawSecurity
    gateway*: ClawGateway
    tools*: ClawTools
    trust*: ClawTrust
    updates*: ClawUpdates           ## Phase 9 — auto-update config (opt-in; default: enabled=false)
    refusal*: Table[string, string] ## Per-language override for the
      ## "I don't recognize you on this channel — send your invite code"
      ## message. Keys are BCP-47 language tags ("zh", "en", "ja", "ko").
      ## Authored in BASE.nims via the `refusal:` block. Versioned with
      ## the company; survives migrations / rebrands. Empty when not
      ## declared — the framework's defaults (gateway.nim::refusalByLang)
      ## are used as the fallback. One authoring location, one fallback.

# ── Global State ──────────────────────────────────────────────────

var spec* {.global.} = ClawSpec(
  defaults: ClawDefaults(maxTokens: 4096, temperature: 0.7, maxToolIterations: 20),
  gateway: ClawGateway(host: "0.0.0.0", port: 18790),
  tools: ClawTools(webSearchMaxResults: 5, webSearchProvider: "auto"),
  updates: ClawUpdates(
    enabled: false,            # opt-in; default off
    branch: "main",
    checkIntervalHours: 4,
    autoApply: false,          # safer default: notify-only until operator opts in
  ),
  refusal: initTable[string, string](),
)

# ── DSL: Organization ─────────────────────────────────────────────

template org*(orgName: string, body: untyped) =
  spec.org.name = orgName
  block:
    template description(d: string) {.used.} =
      spec.org.description = d
    template brand(b: string) {.used.} =
      spec.org.brand = b
    template support(name: string) {.used.} =
      spec.org.support = name
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
      ## DEPRECATED — Phase 4 of provider-config refactor (option C).
      ## Capability decisions (which model an agent uses) belong to the
      ## agent layer. The provider's `defaultModel` was previously
      ## consulted to synthesise an implicit chain for agents that
      ## hadn't declared `models`; that pathway is gone (every agent
      ## now MUST declare `models`). Treated as a hint that this model
      ## should appear at position 0 of `p.models`; if it's not
      ## already in the list, it gets prepended. Drop the line from
      ## BASE.nims via `claw co migrate`.
      if m notin p.models: p.models.insert(m, 0)
    template models(ms: varargs[string]) {.used.} =
      # Dedupe on insert. Some legacy BASE.nims declare the same model
      # via both `defaultModel "X"` (which our deprecated template
      # prepends to p.models) AND `models "X", "Y"`. Without this
      # check, the X entry shows up twice in the resolved list and
      # in /model output.
      for m in ms:
        if m notin p.models: p.models.add(m)
    body
    spec.providers.add(p)

# ── DSL: Agent ────────────────────────────────────────────────────

template agent*(agentName: string, body: untyped) =
  block:
    var a = ClawAgent(name: agentName, maxDepth: 10, identity: "Agent", role: "Member")
    template model(m: string) {.used.} =
      ## DEPRECATED — kept for back-compat. Prefer `models "X"`.
      a.model = m
    template provider(prov: string) {.used.} =
      ## DEPRECATED — kept for back-compat. Provider is now derived
      ## from the company providers list (which provider serves the
      ## agent's chosen model). Phase 2 of provider-config-refactor.
      a.provider = prov
    template models(ms: varargs[string]) {.used.} =
      ## Phase 2 syntax: `models "deepseek-v4-flash", "kimi-k2.5"`.
      ## First model = primary; rest = fallbacks (in order). The
      ## framework looks up the serving provider for each model from
      ## the company providers list at chain-build time.
      for m in ms: a.models.add(m)
    template role(r: string) {.used.} =
      a.role = r
    template identity(id: string) {.used.} =
      a.identity = id
    template jobTitle(jt: string) {.used.} =
      a.jobTitle = jt
    template profile(prof: string) {.used.} =
      a.profile = prof
    template soul(s: string) {.used.} =
      # Dedent common leading whitespace so `soul """ ... """` blocks
      # authored inside an indented DSL keep clean multi-line text
      # instead of carrying the block's indent into the graph.
      a.soul = s.unindent().strip()
    template maxDepth(d: int) {.used.} =
      a.maxDepth = d
    template temperature(t: float) {.used.} =
      a.temperature = t
    template thinking(b: bool) {.used.} =
      a.thinking = some(b)
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
    template external(enabled: bool) {.used.} =
      ## true = no LLM loop in the gateway; identity remains in
      ## the cortex graph for messaging/memory/peer-relationships.
      ## See ClawAgent.external docs.
      a.external = enabled
    template heartbeat(seconds: int) {.used.} =
      ## Opt this agent into autonomous heartbeat ticks at the given
      ## cadence. The runtime fires a stateless one-shot turn (no
      ## session JSONL accumulation) whose prompt comes from
      ## `<office>/memory/HEARTBEAT.md` plus a built-in mailbox scan.
      ## Skipped automatically if the agent has live tasks at tick
      ## time. 0 (default) = no heartbeat.
      a.heartbeatSeconds = seconds
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
    template identifier(sub, agentName: string) {.used.} =
      ## nmobile identifier → agent. `<sub>.<pubkey>` routes inbound to
      ## the named agent. Same seed backs many identifiers (phone-line
      ## + extension model).
      ch.fields.add((key: "identifier", val: sub))
      ch.fields.add((key: "identifier_agent:" & sub, val: agentName))
    template seed(envRef: string) {.used.} =
      ## Bind the NKN seed to an env-var reference, e.g. `seed
      ## "${NKN_WALLET_SEED}"`. The raw seed itself lives in .env.
      ch.fields.add((key: "seed", val: envRef))
    template numSubClients(n: int) {.used.} =
      ch.fields.add((key: "numSubClients", val: $n))
    template originalClient(b: bool) {.used.} =
      ch.fields.add((key: "originalClient", val: $b))
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

# ── DSL: Updates (Phase 9 auto-update) ────────────────────────────

template updates*(body: untyped) =
  ## Opt-in auto-update from upstream claw repo. When `enabled true`,
  ## the gateway registers a scheduled job that polls origin/<branch>
  ## every `check_interval_hours` and either:
  ##   - mails the notify_agent (auto_apply false; default)
  ##   - pulls + builds + restarts (auto_apply true)
  ##
  ## Example:
  ##
  ##   updates:
  ##     enabled true
  ##     branch "main"
  ##     check_interval_hours 4
  ##     auto_apply false
  ##     notify_agent "Lexi"
  ##
  ## Manual `claw co upgrade` works regardless of this block — the
  ## block only controls the scheduled poll.
  block:
    template enabled(b: bool) {.used.} =
      spec.updates.enabled = b
    template repo(url: string) {.used.} =
      spec.updates.repo = url
    template branch(b: string) {.used.} =
      spec.updates.branch = b
    template check_interval_hours(h: int) {.used.} =
      spec.updates.checkIntervalHours = h
    template auto_apply(b: bool) {.used.} =
      spec.updates.autoApply = b
    template notify_agent(name: string) {.used.} =
      spec.updates.notifyAgent = name
    body

# ── DSL: Refusal messages ────────────────────────────────────────
#
# Per-language override for the "I don't recognize you on this
# channel — send your invite code" message that strangers see at
# the unrecognized-user gate. Versioned with the company so the
# wording survives migrations + can be shared across deployments.
#
# Useful during migrations / rebrands to give existing customers
# context for why they're being asked to re-authenticate. Companies
# that don't customize the message can omit this block entirely —
# framework defaults (gateway.nim::refusalByLang) are used.
#
# Example BASE.nims block:
#
#   refusal:
#     zh "抱歉，我们的系统正在进行升级迁移..."
#     en "Our system is currently undergoing a migration upgrade..."
#     ja "申し訳ありません。現在システムの移行..."
#     ko "죄송합니다. 現在シ系テム..."
#
# Free-form `lang "<bcp47>", "<text>"` form supports other languages.

template refusal*(body: untyped) =
  block:
    template lang(code, text: string) {.used.} =
      spec.refusal[code.toLowerAscii] = text
    template zh(text: string) {.used.} =
      spec.refusal["zh"] = text
    template en(text: string) {.used.} =
      spec.refusal["en"] = text
    template ja(text: string) {.used.} =
      spec.refusal["ja"] = text
    template ko(text: string) {.used.} =
      spec.refusal["ko"] = text
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

template focus_mode*(nm: string, body: untyped) =
  ## Declare a focus mode an agent can enter for a single subagent
  ## task. Adds a tool subset + prompt addendum on top of the calling
  ## agent's identity — same agent, different hat.
  ##
  ## The keyword is `focus_mode` (not bare `mode`) because NimScript
  ## already exports a global `mode*: ScriptMode` which shadows a
  ## same-named template at the BASE.nims call site. `focus_mode`
  ## clears the collision while keeping the canonical word in the
  ## DSL, the JSON config, the runtime, and the LLM tool parameter
  ## — one term everywhere.
  ##
  ## Example:
  ##   focus_mode "Plan":
  ##     summary "Software architect — write step-by-step plans, no implementation."
  ##     uses "read_file", "find", "grep"
  ##     model "deepseek-v4-pro"
  ##     promptAddendum """
  ##       In this mode, you PLAN. Output a step-by-step plan with
  ##       explicit ordering and trade-offs. You do NOT modify files.
  ##     """
  block:
    var m = ClawMode(name: nm)
    # Use `summary` (not `description`) because nimscript exports a
    # global `description*: string` for nimble package metadata that
    # we can't reliably shadow at the call site.
    template summary(d: string) {.used.} = m.description = d
    template uses(uss: varargs[string]) {.used.} =
      for x in uss: m.uses.add(x)
    template deny(ds: varargs[string]) {.used.} =
      for x in ds: m.deny.add(x)
    template model(s: string) {.used.} = m.model = s
    template promptAddendum(s: string) {.used.} = m.promptAddendum = s
    template prompt(s: string) {.used.} = m.promptAddendum = s
    body
    spec.focus_modes.add(m)

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

## Provider template defaults — sourced from the framework's res/providers.json
## via `providers/registry`. SSoT: a provider's metadata (apiBase, envKey for
## auto-filling apiKey, defaultModel) lives in ONE place and the DSL looks it
## up by normalized name. Operators authoring BASE.nims only have to repeat
## what they want to OVERRIDE.
##
## Name normalization: providers.json uses display names like "OpenCode Go"
## while BASE.nims tends to use slug form like `provider "opencode-go":`.
## We lowercase + space-to-hyphen on both sides for the match.

proc normalizeProviderKey(name: string): string =
  name.toLowerAscii.replace(" ", "-")

proc getProviderDefault(name: string): provider_registry.ProviderDef =
  ## Look up provider metadata from the framework's res/providers.json (cached
  ## by `provider_registry.builtinProviders`). Returns an empty ProviderDef
  ## (all fields blank) if the name doesn't match any known provider — caller
  ## must check `.apiBase.len > 0` etc. before using a field.
  let key = normalizeProviderKey(name)
  for p in provider_registry.builtinProviders():
    if normalizeProviderKey(p.name) == key: return p
  return provider_registry.ProviderDef()

# ── BASE.json Builder ─────────────────────────────────────────────

# ── Persistent nc:id allocator ────────────────────────────────────
#
# nc:ids are stable identities, like database primary keys: assigned
# once per entity, never reassigned, never recycled. Without this
# discipline, adding an agent in BASE.nims shifts every existing
# entity's nc:id by one, which orphans their session/memory/workstation
# files (which are stored at filesystem paths keyed by nc:id).
#
# The persistent record IS the existing BASE.json's @graph — that's
# the prior-state snapshot from the last build. At the start of a
# rebuild we load it as a name → nc:id table; subsequent calls to
# `assignNcId(name)` reuse the prior assignment if known, otherwise
# allocate the next unused integer.
#
# nc:1 is reserved for the org and is never reassigned to anyone else.
var
  gPriorIds: Table[string, int]    ## name (lowerAscii) → prior nc:id, from existing BASE.json
  gAssignedIds: Table[string, int] ## allocations made during this build
  gUsedIds: HashSet[int]            ## ids known to be in use during this build

proc resetEntityIdAllocator() =
  gPriorIds = initTable[string, int]()
  gAssignedIds = initTable[string, int]()
  gUsedIds = initHashSet[int]()
  gUsedIds.incl(1)  # nc:1 reserved for the org

proc loadPriorEntityIds*(serviceDir: string) =
  ## Read the existing BASE.json @graph (if any) and use it as the
  ## stable baseline for this build. First-time builds (no prior file)
  ## fall through to plain allocation order.
  resetEntityIdAllocator()
  let basePath = serviceDir / "BASE.json"
  if not fileExists(basePath): return
  var j: JsonNode
  try:
    j = parseJson(readFile(basePath))
  except CatchableError:
    return  # malformed prior file — start fresh, don't crash
  if not j.hasKey("@graph") or j["@graph"].kind != JArray: return
  for ent in j["@graph"]:
    if ent.kind != JObject: continue
    let id = ent{"id"}.getStr()
    let name = ent{"name"}.getStr()
    if id.len == 0 or name.len == 0: continue
    if not id.startsWith("nc:"): continue
    var n: int
    try:
      n = parseInt(id["nc:".len .. ^1])
    except CatchableError:
      continue
    gPriorIds[name.toLowerAscii] = n
    gUsedIds.incl(n)

proc assignNcId(name: string): int =
  ## Returns the nc:id integer for `name`, preserving prior assignments.
  ## Always returns the same int for the same name within one build.
  ## New entities (no prior assignment, not yet seen this build) get
  ## the lowest unused integer ≥ 2 — `nc:1` stays reserved for the org.
  let key = name.toLowerAscii
  if key in gAssignedIds: return gAssignedIds[key]
  if key in gPriorIds:
    let id = gPriorIds[key]
    gAssignedIds[key] = id
    return id
  var id = 2
  while id in gUsedIds: inc id
  gAssignedIds[key] = id
  gUsedIds.incl(id)
  return id

proc resolveEntityId(spec: ClawSpec, name: string): string =
  ## Resolve a person/agent name to its nc:ID. Stable across rebuilds:
  ## prior assignments live in BASE.json's @graph (loaded by
  ## `loadPriorEntityIds`); this proc consults that record before
  ## allocating new IDs. Adding new entities never shifts existing ones.
  for a in spec.agents:
    if a.name.toLowerAscii == name.toLowerAscii:
      return "nc:" & $assignNcId(a.name)
  for p in spec.persons:
    if p.name.toLowerAscii == name.toLowerAscii:
      return "nc:" & $assignNcId(p.name)
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

  # Agents — nc:id preserved across rebuilds via `assignNcId`, which
  # consults the prior BASE.json @graph loaded by `loadPriorEntityIds`.
  for a in spec.agents:
    var entity = %*{
      "id": "nc:" & $assignNcId(a.name),
      "kind": "AI",
      "name": a.name,
    }
    # Soul resolution: authored `soul "..."` on the agent wins, then
    # the profile preset's default, then empty. Stored name-free — the
    # graph's `name` field plus the IDENTITY block at prompt-build time
    # are the single source of identity; SOUL is just values text.
    if a.soul != "":
      entity["soul"] = %a.soul
    elif a.profile != "" and hasProfile(a.profile):
      entity["soul"] = %getProfile(a.profile).soul
    # jobTitle fallback from the preset applies regardless of soul source.
    if a.jobTitle == "" and a.profile != "" and hasProfile(a.profile):
      entity["jobTitle"] = %getProfile(a.profile).jobTitle
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
    # Channel identifiers (feishu:<app_id>, nmobile, etc.) are stamped
    # by the post-entity pass below based on DSL channel-block routing
    # targets. Inline `identifier "..."` lines under `agent "...":` still
    # seed the entity directly.
    if a.identifiers.len > 0:
      entity["identifiers"] = buildIdentifiers(a.identifiers)
    else:
      entity["identifiers"] = newJObject()
    # Membership — always member of org
    entity["memberOf"] = %*["nc:1"]
    # Relationships
    if a.reportsTo.len > 0:
      entity["reportsTo"] = buildRelations(spec, a.reportsTo)
    if a.serves.len > 0:
      entity["serves"] = buildRelations(spec, a.serves)
    result.add(entity)

  # Persons — same stable allocation
  for p in spec.persons:
    var entity = %*{
      "id": "nc:" & $assignNcId(p.name),
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

  # Organization (nc:1) — always reserved, never reassigned
  var orgEntity = %*{
    "id": "nc:1",
    "kind": "Corporate",
    "name": if spec.org.name != "": spec.org.name else: "Workspace",
  }
  if spec.org.description != "":
    orgEntity["description"] = %spec.org.description
  if spec.org.brand != "" or spec.org.support != "":
    # Brand + support go into custom (free-form extension point on
    # WorldEntity) so we don't have to grow the entity schema just for
    # display labels. Welcome + gate messages both read these back.
    var c = newJObject()
    if spec.org.brand != "":   c["brand"] = %spec.org.brand
    if spec.org.support != "": c["support"] = %spec.org.support
    orgEntity["custom"] = c
  orgEntity["mood"] = %*{"valence": 0.0, "arousal": 0.1, "archetype": "Assistant"}
  if spec.org.identifiers.len > 0:
    orgEntity["identifiers"] = buildIdentifiers(spec.org.identifiers)
  result.add(orgEntity)

  # ── Channel identifier stamping pass ──────────────────────────────
  #
  # For each `channel "X":` block's routing declarations (`app "id",
  # "target"` or `identifier "sub", "target"`), stamp the target entity
  # with `identifiers["<channel-key>"] = <address>`. The "target" is
  # either a declared agent name or the org name (company-owned apps /
  # main-line identifiers).
  #
  # For NKN, we spawn a short-lived nkn-cli to derive
  # `<sub>.<pubkey>` / bare `<pubkey>` from `NKN_WALLET_SEED`. Skipped
  # silently when no seed is available — the operator re-runs
  # `co update` after their first `claw channel auth nmobile`.

  proc stampChannelIdent(entities: JsonNode, targetName, key, value: string) =
    if value.len == 0: return
    for i in 0 ..< entities.len:
      let ent = entities[i]
      if ent.kind != JObject: continue
      if ent{"name"}.getStr() != targetName: continue
      if not ent.hasKey("identifiers") or ent["identifiers"].kind != JObject:
        ent["identifiers"] = newJObject()
      ent["identifiers"][key] = %value
      return

  for ch in spec.channels:
    let kind = ch.kind.toLowerAscii
    case kind:
    of "feishu":
      # Collect (app_id, target) pairs. First pass: apps. Second pass:
      # routing targets from `app_agent:<id>` field key.
      var targets = initTable[string, string]()
      var appIds: seq[string] = @[]
      for f in ch.fields:
        if f.key == "app":
          appIds.add(f.val)
          if not targets.hasKey(f.val): targets[f.val] = ""
        elif f.key.startsWith("app_agent:"):
          let id = f.key["app_agent:".len .. ^1]
          targets[id] = f.val
      for appId in appIds:
        let target = targets.getOrDefault(appId, "")
        if target.len == 0: continue
        stampChannelIdent(result, target, "feishu:" & appId, appId)
    of "nmobile":
      # nmobile stamping needs to spawn `nkn-cli` to derive full
      # `<sub>.<pubkey>` addresses. We can't do subprocess work inside
      # `buildGraph` because it runs under NimScript via `nim e`, which
      # lacks osproc. `cli_admin.postProcessNkNStamping` runs a second
      # pass in the Nim-compiled CLI path after BASE.json is written.
      discard
    else: discard  # future channels plug in here

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
    "nmobile": {"enabled": false, "stream_intermediary": false, "seed": "", "identifiers": [], "allow_from": []},
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
      of "identifier":
        # nmobile identifiers array. `identifier_agent:<sub>` fields
        # resolve in the post-loop pass, same pattern as Feishu apps.
        if not result[k].hasKey("identifiers") or result[k]["identifiers"].kind != JArray:
          result[k]["identifiers"] = newJArray()
        result[k]["identifiers"].add(%*{"enabled": true, "identifier": f.val, "agent": ""})
      of "seed":
        # Preserve the env-ref verbatim. `loadConfig`'s expandEnv pass
        # substitutes ${NKN_WALLET_SEED} at runtime.
        result[k]["seed"] = %f.val
      of "numSubClients": result[k]["num_sub_clients"] = %parseInt(f.val)
      of "originalClient": result[k]["original_client"] = %parseBool(f.val)
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
        elif f.key.startsWith("identifier_agent:"):
          let targetSub = f.key["identifier_agent:".len .. ^1]
          if result[k].hasKey("identifiers") and result[k]["identifiers"].kind == JArray:
            for i in 0 ..< result[k]["identifiers"].len:
              if result[k]["identifiers"][i]{"identifier"}.getStr() == targetSub:
                result[k]["identifiers"][i]["agent"] = %f.val
                break
        else:
          result[k][f.key] = %f.val
    if allowFrom.len > 0:
      result[k]["allow_from"] = %allowFrom

proc buildConfig(spec: ClawSpec, workspace: string): JsonNode =
  # Post-Phase-4: there's no global default_provider/default_model.
  # Each agent declares their own `models` list (or the deprecated
  # singular `model`); the company-level providers list is just an
  # ordered registry. The values below are still computed because
  # they're used as a per-agent fallback when an agent declared
  # neither `models` nor `model` — the agent inherits providers[0]'s
  # primary in that case.
  let defProvider = if spec.providers.len > 0: spec.providers[0].name else: ""
  let defModel =
    if spec.providers.len > 0 and spec.providers[0].models.len > 0:
      spec.providers[0].models[0]
    elif spec.providers.len > 0:
      spec.providers[0].defaultModel
    else:
      ""

  # Named agents config
  var named = newJArray()
  for a in spec.agents:
    # Phase 2 of provider-config refactor:
    #   - `models` is emitted only when the agent EXPLICITLY declared a
    #     list with `models "X", "Y"`. An empty `models` array means
    #     "agent inherits the company default chain" — semantically
    #     different from "agent has a single-entry chain with no
    #     fallback."
    #   - The deprecated singular `model "X"` is preserved as the agent's
    #     preferred primary model (overrides chain entry 0's model), but
    #     does NOT collapse the company chain into a single entry. This
    #     keeps existing BASE.nims files — which mostly use just
    #     `model "X"` without a fallback list — getting the company
    #     fallback safety net automatically.
    let primaryModel =
      if a.models.len > 0: a.models[0]
      elif a.model != "": a.model
      else: defModel
    var entry = %*{
      "name": a.name,
      "provider": if a.provider != "": a.provider else: defProvider,
      "model": primaryModel,
      "models": a.models,  # exactly what the operator declared; empty = inherit
      "entity": "AI",
      "identity": if a.identity != "": a.identity else: "Agent",
      "max_depth": a.maxDepth,
    }
    if a.role != "":
      entry["role"] = %a.role
    # Surface jobTitle to runtime config so tools like `collaborate route`
    # can score peer fitness by job title match (e.g. "reply to customer in
    # Chinese" → Frontdesk/"Customer Support" wins). Without this, the
    # only role signal at runtime is the trust tier (Admin/Staff/Member),
    # which is too coarse to distinguish peers.
    if a.jobTitle != "":
      entry["job_title"] = %a.jobTitle
    # Effective skills: uses ∪ practices.skills ∪ team.competencies.skills,
    # with framework tool names filtered out. Fallback to raw `uses` when
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
    if a.external:
      entry["external"] = %true
    if a.thinking.isSome:
      entry["thinking"] = %a.thinking.get
    if a.temperature != 0.0:
      entry["temperature"] = %a.temperature
    if a.heartbeatSeconds > 0:
      entry["heartbeat_seconds"] = %a.heartbeatSeconds
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
      # SSoT: derive the floor from manifest. Every tool with
      # `externalAllowed = true` in registry/manifest.nim becomes
      # part of the Guest grant. Edit the manifest, not this list.
      grant: manifest.externalAllowedToolNames(),
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
    "default_temperature": spec.defaults.temperature,
    "agents": {
      "defaults": {
        "workspace": workspace,
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
    "updates": {
      "enabled": spec.updates.enabled,
      "repo": spec.updates.repo,
      "branch": spec.updates.branch,
      "check_interval_hours": spec.updates.checkIntervalHours,
      "auto_apply": spec.updates.autoApply,
      "notify_agent": spec.updates.notifyAgent,
    },
    "refusal": (proc(): JsonNode =
      result = newJObject()
      for k, v in spec.refusal.pairs: result[k] = %v
    )(),
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
    "focus_modes": (proc(): JsonNode =
      result = newJArray()
      for m in spec.focus_modes:
        result.add(%*{
          "name": m.name,
          "description": m.description,
          "uses": m.uses,
          "deny": m.deny,
          "model": m.model,
          "promptAddendum": m.promptAddendum,
        }))(),
  }

proc buildProviders(spec: ClawSpec): JsonNode =
  ## Phase 4 of provider-config refactor (option C): the provider's
  ## `defaultModel` field is no longer emitted. The provider's
  ## `models[0]` IS its canonical model — capability decisions sit in
  ## the agent layer, providers just declare what they serve.
  ##
  ## Back-compat: if a provider was declared with only `defaultModel
  ## "X"` and no `models` list, the DSL's deprecated `defaultModel`
  ## template now prepends X into `p.models`, so this writer doesn't
  ## need to special-case the empty-models case.
  result = newJObject()
  for p in spec.providers:
    let d = getProviderDefault(p.name)
    let key = normalizeProviderKey(p.name)
    # Fill apiBase from registry default if omitted
    var apiBase = if p.apiBase.len > 0: p.apiBase else: d.apiBase
    # Fill apiKey from the registry-declared envKey if omitted. Lets
    # operators write a bare `provider "opencode-go":` block (no body,
    # or just a `models` line) and have the framework auto-resolve
    # `apiKey = ${OPENCODE_GO_API_KEY}` from providers.json's envKey
    # field. ${VAR} expansion happens at gateway boot via loadDotEnv.
    var apiKey = if p.apiKey.len > 0: p.apiKey
                 elif d.envKey.len > 0: "${" & d.envKey & "}"
                 else: ""
    # If models is empty AND the registry has a defaultModel, seed it
    # so the chain build has something to work with (this rescues
    # provider blocks that declared neither `models` nor `defaultModel`
    # — relying entirely on the registry).
    var modelsList = p.models
    if modelsList.len == 0 and d.defaultModel != "":
      modelsList.add(d.defaultModel)
    var models = newJArray()
    for m in modelsList: models.add(%m)
    result[key] = %*{
      "name": p.name.capitalizeAscii,
      "apiBase": apiBase,
      "apiKey": apiKey,
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

proc installAgentSoul(a: ClawAgent, officeDir: string) =
  ## Keep the agent's office SOUL.md in sync with the single source of
  ## truth (BASE.nims). If the agent declared `soul "..."`, that's what
  ## lands in SOUL.md; otherwise fall back to the profile preset.
  ## SOUL.md is a read-only artifact from the DSL's perspective — hand
  ## edits get overwritten on the next `co update`, matching how the
  ## rest of the office workspace is regenerated.
  let resolved =
    if a.soul != "": a.soul
    elif a.profile != "" and hasProfile(a.profile): getProfile(a.profile).soul
    else: ""
  if resolved == "": return
  let soulPath = officeDir / "SOUL.md"
  let current =
    if fileExists(soulPath): readFile(soulPath).strip()
    else: ""
  if current == resolved.strip(): return
  writeFile(soulPath, resolved)
  echo "  + SOUL.md synced from BASE.nims: " & soulPath

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
  # use `github:`/`claw:` schemes for anything beyond the foundation set.
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
  # a HANDBOOK.md (the inline content or sourced markdown). JSON is
  # MERGED with any existing file's content rather than overwritten,
  # so operator-authored fields (heartbeat[], custom keys) survive
  # `claw co update`. DSL-controlled fields (name/description/skills/
  # summary) always reflect the current DSL; everything else is
  # preserved. has_handbook is derived fresh from actual file
  # presence each call.
  var compCount = 0
  for c in spec.competencies:
    let cdir = workspace / "competencies" / c.name
    mkDir cdir
    let compPath = cdir / "COMPETENCY.json"

    # HANDBOOK.md (preserve user edits; only write on first scaffold).
    # Done before composing JSON so has_handbook reflects post-scaffold
    # truth rather than pre-scaffold absence.
    let handbook = cdir / "HANDBOOK.md"
    if not fileExists(handbook):
      let body = resolveContent(c.content, distRoot)
      if body.len > 0:
        writeFile(handbook, body)

    # Read existing JSON if present so we can preserve operator-
    # authored fields (heartbeat[], custom extensions). DSL-controlled
    # fields are always overwritten with current DSL values.
    # Use readFile+parseJson rather than parseFile because clawdsl
    # runs in the Nim-script compile-time context where fopen-based
    # APIs aren't available.
    var compJson: JsonNode
    if fileExists(compPath):
      try:
        compJson = parseJson(readFile(compPath))
        if compJson.kind != JObject:
          compJson = newJObject()
      except CatchableError:
        # File exists but isn't valid JSON — start fresh rather than
        # crash. Operator can recover the old content from git if needed.
        compJson = newJObject()
    else:
      compJson = newJObject()

    # DSL-controlled fields: always reflect current DSL state.
    compJson["name"] = %c.name
    compJson["description"] = %c.description
    compJson["skills"] = %c.skills
    compJson["summary"] = %c.summary
    # Derive has_handbook from actual file presence — self-corrects
    # whether the operator added/removed HANDBOOK.md by hand.
    compJson["has_handbook"] = %fileExists(handbook)

    writeFile(compPath, pretty(compJson, 2))
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
  # Feishu app secrets — one env var per declared app. The framework's
  # feishu channel reads these at boot to auto-init lark-cli without
  # requiring a separate `claw channel auth feishu` step. Convention:
  # FEISHU_APP_SECRET__<app_id>  (also matched against uppercase form
  # at lookup time). See src/claw/channels/feishu.nim::start.
  for ch in spec.channels:
    if ch.kind != "feishu": continue
    for f in ch.fields:
      if f.key == "app":
        addKey("FEISHU_APP_SECRET__" & f.val)

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

type
  ToolGrant* = object
    agent*: string
    tool*: string

proc loadToolGrants(serviceDir: string): tuple[grants, revokes: seq[ToolGrant]] =
  ## Read `<serviceDir>/tool_grants.json` if present. Per-agent grant/revoke
  ## overlay applied after per-skill tool resolution but before dedup. Lets
  ## operators add/remove specific tools per agent without editing BASE.nims.
  ## Format:
  ##   {"grants":  [{"agent": "Lexi", "tool": "exec",  "ts": ..., "by": "..."}],
  ##    "revokes": [{"agent": "Lexi", "tool": "shell", "ts": ..., "by": "..."}]}
  ## See `cli_tools.nim::runToolsGrant/runToolsRevoke` for the writers.
  let path = serviceDir / "tool_grants.json"
  if not fileExists(path): return
  try:
    let j = parseJson(readFile(path))
    if j.kind != JObject: return
    if j.hasKey("grants") and j["grants"].kind == JArray:
      for g in j["grants"]:
        if g.kind != JObject: continue
        let agent = g.getOrDefault("agent").getStr()
        let tool = g.getOrDefault("tool").getStr()
        if agent.len > 0 and tool.len > 0:
          result.grants.add(ToolGrant(agent: agent, tool: tool))
    if j.hasKey("revokes") and j["revokes"].kind == JArray:
      for r in j["revokes"]:
        if r.kind != JObject: continue
        let agent = r.getOrDefault("agent").getStr()
        let tool = r.getOrDefault("tool").getStr()
        if agent.len > 0 and tool.len > 0:
          result.revokes.add(ToolGrant(agent: agent, tool: tool))
  except CatchableError:
    discard

proc resolveAgentCapabilities*(s: var ClawSpec, skillsDirs: seq[string],
                                serviceDir: string = "") =
  ## Resolve each agent's full capability set from their `uses` skills.
  ## Searches skillsDirs in order — first match wins (lab overrides base).
  ## Reads SKILL.md frontmatter to aggregate tools, deps, envs.
  ## Writes resolved lists back into agent.resolvedTools/Deps/Envs.
  echo ""
  echo "Resolving agent capabilities..."

  # Default toolset every agent gets.
  # provider / model / capability are read-only diagnostics — none exposes
  # secrets nor writes .env (CLI-only). Useful for any agent to check LLM
  # connectivity, enumerate models, and feature-gate by capability tags.
  # `cron` is universal because long-running async work (anygen tasks,
  # scheduled checks, customer follow-ups) needs deferred execution
  # without blocking the agent loop. Without cron in the default set,
  # tool results that emit `next_action.tool="cron"` (e.g. anygen submit)
  # silently dead-end: the agent sees the instruction, has no `cron` tool
  # in scope, and improvises (paste the URL, ask the customer to retry).
  # Operators who want to bar a specific agent from scheduling can still
  # `deny "cron"` on that agent.
  # SSOT: the default tool set is derived from the framework's tool
  # manifest (`src/claw/tools/registry/manifest.nim`). Every tool with
  # `default = true` in its manifest entry lands here. Edit the
  # manifest to add/remove a default — never edit a hand-maintained
  # list in this file. Phase 8 ships this; the manual list this
  # replaced was drift-prone (we hit it 3+ times in one day).
  let defaultTools = manifest.defaultToolNames()

  # Auto-granted when the company declares ≥1 focus_mode. Without `spawn`
  # the focus_modes are unreachable — there's no path from an LLM tool
  # call to the SubagentManager. The failure mode is silent (the LLM
  # confidently hallucinates a "subagent ran" response without the tool
  # actually firing), which is hard to diagnose. Auto-granting closes
  # that gap. Operators who want a specific agent excluded can
  # `deny "spawn"` on that agent.
  let autoGrantSpawn = s.focus_modes.len > 0
  if autoGrantSpawn:
    echo "  + Auto-granting `spawn` to all agents (" & $s.focus_modes.len &
         " focus_mode(s) declared)"

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
    # Phase 4 of provider-config refactor (option C): every agent must
    # explicitly declare what models they want. Capability is the
    # agent's concern; the operational layer (providers) should not be
    # synthesising capability decisions on the agent's behalf.
    #   - Auto-promote the deprecated singular `model "X"` to a
    #     single-entry `models = ["X"]` (back-compat for files that
    #     haven't been through `claw co migrate` yet).
    #   - If neither `models` nor the deprecated `model` is declared,
    #     hard-error: the agent must say what it wants. No more silent
    #     "inherit the company chain" — that was the muddled path
    #     option C exists to eliminate.
    if s.agents[i].models.len == 0:
      if s.agents[i].model != "":
        s.agents[i].models = @[s.agents[i].model]
      else:
        echo ""
        echo "  ! ERROR: agent '" & s.agents[i].name & "' has no models declared."
        echo "  ! Add `models \"<name>\", ...` to the agent block in BASE.nims."
        echo "  ! See docs/provider-config-refactor.md for the full design."
        quit(1)
    let a = s.agents[i]
    # Every agent gets defaults (even without uses), minus denies
    var tools: seq[string] = @defaultTools
    if autoGrantSpawn: tools.add("spawn")
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
    # `uses "memory"` or declares `web` in a competency's `skills`, it's
    # really a tool request — silently grant the tool and skip the
    # unknown-skill warning.
    #
    # SSoT: derived from the framework manifest (auto-syncs with renames
    # and unifications). The previous hand-maintained const had stale
    # names from before the unifications (`http_request`, `browser_open`,
    # `playwright`, `learn_skill`, `reply_progress`, `cron`, `shell`,
    # `forge`, `persist`, `remember`, `subagent`) — granting any of them
    # silently produced dead references because the runtime registry
    # only has the post-unification names.
    let builtinTools = manifest.AllTools.mapIt(it.name)

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
          # It's a framework tool referenced as a skill — grant the tool directly.
          tools.add(skillName)
        else:
          unknown.add(skillName)

    # Apply per-agent grant/revoke overlay from <serviceDir>/tool_grants.json.
    # Grants are additive; revokes are subtractive (final word — they come
    # after all sources, so they reliably remove a tool the agent would
    # otherwise have via defaults or a skill).
    if serviceDir.len > 0:
      let overlay = loadToolGrants(serviceDir)
      for g in overlay.grants:
        if g.agent.toLowerAscii == a.name.toLowerAscii: tools.add(g.tool)
      for r in overlay.revokes:
        if r.agent.toLowerAscii == a.name.toLowerAscii:
          var filtered: seq[string]
          for t in tools:
            if t != r.tool: filtered.add(t)
          tools = filtered

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
    # framework tool names (which get granted as tools, not listed as skills).
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

  # Service-dir precedence: NIMCLAW_DIR env override (USB-resident dirs,
  # CI, tests, `claw co update` against a non-active deployment) wins;
  # otherwise derive from the org name in BASE.nims. We deliberately do
  # NOT fall through to the active-context pointer (`getNimClawDir`'s
  # behavior) — `build` is the canonical site that determines where the
  # company materializes, and "create a new company while another is
  # active" should land at the org-named path, not clobber the active.
  let envDir = getEnv("NIMCLAW_DIR")
  let serviceDir =
    if envDir.len > 0: envDir
    else: getHomeDir() / ".nimclaw-" & s.org.name
  let workspace = serviceDir / "workspace"

  # Load prior nc:id assignments from existing BASE.json @graph BEFORE
  # any code path touches `assignNcId` / `resolveEntityId`. First build
  # (no prior file) starts from empty assignments, allocating in
  # declaration order. Subsequent builds preserve every entity's nc:id
  # — adding new agents/persons never reshuffles existing ones.
  loadPriorEntityIds(serviceDir)

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

  # 3. Sync SOUL.md from BASE.nims (authored `soul "..."` wins, preset
  # is the fallback). Runs for every agent, not just ones with a
  # profile preset, so agents with pure-authored souls still get a file.
  for a in s.agents:
    installAgentSoul(a, workspace / "offices" / a.name.toLowerAscii)

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
  ], serviceDir = serviceDir)

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
  # Mirror the precedence rule from the single-arg `build*` overload above:
  # NIMCLAW_DIR wins (USB / CI / tests), else org-name-derived home path.
  let envDir = getEnv("NIMCLAW_DIR")
  let serviceDir =
    if envDir.len > 0: envDir
    else: getHomeDir() / (".nimclaw-" & s.org.name)
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
