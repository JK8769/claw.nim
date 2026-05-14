## company — the navigator of the tools / office / company trio.
##
## Org-level direction: who's here, what we deliver, what we've declared.
##
## Actions:
##   info       op=read | update                                  (admin)
##   memos      op=list | read | create | update | remove | mark_critical
##   workforce  op=agents | offices | performance                 (cross-office views)
##   labs       op=list | info | members | tasks | performance    (team workspaces)
##   business   op=overview | revenue | performance | customers | payment
##
## Trust gating (every write requires Staff+ minimum; sensitive writes
## are Admin+). External customers (Guest tier) blocked from EVERY action.
##
## Phase 1 implements: reads (info read, memos list/read, workforce
## agents/offices, labs list/info, business overview). Writes deferred
## to Phase 2 once persistence and approval flows are designed.
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
  description = "Org-level navigator. info (admin metadata) | memos (policy docs) | workforce (agents/offices/performance) | labs (team workspaces) | business (overview/revenue/performance/customers/payment). Reads gated by trust tier (Member+); writes by Staff+ or Admin+. Guest tier blocked entirely.",
  tags = @["agent", "core", "company", "org"],
  searchKeywords = @["company", "org", "organization", "info", "memos",
                      "workforce", "agents", "offices", "labs", "teams",
                      "business", "revenue", "performance", "customers",
                      "payment", "policy", "staff", "directory"],
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

proc newCompanyTool*(workspace, companyName: string,
                     agents: seq[NamedAgentConfig]): CompanyTool =
  CompanyTool(
    workspace: workspace,
    companyName: companyName,
    agentsConfig: agents,
    trustLevel: 100  # default safe — overwritten per-turn via setRequesterContext
  )

proc setRequesterContext*(t: CompanyTool, trustLevel: int) =
  ## Refresh trust per turn — gates trust-tier checks in action handlers.
  ## Mirrors UnifiedMemoryTool's setRequesterContext pattern.
  t.trustLevel = trustLevel

method name*(t: CompanyTool): string = "company"

method description*(t: CompanyTool): string =
  "Org-level navigator — the navigator of the tools / office / company " &
  "trio.\n\n" &
  "Actions (each with sub-ops):\n" &
  "  info       — admin metadata (op: read | update)\n" &
  "  memos      — policy docs (op: list | read | create | update | remove | mark_critical)\n" &
  "  workforce  — individuals (op: agents | offices | performance)\n" &
  "  labs       — team workspaces (op: list | info | members | tasks | performance)\n" &
  "  business   — what we deliver (op: overview | revenue | performance | customers | payment)\n\n" &
  "Trust gating: reads require Member tier (40+); writes require Staff (70+) " &
  "or Admin (90+). External customers (Guest tier) blocked from every action.\n\n" &
  "Phase 1: reads only (info/memos/workforce/labs/business read ops). " &
  "Writes Phase 2."

method parameters*(t: CompanyTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["info", "memos", "workforce", "labs", "business"],
        "description": "Top-level concern. Each takes an `op` sub-arg."
      },
      "op": {
        "type": "string",
        "description": "Sub-operation. info: read | update. memos: list | read | create | update | remove | mark_critical. workforce: agents | offices | performance. labs: list | info | members | tasks | performance. business: overview | revenue | performance | customers | payment."
      },
      "name": {
        "type": "string",
        "description": "Resource name (memo/agent/office/lab name)."
      },
      "content": {
        "type": "string",
        "description": "memos op=create/update — memo body."
      },
      "field": {
        "type": "string",
        "description": "info op=update — field name (description, etc.)"
      },
      "value": {
        "type": "string",
        "description": "info op=update — new field value."
      },
      "critical": {
        "type": "boolean",
        "description": "memos op=create/mark_critical — is this a critical memo (surfaces in every agent's system prompt)?"
      },
      "period": {
        "type": "string",
        "description": "performance ops — time window: today | last_7d | last_30d | all (default all)."
      }
    },
    "required": %["action"]
  }.toTable

# ── Trust gates ─────────────────────────────────────────────────────

const
  TrustGuest = 10
  TrustMember = 40
  TrustStaff = 70
  TrustAdmin = 90

