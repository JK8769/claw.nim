## claw — AI agent framework CLI.
## Single binary: gateway mode (long-running) + management commands (one-shot).

import std/[os, strutils, json, tables, osproc, posix, sequtils, times, algorithm, unicode, sets]
import docopt
import claw/[config, doctor, protocol, version as version_mod, context, env_file]
import claw/agent/context as agent_context
import claw/cli/client
import claw/cli_admin
import claw/cli_providers
import claw/gateway
import claw/skills/skill_id
import claw/providers/[registry as prov_registry, auth as prov_auth, models_catalog]
import std/terminal

const doc = """claw — AI agent framework.

Usage:
  claw gateway [--stdio] [--pane=PANE] [--debug]
  claw (company|co) list [--sort=<key>] [--reverse] [--status=<state>] [--format=<fmt>]
  claw (company|co) use [<name>]
  claw (company|co) create [<file>] [--as=<name>]
  claw (company|co) update [--restart] [--no-pull]
  claw (company|co) push [<url>] [--message=<m>] [--force]
  claw (company|co) pull
  claw (company|co) diverge [--remove-origin] [--rename=<name>]
  claw (company|co) install [--dry-run]
  claw (company|co) stop
  claw (company|co) status
  claw provider auth <name>
  claw provider list [--verify] [--format=<fmt>]
  claw model list [--vendor=<v>] [--owner=<v>] [--family=<fam>] [--has=<cap>] [--match=<pat>] [--all-versions] [--format=<fmt>]
  claw model refresh [<provider>]
  claw model add <provider> <model-id> [--canonical=<c>] [--context=<n>] [--capabilities=<list>] [--input-cost=<f>] [--output-cost=<f>]
  claw model set <provider> <model-id> [--canonical=<c>] [--context=<n>] [--capabilities=<list>] [--input-cost=<f>] [--output-cost=<f>]
  claw model remove <provider> <model-id>
  claw provider add <name> --api-base=<url> [--env-key=<var>] [--default-model=<model>] [--auth=<hdr>] [--verify-path=<path>] [--local]
  claw provider set <name> [--rename=<name>] [--api-base=<url>] [--env-key=<var>] [--default-model=<model>] [--auth=<hdr>] [--verify-path=<path>]
  claw provider remove <name>
  claw provider <cmd> [<args>...]
  claw channel <cmd> [<args>...]
  claw agent list
  claw agent caps <name>
  claw agent prompt <name>
  claw agent send <name> <message>
  claw skill list [--sort=<key>] [--reverse] [--format=<fmt>]
  claw skill new <name>
  claw skill remove <name>
  claw skill auth <name> [--region=<r>]
  claw skill sync [<name>]
  claw skill share <name>
  claw skill unshare <name>
  claw skill install <ref> [--as=<alias>]
  claw doctor [--no-color]
  claw version
  claw --version
  claw --help

Options:
  -h, --help           Show this help
  --version            Show version
  --stdio              Zen mode: JSONL on stdin/stdout
  --pane=PANE          Zen pane [default: left]
  --debug              Debug logging
  --dry-run            Show what would be installed, don't run
  --no-color           Disable colors
  --as=<alias>         Rename skill on install
  --restart            After update, stop and restart the gateway if running
  --no-pull            Skip `git pull` during `co update` (regenerate locally only)
  --message=<m>        Commit message for `co push` auto-commit
  --force              git push --force (confirms before running)
  --remove-origin      Fully remove origin on `co diverge` (default: keep as 'original')
  --rename=<name>      Rename origin to <name> on `co diverge` (default: 'original')
  --region=<r>         Scope a skill's env vars to a region (e.g. us|eu|cn).
                       SUNGROW_APPKEY becomes SUNGROW_US_APPKEY when --region=us
  --sort=<key>         Sort by column key (see command-specific keys)
  --reverse            Reverse sort direction
  --status=<state>     Filter company list by gateway state: running|stopped
  --format=<fmt>       Output format: table|json  [default: table]
  --verify             Verify each provider's stored API key (provider list)
  --api-base=<url>     Provider API base URL (provider add/set)
  --env-key=<var>      Env var holding the API key (defaults to <NAME>_API_KEY)
  --default-model=<m>  Default model name for the provider
  --auth=<hdr>         Auth header style: bearer|x-api-key|none  [default: bearer]
  --verify-path=<path> Path suffix (relative to apiBase) used to validate key  [default: /models]
  --local              Mark provider as local (no auth required, e.g. ollama)
  --vendor=<v>         Filter by vendor (meta, anthropic, openai, ...)
  --owner=<v>          Alias for --vendor (matches the OWNED BY column)
  --family=<fam>       Filter by model family (llama-3.3, claude-3.5, gpt-4o, ...)
  --all-versions       Include older versions (default: latest version per family-variant)
  --has=<cap>          Filter by capability (tool-use, vision, reasoning, ...)
  --match=<pat>        Substring match on model id (case-insensitive)
  --canonical=<c>      Canonical model id to link a provider-offered model to (model add)
  --context=<n>        Context length in tokens (model add)
  --input-cost=<f>     USD per 1M input tokens (model add)
  --output-cost=<f>    USD per 1M output tokens (model add)
  --capabilities=<l>   Comma-separated list (tool-use,vision,reasoning,code,multilingual,audio)
"""

# ── Helpers ─────────────────────────────────────────────────────────

proc isCommand(args: Table[string, Value], cmd1, cmd2: string): bool =
  args[cmd1] and args[cmd2]

proc isCompanyCmd(args: Table[string, Value], verb: string): bool =
  ## `claw company <verb>` or `claw co <verb>` — both forms.
  (args["company"] or args["co"]) and args[verb]

proc padDisplay(s: string, width: int): string =
  ## Left-pad a string to `width` visible columns, counting UTF-8 runes.
  ## Use this instead of strutils.alignLeft when cells may contain non-ASCII
  ## (e.g. ✓/✗/⚠ status markers). ASCII-only input falls back to the fast path.
  let visible = s.runeLen
  if visible >= width: return s
  return s & repeat(' ', width - visible)

# ─── git helpers for company co push/pull/update ─────────────────────

const CompanyGitignore = """
# claw-generated .gitignore — credentials and runtime data must not ship.
.env
.env.*
BASE.json
claw.lock

# Runtime / observability
logs/
activity.jsonl
*.pid
*.sock

# Per-user agent state (diverges between deployments)
workspace/offices/*/memory/
workspace/offices/*/sessions/
workspace/offices/*/cache/

# Per-machine compiled binaries (consumer rebuilds)
workspace/skills/*/bin/

# Editor / OS noise
.DS_Store
*.swp
"""

proc runGit(args: openArray[string], cwd: string, captureOutput = false): tuple[exitCode: int, output: string] =
  ## Run `git <args>` in `cwd`. Returns exit code and (optionally) stdout.
  var cmd = "git -C " & quoteShell(cwd)
  for a in args: cmd.add(" " & quoteShell(a))
  if captureOutput:
    let (output, exitCode) = execCmdEx(cmd)
    return (exitCode, output)
  else:
    let exitCode = execCmd(cmd)
    return (exitCode, "")

proc isGitRepo(dir: string): bool =
  dirExists(dir / ".git")

proc gitHasOrigin(dir: string): bool =
  let (_, output) = runGit(["remote", "get-url", "origin"], dir, captureOutput = true)
  output.strip().len > 0 and not output.contains("No such remote")

proc gitOriginUrl(dir: string): string =
  let (code, output) = runGit(["remote", "get-url", "origin"], dir, captureOutput = true)
  if code == 0: output.strip() else: ""

proc ensureCompanyGitignore(dir: string) =
  let path = dir / ".gitignore"
  if not fileExists(path):
    writeFile(path, CompanyGitignore)
  # If it exists, trust the user — don't clobber.

type
  ModelParts = object
    vendor: string      ## part before '/' (e.g. "meta", "z-ai")
    family: string      ## first word token (e.g. "llama", "gpt", "glm")
    version: string     ## numeric token (e.g. "3.3", "5.1"), "" if none
    size: string        ## raw size token (e.g. "70b", "8x22b"), "" if none
    sizeB: float        ## size in billions (70, 176); 0 if unknown
    roles: seq[string]  ## trailing word tokens (["instruct"], ["o", "mini"], ...)

proc isSizeToken(s: string): bool =
  ## True iff s matches Nb or NxMb (e.g. "70b", "8x22b"). Case-insensitive on the
  ## trailing 'b'/'x'.
  if s.len < 2 or s[^1] notin {'b','B'}: return false
  var i = 0
  while i < s.len - 1 and s[i].isDigit(): inc i
  if i == 0: return false
  if i == s.len - 1: return true                  # "Nb"
  if s[i] notin {'x','X'}: return false
  let afterX = i + 1
  i = afterX
  while i < s.len - 1 and s[i].isDigit(): inc i
  i == s.len - 1 and i > afterX                   # "NxMb"

proc parseSizeB(s: string): float =
  ## Given a size token, return billions. "70b" → 70, "8x22b" → 176.
  if not isSizeToken(s): return 0
  var i = 0
  while s[i].isDigit(): inc i
  let n = try: parseInt(s[0 ..< i]) except: 0
  if s[i] in {'b','B'}: return float(n)
  let mStart = i + 1
  var j = mStart
  while s[j].isDigit(): inc j
  let m = try: parseInt(s[mStart ..< j]) except: 0
  return float(n * m)

proc splitTextNum(token: string): seq[string] =
  ## Split a dash-less token at text↔number boundaries.
  ## "glm4.7" → ["glm","4.7"];  "qwen2.5" → ["qwen","2.5"];  "4o" → ["4","o"];
  ## size tokens like "70b" / "8x22b" are preserved as a single element.
  if token.len == 0: return
  if isSizeToken(token): return @[token]
  proc numish(c: char): bool = c.isDigit() or c == '.'
  var cur = ""
  var curIsNum = numish(token[0])
  for c in token:
    let n = numish(c)
    if n != curIsNum and cur.len > 0:
      result.add(cur)
      cur = ""
      curIsNum = n
    cur.add(c)
  if cur.len > 0: result.add(cur)

proc parseModelId(modelId: string): ModelParts =
  ## Parse "vendor/model-name" into structured parts using split('/') then
  ## split('-'), with text↔num splitting for un-dashed tokens.
  let slash = modelId.find('/')
  var rest = modelId
  if slash >= 0:
    result.vendor = modelId[0 ..< slash]
    rest = modelId[slash + 1 .. ^1]
  var tokens: seq[string]
  for part in rest.split('-'):
    if part.len == 0: continue
    for sub in splitTextNum(part):
      if sub.len > 0: tokens.add(sub)
  for tok in tokens:
    if isSizeToken(tok):
      if result.size.len == 0:
        result.size = tok
        result.sizeB = parseSizeB(tok)
    elif tok[0].isDigit() or tok[0] == '.':
      if result.version.len == 0:
        result.version = tok
    else:
      if result.family.len == 0: result.family = tok
      else: result.roles.add(tok)

proc compareVersions(a, b: string): int =
  ## Segment-wise version compare: "3.10" > "3.3", "5.1" > "5", "" is lowest.
  if a.len == 0 and b.len == 0: return 0
  if a.len == 0: return -1
  if b.len == 0: return 1
  let ap = a.split('.')
  let bp = b.split('.')
  for i in 0 ..< max(ap.len, bp.len):
    let av = if i < ap.len: (try: parseInt(ap[i]) except: 0) else: 0
    let bv = if i < bp.len: (try: parseInt(bp[i]) except: 0) else: 0
    if av != bv: return av - bv
  return 0

# ── Entry point ─────────────────────────────────────────────────────

