## Active company context.
##
## A developer managing multiple companies uses `claw company use <name>` to
## pick the one they're working on. The choice persists at ~/.config/claw/active
## until they `use` another.
##
## Resolution order for commands (in config.nim's getNimClawDir):
##   1. $NIMCLAW_DIR           — one-off override (scripts, CI)
##   2. ~/.config/claw/active  — persistent "active company" pointer
##   3. ~/.nimclaw             — default fallback

import std/[os, strutils, json, times, tables]

proc activeContextFile*(): string =
  ## Path to the file holding the active company's name.
  let cfgHome = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  cfgHome / "claw" / "active"

proc readActiveContext*(): string =
  ## Returns the active company name (e.g. "SunGrow") or "" if unset.
  let path = activeContextFile()
  if not fileExists(path): return ""
  try: return readFile(path).strip()
  except: return ""

proc writeActiveContext*(name: string) =
  ## Persist the active company name. Creates the config dir if needed.
  let path = activeContextFile()
  createDir(path.parentDir)
  writeFile(path, name & "\n")

proc clearActiveContext*() =
  let path = activeContextFile()
  if fileExists(path):
    try: removeFile(path)
    except: discard

proc companyDirForName*(name: string): string =
  ## Map a bare company name → filesystem path. E.g. "SunGrow" → ~/.nimclaw-SunGrow.
  ## If the name looks like a path already (contains / or starts with ~), returns it as-is.
  if name.len == 0: return ""
  if name.startsWith("~") or "/" in name:
    return expandTilde(name)
  return getHomeDir() / (".nimclaw-" & name)

proc listCompanies*(): seq[tuple[name, path: string]] =
  ## Enumerate every ~/.nimclaw-<name>/ directory on this host (names + paths only).
  let home = getHomeDir()
  if not dirExists(home): return
  for kind, entry in walkDir(home):
    if kind != pcDir: continue
    let base = entry.lastPathPart
    if not base.startsWith(".nimclaw-"): continue
    # Exclude ~/.nimclaw (default/unnamed) from the company list
    if base.len <= ".nimclaw-".len: continue
    result.add((name: base[".nimclaw-".len .. ^1], path: entry))

# ── Richer inspection for `claw company list` ────────────────────

type
  CompanyInfo* = object
    name*: string            ## short name (e.g. "SunGrow")
    path*: string            ## absolute dir
    owner*: string           ## SuperAdmin Person's name (from @graph)
    agents*: int             ## declared agent count (from BASE.json)
    skills*: int             ## count of Tier 2 skills in workspace/skills
    providers*: seq[string]  ## provider names configured
    description*: string     ## from @graph Corporate entity
    modified*: Time          ## mtime of BASE.nims (or BASE.json if nims missing)
    totalTokens*: int64      ## cumulative LLM tokens used, summed from activity logs
    valid*: bool             ## false if BASE.json is missing/unreadable

proc formatTokens*(n: int64): string =
  ## Compact human-readable token count: "1,234" / "12.3K" / "1.2M" / "2.5B".
  if n < 1000: return $n
  if n < 1_000_000:
    let k = n.float / 1000.0
    return formatFloat(k, ffDecimal, 1) & "K"
  if n < 1_000_000_000:
    let m = n.float / 1_000_000.0
    return formatFloat(m, ffDecimal, 1) & "M"
  let b = n.float / 1_000_000_000.0
  return formatFloat(b, ffDecimal, 1) & "B"

proc relativeTime*(t: Time): string =
  ## Human-friendly "2h ago", "today", "3 days ago".
  let delta = now().toTime() - t
  let secs = delta.inSeconds
  if secs < 60: return "just now"
  if secs < 3600: return $(secs div 60) & "m ago"
  if secs < 86400:
    let h = secs div 3600
    if h < 6: return $h & "h ago"
    return "today"
  let days = secs div 86400
  if days == 1: return "yesterday"
  if days < 14: return $days & " days ago"
  if days < 60: return $(days div 7) & " weeks ago"
  if days < 730: return $(days div 30) & " months ago"
  return $(days div 365) & " years ago"

