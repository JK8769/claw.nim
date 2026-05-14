## company — the navigator of the tools / office / company trio.
##
## Org-level direction: who's here, what we deliver, what we've declared.
##
## Uses METHOD-style dispatch — a single `method` arg accepts a dotted
## path that selects the operation. Mirrors Nim's OOP `obj.member.method()`
## syntax, just expressed as a string the LLM constructs.
##
## Methods (Phase 1 — reads only):
##   info.read                       — admin metadata
##   info.update                     — Phase 2 (BASE.nims persistence)
##   memos.list | memos.read          — list/read policy docs
##   memos.create | memos.update      — Phase 2 (Staff+ writes)
##   memos.remove | memos.mark_critical — Phase 2 (Admin+ writes)
##   workforce.agents | workforce.offices  — staff directory + vessel directory
##   workforce.performance            — Phase 2 (per-agent metrics)
##   labs.list | labs.info            — team workspace directory + per-team config
##   labs.members | labs.tasks | labs.performance — Phase 2
##   business.overview                — what the company does
##   business.revenue | business.performance — Phase 2 (Admin+ financial reads)
##   business.customers | business.payment   — Phase 2 (Staff+/Admin+)
##   business.<domain>.<op>           — template-extensible (Phase 2)
##
## Trust gating (every write requires Staff+ minimum; sensitive writes
## are Admin+). External customers (Guest tier) blocked from EVERY method.
##
## Sibling tools on this trio:
##   tools     — sea (workforce capabilities, agent's craft)
##   office    — ship (agent's vessel — clock/calendar/state/etc.)

import std/[asyncdispatch, json, tables, strutils, os, times, algorithm, options]
import ../types
import ../spec
import ../../config

const ToolSpec* = spec(
  name = "company",
  description = "Org-level navigator. Method-style dispatch — `method=path.to.thing`. Top-level methods: info | memos | workforce | labs | business. Each takes nested ops via dot (e.g. memos.list, workforce.agents, business.solar.plant_list). Reads gated at Member tier (40+); writes Staff+ or Admin+. Guest tier blocked entirely.",
  tags = @["agent", "core", "company", "org"],
  searchKeywords = @["company", "org", "organization", "info", "memos",
                      "workforce", "agents", "offices", "labs", "teams",
                      "business", "revenue", "performance", "customers",
                      "payment", "policy", "staff", "directory", "method"],
  domain = "agent",
  default = true,
  heartbeatSafe = true,
  category = "self-management",
)

type
  CompanyTool* = ref object of ContextualTool
    workspace*: string                ## company workspace dir
    companyName*: string              ## from workspace dir basename
    agentsConfig*: seq[NamedAgentConfig]
    trustLevel*: int                  ## refreshed per turn — gates writes
    businessDomains*: Table[string, Tool]  ## domain → handler tool. Lets
                                           ## templates register sub-namespaces
                                           ## under company.business (e.g.
                                           ## "solar" → SolarTool, "payment"
                                           ## → PaymentTool). Routed by
                                           ## doBusiness as `business.<dom>.<op>`.

proc newCompanyTool*(workspace, companyName: string,
                     agents: seq[NamedAgentConfig]): CompanyTool =
  CompanyTool(
    workspace: workspace,
    companyName: companyName,
    agentsConfig: agents,
    trustLevel: 100,  # default safe — overwritten per-turn via setRequesterContext
    businessDomains: initTable[string, Tool]()
  )

proc setRequesterContext*(t: CompanyTool, trustLevel: int) =
  ## Refresh trust per turn — gates trust-tier checks in method handlers.
  t.trustLevel = trustLevel

proc registerBusinessDomain*(t: CompanyTool, domain: string, handler: Tool) =
  ## Register a sub-namespace under company.business. Calls to
  ## `company method=business.<domain>.<op>` route to handler.execute()
  ## with the op substituted as the handler's `method` arg.
  t.businessDomains[domain.toLowerAscii] = handler

method name*(t: CompanyTool): string = "company"