when isMainModule:
  loadDotEnv()
  let args = docopt(doc, version = "claw " & version_mod.versionString())

  # Gateway (long-running)
  if args["gateway"]:
    let useStdio = bool(args["--stdio"])
    let debug = bool(args["--debug"])
    let pane = $args["--pane"]
    runGateway("127.0.0.1", 3000, debug, true, useStdio, pane)

  # ── Company commands ─────────────────────────────────────────────
  # `claw company ...` or the short form `claw co ...`

  elif isCompanyCmd(args, "list"):
    let active = readActiveContext()
    let companies = listCompanies()
    if companies.len == 0:
      echo "No companies found under $HOME/.nimclaw-*/"
      echo "Run: claw company create <template.nims>"
      quit(0)

    # Collect richer info per company. We keep BOTH formatted display strings
    # (for rendering) AND raw numeric values (for sorting) — string sort is
    # wrong for numbers ("103.1K" < "12.3K" alphabetically).
    type Row = object
      name, owner, agents, skills, tokens, status, provs, modified, description: string
      # Raw values for comparison
      rawAgents, rawSkills: int
      rawTokens, rawUptime: int64
      rawModified: int64  # unix timestamp
      rawRunning: bool
      active: bool
    var rows: seq[Row] = @[]
    for c in companies:
      let info = inspectCompany(c.path)
      let running = isGatewayRunning(c.path)
      let uptime = if running: gatewayUptimeSeconds(c.path) else: 0'i64
      let statusStr = if running:
        if uptime > 0: "running " & formatUptime(uptime) else: "running"
      else: "stopped"
      rows.add(Row(
        name: c.name,
        owner: (if info.owner.len > 0: info.owner else: "-"),
        agents: (if info.valid: $info.agents else: "?"),
        skills: (if info.valid: $info.skills else: "?"),
        tokens: (if info.totalTokens > 0: formatTokens(info.totalTokens) else: "-"),
        status: statusStr,
        provs: (if info.providers.len > 0: info.providers.join(",") else: "-"),
        modified: (if info.modified != times.Time(): relativeTime(info.modified) else: "-"),
        description: (if info.description.len > 0: info.description else: ""),
        rawAgents: info.agents,
        rawSkills: info.skills,
        rawTokens: info.totalTokens,
        rawUptime: uptime,
        rawModified: info.modified.toUnix,
        rawRunning: running,
        active: c.name == active
      ))

    # Filter by --status if set
    var statusFilter = $args["--status"]
    if statusFilter == "nil": statusFilter = ""
    if statusFilter.len > 0:
      let want = statusFilter.toLowerAscii()
      if want notin ["running", "stopped"]:
        echo "Error: --status must be 'running' or 'stopped' (got: " & statusFilter & ")"
        quit(1)
      var filtered: seq[Row] = @[]
      for r in rows:
        if (want == "running") == r.rawRunning: filtered.add(r)
      rows = filtered

    # Sort if requested
    var sortKey = $args["--sort"]
    if sortKey == "nil": sortKey = ""
    let reverse = bool(args["--reverse"])
    if sortKey.len > 0:
      # Numeric keys default to descending (biggest first); text keys to ascending.
      # --reverse flips whichever default applies.
      let numeric = sortKey in ["uptime", "agents", "skills", "tokens", "modified"]
      let descending = if reverse: not numeric else: numeric
      proc cmpRow(a, b: Row): int =
        case sortKey
        of "name":     cmp(a.name.toLowerAscii, b.name.toLowerAscii)
        of "owner":    cmp(a.owner.toLowerAscii, b.owner.toLowerAscii)
        of "status":   cmp(a.status, b.status)
        of "uptime":   cmp(a.rawUptime, b.rawUptime)
        of "agents":   cmp(a.rawAgents, b.rawAgents)
        of "skills":   cmp(a.rawSkills, b.rawSkills)
        of "tokens":   cmp(a.rawTokens, b.rawTokens)
        of "modified": cmp(a.rawModified, b.rawModified)
        else:
          echo "Warning: unknown --sort key '" & sortKey & "'. Valid: " &
               "name|owner|status|uptime|agents|skills|tokens|modified"
          0
      rows.sort(cmpRow, order = (if descending: SortOrder.Descending else: SortOrder.Ascending))

    # JSON output — scripting-friendly, raw numeric values (not human-formatted)
    var formatKind = $args["--format"]
    if formatKind == "nil": formatKind = "table"
    if formatKind == "json":
      var arr = newJArray()
      for r in rows:
        arr.add(%*{
          "name": r.name,
          "owner": (if r.owner == "-": newJNull() else: %r.owner),
          "description": r.description,
          "agents": r.rawAgents,
          "skills": r.rawSkills,
          "tokens": r.rawTokens,
          "running": r.rawRunning,
          "uptime_seconds": r.rawUptime,
          "modified_unix": r.rawModified,
          "providers": (if r.provs == "-": newJArray() else: %r.provs.split(',')),
          "active": r.active,
          "path": companyDirForName(r.name)
        })
      echo pretty(arr, 2)
      quit(0)

    # Column widths
    var wName = "NAME".len
    var wOwner = "OWNER".len
    var wAgents = "AGENTS".len
    var wSkills = "SKILLS".len
    var wTokens = "TOKENS".len
    var wStatus = "STATUS".len
    var wProvs = "PROVIDERS".len
    var wMod = "MODIFIED".len
    for r in rows:
      if r.name.len > wName: wName = r.name.len
      if r.owner.len > wOwner: wOwner = r.owner.len
      if r.agents.len > wAgents: wAgents = r.agents.len
      if r.skills.len > wSkills: wSkills = r.skills.len
      if r.tokens.len > wTokens: wTokens = r.tokens.len
      if r.status.len > wStatus: wStatus = r.status.len
      if r.provs.len > wProvs: wProvs = r.provs.len
      if r.modified.len > wMod: wMod = r.modified.len
    let pad = 2
    let nameW = wName + pad
    let ownerW = wOwner + pad
    let agentsW = wAgents + pad
    let skillsW = wSkills + pad
    let tokensW = wTokens + pad
    let statusW = wStatus + pad
    let provsW = wProvs + pad
    let modW = wMod + pad

    # Truncate descriptions that are too long for the trailing column
    const maxDescrLen = 50
    proc trunc(s: string): string =
      if s.len <= maxDescrLen: s
      else: s[0 ..< maxDescrLen - 3] & "..."

    echo alignLeft("", 2) &
         alignLeft("NAME", nameW) &
         alignLeft("OWNER", ownerW) &
         alignLeft("STATUS", statusW) &
         alignLeft("AGENTS", agentsW) &
         alignLeft("SKILLS", skillsW) &
         alignLeft("TOKENS", tokensW) &
         alignLeft("PROVIDERS", provsW) &
         alignLeft("MODIFIED", modW) &
         "DESCRIPTION"
    for r in rows:
      let marker = if r.active: "* " else: "  "
      echo marker &
           alignLeft(r.name, nameW) &
           alignLeft(r.owner, ownerW) &
           alignLeft(r.status, statusW) &
           alignLeft(r.agents, agentsW) &
           alignLeft(r.skills, skillsW) &
           alignLeft(r.tokens, tokensW) &
           alignLeft(r.provs, provsW) &
           alignLeft(r.modified, modW) &
           trunc(r.description)
    if active.len > 0:
      echo ""
      echo "(* = active)"

  elif isCompanyCmd(args, "use"):
    var nameArg = $args["<name>"]
    if nameArg == "nil": nameArg = ""
    if nameArg.len == 0:
      # Show current
      let active = readActiveContext()
      if active.len == 0:
        echo "No active company set."
        echo "Use: claw company use <name>"
      else:
        echo "Active company: " & active
        echo "Path: " & companyDirForName(active)
      quit(0)
    # Validate that the company exists
    let resolved = companyDirForName(nameArg)
    if not dirExists(resolved):
      echo "Error: no company at " & resolved
      echo ""
      echo "Available companies:"
      for c in listCompanies():
        echo "  " & c.name
      quit(1)
    writeActiveContext(nameArg)
    echo "Active company: " & nameArg & " (" & resolved & ")"

  # Create company from .nims script.
  # With a file arg: build from that file; on success the .nims itself copies
  #   itself to <serviceDir>/BASE.nims (see build(currentSourcePath()) in templates).
  # Without a file arg: default to the active company's BASE.nims.
  elif isCompanyCmd(args, "create"):
    var fileArg = $args["<file>"]
    if fileArg == "nil": fileArg = ""
    var renameAs = $args["--as"]
    if renameAs == "nil": renameAs = ""
    var scriptPath = ""

    # Detect a git URL as the `<file>` arg — clone first, then treat the
    # cloned BASE.nims as the script. Supports github:owner/repo shortcuts.
    proc looksLikeGitUrl(s: string): bool =
      s.startsWith("https://") or s.startsWith("http://") or
      s.startsWith("git@") or s.endsWith(".git") or s.startsWith("github:") or
      s.startsWith("file://")
    proc expandGithubShortcut(s: string): string =
      if s.startsWith("github:"):
        let rest = s["github:".len .. ^1]
        return "https://github.com/" & rest & ".git"
      s

    # claw:<company> — use that local company's BASE.nims as the template.
    # Rejects claw:// explicitly so the strict form is the only accepted one.
    if fileArg.startsWith("claw://"):
      echo "Error: 'claw://' is not supported — use 'claw:<company>' (no slashes)"
      quit(1)
    if fileArg.startsWith("claw:"):
      let srcCompany = fileArg["claw:".len .. ^1]
      if srcCompany.len == 0 or '/' in srcCompany:
        echo "Error: claw:<company> form takes just a company name — got '" &
             srcCompany & "'"
        quit(1)
      let srcDir = companyDirForName(srcCompany)
      let srcBase = srcDir / "BASE.nims"
      if not fileExists(srcBase):
        echo "Error: no BASE.nims at " & srcBase
        echo "       company '" & srcCompany & "' does not exist locally."
        echo "       Clone it first: claw co create <url> --as=" & srcCompany
        quit(1)
      if renameAs.len == 0:
        echo "Error: --as=<name> is required when creating from claw:<company>"
        echo "       (otherwise the new company would collide with " & srcCompany & ")"
        quit(1)
      # Rewrite `skill "<name>"` → `skill "claw:<src>/<name>"` for any skill
      # that lives in <src>'s workspace/skills (company-tier). Foundation
      # skills and external refs are left alone. This pins the new company
      # to <src>'s actual skill content, preserving any customizations
      # instead of silently falling back to distribution defaults.
      let srcSkillsDir = srcDir / "workspace" / "skills"
      var src = readFile(srcBase)
      var modified = ""
      var rewrittenCount = 0
      for rawLine in src.splitLines(keepEol = true):
        var line = rawLine
        let stripped = line.strip(leading = true, trailing = false)
        if stripped.startsWith("skill \""):
          let closeQuote = stripped.find('"', 7)
          if closeQuote > 7:
            let inner = stripped[7 ..< closeQuote]
            # If the declaration has a SECOND argument (an explicit source),
            # leave it alone — the user has already specified where it comes
            # from (github:/http:/etc). Only rewrite bare `skill "X"` lines
            # that would otherwise fall back to bundled.
            let afterClose = stripped[closeQuote + 1 .. ^1].strip(leading = true)
            let hasSecondArg = afterClose.startsWith(",")
            if not hasSecondArg and ':' notin inner and '/' notin inner:
              let atPos = inner.find('@')
              let bareName = if atPos > 0: inner[0 ..< atPos] else: inner
              if dirExists(srcSkillsDir / bareName):
                let indent = line[0 ..< line.len - stripped.len]
                let tail = stripped[closeQuote + 1 .. ^1]
                let verSuffix = if atPos > 0: inner[atPos .. ^1] else: ""
                line = indent & "skill \"claw:" & srcCompany & "/" & bareName &
                       verSuffix & "\"" & tail
                inc rewrittenCount
        modified.add(line)
      if rewrittenCount > 0:
        # Sanitize for Nim module name
        var safe = ""
        for c in renameAs:
          if c in {'A'..'Z', 'a'..'z', '0'..'9', '_'}: safe.add(c)
          else: safe.add('_')
        let tempPath = getTempDir() / (safe & "-from-" & srcCompany & ".nims")
        writeFile(tempPath, modified)
        scriptPath = tempPath
        echo "Using template from " & srcCompany & " — pinned " & $rewrittenCount &
             " company-skill ref(s) to claw:" & srcCompany & "/..."
      else:
        scriptPath = srcBase
        echo "Using template from " & srcCompany & " (" & srcBase & ")"
    elif fileArg.len > 0 and looksLikeGitUrl(fileArg):
      if renameAs.len == 0:
        echo "Error: --as=<name> is required when creating from a git URL"
        quit(1)
      let cloneUrl = expandGithubShortcut(fileArg)
      let targetDir = getHomeDir() / ".nimclaw-" & renameAs
      if dirExists(targetDir):
        echo "Error: " & targetDir & " already exists. Pick a different --as name,"
        echo "       or remove the existing company first."
        quit(1)
      echo "→ git clone " & cloneUrl & " → " & targetDir
      let cmd = "git clone " & quoteShell(cloneUrl) & " " & quoteShell(targetDir)
      if execCmd(cmd) != 0:
        echo "  git clone failed"
        quit(1)
      let cloned = targetDir / "BASE.nims"
      if not fileExists(cloned):
        echo "Error: cloned repo has no BASE.nims at its root"
        echo "       Not all git repos are claw companies. Make sure the URL points"
        echo "       to a repo created via `claw co push`."
        removeDir(targetDir)
        quit(1)
      scriptPath = cloned
      echo "  Cloned. Treating " & cloned & " as the template."
    elif fileArg.len > 0:
      if not fileExists(fileArg):
        echo "Error: file not found: " & fileArg
        quit(1)
      scriptPath = expandFilename(fileArg)
    else:
      let defaultPath = getNimClawDir() / "BASE.nims"
      if not fileExists(defaultPath):
        echo "Error: no file argument and no default config at " & defaultPath
        echo ""
        echo "First time? Run with a template path:"
        echo "  claw create /path/to/MyCompany.nims"
        echo ""
        echo "Claw will copy it to <companyDir>/BASE.nims so you can edit"
        echo "locally and re-run 'claw create' (no arg needed) to rebuild."
        quit(1)
      scriptPath = defaultPath
      echo "Using local config: " & scriptPath

    # --as=<new>: rewrite the org name into a temp copy, then run that instead.
    # The org line looks like: org "OldName":  (possibly surrounded by whitespace).
    if renameAs.len > 0:
      let src = readFile(scriptPath)
      var modified = ""
      var renamed = false
      for line in src.splitLines(keepEol = true):
        if not renamed:
          let stripped = line.strip(leading = true, trailing = false)
          if stripped.startsWith("org \""):
            let closeQuote = stripped.find('"', 5)
            if closeQuote > 5:
              let indent = line[0 ..< line.len - stripped.len]
              let tail = stripped[closeQuote + 1 .. ^1]
              modified.add(indent & "org \"" & renameAs & "\"" & tail)
              renamed = true
              continue
        modified.add(line)
      if not renamed:
        echo "Error: --as was given but no `org \"...\":` line was found in " & scriptPath
        quit(1)
      # Nim uses the basename as the module name, which must be a valid Nim
      # identifier (no hyphens). Sanitize renameAs for the temp filename only.
      var safe = ""
      for c in renameAs:
        if c in {'A'..'Z', 'a'..'z', '0'..'9', '_'}: safe.add(c)
        else: safe.add('_')
      let tempPath = getTempDir() / (safe & ".nims")
      writeFile(tempPath, modified)
      scriptPath = tempPath
      echo "Using template " & fileArg & " → org renamed to '" & renameAs & "'"

    var srcPath = getCurrentDir() / "src"
    if not dirExists(srcPath / "claw"):
      srcPath = getAppDir() / "src"
      if not dirExists(srcPath / "claw"):
        srcPath = getAppDir().parentDir() / "src"
    var cmd = "nim e"
    if dirExists(srcPath / "claw"):
      cmd &= " --path:" & quoteShell(srcPath)
    cmd &= " " & quoteShell(scriptPath)
    let exitCode = execCmd(cmd)
    if exitCode != 0: quit(exitCode)

  # Update — regenerate an existing company from its own BASE.nims. Same
  # machinery as `create` with no file arg, but with a clearer verb and an
  # optional gateway restart.
  elif isCompanyCmd(args, "update"):
    let doRestart = bool(args["--restart"])
    let noPull = bool(args["--no-pull"])
    let companyDir = getNimClawDir()
    let scriptPath = companyDir / "BASE.nims"
    if not fileExists(scriptPath):
      echo "Error: no BASE.nims at " & scriptPath
      echo "This company wasn't created from a template. Use `claw co create`."
      quit(1)

    # Git-aware update: pull from origin first if the company tracks one.
    if not noPull and isGitRepo(companyDir) and gitHasOrigin(companyDir):
      echo "→ git pull from " & gitOriginUrl(companyDir)
      let (code, _) = runGit(["pull", "--ff-only"], companyDir)
      if code != 0:
        echo "  Pull failed — resolve conflicts (`git -C " & companyDir &
             " status`) or pass --no-pull to skip."
        quit(code)
      # Preserve this consumer's identity: if the dir's basename implies a
      # different org than what upstream's BASE.nims declares, rewrite the
      # org line locally. Keeps clones independent even when upstream
      # evolves. Not committed — each pull re-applies the rewrite.
      let base = companyDir.lastPathPart
      let localOrgName =
        if base.startsWith(".nimclaw-"): base[".nimclaw-".len .. ^1] else: base
      if fileExists(scriptPath):
        let src = readFile(scriptPath)
        var rewrote = false
        var rewritten = ""
        for rawLine in src.splitLines(keepEol = true):
          if not rewrote:
            let stripped = rawLine.strip(leading = true, trailing = false)
            if stripped.startsWith("org \""):
              let closeQuote = stripped.find('"', 5)
              if closeQuote > 5:
                let upstreamName = stripped[5 ..< closeQuote]
                if upstreamName != localOrgName:
                  let indent = rawLine[0 ..< rawLine.len - stripped.len]
                  let tail = stripped[closeQuote + 1 .. ^1]
                  rewritten.add(indent & "org \"" & localOrgName & "\"" & tail)
                  rewrote = true
                  echo "  ↻ kept local org name: upstream had '" &
                       upstreamName & "' → restored '" & localOrgName & "'"
                  continue
          rewritten.add(rawLine)
        if rewrote: writeFile(scriptPath, rewritten)

    let wasRunning = isGatewayRunning(companyDir)
    if wasRunning and not doRestart:
      echo "Note: company is running — `claw co update` won't stop it, so any"
      echo "      in-flight agent work is safe. The new config is written to"
      echo "      BASE.json but the running gateway keeps its pinned config."
      echo "      Restart the company when you're ready:"
      echo "        claw co stop && claw gateway"
      echo "      (or re-run with --restart to do it in one step)"
      echo ""

    var srcPath = getCurrentDir() / "src"
    if not dirExists(srcPath / "claw"):
      srcPath = getAppDir() / "src"
      if not dirExists(srcPath / "claw"):
        srcPath = getAppDir().parentDir() / "src"
    var cmd = "nim e"
    if dirExists(srcPath / "claw"):
      cmd &= " --path:" & quoteShell(srcPath)
    cmd &= " " & quoteShell(scriptPath)
    let exitCode = execCmd(cmd)
    if exitCode != 0: quit(exitCode)

    if wasRunning and doRestart:
      echo ""
      echo "→ Restarting gateway to apply changes..."
      var pidPath = gatewayPidPath()
      if not fileExists(pidPath): pidPath = pidFilePath()
      if fileExists(pidPath):
        let pid = readFile(pidPath).strip().parseInt()
        discard kill(pid.cint, cint(15))
        # Give the old gateway a moment to release sockets/PID file
        var waited = 0
        while isGatewayRunning(companyDir) and waited < 20:
          sleep(100)
          waited.inc
      echo "  Gateway stopped. Run `claw gateway` to start it back up with"
      echo "  the new config (backgrounding this from a script requires shell '&')."

  # Company push — publish the active company to a git remote.
  # First invocation with a <url>: init + commit + set origin + push.
  # Subsequent invocations: auto-commit changes and push to origin.
  elif isCompanyCmd(args, "push"):
    let companyDir = getNimClawDir()
    var urlArg = $args["<url>"]
    if urlArg == "nil": urlArg = ""
    var msg = $args["--message"]
    if msg == "nil": msg = "Update company state"
    let doForce = bool(args["--force"])

    # Step 1: ensure it's a git repo with a .gitignore
    if not isGitRepo(companyDir):
      echo "→ git init in " & companyDir
      let (code, _) = runGit(["init", "-b", "main"], companyDir)
      if code != 0:
        echo "  git init failed"
        quit(code)
    ensureCompanyGitignore(companyDir)

    # Step 2: stage + commit if there are changes
    discard runGit(["add", "-A"], companyDir)
    let (statusCode, statusOut) = runGit(["status", "--porcelain"], companyDir,
                                          captureOutput = true)
    if statusCode == 0 and statusOut.strip().len > 0:
      echo "→ commit: " & msg
      let (ccode, _) = runGit(["commit", "-m", msg], companyDir)
      if ccode != 0:
        echo "  commit failed — see git output above"
        quit(ccode)
    else:
      echo "  (no changes to commit)"

    # Step 3: wire origin if user provided a URL; else use existing.
    if urlArg.len > 0:
      if gitHasOrigin(companyDir):
        let existing = gitOriginUrl(companyDir)
        if existing != urlArg:
          echo "→ setting origin: " & existing & " → " & urlArg
          discard runGit(["remote", "set-url", "origin", urlArg], companyDir)
      else:
        echo "→ adding origin: " & urlArg
        discard runGit(["remote", "add", "origin", urlArg], companyDir)

    if not gitHasOrigin(companyDir):
      echo "Error: no origin set. Pass a URL: `claw co push <url>`"
      quit(1)

    # Step 4: push
    var pushArgs = @["push", "-u", "origin", "main"]
    if doForce:
      stdout.write "  --force push requested. Confirm? [y/N] "
      let ans = readLine(stdin).strip().toLowerAscii()
      if ans != "y" and ans != "yes":
        echo "  aborted"
        quit(1)
      pushArgs.add("--force")
    echo "→ git push origin main"
    let (pcode, _) = runGit(pushArgs, companyDir)
    if pcode != 0:
      echo "  push failed — see git output above"
      quit(pcode)
    echo "✓ pushed to " & gitOriginUrl(companyDir)

  # Company pull — fetch + merge from origin without regenerating.
  # For most users, `claw co update` is preferable (pull + regenerate).
  elif isCompanyCmd(args, "pull"):
    let companyDir = getNimClawDir()
    if not isGitRepo(companyDir):
      echo "Error: " & companyDir & " is not a git repo (no upstream to pull from)"
      quit(1)
    if not gitHasOrigin(companyDir):
      echo "Error: no origin set for this company"
      quit(1)
    echo "→ git pull from " & gitOriginUrl(companyDir)
    let (code, _) = runGit(["pull", "--ff-only"], companyDir)
    if code != 0:
      echo "  Pull failed — inspect `git -C " & companyDir & " status`"
      quit(code)
    echo ""
    echo "Note: BASE.json / claw.lock were NOT regenerated. Run `claw co update"
    echo "      --no-pull` if you need to re-process BASE.nims without pulling again."

  # Company diverge — cut (or soften) the tie to upstream.
  # Default: keep old origin as 'original' for future cherry-picks.
  elif isCompanyCmd(args, "diverge"):
    let companyDir = getNimClawDir()
    if not isGitRepo(companyDir):
      echo "Error: " & companyDir & " is not a git repo"
      quit(1)
    if not gitHasOrigin(companyDir):
      echo "Error: no origin set — nothing to diverge from"
      quit(1)
    let removeOrigin = bool(args["--remove-origin"])
    var renameTo = $args["--rename"]
    if renameTo == "nil": renameTo = "original"

    let oldUrl = gitOriginUrl(companyDir)
    if removeOrigin:
      discard runGit(["remote", "remove", "origin"], companyDir)
      echo "→ removed origin (was " & oldUrl & ")"
      echo "  Company is now standalone. Use `claw co push <url>` to re-publish."
    else:
      discard runGit(["remote", "rename", "origin", renameTo], companyDir)
      echo "→ renamed origin → '" & renameTo & "' (" & oldUrl & ")"
      echo "  You can still cherry-pick from it via:"
      echo "    git -C " & companyDir & " fetch " & renameTo & " main"
      echo "    git -C " & companyDir & " cherry-pick <sha>"
      echo "  When ready, `claw co push <new-url>` adopts a new remote."

  # Install resolved deps from lockfile / skills.json
  elif isCompanyCmd(args, "install"):
    let dryRun = bool(args["--dry-run"])
    let serviceDir = getNimClawDir()
    let lockPath = serviceDir / "claw.lock"
    if not fileExists(lockPath):
      echo "Error: no claw.lock at " & lockPath
      echo "Run: claw create <file.nims>"
      quit(1)
    let lock = parseJson(readFile(lockPath))
    echo "Installing deps for " & lock{"org"}.getStr("?") & "..."

    # Collect unique deps across all agents
    var allDeps: seq[string]
    for a in lock{"agents"}.getElems():
      for d in a{"resolved_deps"}.getElems():
        let dep = d.getStr()
        if dep notin allDeps: allDeps.add(dep)

    if allDeps.len == 0:
      echo "No deps to install."
      quit(0)

    # Look up install command per dep from bundled deps.json
    var depsPath = getCurrentDir() / "deps" / "deps.json"
    if not fileExists(depsPath):
      depsPath = getAppDir() / "deps" / "deps.json"
    var depsReg = if fileExists(depsPath): parseJson(readFile(depsPath)) else: newJArray()

    for dep in allDeps:
      # Find in registry by package name or alias
      var cmd = ""
      for d in depsReg:
        if d{"name"}.getStr() == dep:
          cmd = d{"install"}.getStr("")
          break
      if cmd == "":
        # Fallback: assume npm global install
        cmd = "npm install -g " & dep
      echo "  " & dep & ": " & cmd
      if not dryRun:
        let ec = execCmd(cmd)
        if ec != 0:
          echo "    ✗ failed (exit " & $ec & ")"
        else:
          echo "    ✓ installed"
      else:
        echo "    (dry-run — not executed)"

    if dryRun:
      echo "\nDry run complete. Remove --dry-run to install."
    else:
      echo "\nDone."

  # Stop the active company's gateway
  elif isCompanyCmd(args, "stop"):
    # Prefer the company-scoped PID; fall back to legacy service-scoped path
    var pidPath = gatewayPidPath()
    if not fileExists(pidPath): pidPath = pidFilePath()
    if not fileExists(pidPath):
      echo "Not running."
      quit(1)
    let pid = readFile(pidPath).strip().parseInt()
    discard kill(pid.cint, cint(15))  # SIGTERM
    echo "Stopped (PID " & $pid & ")"

  # Status of the active company's gateway
  elif isCompanyCmd(args, "status"):
    let running = isGatewayRunning(getNimClawDir())
    let active = readActiveContext()
    echo "Company: " & (if active.len > 0: active else: "(no active, using default)")
    if running:
      let up = gatewayUptimeSeconds(getNimClawDir())
      echo "Status:  running" & (if up > 0: " (uptime " & formatUptime(up) & ")" else: "")
    else:
      echo "Status:  stopped"
    echo "Path:    " & getNimClawDir()

  # Provider list — tabular view of the global provider catalog.
  # Auth state + token usage are scoped to the ACTIVE company (.env lives
  # per-company), but the provider definitions themselves are global.
  elif args.isCommand("provider", "list"):
    let doVerify = bool(args["--verify"])
    var formatKind = $args["--format"]
    if formatKind == "nil": formatKind = "table"

    let envPath = getNimClawDir() / ".env"
    let companyDir = getNimClawDir()
    # Token attribution across all offices for this company (one walk, not per-provider)
    let tokenByProvider = providerTokensUsage(companyDir)

    type Row = object
      name, keyVar, status, tokens, url: string
      # raw for JSON
      isLocal, isSet, isValid: bool
      rawTokens: int64
    var rows: seq[Row] = @[]

    for p in prov_registry.effectiveProviders():
      var r = Row(name: p.name, url: p.apiBase)
      r.keyVar = if p.local: "(local)"
                 elif p.envKey.len == 0: "(no env var)"
                 else: p.envKey
      r.isLocal = p.local
      let stored = if p.local: "" else: readEnvValue(envPath, p.envKey)
      r.isSet = stored.len > 0
      r.rawTokens = if tokenByProvider.hasKey(p.name): tokenByProvider[p.name] else: 0
      r.tokens = if r.rawTokens > 0: formatTokens(r.rawTokens) else: "-"

      if p.local:
        if doVerify:
          let vr = prov_auth.verifyKey(p, "")
          r.isValid = vr.outcome == prov_auth.voSkipped
          r.status = if r.isValid: "✓ local" else: "✗ unreachable"
        else:
          r.status = "local"
      elif not r.isSet:
        r.status = "not set"
      elif doVerify:
        let vr = prov_auth.verifyKey(p, stored)
        case vr.outcome
        of prov_auth.voOk:          r.isValid = true; r.status = "✓ valid"
        of prov_auth.voAuthFailed:  r.status = "✗ invalid"
        of prov_auth.voRateLimit:   r.status = "⚠ 429"
        of prov_auth.voNetwork:     r.status = "✗ network"
        of prov_auth.voServerError: r.status = "⚠ 5xx"
        else:                       r.status = "? unknown"
      else:
        r.status = "set"

      rows.add(r)

    # JSON format — scripting-friendly
    if formatKind == "json":
      var arr = newJArray()
      for r in rows:
        arr.add(%*{
          "name": r.name,
          "env_var": (if r.isLocal: newJNull() else: %r.keyVar),
          "api_base": r.url,
          "local": r.isLocal,
          "key_set": r.isSet,
          "verified": (if doVerify: %r.isValid else: newJNull()),
          "tokens_used": r.rawTokens
        })
      echo pretty(arr, 2)
      quit(0)

    # Table format
    let active = readActiveContext()
    echo "Company: " & (if active.len > 0: active else: getNimClawDir()) &
         (if doVerify: "  (verifying stored keys...)" else: "")
    echo ""
    var wName = "NAME".runeLen
    var wKey = "KEY".runeLen
    var wStatus = "STATUS".runeLen
    var wTokens = "TOKENS".runeLen
    for r in rows:
      if r.name.runeLen > wName: wName = r.name.runeLen
      if r.keyVar.runeLen > wKey: wKey = r.keyVar.runeLen
      if r.status.runeLen > wStatus: wStatus = r.status.runeLen
      if r.tokens.runeLen > wTokens: wTokens = r.tokens.runeLen
    let pad = 2
    echo padDisplay("NAME", wName + pad) &
         padDisplay("KEY", wKey + pad) &
         padDisplay("STATUS", wStatus + pad) &
         padDisplay("TOKENS", wTokens + pad) &
         "API ENDPOINT"
    for r in rows:
      echo padDisplay(r.name, wName + pad) &
           padDisplay(r.keyVar, wKey + pad) &
           padDisplay(r.status, wStatus + pad) &
           padDisplay(r.tokens, wTokens + pad) &
           r.url
    echo ""
    if not doVerify:
      echo "Run with --verify to check each stored key against the provider's API."
    echo "Run `claw provider auth <name>` to set/update a key."

  # Provider auth — verify an API key and write it to the active company's .env
  elif args.isCommand("provider", "auth"):
    let name = $args["<name>"]
    let (def, found) = prov_registry.findProvider(name)
    if not found:
      echo "Error: unknown provider '" & name & "'"
      echo ""
      echo "Known: " & prov_registry.providerNames().join(", ")
      quit(1)

    let companyDir = getNimClawDir()
    let envPath = companyDir / ".env"
    let active = readActiveContext()
    let companyLabel = if active.len > 0: active else: companyDir.lastPathPart

    # Style B — explicit narration
    echo "→ Provider:  " & def.name & (if def.local: " (local)" else: "")
    echo "→ API base:  " & def.apiBase
    if def.envKey.len > 0:
      echo "→ Env var:   " & def.envKey
    echo "→ Company:   " & companyLabel & "  (" & envPath & ")"
    echo ""

    if def.local:
      echo "  Local providers don't use API keys. Nothing to store."
      echo "  Reachability check: GET " & def.apiBase & def.verifyPath
      let res = prov_auth.verifyKey(def, "")
      case res.outcome
      of prov_auth.voSkipped:
        echo "  ✓ (skipped auth — local provider)"
      of prov_auth.voNetwork:
        echo "  ✗ " & res.errMsg & " — is the local server running?"
        quit(1)
      else:
        echo "  ✓ reachable"
      quit(0)

    # Is a key already stored? Offer to re-verify or replace.
    let existing = readEnvValue(envPath, def.envKey)
    var apiKey = ""
    if existing.len > 0:
      echo "  " & def.envKey & " is already set in .env."
      echo "  Re-verifying the stored key..."
      let vr = prov_auth.verifyKey(def, existing)
      if vr.outcome == prov_auth.voOk:
        echo "  ✓ stored key is valid" &
             (if vr.modelCount > 0: " (" & $vr.modelCount & " models available)" else: "")
        stdout.write "  Replace with a new key? [y/N] "
        let ans = readLine(stdin).strip().toLowerAscii()
        if ans != "y" and ans != "yes":
          quit(0)
      else:
        echo "  ✗ stored key is NOT valid: " & vr.errMsg
        echo "  Paste a new key to replace it."
      # Fall through to prompt for new key

    if apiKey.len == 0:
      stdout.write "  Enter " & def.envKey & ": "
      stdout.flushFile()
      apiKey = readPasswordFromStdin().strip()
      echo ""   # newline after the hidden prompt

    if apiKey.len == 0:
      echo "  ✗ empty key — aborting"
      quit(1)

    echo "  Verifying via GET " & def.apiBase & def.verifyPath & " ..."
    let vr = prov_auth.verifyKey(def, apiKey)
    case vr.outcome
    of prov_auth.voOk:
      echo "  ✓ key accepted" &
           (if vr.modelCount > 0: " (" & $vr.modelCount & " models available)" else: "")
      writeEnvValue(envPath, def.envKey, apiKey)
      echo "  ✓ written to " & envPath & "  (" & def.envKey & ")"
      echo ""
      echo "The key is scoped to this company only. Other companies have"
      echo "their own .env and cannot see or use this key."
    of prov_auth.voAuthFailed:
      echo "  ✗ " & vr.errMsg
      echo "  .env was not touched."
      quit(1)
    of prov_auth.voRateLimit:
      echo "  ⚠ " & vr.errMsg
      echo "  The key is probably valid. Writing it and you can re-verify later."
      writeEnvValue(envPath, def.envKey, apiKey)
    of prov_auth.voNetwork:
      echo "  ✗ " & vr.errMsg
      echo "  .env was not touched."
      quit(1)
    of prov_auth.voServerError, prov_auth.voUnknown:
      echo "  ⚠ " & vr.errMsg
      echo "  Unable to fully verify. Write the key anyway? [y/N] "
      let ans = readLine(stdin).strip().toLowerAscii()
      if ans == "y" or ans == "yes":
        writeEnvValue(envPath, def.envKey, apiKey)
        echo "  ✓ written to " & envPath & " (unverified)"
      else:
        echo "  .env was not touched."
        quit(1)
    of prov_auth.voSkipped:
      discard  # handled above for local providers


  # Model refresh — fetch live models from configured providers, write to
  # the active company's model cache. Company-aware (requires .env keys).
  elif args.isCommand("model", "refresh"):
    let companyDir = getNimClawDir()
    var name = $args["<provider>"]
    if name == "nil": name = ""

    var targets: seq[prov_registry.ProviderDef] = @[]
    if name.len > 0:
      let (def, found) = prov_registry.findProvider(name)
      if not found:
        echo "Error: unknown provider '" & name & "'"
        quit(1)
      targets.add(def)
    else:
      # Refresh all providers that have a key set (or are local)
      for p in prov_registry.effectiveProviders():
        if p.local or readEnvValue(companyDir / ".env", p.envKey).len > 0:
          targets.add(p)
      if targets.len == 0:
        echo "No providers have keys set. Run `claw provider auth <name>` first,"
        echo "or pass a specific provider name to this command."
        quit(1)

    for def in targets:
      stdout.write "→ " & def.name & " ... "
      stdout.flushFile()
      let key = if def.local: "" else: readEnvValue(companyDir / ".env", def.envKey)
      if not def.local and key.len == 0:
        echo "skipped (no key)"
        continue
      let n = models_catalog.refreshProvider(def, key)
      if n > 0:
        echo $n & " models written"
      else:
        echo "0 models (unreachable or empty)"
    echo ""
    echo "Catalog: " & models_catalog.catalogPath()

  # Model add — manually register a model offering for a provider that doesn't
  # have a discovery API (or for which refresh missed the entry).
  elif args.isCommand("model", "add"):
    let provName = $args["<provider>"]
    let modelId = $args["<model-id>"]
    let (def, found) = prov_registry.findProvider(provName)
    if not found:
      echo "Error: unknown provider '" & provName & "'"
      echo "Known: " & prov_registry.providerNames().join(", ")
      quit(1)
    let catPath = models_catalog.catalogPath()
    if catPath.len == 0:
      echo "Error: can't locate res/models.json"
      quit(1)
    var cat = models_catalog.loadCatalog(catPath)

    var canonical = $args["--canonical"]
    if canonical == "nil": canonical = ""
    var contextArg = $args["--context"]
    var inCostArg = $args["--input-cost"]
    var outCostArg = $args["--output-cost"]
    var capsArg = $args["--capabilities"]
    let contextLen = if contextArg == "nil": 0 else: (try: parseInt(contextArg) except: 0)
    let inCost = if inCostArg == "nil": 0.0 else: (try: parseFloat(inCostArg) except: 0.0)
    let outCost = if outCostArg == "nil": 0.0 else: (try: parseFloat(outCostArg) except: 0.0)
    var caps: seq[string]
    if capsArg != "nil":
      for c in capsArg.split(','):
        let s = c.strip()
        if s.len > 0: caps.add(s)

    if canonical.len > 0 and not cat.canonical.hasKey(canonical):
      echo "Warning: canonical '" & canonical & "' is not in the catalog."
      echo "         The model will still link, but won't appear in `model list`"
      echo "         until a matching canonical entry is added."

    var pc = cat.providers.getOrDefault(def.name)
    # Reject duplicate id
    for m in pc.models:
      if m.id == modelId:
        echo "Error: provider '" & def.name & "' already has a model '" & modelId & "'"
        echo "Use `claw model set` to update an existing entry, or `claw model remove` to delete."
        quit(1)
    pc.models.add(prov_auth.ModelInfo(
      id: modelId, canonical: canonical,
      contextLen: contextLen,
      inputCostPer1M: inCost, outputCostPer1M: outCost,
      capabilities: caps))
    if pc.updated.len == 0: pc.updated = now().format("yyyy-MM-dd")
    cat.providers[def.name] = pc
    models_catalog.saveCatalog(catPath, cat)
    echo "→ Added '" & modelId & "' under provider '" & def.name & "'"
    if canonical.len > 0: echo "  Canonical: " & canonical
    echo "  Catalog: " & catPath

  # Model set — update fields on an existing offering without removing it.
  elif args.isCommand("model", "set"):
    let provName = $args["<provider>"]
    let modelId = $args["<model-id>"]
    let catPath = models_catalog.catalogPath()
    if catPath.len == 0:
      echo "Error: can't locate res/models.json"
      quit(1)
    var cat = models_catalog.loadCatalog(catPath)
    if not cat.providers.hasKey(provName):
      echo "Error: provider '" & provName & "' has no catalog entry"
      quit(1)
    var pc = cat.providers[provName]
    var idx = -1
    for i, m in pc.models:
      if m.id == modelId: idx = i; break
    if idx < 0:
      echo "Error: no model '" & modelId & "' under provider '" & provName & "'"
      quit(1)

    var canonical = $args["--canonical"]
    var contextArg = $args["--context"]
    var inCostArg = $args["--input-cost"]
    var outCostArg = $args["--output-cost"]
    var capsArg = $args["--capabilities"]
    var touched = false
    if canonical != "nil":
      pc.models[idx].canonical = canonical
      touched = true
    if contextArg != "nil":
      pc.models[idx].contextLen = (try: parseInt(contextArg) except: 0)
      touched = true
    if inCostArg != "nil":
      pc.models[idx].inputCostPer1M = (try: parseFloat(inCostArg) except: 0.0)
      touched = true
    if outCostArg != "nil":
      pc.models[idx].outputCostPer1M = (try: parseFloat(outCostArg) except: 0.0)
      touched = true
    if capsArg != "nil":
      var caps: seq[string]
      for c in capsArg.split(','):
        let s = c.strip()
        if s.len > 0: caps.add(s)
      pc.models[idx].capabilities = caps
      touched = true
    if not touched:
      echo "Error: nothing to set — pass at least one of --canonical, --context, --capabilities, --input-cost, --output-cost"
      quit(1)
    cat.providers[provName] = pc
    models_catalog.saveCatalog(catPath, cat)
    echo "→ Updated '" & modelId & "' under provider '" & provName & "'"

  # Model remove — delete a provider-offering entry from res/models.json
  elif args.isCommand("model", "remove"):
    let provName = $args["<provider>"]
    let modelId = $args["<model-id>"]
    let catPath = models_catalog.catalogPath()
    if catPath.len == 0:
      echo "Error: can't locate res/models.json"
      quit(1)
    var cat = models_catalog.loadCatalog(catPath)
    if not cat.providers.hasKey(provName):
      echo "Error: provider '" & provName & "' has no catalog entry"
      quit(1)
    var pc = cat.providers[provName]
    var kept: seq[prov_auth.ModelInfo]
    var found = false
    for m in pc.models:
      if m.id == modelId: found = true
      else: kept.add(m)
    if not found:
      echo "Error: no model '" & modelId & "' under provider '" & provName & "'"
      quit(1)
    pc.models = kept
    cat.providers[provName] = pc
    models_catalog.saveCatalog(catPath, cat)
    echo "→ Removed '" & modelId & "' from provider '" & provName & "'"
    echo "  Catalog: " & catPath

  # Provider add — register a new provider in the global catalog
  elif args.isCommand("provider", "add"):
    let name = $args["<name>"]
    let resPath = prov_registry.builtinProvidersPath()
    if resPath.len == 0:
      echo "Error: can't locate res/providers.json"
      quit(1)

    # Reject if the name already exists in the global catalog
    for p in prov_registry.effectiveProviders():
      if p.name == name:
        echo "Error: '" & name & "' is already in the catalog."
        echo "Use `claw provider set " & name & "` to modify it."
        quit(1)

    # Gather fields from flags
    var apiBase = $args["--api-base"]
    if apiBase == "nil": apiBase = ""
    if apiBase.len == 0:
      echo "Error: --api-base is required for provider add"
      quit(1)

    var envKey = $args["--env-key"]
    if envKey == "nil": envKey = ""
    var defaultModel = $args["--default-model"]
    if defaultModel == "nil": defaultModel = ""
    var authFlag = $args["--auth"]
    if authFlag == "nil": authFlag = "bearer"
    var verifyPath = $args["--verify-path"]
    if verifyPath == "nil": verifyPath = "/models"
    let isLocal = bool(args["--local"])

    # Derive env key default: <NAME uppercase>_API_KEY.
    # Coerce to a valid shell identifier (letters/digits/underscore only).
    if envKey.len == 0 and not isLocal:
      var safe = ""
      for c in name.toUpperAscii():
        if c in {'A'..'Z', '0'..'9'}: safe.add(c)
        else: safe.add('_')
      while safe.contains("__"): safe = safe.replace("__", "_")
      safe = safe.strip(chars = {'_'})
      envKey = safe & "_API_KEY"

    let authHeader = case authFlag.toLowerAscii()
      of "bearer":    "Authorization: Bearer"
      of "x-api-key": "x-api-key"
      of "none":      ""
      else:
        echo "Error: --auth must be bearer|x-api-key|none (got: " & authFlag & ")"
        quit(1)
        ""

    var providers = prov_registry.effectiveProviders()
    providers.add(prov_registry.ProviderDef(
      name: name, envKey: envKey, apiBase: apiBase,
      authHeader: authHeader, verifyPath: verifyPath,
      defaultModel: defaultModel, local: isLocal))
    prov_registry.saveProvidersFile(resPath, providers)
    prov_registry.invalidateBuiltinCache()

    echo "→ Added provider '" & name & "' to " & resPath
    echo "  (Global catalog — visible to all companies on this install.)"
    if not isLocal:
      echo "  Set the key with: claw provider auth " & name

  # Provider set — modify fields on a provider in the global catalog.
  elif args.isCommand("provider", "set"):
    let name = $args["<name>"]
    let resPath = prov_registry.builtinProvidersPath()
    if resPath.len == 0:
      echo "Error: can't locate res/providers.json"
      quit(1)

    var providers = prov_registry.effectiveProviders()
    var idx = -1
    for i, p in providers:
      if p.name == name: idx = i; break
    if idx < 0:
      echo "Error: unknown provider '" & name & "' — use `claw provider add` to create it"
      quit(1)

    # Gather only flags that were actually provided
    var apiBase = $args["--api-base"]
    var envKey = $args["--env-key"]
    var defaultModel = $args["--default-model"]
    var authFlag = $args["--auth"]
    var verifyPath = $args["--verify-path"]
    var renameTo = $args["--rename"]
    if apiBase == "nil": apiBase = ""
    if envKey == "nil": envKey = ""
    if defaultModel == "nil": defaultModel = ""
    if authFlag == "nil": authFlag = ""
    if verifyPath == "nil": verifyPath = ""
    if renameTo == "nil": renameTo = ""

    if apiBase.len == 0 and envKey.len == 0 and defaultModel.len == 0 and
       authFlag.len == 0 and verifyPath.len == 0 and renameTo.len == 0:
      echo "Error: nothing to set — pass at least one of --api-base, --env-key, --default-model, --auth, --verify-path, --rename"
      quit(1)

    # Renaming: collision check + update any linked model-catalog offerings
    if renameTo.len > 0 and renameTo != name:
      for p in providers:
        if p.name == renameTo:
          echo "Error: a provider named '" & renameTo & "' already exists"
          quit(1)
      providers[idx].name = renameTo
      # Move any model offerings in res/models.json from old name → new
      let catPath = models_catalog.catalogPath()
      if catPath.len > 0:
        var cat = models_catalog.loadCatalog(catPath)
        if cat.providers.hasKey(name):
          cat.providers[renameTo] = cat.providers[name]
          cat.providers.del(name)
          models_catalog.saveCatalog(catPath, cat)

    if apiBase.len > 0:      providers[idx].apiBase = apiBase
    if envKey.len > 0:       providers[idx].envKey = envKey
    if defaultModel.len > 0: providers[idx].defaultModel = defaultModel
    if verifyPath.len > 0:   providers[idx].verifyPath = verifyPath
    if authFlag.len > 0:
      providers[idx].authHeader = case authFlag.toLowerAscii()
        of "bearer":    "Authorization: Bearer"
        of "x-api-key": "x-api-key"
        of "none":      ""
        else:
          echo "Error: --auth must be bearer|x-api-key|none"
          quit(1)
          ""

    prov_registry.saveProvidersFile(resPath, providers)
    prov_registry.invalidateBuiltinCache()
    let finalName = if renameTo.len > 0: renameTo else: name
    echo "→ Updated provider '" & finalName & "' in " & resPath
    if renameTo.len > 0 and renameTo != name:
      echo "  Renamed from '" & name & "' (model offerings moved too)"
      echo "  Note: if the env var was derived from the old name, update it with --env-key"

  # Provider remove — delete a provider entry. Custom/override entries come
  # Provider remove — delete an entry from the global catalog.
  elif args.isCommand("provider", "remove"):
    let name = $args["<name>"]
    let resPath = prov_registry.builtinProvidersPath()
    if resPath.len == 0:
      echo "Error: can't locate res/providers.json"
      quit(1)
    var kept: seq[prov_registry.ProviderDef]
    var found = false
    for p in prov_registry.effectiveProviders():
      if p.name == name: found = true
      else: kept.add(p)
    if not found:
      echo "Error: no provider named '" & name & "' in the catalog"
      quit(1)
    prov_registry.saveProvidersFile(resPath, kept)
    prov_registry.invalidateBuiltinCache()
    echo "→ Removed '" & name & "' from " & resPath
    echo "  (Affects all companies on this install.)"

  # Provider management (legacy generic dispatch)
  elif args["provider"]:
    var cfg = loadConfig(getConfigPath())
    var provArgs: seq[string]
    for a in @(args["<args>"]): provArgs.add(a)
    echo runProviderCommand(cfg, @[$args["<cmd>"]] & provArgs)

  # Channel management
  elif args["channel"]:
    var cfg = loadConfig(getConfigPath())
    var chanArgs: seq[string]
    for a in @(args["<args>"]): chanArgs.add(a)
    echo runChannelCommand(cfg, @[$args["<cmd>"]] & chanArgs)

  # Agent commands
  elif args.isCommand("agent", "list"):
    var cfg = loadConfig(getConfigPath())
    echo runAgentsCommand(cfg, @["list"])

  elif args.isCommand("agent", "caps"):
    let name = $args["<name>"]
    let basePath = getNimClawDir() / "BASE.json"
    if not fileExists(basePath):
      echo "Error: no BASE.json at " & basePath
      quit(1)
    let base = parseJson(readFile(basePath))
    let named = base{"config", "agents", "named"}
    if named == nil:
      echo "No agents defined."
      quit(1)
    var found: JsonNode = nil
    for a in named:
      if a{"name"}.getStr("").toLowerAscii() == name.toLowerAscii():
        found = a; break
    if found == nil:
      echo "Agent not found: " & name
      quit(1)
    echo "Agent: " & found{"name"}.getStr()
    echo "  Provider:   " & found{"provider"}.getStr("?")
    echo "  Model:      " & found{"model"}.getStr("?")
    if found.hasKey("role"):
      echo "  Role:       " & found{"role"}.getStr()
    if found.hasKey("workstation"):
      echo "  Workstation: " & (if found{"workstation"}.getBool(): "enabled" else: "disabled")
    let skills = found{"skills"}
    if skills != nil and skills.len > 0:
      echo "  Skills:     " & skills.getElems().mapIt(it.getStr()).join(", ")
    let tools = found{"tools"}
    if tools != nil and tools.len > 0:
      echo "  Tools (" & $tools.len & "):"
      for t in tools:
        echo "    - " & t.getStr()
    let deps = found{"deps"}
    if deps != nil and deps.len > 0:
      echo "  Deps:"
      for d in deps:
        echo "    - " & d.getStr()
    let envs = found{"envs"}
    if envs != nil and envs.len > 0:
      echo "  Env vars needed:"
      for e in envs:
        let envName = e.getStr()
        let set = getEnv(envName) != ""
        echo "    - " & envName & (if set: " (set)" else: " (NOT SET)")
    let deny = found{"deny"}
    if deny != nil and deny.len > 0:
      echo "  Denied:     " & deny.getElems().mapIt(it.getStr()).join(", ")
    let practices = found{"practices"}
    if practices != nil and practices.len > 0:
      echo "  Practices:  " & practices.getElems().mapIt(it.getStr()).join(", ")
    # Team memberships — scanned from workspace/collaboration/teams/
    let ws = getNimClawDir() / "workspace"
    let teams = agent_context.loadTeams(ws)
    var myTeams: seq[string]
    for t in teams:
      for m in t.members:
        if m.toLowerAscii() == name.toLowerAscii():
          var line = t.name
          if t.lead.toLowerAscii() == name.toLowerAscii(): line.add(" (lead)")
          myTeams.add(line); break
    if myTeams.len > 0:
      echo "  Teams:      " & myTeams.join(", ")

  # Dump the full system prompt for an agent. Useful for debugging prompt
  # wiring (memoranda, teams, handbooks, skills) without running gateway.
  elif args.isCommand("agent", "prompt"):
    let name = $args["<name>"]
    let companyDir = getNimClawDir()
    let basePath = companyDir / "BASE.json"
    if not fileExists(basePath):
      echo "Error: no BASE.json at " & basePath
      quit(1)
    let cfg = loadConfig(getConfigPath())
    # Find the agent in config (case-insensitive) so the office dir matches.
    var canonical = name
    for a in cfg.agents.named:
      if a.name.toLowerAscii() == name.toLowerAscii():
        canonical = a.name
        break
    let workspace = companyDir / "workspace"
    let officeDir = workspace / "offices" / canonical.toLowerAscii()
    if not dirExists(officeDir):
      echo "Error: no office dir at " & officeDir
      quit(1)
    let cb = newContextBuilder(officeDir, workspace, cfg.agents.named)
    cb.agentName = canonical
    for a in cfg.agents.named:
      if a.name == canonical:
        cb.allowedSkills = a.skills
        break
    echo cb.buildSystemPrompt(userID = "Owner", recipientID = canonical)

  elif args.isCommand("agent", "send"):
    let dc = newDaemonClient()
    if not dc.isRunning():
      echo "Error: gateway not running. Start with: claw gateway"
      quit(1)
    let resp = dc.callOrDie("agent.send", %*{
      "name": $args["<name>"],
      "message": $args["<message>"]
    })
    if resp.kind == JString: echo resp.getStr()
    else: echo resp.pretty(2)

  # Skills listing — docker-image-style catalog across all 3 tiers.
  elif args.isCommand("skill", "list"):
    let companyDir = getNimClawDir()
    if not dirExists(companyDir):
      echo "No company directory at " & companyDir
      echo "Run: claw company create <file.nims>"
      quit(1)
    # Derive the REFERENCE column's company prefix from companyDir itself so
    # it stays correct when NIMCLAW_DIR overrides the active-context pointer.
    let companyName = block:
      let base = companyDir.lastPathPart
      if base.startsWith(".nimclaw-"): base[".nimclaw-".len .. ^1] else: base
    var skills = listAllSkills(companyDir)

    # Sort if requested. Numeric keys default desc, text default asc.
    var sortKey = $args["--sort"]
    if sortKey == "nil": sortKey = ""
    let reverse = bool(args["--reverse"])
    if sortKey.len > 0:
      # Valid keys: tier, name, version, id, size
      let numeric = sortKey == "size"
      let descending = if reverse: not numeric else: numeric
      proc cmpSkill(a, b: SkillMeta): int =
        case sortKey
        of "tier":    cmp(a.tier, b.tier)
        of "name":    cmp(a.name.toLowerAscii, b.name.toLowerAscii)
        of "version": cmp(a.version, b.version)
        of "id":      cmp(a.id, b.id)
        of "size":    cmp(a.size, b.size)
        else:
          echo "Warning: unknown --sort key '" & sortKey & "'. Valid: tier|name|version|id|size"
          0
      skills.sort(cmpSkill, order = (if descending: SortOrder.Descending else: SortOrder.Ascending))

    var formatKind = $args["--format"]
    if formatKind == "nil": formatKind = "table"
    if formatKind == "json":
      echo formatSkillJson(skills, companyName)
    else:
      stdout.write(formatSkillTable(skills, companyName))
    quit(0)

  # Model list — canonical-first view filtered by configured providers.
  # Answers "what models can I actually use right now?" based on keys in .env.
  elif args.isCommand("model", "list"):
    let companyDir = getNimClawDir()
    var formatKind = $args["--format"]
    if formatKind == "nil": formatKind = "table"
    let latestOnly = not bool(args["--all-versions"])
    var vendorFilter = $args["--vendor"]
    if vendorFilter == "nil": vendorFilter = ""
    var ownerFilter = $args["--owner"]
    if ownerFilter == "nil": ownerFilter = ""
    if ownerFilter.len > 0 and vendorFilter.len == 0: vendorFilter = ownerFilter
    var familyFilter = $args["--family"]
    if familyFilter == "nil": familyFilter = ""
    var capFilter = $args["--has"]
    if capFilter == "nil": capFilter = ""
    var matchFilter = $args["--match"]
    if matchFilter == "nil": matchFilter = ""

    # Determine which providers have an API key configured for this company.
    # Local providers (ollama) are included here too so their models can still
    # appear in the list, but they don't count toward the "N configured" header
    # unless they actually contribute rows.
    var configured = initHashSet[string]()
    var keyedProviders = initHashSet[string]()
    for p in prov_registry.effectiveProviders():
      if p.local:
        configured.incl(p.name)
      elif readEnvValue(companyDir / ".env", p.envKey).len > 0:
        configured.incl(p.name)
        keyedProviders.incl(p.name)

    # Build canonical → [offerings] reverse index from the catalog
    let cat = models_catalog.effectiveCatalog()
    type Offering = object
      provider, providerModelId: string
      inCost, outCost: float
      keySet: bool
    var offeringsByCanonical = initTable[string, seq[Offering]]()
    for provName, pc in cat.providers.pairs:
      for m in pc.models:
        if m.canonical.len == 0: continue
        var ofr = Offering(provider: provName, providerModelId: m.id,
                           inCost: m.inputCostPer1M, outCost: m.outputCostPer1M,
                           keySet: provName in configured)
        offeringsByCanonical.mgetOrPut(m.canonical, @[]).add(ofr)

    # Build rows
    type MRow = object
      id, vendor, context, caps, cheapestVia, pricing, providers: string
      family: string     # canonical family field (e.g. "llama-3.3", "gpt-4o")
      # Raw for JSON
      rawContext: int
      rawCaps: seq[string]
      rawOfferings: seq[Offering]
    var rows: seq[MRow] = @[]

    for id, cm in cat.canonical.pairs:
      # Apply filters (vendor, family, capability, substring)
      if vendorFilter.len > 0 and cm.vendor != vendorFilter: continue
      if familyFilter.len > 0 and cm.family != familyFilter: continue
      if capFilter.len > 0 and capFilter notin cm.capabilities: continue
      if matchFilter.len > 0 and
         matchFilter.toLowerAscii() notin id.toLowerAscii(): continue

      let offerings = offeringsByCanonical.getOrDefault(id, @[])
      let availableOff = offerings.filterIt(it.keySet)
      # Only show models with at least one configured provider key
      if availableOff.len == 0: continue

      # Choose representative offering: cheapest by (in + out) cost among those
      # with known pricing; else fall back to any available offering (so users
      # still see which provider serves the model even without pricing data).
      var cheapest = Offering()
      var best = float.high
      for o in availableOff:
        let score = o.inCost + o.outCost
        if score > 0 and score < best:
          best = score
          cheapest = o
      if cheapest.provider.len == 0: cheapest = availableOff[0]

      proc fmtPrice(o: Offering): string =
        if o.inCost > 0 or o.outCost > 0:
          "$" & formatFloat(o.inCost, ffDecimal, 2) & "/$" & formatFloat(o.outCost, ffDecimal, 2)
        else: "-"

      var r = MRow(id: id, vendor: cm.vendor, family: cm.family)
      if cm.contextLength > 0:
        if cm.contextLength >= 1000: r.context = $(cm.contextLength div 1000) & "K"
        else: r.context = $cm.contextLength
      else: r.context = "-"
      r.caps = if cm.capabilities.len > 0: cm.capabilities.join(",") else: "-"
      r.cheapestVia = cheapest.provider
      r.pricing = fmtPrice(cheapest)

      # Comma-separated list of available providers
      var provList: seq[string]
      for o in availableOff: provList.add(o.provider)
      r.providers = if provList.len > 0: provList.join(",") else: "-"

      r.rawContext = cm.contextLength
      r.rawCaps = cm.capabilities
      r.rawOfferings = availableOff
      rows.add(r)

    # Uncanonical provider models — surface models that are in the catalog
    # but not linked to a canonical entry. This covers both local providers
    # (ollama) with dynamic installed models AND cloud providers (e.g.,
    # OpenCode Go) that ship models without canonical coverage.
    for p in prov_registry.effectiveProviders():
      if p.name notin configured: continue
      if not cat.providers.hasKey(p.name): continue
      for m in cat.providers[p.name].models:
        if m.canonical.len > 0: continue  # already covered by the canonical loop above
        if matchFilter.len > 0 and matchFilter.toLowerAscii() notin m.id.toLowerAscii(): continue
        if vendorFilter.len > 0 and vendorFilter.toLowerAscii() != p.name.toLowerAscii(): continue
        if familyFilter.len > 0 and m.family.toLowerAscii() != familyFilter.toLowerAscii(): continue
        if capFilter.len > 0:
          var found = false
          for c in m.capabilities:
            if c.toLowerAscii() == capFilter.toLowerAscii(): found = true; break
          if not found: continue
        let ofr = Offering(provider: p.name, providerModelId: m.id,
                           inCost: m.inputCostPer1M, outCost: m.outputCostPer1M,
                           keySet: true)
        var r = MRow(id: p.name & "/" & m.id, vendor: p.name, family: m.family)
        r.context = if m.contextLen > 0:
                      (if m.contextLen >= 1000: $(m.contextLen div 1000) & "K" else: $m.contextLen)
                    else: "-"
        let capsLabel = if p.local: "(local)" else: "(" & p.name & ")"
        r.caps = if m.capabilities.len > 0: m.capabilities.join(",") else: capsLabel
        r.cheapestVia = p.name
        r.pricing = if m.inputCostPer1M > 0 or m.outputCostPer1M > 0:
                      "$" & formatFloat(m.inputCostPer1M, ffDecimal, 2) &
                      "/$" & formatFloat(m.outputCostPer1M, ffDecimal, 2)
                    else: "-"
        r.providers = p.name
        r.rawContext = m.contextLen
        r.rawCaps = m.capabilities
        r.rawOfferings = @[ofr]
        rows.add(r)

    # --latest (default): parse each id into (vendor, family, version, size,
    # roles) then do two reductions:
    #
    #   Stage 1 — by family: group rows by (vendor, family). Within each group
    #   keep only rows whose version equals the max version in that group.
    #   Drops older generations regardless of size/role (llama-3.1 dies when
    #   llama-3.3 exists; claude-3-opus dies when claude-3.5-* exists).
    #
    #   Stage 2 — by variant: group survivors by (vendor, family, version,
    #   roles). Within each group keep only rows with the largest size.
    #   Collapses pure size variants (gemma-2-27b wins over gemma-2-9b;
    #   mixtral-8x22b wins over 8x7b).
    if latestOnly:
      var parsed: seq[ModelParts] = @[]
      for r in rows: parsed.add(parseModelId(r.id))

      # Stage 1
      var maxVerByFam = initTable[string, string]()
      for p in parsed:
        let k = p.vendor & "/" & p.family
        if k notin maxVerByFam or compareVersions(p.version, maxVerByFam[k]) > 0:
          maxVerByFam[k] = p.version
      var keptRows: seq[MRow] = @[]
      var keptParsed: seq[ModelParts] = @[]
      for i, p in parsed:
        let k = p.vendor & "/" & p.family
        if compareVersions(p.version, maxVerByFam[k]) == 0:
          keptRows.add(rows[i])
          keptParsed.add(p)

      # Stage 2
      var maxSizeByVariant = initTable[string, float]()
      for p in keptParsed:
        let k = p.vendor & "/" & p.family & ":" & p.version & ":" & p.roles.join(",")
        if k notin maxSizeByVariant or p.sizeB > maxSizeByVariant[k]:
          maxSizeByVariant[k] = p.sizeB
      rows = @[]
      for i, p in keptParsed:
        let k = p.vendor & "/" & p.family & ":" & p.version & ":" & p.roles.join(",")
        if p.sizeB == maxSizeByVariant[k]:
          rows.add(keptRows[i])

    # Sort by ID for stable output
    rows.sort(proc(a, b: MRow): int = cmp(a.id, b.id))

    if formatKind == "json":
      var arr = newJArray()
      for r in rows:
        var offs = newJArray()
        for o in r.rawOfferings:
          offs.add(%*{
            "provider": o.provider,
            "provider_model_id": o.providerModelId,
            "input_cost_per_1m_usd": o.inCost,
            "output_cost_per_1m_usd": o.outCost,
            "key_set": o.keySet
          })
        arr.add(%*{
          "model": r.id,
          "vendor": r.vendor,
          "context_length": r.rawContext,
          "capabilities": r.rawCaps,
          "offerings": offs
        })
      echo pretty(arr, 2)
      quit(0)

    # Table
    let active = readActiveContext()
    let label = if active.len > 0: active else: companyDir.lastPathPart
    # Count only providers that actually contribute a model to the output
    var contributing = initHashSet[string]()
    for r in rows:
      for o in r.rawOfferings: contributing.incl(o.provider)
    let scope = "(" & $contributing.len & " configured provider" &
                (if contributing.len == 1: "" else: "s") & ")"
    echo "Available models for " & label & " " & scope
    echo ""

    if rows.len == 0:
      if configured.len == 0:
        echo "No provider keys configured."
        echo "Configure one with: claw provider auth <name>"
      else:
        echo "No canonical models matched the current filters."
      quit(0)

    # Display MODEL without the "vendor/" prefix since VENDOR is its own column.
    proc modelDisplay(id: string): string =
      let slash = id.find('/')
      if slash >= 0: id[slash+1 .. ^1] else: id

    var wId = "MODEL".runeLen
    var wVendor = "VENDOR".runeLen
    var wCtx = "CONTEXT".runeLen
    var wCaps = "CAPABILITIES".runeLen
    var wVia = "CHEAPEST VIA".runeLen
    var wPrice = "PRICE IN/OUT".runeLen
    for r in rows:
      let m = modelDisplay(r.id)
      if m.runeLen > wId: wId = m.runeLen
      if r.vendor.runeLen > wVendor: wVendor = r.vendor.runeLen
      if r.context.runeLen > wCtx: wCtx = r.context.runeLen
      if r.caps.runeLen > wCaps: wCaps = r.caps.runeLen
      if r.cheapestVia.runeLen > wVia: wVia = r.cheapestVia.runeLen
      if r.pricing.runeLen > wPrice: wPrice = r.pricing.runeLen
    let pad = 2
    echo padDisplay("MODEL", wId + pad) &
         padDisplay("VENDOR", wVendor + pad) &
         padDisplay("CONTEXT", wCtx + pad) &
         padDisplay("CAPABILITIES", wCaps + pad) &
         padDisplay("CHEAPEST VIA", wVia + pad) &
         "PRICE IN/OUT"
    for r in rows:
      echo padDisplay(modelDisplay(r.id), wId + pad) &
           padDisplay(r.vendor, wVendor + pad) &
           padDisplay(r.context, wCtx + pad) &
           padDisplay(r.caps, wCaps + pad) &
           padDisplay(r.cheapestVia, wVia + pad) &
           r.pricing

  # Create a new Tier 2 skill in the active company's lab.
  # Scaffolds a minimal SKILL.md with frontmatter + section stubs.
  elif args.isCommand("skill", "new"):
    let name = $args["<name>"]
    # Validate kebab-case
    var validName = name.len > 0 and name[0] in {'a'..'z'}
    for c in name:
      if c notin {'a'..'z', '0'..'9', '-'}:
        validName = false
        break
    if not validName:
      echo "Error: skill name must be kebab-case (lowercase letters/digits/hyphens, starting with a letter)."
      echo "Got: '" & name & "'"
      quit(1)
    let companyDir = getNimClawDir()
    let labDir = companyDir / "workspace" / "skills"
    let skillDir = labDir / name
    if dirExists(skillDir):
      echo "Error: skill already exists at " & skillDir
      quit(1)
    createDir(skillDir)
    let title = block:
      var t = ""
      var cap = true
      for c in name:
        if c == '-':
          t.add(' '); cap = true
        elif cap:
          t.add(c.toUpperAscii); cap = false
        else: t.add(c)
      t
    let template_md = "---\n" &
      "name: " & name & "\n" &
      "version: 0.1.0\n" &
      "description: \"TODO: trigger-oriented sentence — what should call this skill\"\n" &
      "requires:\n" &
      "  tools:\n" &
      "    - reply\n" &
      "  env: []\n" &
      "---\n\n" &
      "# " & title & "\n\n" &
      "TODO: one-paragraph purpose.\n\n" &
      "## When to use\n" &
      "- TODO\n\n" &
      "## Workflow\n" &
      "1. TODO\n" &
      "2. Reply with the result\n\n" &
      "## Examples\n" &
      "- TODO: User: \"...\" → Call `tool(...)` → Reply \"...\"\n"
    writeFile(skillDir / "SKILL.md", template_md)
    echo "Created skill '" & name & "' at " & skillDir / "SKILL.md"

    # Append a BARE `skill "<name>"` line to BASE.nims. Bare means "private,
    # not ready for other companies to consume". Run `claw skill share <name>`
    # to promote to `skill "claw:<co>/<name>"` when it's ready.
    let basePath = companyDir / "BASE.nims"
    let declLine = "skill \"" & name & "\""
    if fileExists(basePath):
      let src = readFile(basePath)
      if declLine & "\n" in src or declLine & "\r\n" in src:
        echo "  (skill already declared in BASE.nims)"
      else:
        var lastIdx = -1
        var lineStart = 0
        for i, ch in src:
          if ch == '\n':
            let line = src[lineStart ..< i].strip(leading = true,
                                                   trailing = false)
            if line.startsWith("skill \"") or line.startsWith("skill  \""):
              lastIdx = i
            lineStart = i + 1
        var rewritten: string
        if lastIdx >= 0:
          rewritten = src[0 .. lastIdx] & declLine & "\n" & src[lastIdx + 1 .. ^1]
        else:
          rewritten = src
          if not rewritten.endsWith("\n"): rewritten.add("\n")
          rewritten.add(declLine & "\n")
        writeFile(basePath, rewritten)
        echo "  + Added to BASE.nims: " & declLine & "   (private — run `claw skill share " & name & "` to share)"
    echo ""
    echo "Next:"
    echo "  - Edit the SKILL.md to define triggers and workflow"
    echo "  - Update requires.tools with the actual tools this skill calls"
    echo "  - Add `uses \"" & name & "\"` to an agent in BASE.nims to wire it up"
    echo "  - Run `claw co update` to regenerate BASE.json / claw.lock"
    echo "  - Once it's ready for other companies: `claw skill share " & name & "`"

  # Remove a Tier 2 skill (lab only — refuses foundation/workstation).
  elif args.isCommand("skill", "remove"):
    let name = $args["<name>"]
    let companyDir = getNimClawDir()
    let skillDir = companyDir / "workspace" / "skills" / name
    if not dirExists(skillDir):
      # Is the name visible at another tier? Give a helpful error.
      let all = listAllSkills(companyDir)
      var foundAt = ""
      for s in all:
        if s.name == name or s.name.replace('_', '-') == name:
          foundAt = s.tier & " (" & s.path & ")"
          break
      if foundAt.len > 0:
        echo "Error: '" & name & "' is at tier " & foundAt
        echo "Only Tier 2 (company lab) skills can be removed. Foundation skills"
        echo "come from the claw distribution; workstation skills belong to agents."
      else:
        echo "Error: no Tier 2 skill named '" & name & "' at " & skillDir
      quit(1)
    # Warn if any agent uses this skill
    let baseJsonPath = companyDir / "BASE.json"
    var usingAgents: seq[string] = @[]
    if fileExists(baseJsonPath):
      try:
        let base = parseJson(readFile(baseJsonPath))
        let named = base{"config", "agents", "named"}
        if named != nil:
          for a in named:
            let skills = a{"skills"}
            if skills == nil: continue
            for s in skills:
              if s.getStr() == name:
                usingAgents.add(a{"name"}.getStr())
                break
      except: discard
    if usingAgents.len > 0:
      echo "Warning: '" & name & "' is used by: " & usingAgents.join(", ")
      echo "Remove these agents' `uses \"" & name & "\"` in BASE.nims first, or they'll"
      echo "reference a missing skill on the next `claw company create`."
      echo ""
    removeDir(skillDir)
    echo "Removed skill '" & name & "' from " & skillDir

  # Skill auth — interactively set the env vars a skill declares in its
  # SKILL.md frontmatter (`requires.env`). Values go into the active
  # company's .env. Company-scoped; never touches other companies.
  elif args.isCommand("skill", "auth"):
    let name = $args["<name>"]
    let companyDir = getNimClawDir()
    # Find the skill's SKILL.md across the standard tiers
    var skillMd = ""
    for root in [
      companyDir / "workspace" / "skills",
      companyDir / "foundation" / "skills",
      companyDir / "support" / "skills",
    ]:
      let candidate = root / name / "SKILL.md"
      if fileExists(candidate):
        skillMd = candidate
        break
    if skillMd.len == 0:
      echo "Error: no skill '" & name & "' installed in this company."
      echo "Searched: workspace/skills, foundation/skills, support/skills"
      quit(1)

    # Minimal frontmatter parse: find `requires.env:` list between --- markers.
    # (Full YAML would be overkill; the format is predictable.)
    # Indent-aware parse: find any `env:` key in the frontmatter (at any
    # nesting depth) and collect its list items. Exits the env block when
    # indentation returns to the `env:` line's level or higher.
    # Handles both top-level `requires.env` (sungrow style) and nested
    # `metadata.clawdbot.requires.env` (anygen style).
    var envs: seq[string]
    var inFrontmatter = false
    var inEnv = false
    var envIndent = -1
    let src = readFile(skillMd)
    for rawLine in src.splitLines():
      if rawLine.strip() == "---":
        if not inFrontmatter: inFrontmatter = true
        else: break
        continue
      if not inFrontmatter: continue
      let stripped = rawLine.strip(leading = true, trailing = false)
      if stripped.len == 0: continue
      let indent = rawLine.len - stripped.len
      # Exit env block when we see a non-list line at or above the env:
      # marker's indentation (a sibling or parent key).
      if inEnv and not stripped.startsWith("- ") and indent <= envIndent:
        inEnv = false
        envIndent = -1
      if stripped.startsWith("env:"):
        # Only treat as list-start if the value on the same line is empty.
        # (Inline forms like `env: []` don't need further parsing.)
        let after = stripped["env:".len .. ^1].strip()
        if after.len == 0:
          inEnv = true
          envIndent = indent
        continue
      if inEnv and stripped.startsWith("- "):
        envs.add(stripped[2 .. ^1].strip())

    if envs.len == 0:
      echo "Skill '" & name & "' declares no required env vars."
      echo "(Looked in " & skillMd & " under `requires.env`.)"
      quit(0)

    # --region: rewrite env var names to be region-scoped so the same skill
    # can hold credentials for multiple regions. Rule:
    #   SKILL_X → SKILL_<REGION>_X
    # Any var containing "REGION" is left alone (it's the selector itself),
    # as are vars that don't start with the skill's uppercase prefix.
    var region = $args["--region"]
    if region == "nil": region = ""
    if region.len > 0:
      let skillPrefix = name.toUpperAscii().replace('-', '_') & "_"
      let regionTag = region.toUpperAscii() & "_"
      var rewritten: seq[string]
      for k in envs:
        if "REGION" in k: rewritten.add(k)
        elif k.startsWith(skillPrefix):
          rewritten.add(skillPrefix & regionTag & k[skillPrefix.len .. ^1])
        else:
          rewritten.add(k)
      envs = rewritten

    let envPath = companyDir / ".env"
    let active = readActiveContext()
    let companyLabel = if active.len > 0: active else: companyDir.lastPathPart
    echo "→ Skill:    " & name & "  (" & skillMd & ")"
    echo "→ Company:  " & companyLabel & "  (" & envPath & ")"
    if region.len > 0:
      echo "→ Region:   " & region & "  (vars scoped: " & name.toUpperAscii().replace('-','_') &
           "_" & region.toUpperAscii() & "_*)"
    echo "→ Requires: " & envs.join(", ")
    echo ""
    echo "You'll be prompted for each. Leave blank to keep the current value"
    echo "(or skip if unset). Values are written only after all prompts complete."
    echo ""

    var updates: seq[(string, string)]
    for key in envs:
      let existing = readEnvValue(envPath, key)
      let marker = if existing.len > 0: " [set]" else: " [not set]"
      stdout.write "  " & key & marker & ": "
      stdout.flushFile()
      let value = readPasswordFromStdin().strip()
      echo ""
      if value.len > 0:
        updates.add((key, value))

    if updates.len == 0:
      echo "No changes."
      quit(0)

    for (k, v) in updates:
      writeEnvValue(envPath, k, v)
    echo ""
    echo "✓ wrote " & $updates.len & " value" & (if updates.len == 1: "" else: "s") &
         " to " & envPath
    echo "  Scoped to this company only — other companies keep their own .env."

  # Skill sync — opt-in re-copy of bundled skill contents into the active
  # company when the bundled version differs. `claw co update` does NOT do
  # this automatically (so old companies keep their pinned skill state);
  # this command is the explicit "yes, update my skills" trigger.
  elif args.isCommand("skill", "sync"):
    var skillFilter = $args["<name>"]
    if skillFilter == "nil": skillFilter = ""
    let companyDir = getNimClawDir()
    let scriptPath = companyDir / "BASE.nims"
    if not fileExists(scriptPath):
      echo "Error: no BASE.nims at " & scriptPath
      quit(1)

    # Re-run the company's BASE.nims with CLAW_SYNC_SKILLS=1 set. The
    # installSkill proc in clawdsl reads this env var and replaces any
    # stale bundled skill content in place.
    var srcPath = getCurrentDir() / "src"
    if not dirExists(srcPath / "claw"):
      srcPath = getAppDir() / "src"
      if not dirExists(srcPath / "claw"):
        srcPath = getAppDir().parentDir() / "src"
    var cmd = "CLAW_SYNC_SKILLS=1 nim e"
    if dirExists(srcPath / "claw"):
      cmd &= " --path:" & quoteShell(srcPath)
    cmd &= " " & quoteShell(scriptPath)
    if skillFilter.len > 0:
      echo "(Note: --name filter not yet implemented; syncing ALL bundled skills.)"
    echo "→ Syncing skills for " & companyDir & " ..."
    let exitCode = execCmd(cmd)
    if exitCode != 0: quit(exitCode)

  # Skill share/unshare — toggle a BASE.nims line between bare
  # (`skill "<name>"`) and sharable (`skill "claw:<co>/<name>"`).
  # Bare = "private, not ready for other companies to depend on".
  # Sharable = "consumers can rely on this via claw: ref".
  elif args.isCommand("skill", "share") or args.isCommand("skill", "unshare"):
    let name = $args["<name>"]
    let promote = args.isCommand("skill", "share")
    let companyDir = getNimClawDir()
    let companyName = block:
      let baseN = companyDir.lastPathPart
      if baseN.startsWith(".nimclaw-"): baseN[".nimclaw-".len .. ^1] else: baseN
    let basePath = companyDir / "BASE.nims"
    if not fileExists(basePath):
      echo "Error: no BASE.nims at " & basePath
      quit(1)
    # Also require the skill dir to exist — can't share a skill that isn't
    # here.
    let skillDir = companyDir / "workspace" / "skills" / name
    if promote and not dirExists(skillDir):
      echo "Error: no skill '" & name & "' at " & skillDir
      echo "       Create it first with `claw skill new " & name & "`."
      quit(1)

    let bareForm = "skill \"" & name & "\""
    let sharedForm = "skill \"claw:" & companyName & "/" & name & "\""
    let fromForm = if promote: bareForm else: sharedForm
    let toForm = if promote: sharedForm else: bareForm

    let src = readFile(basePath)
    var rewritten = ""
    var rewroteLine = false
    for rawLine in src.splitLines(keepEol = true):
      let stripped = rawLine.strip(leading = true, trailing = false)
      # Match the skill name in bare OR shared form. Preserve any @version
      # and comma-separated second arg by keeping everything after the quote.
      let prefixes = if promote:
        @["skill \"" & name & "\"", "skill \"" & name & "@"]
      else:
        @["skill \"claw:" & companyName & "/" & name & "\"",
          "skill \"claw:" & companyName & "/" & name & "@"]
      var matched = false
      for prefix in prefixes:
        if stripped.startsWith(prefix) and not rewroteLine:
          # Find the closing quote of the first string, preserve tail
          let firstQuote = rawLine.find('"')
          let closeQuote = rawLine.find('"', firstQuote + 1)
          if closeQuote > firstQuote:
            let indent = rawLine[0 ..< rawLine.len - stripped.len]
            let inner = rawLine[firstQuote + 1 ..< closeQuote]
            let tail = rawLine[closeQuote + 1 .. ^1]
            # Build new inner: swap bare<->shared while keeping @version suffix
            var newInner = ""
            if promote:
              let atPos = inner.find('@')
              let verSuffix = if atPos > 0: inner[atPos .. ^1] else: ""
              newInner = "claw:" & companyName & "/" & name & verSuffix
            else:
              let prefixLen = ("claw:" & companyName & "/").len
              newInner = inner[prefixLen .. ^1]  # strip the prefix, keep tail
            rewritten.add(indent & "skill \"" & newInner & "\"" & tail)
            rewroteLine = true
            matched = true
            break
      if not matched:
        rewritten.add(rawLine)

    if not rewroteLine:
      let looking = if promote: bareForm else: sharedForm
      echo "Error: no matching `" & looking & "` line in BASE.nims"
      quit(1)
    writeFile(basePath, rewritten)
    if promote:
      echo "→ Promoted '" & name & "' to sharable: " & sharedForm
      echo "  Other companies can now use it via that ref."
    else:
      echo "→ Unshared '" & name & "' — reverted to private: " & bareForm
      echo "  External refs will no longer resolve cleanly."

  # Install a skill from a claw: reference, github: ref, URL, or local path.
  elif args.isCommand("skill", "install"):
    let refStr = $args["<ref>"]
    var asAlias = $args["--as"]
    if asAlias == "nil": asAlias = ""
    let companyDir = getNimClawDir()
    let destLab = companyDir / "workspace" / "skills"
    if not dirExists(destLab):
      echo "Error: no skills dir at " & destLab & " — run `claw company create` first"
      quit(1)
    createDir(destLab)

    # Dispatch on scheme
    if refStr.startsWith("claw://"):
      echo "Error: 'claw://' is not supported — use 'claw:<company>/<skill>'"
      echo "       (no slashes after the colon)"
      quit(1)
    if refStr.startsWith("claw:"):
      # claw:<company>/<skill>[@<ref>]
      let body = refStr["claw:".len .. ^1]
      let atIdx = body.rfind('@')
      let pathPart = if atIdx >= 0: body[0 ..< atIdx] else: body
      let refPart = if atIdx >= 0: body[atIdx + 1 .. ^1] else: ""
      let parts = pathPart.split('/')
      if parts.len < 2 or parts[0].len == 0 or parts[1].len == 0:
        echo "Error: claw: reference must be claw:<company>/<skill>[@<ref>]"
        quit(1)
      let srcCompany = parts[0]
      let srcSkill = parts[1]
      let srcRoot = companyDirForName(srcCompany)
      let srcSkillDir = srcRoot / "workspace" / "skills" / srcSkill
      if not dirExists(srcSkillDir):
        echo "Error: no skill at " & srcSkillDir
        echo "Source company '" & srcCompany & "' does not have '" & srcSkill & "' in its lab."
        quit(1)
      # Version check (best-effort — warn if mismatch)
      if refPart.len > 0:
        let srcMd = srcSkillDir / "SKILL.md"
        if fileExists(srcMd):
          let (_, ver, _) = parseFrontmatterBasics(readFile(srcMd))
          let id = computeSkillId(srcMd)
          let matches = refPart == ver or refPart == id or
                        (refPart.len == 12 and id.startsWith(refPart))
          if not matches:
            echo "Warning: requested @" & refPart & " but source is version=" & ver &
                 " id=" & id
      let destName = if asAlias.len > 0: asAlias else: srcSkill
      let destSkillDir = destLab / destName
      if dirExists(destSkillDir):
        echo "Error: '" & destName & "' already installed at " & destSkillDir
        echo "Remove it first: claw skill remove " & destName
        quit(1)
      copyDir(srcSkillDir, destSkillDir)
      # If renamed via --as, rewrite `name:` in the frontmatter so the skill
      # reports itself under the new name (not just its dir).
      if asAlias.len > 0:
        let mdPath = destSkillDir / "SKILL.md"
        if fileExists(mdPath):
          var md = readFile(mdPath)
          # Conservative: rewrite only the top-level `name:` line in frontmatter
          if md.startsWith("---\n"):
            let endIdx = md.find("\n---\n", 4)
            if endIdx > 0:
              var fm = md[4 .. endIdx]
              var newFm = ""
              var rewrote = false
              for line in fm.splitLines():
                if not rewrote and line.strip().startsWith("name:") and
                   not line.startsWith(" "):
                  newFm.add("name: " & asAlias & "\n")
                  rewrote = true
                else:
                  newFm.add(line & "\n")
              if rewrote:
                md = md[0..3] & newFm & md[endIdx .. ^1]
                writeFile(mdPath, md)
      echo "Installed '" & destName & "' from " & refStr
      echo "  Source: " & srcSkillDir
      echo "  Dest:   " & destSkillDir

    elif refStr.startsWith("http://") or refStr.startsWith("https://") or
         refStr.startsWith("git@") or refStr.endsWith(".git") or
         refStr.startsWith("github:"):
      # Git clone — supports three shapes:
      #   github:owner/repo                 → whole repo IS the skill
      #   github:owner/repo/path/to/skill   → skill in a mono-repo subdir
      #   github:owner/repo[/path]@<ref>    → specific tag/branch/commit
      #   https://... | git@...             → same conventions via full URL
      var body = refStr
      if body.startsWith("github:"): body = body["github:".len .. ^1]
      # Extract @<ref> if present
      var gitRef = ""
      let atIdx = body.rfind('@')
      # Only treat '@' as a ref separator when it's AFTER the repo host —
      # skips the '@' in "git@github.com:..."
      if atIdx >= 0 and (refStr.startsWith("github:") or refStr.startsWith("http")):
        gitRef = body[atIdx + 1 .. ^1]
        body = body[0 ..< atIdx]
      # Split into repo-url + subpath
      var repoUrl = body
      var subpath = ""
      if refStr.startsWith("github:"):
        let parts = body.split('/')
        if parts.len < 2:
          echo "Error: github: form must be github:owner/repo[/path][@<ref>]"
          quit(1)
        repoUrl = "https://github.com/" & parts[0] & "/" & parts[1] & ".git"
        if parts.len > 2: subpath = parts[2 .. ^1].join("/")
      # else: plain URL, no subpath support (user can use local path trick)

      let defaultName = block:
        var n = if subpath.len > 0: subpath.lastPathPart
                else: repoUrl.splitPath.tail
        if n.endsWith(".git"): n[0 ..< n.len - 4] else: n
      # Precedence: --as > manifest's `name` > defaultName from path
      var destName = if asAlias.len > 0: asAlias else: defaultName
      if asAlias.len == 0:
        let mfPath = prov_registry.findDistributionResource("res" / "skills.json")
        if mfPath.len > 0 and fileExists(mfPath):
          try:
            let mf = parseJson(readFile(mfPath))
            let entries = mf{"skills"}
            if entries != nil and entries.hasKey(refStr):
              let nameOverride = entries[refStr]{"name"}.getStr("")
              if nameOverride.len > 0: destName = nameOverride
          except: discard
      let destSkillDir = destLab / destName
      if dirExists(destSkillDir):
        echo "Error: '" & destName & "' already installed"
        quit(1)

      # Clone to a temp location, then move just the subpath (or the whole
      # repo) into the skills dir. Using temp keeps the skills dir clean
      # when a mono-repo is big.
      let tmpClone = getTempDir() / ("claw-clone-" & $getTime().toUnix())
      removeDir(tmpClone)
      var cloneCmd = "git clone --depth 1"
      if gitRef.len > 0: cloneCmd &= " --branch " & quoteShell(gitRef)
      cloneCmd &= " " & quoteShell(repoUrl) & " " & quoteShell(tmpClone)
      echo "→ Cloning " & repoUrl & (if gitRef.len > 0: "@" & gitRef else: "")
      if execCmd(cloneCmd) != 0:
        echo "Error: git clone failed"
        removeDir(tmpClone)
        quit(1)

      let src = if subpath.len > 0: tmpClone / subpath else: tmpClone
      if not dirExists(src):
        echo "Error: clone succeeded but no directory at " & subpath
        removeDir(tmpClone)
        quit(1)
      if not fileExists(src / "SKILL.md"):
        echo "Warning: " & src & " has no SKILL.md — you may have the wrong path"
      copyDir(src, destSkillDir)
      # Remove the destination's .git if we copied the whole clone (avoid
      # turning the skill into a nested git repo by accident).
      if subpath.len == 0 and dirExists(destSkillDir / ".git"):
        removeDir(destSkillDir / ".git")
      removeDir(tmpClone)
      echo "Installed '" & destName & "' from " & refStr
      if subpath.len > 0: echo "  Subpath: " & subpath

      # Bootstrap recipes — if res/skills.json has a matching entry for this
      # ref, run its post-install steps (npm install, CLI-driven sub-skill
      # install, env var wiring). Keeps all side-effects scoped to the
      # active company.
      let skillsJsonPath = prov_registry.findDistributionResource("res" / "skills.json")
      if skillsJsonPath.len > 0 and fileExists(skillsJsonPath):
        let manifest = parseJson(readFile(skillsJsonPath))
        let entries = manifest{"skills"}
        if entries != nil and entries.kind == JObject:
          let lookupKey = refStr
          if entries.hasKey(lookupKey):
            let recipe = entries[lookupKey]
            echo ""
            echo "→ Running bootstrap for " & lookupKey
            let supportDir = companyDir / "support" / destName
            createDir(supportDir)
            let envPath = companyDir / ".env"

            # Step 1: run each bootstrap action
            let steps = recipe{"bootstrap"}
            if steps != nil and steps.kind == JArray:
              for step in steps:
                let kind = step{"kind"}.getStr("")
                case kind
                of "npm_install":
                  let pkg = step{"package"}.getStr("")
                  let bin = step{"binary"}.getStr("")
                  if pkg.len > 0:
                    echo "  ⟳ npm install -g " & pkg
                    if execCmd("npm install -g " & quoteShell(pkg)) != 0:
                      echo "  ⚠ npm install failed — install manually: npm install -g " & pkg
                    elif bin.len > 0:
                      echo "  ✓ " & bin & " available"
                of "nimble_install":
                  let pkg = step{"package"}.getStr("")
                  let bin = step{"binary"}.getStr("")
                  if pkg.len > 0:
                    echo "  ⟳ nimble install -y " & pkg
                    if execCmd("nimble install -y " & quoteShell(pkg)) != 0:
                      echo "  ⚠ nimble install failed — install manually: nimble install " & pkg
                    elif bin.len > 0:
                      echo "  ✓ " & bin & " available"
                of "cli_install_skills":
                  let cliCmd = step{"command"}.getStr("")
                  let upstreamOut = step{"upstream_output"}.getStr("")
                  let subSkillsNode = step{"sub_skills"}
                  if cliCmd.len > 0:
                    echo "  ⟳ " & cliCmd
                    if execCmd(cliCmd) != 0:
                      echo "  ⚠ bootstrap command failed"
                    elif upstreamOut.len > 0 and subSkillsNode != nil:
                      # Copy each sub-skill from upstream output into company lab
                      let upstreamExpanded = expandTilde(upstreamOut)
                      for ss in subSkillsNode:
                        let subName = ss.getStr("")
                        if subName.len == 0: continue
                        let srcSub = upstreamExpanded / subName
                        let dstSub = destLab / subName
                        if dirExists(srcSub):
                          if dirExists(dstSub):
                            echo "    ~ sub-skill already in lab: " & subName
                          else:
                            copyDir(srcSub, dstSub)
                            echo "    + installed sub-skill: " & subName
                        else:
                          echo "    ! sub-skill not found at " & srcSub
                else:
                  echo "  ! Unknown bootstrap kind: " & kind

            # Step 2: write runtime_env to .env (so agent's shell exec inherits)
            let runtimeEnv = recipe{"runtime_env"}
            if runtimeEnv != nil and runtimeEnv.kind == JObject:
              for varName, tmplNode in runtimeEnv.pairs:
                let tmpl = tmplNode.getStr("")
                # Expand {company_support} placeholder
                var value = tmpl.replace("{company_support}", companyDir / "support")
                writeEnvValue(envPath, varName, value)
                echo "  + env " & varName & "=" & value

            echo "✓ Bootstrap complete. " & destName & " ready for agent use."

    elif refStr.startsWith("./") or refStr.startsWith("/") or refStr.startsWith("~"):
      # Local filesystem
      let src = expandTilde(refStr).absolutePath
      if not dirExists(src):
        echo "Error: no directory at " & src
        quit(1)
      let destName = if asAlias.len > 0: asAlias else: src.lastPathPart
      let destSkillDir = destLab / destName
      if dirExists(destSkillDir):
        echo "Error: '" & destName & "' already installed"
        quit(1)
      copyDir(src, destSkillDir)
      echo "Installed '" & destName & "' from " & src

    else:
      # Bare name — look up a registered recipe in res/skills.json.
      # Used for skills distributed as nimble/pip packages rather than
      # cloneable git trees (e.g. `claw skill install tts` → tts.nim).
      # The recipe drives: dependency install, SKILL.md scaffold, and
      # optional bin/<name> MCP-server shim pointing at an external binary.
      let mfPath = prov_registry.findDistributionResource("res" / "skills.json")
      var recipe: JsonNode = nil
      if mfPath.len > 0 and fileExists(mfPath):
        try:
          let mf = parseJson(readFile(mfPath))
          let entries = mf{"skills"}
          if entries != nil and entries.hasKey(refStr):
            recipe = entries[refStr]
        except: discard

      if recipe == nil:
        echo "Error: unrecognized reference: " & refStr
        echo ""
        echo "Supported forms:"
        echo "  claw:<company>/<skill>[@<version|id>]   — cross-company"
        echo "  github:owner/repo[/subpath][@ref]        — github skill or mono-repo"
        echo "  https://... | git@... | *.git            — git clone"
        echo "  ./path | /abs/path | ~/path              — local directory"
        echo "  <bare-name>                              — registered recipe (see res/skills.json)"
        quit(1)

      let destName = block:
        if asAlias.len > 0: asAlias
        else:
          let n = recipe{"name"}.getStr("")
          if n.len > 0: n else: refStr
      let destSkillDir = destLab / destName
      if dirExists(destSkillDir):
        echo "Error: '" & destName & "' already installed"
        quit(1)
      createDir(destSkillDir)
      echo "→ Installing '" & destName & "' from registered recipe"

      let supportDir = companyDir / "support" / destName
      createDir(supportDir)
      let envPath = companyDir / ".env"

      let steps = recipe{"bootstrap"}
      if steps != nil and steps.kind == JArray:
        for step in steps:
          let kind = step{"kind"}.getStr("")
          case kind
          of "nimble_install":
            let pkg = step{"package"}.getStr("")
            let bin = step{"binary"}.getStr("")
            if pkg.len > 0:
              echo "  ⟳ nimble install -y " & pkg
              if execCmd("nimble install -y " & quoteShell(pkg)) != 0:
                echo "  ⚠ nimble install failed — install manually: nimble install " & pkg
                removeDir(destSkillDir)
                quit(1)
              elif bin.len > 0:
                echo "  ✓ " & bin & " available"
          of "npm_install":
            let pkg = step{"package"}.getStr("")
            let bin = step{"binary"}.getStr("")
            if pkg.len > 0:
              echo "  ⟳ npm install -g " & pkg
              if execCmd("npm install -g " & quoteShell(pkg)) != 0:
                echo "  ⚠ npm install failed — install manually: npm install -g " & pkg
              elif bin.len > 0:
                echo "  ✓ " & bin & " available"
          else:
            echo "  ! Unknown bootstrap kind: " & kind

      let skillMd = recipe{"skill_md"}.getStr("")
      if skillMd.len > 0:
        writeFile(destSkillDir / "SKILL.md", skillMd)
        echo "  + wrote SKILL.md"

      let mcpExec = recipe{"mcp_exec"}.getStr("")
      if mcpExec.len > 0:
        let binDir = destSkillDir / "bin"
        createDir(binDir)
        let shimPath = binDir / destName
        writeFile(shimPath, "#!/bin/sh\nexec " & mcpExec & " \"$@\"\n")
        discard execShellCmd("chmod +x " & quoteShell(shimPath))
        echo "  + wrote MCP shim: bin/" & destName & " → " & mcpExec

      let runtimeEnv = recipe{"runtime_env"}
      if runtimeEnv != nil and runtimeEnv.kind == JObject:
        for varName, tmplNode in runtimeEnv.pairs:
          let tmpl = tmplNode.getStr("")
          var value = tmpl.replace("{company_support}", companyDir / "support")
          writeEnvValue(envPath, varName, value)
          echo "  + env " & varName & "=" & value

      echo "✓ Installed '" & destName & "'."

  # Doctor
  elif args["doctor"]:
    let color = not bool(args["--no-color"])
    putEnv("NO_COLOR", if not color: "1" else: "")
    doctor.runDoctor(loadConfig(getConfigPath()), color)

  # Version
  elif args["version"]:
    echo "claw " & version_mod.versionString()