proc providerTokensUsage*(companyDir: string): Table[string, int64] =
  ## Sum tokens per provider across all offices' activity logs.
  ## Attribution: each `start` entry names the provider; later `inference`
  ## entries with the same taskId inherit it. Unknown tasks (e.g. whose
  ## `start` was rotated out) are attributed to "unknown".
  ##
  ## Resolves the special alias "default" to the first provider in
  ## the BASE.json `providers` list (post-Phase-4 ordering is the
  ## source of truth — there's no separate `default_provider` field).
  result = initTable[string, int64]()

  # Resolve "default" → providers list[0]
  var defaultProvider = "default"
  let basePath = companyDir / "BASE.json"
  if fileExists(basePath):
    try:
      let j = parseJson(readFile(basePath))
      if j.hasKey("providers") and j["providers"].kind == JObject:
        for k, _ in j["providers"].fields:
          defaultProvider = k
          break
    except: discard

  let offices = companyDir / "workspace" / "offices"
  if not dirExists(offices): return

  for kind, officePath in walkDir(offices):
    if kind != pcDir: continue
    # Map taskId → provider for THIS office (tasks don't cross offices)
    var taskProvider = initTable[string, string]()
    for fn in ["activity.jsonl.1", "activity.jsonl"]:  # read archive first, current last
      let p = officePath / fn
      if not fileExists(p): continue
      try:
        for line in lines(p):
          let trimmed = line.strip()
          if not trimmed.startsWith("{"): continue
          try:
            let j = parseJson(trimmed)
            let action = j{"action"}.getStr()
            let taskId = j{"taskId"}.getStr()
            case action
            of "start":
              var prov = j{"provider"}.getStr()
              if prov == "default" or prov.len == 0: prov = defaultProvider
              if taskId.len > 0: taskProvider[taskId] = prov
            of "inference":
              let tokens = j{"tokens"}.getInt()
              if tokens <= 0: continue
              let prov = if taskId.len > 0 and taskProvider.hasKey(taskId):
                taskProvider[taskId]
              else: "unknown"
              if result.hasKey(prov): result[prov] += tokens
              else: result[prov] = tokens
            else: discard
          except: discard
      except: discard

proc inspectCompany*(dir: string): CompanyInfo =
  ## Read a company dir and extract summary info. Non-fatal on errors —
  ## fields that couldn't be read stay empty and `valid` is set false.
  result.path = dir
  result.name = block:
    let base = dir.lastPathPart
    if base.startsWith(".nimclaw-"): base[".nimclaw-".len .. ^1] else: base

  # Modified time — prefer BASE.nims (user intent); fall back to BASE.json
  let nimsPath = dir / "BASE.nims"
  let jsonPath = dir / "BASE.json"
  try:
    if fileExists(nimsPath): result.modified = getLastModificationTime(nimsPath)
    elif fileExists(jsonPath): result.modified = getLastModificationTime(jsonPath)
  except: discard

  # Parse BASE.json for agents, providers, description
  if fileExists(jsonPath):
    try:
      let j = parseJson(readFile(jsonPath))
      let named = j{"config", "agents", "named"}
      if named != nil: result.agents = named.len
      let provs = j{"providers"}
      if provs != nil and provs.kind == JObject:
        for k, _ in provs.pairs: result.providers.add(k)
      # Walk @graph once to extract description (Corporate) and owner (SuperAdmin Person)
      let g = j{"@graph"}
      if g != nil:
        for entry in g:
          case entry{"kind"}.getStr()
          of "Corporate":
            if result.description.len == 0:
              result.description = entry{"description"}.getStr("")
          of "Person":
            if result.owner.len == 0 and
               entry{"permission-group"}.getStr() == "SuperAdmin":
              result.owner = entry{"name"}.getStr("")
          else: discard
      result.valid = true
    except: discard

  # Skill count from workspace/skills (Tier 2 only — the admin's scope).
  # Also scan legacy workspace/lab/skills for companies pre-refactor.
  for sd in [dir / "workspace" / "skills",
             dir / "workspace" / "lab" / "skills"]:
    if dirExists(sd):
      for kind, _ in walkDir(sd):
        if kind == pcDir: inc result.skills
      break   # only count once, current path wins

  # Total LLM tokens across all agents — summed from activity.jsonl files.
  # Each inference entry has shape: {"action":"inference","tokens":N,...}
  # We parse each line; malformed lines are ignored.
  let offices = dir / "workspace" / "offices"
  if dirExists(offices):
    for kind, officePath in walkDir(offices):
      if kind != pcDir: continue
      # Rotated archive + current log
      for fn in ["activity.jsonl", "activity.jsonl.1"]:
        let p = officePath / fn
        if not fileExists(p): continue
        try:
          for line in lines(p):
            let trimmed = line.strip()
            if not trimmed.startsWith("{"): continue
            # Fast path: skip lines that can't possibly contain token info
            if "\"tokens\"" notin trimmed: continue
            try:
              let j = parseJson(trimmed)
              if j{"tokens"}.getInt() > 0:
                result.totalTokens += j{"tokens"}.getInt()
            except: discard
        except: discard