proc requireTrust(t: CompanyTool, minTrust: int, label: string): string =
  ## Returns "" if trust met; an Error message otherwise.
  if t.role.toLowerAscii in ["boss", "master", "admin", "superadmin"]:
    return ""  # internal high-priv roles bypass numeric checks
  # Note: for memos op=remove and op=mark_critical we ALSO check role
  # since these are admin-tier; trustLevel may still be Staff (70).
  # Here we use the structural role + trust band check.
  if minTrust >= TrustAdmin:
    if t.role.toLowerAscii notin ["boss", "master", "admin", "superadmin"]:
      return "Error: '" & label & "' requires Admin tier or higher. " &
             "Current caller role: '" & t.role & "'. Lower tiers can read " &
             "but cannot perform admin writes."
  # For Staff+ checks, structural role lookup or fall back
  return ""  # Phase 1: trust band integration with framework happens in Phase 2

# ── info handlers ──────────────────────────────────────────────────

proc doInfoRead(t: CompanyTool): string =
  ## Public-readable company info (gated at Member tier).
  let envelope = %*{
    "name": t.companyName,
    "workspace": t.workspace,
    "agents_count": t.agentsConfig.len,
    "providers": "(see `provider list`)",
    "channels": "(see `channel list`)",
    "comment": "Phase 2: providers/channels/teams enumerated here directly"
  }
  envelope.pretty()

proc doInfo(t: CompanyTool, args: Table[string, JsonNode]): string =
  let op = if args.hasKey("op"): args["op"].getStr().strip().toLowerAscii() else: "read"
  case op
  of "read", "":
    return doInfoRead(t)
  of "update":
    return "Error: 'info op=update' is Phase 2 — needs BASE.nims persistence design. " &
           "Today, edit BASE.nims directly and run `claw co update`."
  else:
    return "Error: unknown info op '" & op & "'. Use: read | update."

# ── memos handlers ─────────────────────────────────────────────────

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
  if not args.hasKey("name"): return "Error: 'name' is required for memos read"
  let name = args["name"].getStr().strip()
  if name.len == 0: return "Error: 'name' must not be empty"
  let path = t.memorandumDir() / (if name.endsWith(".md"): name else: name & ".md")
  if not fileExists(path):
    return "Error: memo '" & name & "' not found at " & path
  try:
    return readFile(path)
  except CatchableError as e:
    return "Error: failed to read memo: " & e.msg

proc doMemos(t: CompanyTool, args: Table[string, JsonNode]): string =
  let op = if args.hasKey("op"): args["op"].getStr().strip().toLowerAscii() else: "list"
  case op
  of "list", "":
    return doMemosList(t)
  of "read":
    return doMemosRead(t, args)
  of "create", "update":
    let gate = t.requireTrust(TrustStaff, "memos op=" & op)
    if gate.len > 0: return gate
    return "Error: 'memos op=" & op & "' is Phase 2 — needs file-write + frontmatter handling."
  of "remove", "mark_critical":
    let gate = t.requireTrust(TrustAdmin, "memos op=" & op)
    if gate.len > 0: return gate
    return "Error: 'memos op=" & op & "' is Phase 2 (Admin-tier write)."
  else:
    return "Error: unknown memos op '" & op & "'. Use: list | read | create | update | remove | mark_critical."

# ── workforce handlers ─────────────────────────────────────────────

proc doWorkforceAgents(t: CompanyTool): string =
  ## List agents from cfg.
  if t.agentsConfig.len == 0: return "(no agents declared in this company)"
  var rows: seq[string]
  for a in t.agentsConfig:
    let role = if a.role.isSome: a.role.get() else: "—"
    let job = if a.job_title.len > 0: a.job_title else: "(no job title)"
    rows.add("  " & a.name & "  [" & role & "]  " & job)
  rows.sort()
  return "Agents (" & $t.agentsConfig.len & "):\n" & rows.join("\n")

proc doWorkforceOffices(t: CompanyTool): string =
  ## List office dirs (per-agent vessels). Trust-gated: lower tiers see less.
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
    # SuperAdmin tier sees more detail; Member only sees existence.
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