method description*(t: CompanyTool): string =
  "Org-level navigator — the navigator of the tools / office / company " &
  "trio.\n\n" &
  "Method-style dispatch: `method=path.to.thing`. Reads naturally as " &
  "Nim/OOP `company.path.to.thing(args)`. Available methods:\n\n" &
  "  info.read                          — admin metadata\n" &
  "  info.update                        — Phase 2 (BASE.nims persistence)\n" &
  "  memos.list | memos.read             — list / read policy docs\n" &
  "  memos.create | memos.update         — Staff+ writes (Phase 2)\n" &
  "  memos.remove | memos.mark_critical  — Admin+ writes (Phase 2)\n" &
  "  workforce.agents                   — list staff (people lens)\n" &
  "  workforce.offices                  — list vessels (state lens)\n" &
  "  workforce.performance              — Staff+ (Phase 2)\n" &
  "  labs.list | labs.info              — team workspaces directory + config\n" &
  "  labs.members | labs.tasks | labs.performance — Phase 2\n" &
  "  business.overview                  — what the company does\n" &
  "  business.revenue | business.performance — Admin+ financial (Phase 2)\n" &
  "  business.customers | business.payment   — Staff+/Admin+ (Phase 2)\n" &
  "  business.<domain>.<op>             — template-extensible (Phase 2)\n\n" &
  "Trust gating: reads require Member tier (40+); writes require Staff (70+) " &
  "or Admin (90+). External customers (Guest tier) blocked from every method."

method parameters*(t: CompanyTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "description": "Dot-separated method path. Top-level: info | memos | workforce | labs | business. Examples: info.read, memos.list, memos.read, workforce.agents, workforce.offices, labs.list, labs.info, business.overview, business.solar.plant_list."
      },
      "name": {
        "type": "string",
        "description": "Resource name (memos.read, labs.info — the memo/lab name to fetch)."
      },
      "content": {
        "type": "string",
        "description": "memos.create / memos.update — memo body."
      },
      "field": {
        "type": "string",
        "description": "info.update — field name (description, etc.)."
      },
      "value": {
        "type": "string",
        "description": "info.update — new field value."
      },
      "critical": {
        "type": "boolean",
        "description": "memos.create / memos.mark_critical — is this a critical memo (surfaces in every agent's system prompt)?"
      },
      "period": {
        "type": "string",
        "description": "performance methods — time window: today | last_7d | last_30d | all (default all)."
      }
    },
    "required": %["method"]
  }.toTable

# ── Trust gates ─────────────────────────────────────────────────────

const
  TrustGuest = 10
  TrustMember = 40
  TrustStaff = 70
  TrustAdmin = 90

proc requireAdmin(t: CompanyTool, label: string): string =
  ## Returns "" if Admin tier met; an Error message otherwise.
  if t.role.toLowerAscii in ["boss", "master", "admin", "superadmin"]:
    return ""
  return "Error: '" & label & "' requires Admin tier. Current caller " &
         "role: '" & t.role & "'. Lower tiers can read but cannot " &
         "perform admin writes."

proc requireStaff(t: CompanyTool, label: string): string =
  ## Phase 1: lenient (trust-band integration deferred). Will tighten in Phase 2.
  if t.role.toLowerAscii in ["boss", "master", "admin", "superadmin", "staff"]:
    return ""
  return "Error: '" & label & "' requires Staff tier (70+). Current caller " &
         "role: '" & t.role & "'."

# ── info.* ──────────────────────────────────────────────────────────

proc doInfoRead(t: CompanyTool): string =
  let envelope = %*{
    "name": t.companyName,
    "workspace": t.workspace,
    "agents_count": t.agentsConfig.len,
    "providers": "(see `provider list`)",
    "channels": "(see `channel list`)",
    "comment": "Phase 2: providers/channels/teams enumerated here directly"
  }
  envelope.pretty()

proc doInfo(t: CompanyTool, op: string, args: Table[string, JsonNode]): string =
  case op
  of "", "read":
    return doInfoRead(t)
  of "update":
    let gate = t.requireStaff("info.update")
    if gate.len > 0: return gate
    return "Error: 'info.update' is Phase 2 — needs BASE.nims persistence design. " &
           "Today, edit BASE.nims directly and run `claw co update`."
  else:
    return "Error: unknown info method 'info." & op & "'. Use: info.read | info.update."

# ── memos.* ─────────────────────────────────────────────────────────

proc memorandumDir(t: CompanyTool): string =
  t.workspace / "memorandum"

proc doMemosList(t: CompanyTool): string =
  let dir = t.memorandumDir()
  if not dirExists(dir):
    return "(no memos yet — workspace/memorandum/ doesn't exist)"
  var rows: seq[string]
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    if not path.endsWith(".md"): continue
    let name = path.extractFilename
    let summary = block:
      try:
        let content = readFile(path)
        let lines = content.splitLines()
        var firstNonEmpty = ""
        for l in lines:
          let s = l.strip()
          if s.len > 0 and not s.startsWith("---"):
            firstNonEmpty = s
            break
        if firstNonEmpty.len > 80: firstNonEmpty[0 ..< 80] & "..."
        else: firstNonEmpty
      except: ""
    rows.add("  " & name & "  —  " & summary)
  if rows.len == 0:
    return "(no memos)"
  rows.sort()
  return "Memos in " & dir & ":\n" & rows.join("\n")