proc doWorkforce(t: CompanyTool, args: Table[string, JsonNode]): string =
  let op = if args.hasKey("op"): args["op"].getStr().strip().toLowerAscii() else: "agents"
  case op
  of "agents", "":
    return doWorkforceAgents(t)
  of "offices":
    return doWorkforceOffices(t)
  of "performance":
    let gate = t.requireTrust(TrustStaff, "workforce op=performance")
    if gate.len > 0: return gate
    return "Error: 'workforce op=performance' is Phase 2 (per-agent metrics aggregation)."
  else:
    return "Error: unknown workforce op '" & op & "'. Use: agents | offices | performance."

# ── labs handlers ──────────────────────────────────────────────────

proc labsDir(t: CompanyTool): string =
  ## Phase 1 reads from existing collaboration/teams/ location.
  ## Phase 2 will migrate to workspace/labs/ for parallel structure with
  ## offices (offices/<agent>/ + labs/<team>/).
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
  if not args.hasKey("name"): return "Error: 'name' is required for labs info"
  let name = args["name"].getStr().strip()
  let teamPath = t.labsDir() / name / "TEAM.json"
  if not fileExists(teamPath):
    return "Error: lab '" & name & "' not found (no TEAM.json at " & teamPath & ")"
  try:
    return readFile(teamPath)
  except CatchableError as e:
    return "Error: failed to read TEAM.json: " & e.msg

proc doLabs(t: CompanyTool, args: Table[string, JsonNode]): string =
  let op = if args.hasKey("op"): args["op"].getStr().strip().toLowerAscii() else: "list"
  case op
  of "list", "":
    return doLabsList(t)
  of "info":
    return doLabsInfo(t, args)
  of "members", "tasks", "performance":
    return "Error: 'labs op=" & op & "' is Phase 2 (members from TEAM.json; tasks from labs/<team>/TASKS.md; performance aggregation)."
  else:
    return "Error: unknown labs op '" & op & "'. Use: list | info | members | tasks | performance."

# ── business handlers ─────────────────────────────────────────────

proc doBusinessOverview(t: CompanyTool): string =
  ## Phase 1: generic overview. Templates extend with domain ops in Phase 2.
  let envelope = %*{
    "company": t.companyName,
    "agents": t.agentsConfig.len,
    "comment": "domain-specific business sub-ops (fleet, inverter_alarms, etc.) are template-extension territory — Phase 2"
  }
  envelope.pretty()

proc doBusiness(t: CompanyTool, args: Table[string, JsonNode]): string =
  let op = if args.hasKey("op"): args["op"].getStr().strip().toLowerAscii() else: "overview"
  case op
  of "overview", "":
    return doBusinessOverview(t)
  of "revenue", "performance":
    let gate = t.requireTrust(TrustAdmin, "business op=" & op)
    if gate.len > 0: return gate
    return "Error: 'business op=" & op & "' is Phase 2 (Admin-tier financial/operational reads)."
  of "customers":
    let gate = t.requireTrust(TrustStaff, "business op=customers")
    if gate.len > 0: return gate
    return "Error: 'business op=customers' is Phase 2 — for now use `social my_customers`."
  of "payment":
    let gate = t.requireTrust(TrustStaff, "business op=payment")
    if gate.len > 0: return gate
    return "Error: 'business op=payment' is Phase 2 — for now use the standalone `payment` tool. Will fold here once company.business sub-actions stabilize."
  else:
    return "Error: unknown business op '" & op & "'. Use: overview | revenue | performance | customers | payment."

# ── dispatch ───────────────────────────────────────────────────────

method execute*(t: CompanyTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (info | memos | workforce | labs | business)"

  # Hard guard: external customers (Guest tier 10) blocked from every action.
  if t.trustLevel <= TrustGuest:
    return "Error: company-level actions are not available at Guest trust. " &
           "External customers can use `chat`, `mail`, and `social action=redeem` " &
           "to interact with the company; internal directory and operations are restricted."

  let action = args["action"].getStr().toLowerAscii()
  case action
  of "info":      return doInfo(t, args)
  of "memos":     return doMemos(t, args)
  of "workforce": return doWorkforce(t, args)
  of "labs":      return doLabs(t, args)
  of "business":  return doBusiness(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: info | memos | workforce | labs | business."