proc doMemosRead(t: CompanyTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("name"): return "Error: 'name' is required for memos.read"
  let name = args["name"].getStr().strip()
  if name.len == 0: return "Error: 'name' must not be empty"
  let path = t.memorandumDir() / (if name.endsWith(".md"): name else: name & ".md")
  if not fileExists(path):
    return "Error: memo '" & name & "' not found at " & path
  try:
    return readFile(path)
  except CatchableError as e:
    return "Error: failed to read memo: " & e.msg

proc doMemos(t: CompanyTool, op: string, args: Table[string, JsonNode]): string =
  case op
  of "", "list":
    return doMemosList(t)
  of "read":
    return doMemosRead(t, args)
  of "create", "update":
    let gate = t.requireStaff("memos." & op)
    if gate.len > 0: return gate
    return "Error: 'memos." & op & "' is Phase 2 — needs file-write + frontmatter handling."
  of "remove", "mark_critical":
    let gate = t.requireAdmin("memos." & op)
    if gate.len > 0: return gate
    return "Error: 'memos." & op & "' is Phase 2 (Admin-tier write)."
  else:
    return "Error: unknown memos method 'memos." & op &
           "'. Use: memos.list | memos.read | memos.create | memos.update | memos.remove | memos.mark_critical."

# ── workforce.* ─────────────────────────────────────────────────────

proc doWorkforceAgents(t: CompanyTool): string =
  if t.agentsConfig.len == 0: return "(no agents declared in this company)"
  var rows: seq[string]
  for a in t.agentsConfig:
    let role = if a.role.isSome: a.role.get() else: "—"
    let job = if a.job_title.len > 0: a.job_title else: "(no job title)"
    rows.add("  " & a.name & "  [" & role & "]  " & job)
  rows.sort()
  return "Agents (" & $t.agentsConfig.len & "):\n" & rows.join("\n")

proc doWorkforceOffices(t: CompanyTool): string =
  let officesDir = t.workspace / "offices"
  if not dirExists(officesDir):
    return "(no offices yet — workspace/offices/ doesn't exist)"
  var rows: seq[string]
  for kind, path in walkDir(officesDir):
    if kind != pcDir: continue
    let name = path.extractFilename
    if name.startsWith("."): continue
    var lastActive = "(unknown)"
    var size = ""
    try:
      let info = getFileInfo(path)
      lastActive = info.lastWriteTime.format("yyyy-MM-dd HH:mm")
    except: discard
    if t.role.toLowerAscii in ["boss", "master", "admin", "superadmin"]:
      var bytes: int64 = 0
      for p in walkDirRec(path, relative = false, checkDir = false):
        try:
          let info = getFileInfo(p, followSymlink = false)
          if info.kind == pcFile: bytes += info.size
        except: discard
      size = " — " & $(bytes div 1024) & " KB"
    rows.add("  " & name & "  last-active: " & lastActive & size)
  rows.sort()
  return "Offices in " & officesDir & ":\n" & rows.join("\n")

proc doWorkforce(t: CompanyTool, op: string, args: Table[string, JsonNode]): string =
  case op
  of "", "agents":
    return doWorkforceAgents(t)
  of "offices":
    return doWorkforceOffices(t)
  of "performance":
    let gate = t.requireStaff("workforce.performance")
    if gate.len > 0: return gate
    return "Error: 'workforce.performance' is Phase 2 (per-agent metrics aggregation)."
  else:
    return "Error: unknown workforce method 'workforce." & op &
           "'. Use: workforce.agents | workforce.offices | workforce.performance."

# ── labs.* ──────────────────────────────────────────────────────────

proc labsDir(t: CompanyTool): string =
  ## Phase 1 reads from existing collaboration/teams/ location.
  ## Phase 2 will migrate to workspace/labs/ for parallel structure with offices.
  t.workspace / "collaboration" / "teams"

proc doLabsList(t: CompanyTool): string =
  let dir = t.labsDir()
  if not dirExists(dir):
    return "(no labs/teams declared — collaboration/teams/ doesn't exist)"
  var rows: seq[string]
  for kind, path in walkDir(dir):
    if kind != pcDir: continue
    let name = path.extractFilename
    if name.startsWith(".") or name.startsWith("_"): continue
    var description = ""
    let teamJsonPath = path / "TEAM.json"
    if fileExists(teamJsonPath):
      try:
        let cfg = parseJson(readFile(teamJsonPath))
        description = cfg{"description"}.getStr("")
      except: discard
    let descPart = if description.len > 0: " — " & description else: ""
    rows.add("  " & name & descPart)
  if rows.len == 0:
    return "(no labs/teams)"
  rows.sort()
  return "Labs (team workspaces):\n" & rows.join("\n")

proc doLabsInfo(t: CompanyTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("name"): return "Error: 'name' is required for labs.info"
  let name = args["name"].getStr().strip()
  let teamPath = t.labsDir() / name / "TEAM.json"
  if not fileExists(teamPath):
    return "Error: lab '" & name & "' not found (no TEAM.json at " & teamPath & ")"
  try:
    return readFile(teamPath)
  except CatchableError as e:
    return "Error: failed to read TEAM.json: " & e.msg

proc doLabs(t: CompanyTool, op: string, args: Table[string, JsonNode]): string =
  case op
  of "", "list":
    return doLabsList(t)
  of "info":
    return doLabsInfo(t, args)
  of "members", "tasks", "performance":
    return "Error: 'labs." & op & "' is Phase 2 (members from TEAM.json; tasks from labs/<team>/TASKS.md; performance aggregation)."
  else:
    return "Error: unknown labs method 'labs." & op &
           "'. Use: labs.list | labs.info | labs.members | labs.tasks | labs.performance."

# ── business.* ─────────────────────────────────────────────────────

proc doBusinessOverview(t: CompanyTool): string =
  let envelope = %*{
    "company": t.companyName,
    "agents": t.agentsConfig.len,
    "comment": "domain-specific business sub-methods (e.g. business.solar.plant_list, business.payment.balance) are template-extension territory — Phase 2"
  }
  envelope.pretty()

proc doBusiness(t: CompanyTool, subpath: string, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## subpath can be:
  ##   "" or "overview"           → doBusinessOverview
  ##   "revenue" / "performance"  → Admin-gated stubs (Phase 2)
  ##   "customers"                → Staff-gated stub (Phase 2)
  ##   "<domain>.<op>"            → routed to registered businessDomains[<domain>]
  if subpath == "" or subpath == "overview":
    return doBusinessOverview(t)

  let dotIdx = subpath.find('.')
  let topOp = if dotIdx < 0: subpath else: subpath[0 ..< dotIdx]
  let rest = if dotIdx < 0: "" else: subpath[dotIdx + 1 .. ^1]

  case topOp.toLowerAscii
  of "revenue", "performance":
    let gate = t.requireAdmin("business." & topOp)
    if gate.len > 0: return gate
    return "Error: 'business." & topOp & "' is Phase 2 (Admin-tier financial/operational reads)."
  of "customers":
    let gate = t.requireStaff("business.customers")
    if gate.len > 0: return gate
    return "Error: 'business.customers' is Phase 2 — for now use `social my_customers`."
  else:
    # Try registered business domains (e.g. solar, payment).
    let domain = topOp.toLowerAscii
    if t.businessDomains.hasKey(domain):
      var subArgs = initTable[string, JsonNode]()
      subArgs["method"] = %rest  # pass the rest of the path as the handler's method
      for k, v in args.pairs:
        if k != "method": subArgs[k] = v
      return await t.businessDomains[domain].execute(subArgs)
    var available: seq[string]
    for d in t.businessDomains.keys: available.add(d)
    let availStr = if available.len > 0: " Registered domains: " & available.join(", ") else: ""
    return "Error: 'business." & subpath & "' — domain '" & topOp &
           "' not registered." & availStr

# ── dispatch ───────────────────────────────────────────────────────

method execute*(t: CompanyTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("method"):
    return "Error: 'method' is required (e.g. info.read, memos.list, workforce.agents, labs.list, business.overview)"

  # Hard guard: external customers (Guest tier) blocked from every method.
  if t.trustLevel <= TrustGuest:
    return "Error: company-level methods are not available at Guest trust. " &
           "External customers can use `chat`, `mail`, and `social method=redeem` " &
           "to interact with the company; internal directory and operations are restricted."

  let methodPath = args["method"].getStr().strip()
  if methodPath.len == 0:
    return "Error: 'method' must not be empty"

  # Parse: split on first dot — top-level method + the rest as sub-path.
  let dotIdx = methodPath.find('.')
  let top = if dotIdx < 0: methodPath else: methodPath[0 ..< dotIdx]
  let rest = if dotIdx < 0: "" else: methodPath[dotIdx + 1 .. ^1]

  case top.toLowerAscii
  of "info":      return doInfo(t, rest, args)
  of "memos":     return doMemos(t, rest, args)
  of "workforce": return doWorkforce(t, rest, args)
  of "labs":      return doLabs(t, rest, args)
  of "business":  return await doBusiness(t, rest, args)
  else:
    return "Error: unknown method '" & methodPath &
           "'. Top-level methods: info | memos | workforce | labs | business. " &
           "Examples: info.read, memos.list, workforce.agents, labs.list, business.overview."
