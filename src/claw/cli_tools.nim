## `claw tools` CLI subcommand implementations.
##
## list   — enumerate framework tools with metadata, filterable by
##          domain / default-status / heartbeat-safety
## show   — full ToolSpec for one tool (text or JSON)
## validate — runs the manifest-vs-registry consistency check;
##          exits non-zero on drift (CI-friendly)
##
## Reads the framework manifest at `tools/registry/manifest.nim` —
## this is the single source of truth for "what tools exist."
## Per-agent grants/revokes (the future `grant`/`revoke` actions) are
## a separate concern handled by the resolver, not by this module.

import std/[json, os, times, strutils, options, sequtils, algorithm]
import tools/spec
import tools/registry/manifest as tool_manifest

proc fmtCheck(b: bool): string = (if b: "✓" else: " ")

proc renderListTable(specs: seq[ToolSpec]): string =
  ## Pretty-print a list of ToolSpecs as a fixed-width table.
  if specs.len == 0: return "No tools match the filters."
  var rows: seq[(string, string, string, string, string)] = @[]
  rows.add(("NAME", "DOMAIN", "DEFAULT", "HBSAFE", "DESCRIPTION"))
  for s in specs:
    rows.add((s.name, s.domain, fmtCheck(s.default), fmtCheck(s.heartbeatSafe), s.description))
  # Compute widths
  var w1, w2, w3, w4 = 0
  for r in rows:
    if r[0].len > w1: w1 = r[0].len
    if r[1].len > w2: w2 = r[1].len
    if r[2].len > w3: w3 = r[2].len
    if r[3].len > w4: w4 = r[3].len
  result = ""
  for i, r in rows:
    let line = r[0].alignLeft(w1 + 2) & r[1].alignLeft(w2 + 2) &
               r[2].alignLeft(w3 + 2) & r[3].alignLeft(w4 + 2) & r[4]
    result.add(line)
    result.add("\n")
    if i == 0:
      # underline the header
      result.add("-".repeat(w1 + w2 + w3 + w4 + 8 + 40))
      result.add("\n")
  result.add("\n" & $specs.len & " tool(s).\n")

proc renderListJson(specs: seq[ToolSpec]): string =
  let arr = newJArray()
  for s in specs:
    arr.add(%*{
      "name": s.name,
      "description": s.description,
      "tags": s.tags,
      "domain": s.domain,
      "default": s.default,
      "heartbeat_safe": s.heartbeatSafe,
      "category": s.category,
      "version": s.version
    })
  $arr

proc runToolsList*(args: seq[string]): string =
  ## `claw tools list [--domain=<d>] [--default] [--heartbeat-safe] [--format=<fmt>]`
  var domainFilter = ""
  var onlyDefault = false
  var onlyHeartbeat = false
  var fmt = "table"
  for a in args:
    if a.startsWith("--domain="): domainFilter = a[9 .. ^1]
    elif a == "--default": onlyDefault = true
    elif a == "--heartbeat-safe": onlyHeartbeat = true
    elif a.startsWith("--format="): fmt = a[9 .. ^1]
  var specs: seq[ToolSpec] = @[]
  for s in tool_manifest.AllTools:
    if domainFilter.len > 0 and s.domain != domainFilter: continue
    if onlyDefault and not s.default: continue
    if onlyHeartbeat and not s.heartbeatSafe: continue
    specs.add(s)
  specs.sort(proc(a, b: ToolSpec): int = cmp(a.name, b.name))
  case fmt
  of "json": return renderListJson(specs)
  else: return renderListTable(specs)

proc runToolsShow*(name: string, fmt: string = "text"): string =
  ## `claw tools show <name> [--format=<fmt>]`
  let opt = tool_manifest.toolByName(name)
  if opt.isNone:
    return "Tool not found in manifest: " & name &
           "\nUse `claw tools list` to see available names." &
           "\nNote: MCP-forged tools (mcp_*) are dynamic and not in the manifest."
  let s = opt.get()
  case fmt
  of "json":
    return $(%*{
      "name": s.name,
      "description": s.description,
      "tags": s.tags,
      "domain": s.domain,
      "default": s.default,
      "heartbeat_safe": s.heartbeatSafe,
      "category": s.category,
      "version": s.version
    })
  else:
    result = "Tool: " & s.name & "\n"
    result.add("  Description:    " & s.description & "\n")
    result.add("  Domain:         " & s.domain & "\n")
    result.add("  Category:       " & s.category & "\n")
    result.add("  Tags:           " & s.tags.join(", ") & "\n")
    result.add("  Default:        " & (if s.default: "yes (auto-granted to every agent)" else: "no (opt-in via skill)") & "\n")
    result.add("  Heartbeat-safe: " & (if s.heartbeatSafe: "yes (callable during heartbeat ticks)" else: "no") & "\n")
    result.add("  Version:        " & s.version & "\n")

proc runToolsGrant*(serviceDir, toolName, agentName, byUser: string): string =
  ## `claw tools grant <name> --agent <a>` — add an entry to
  ## `<serviceDir>/tool_grants.json`. Idempotent. Operator must run
  ## `claw co update` (no restart needed for the file write itself —
  ## but the in-memory tool list per agent is materialized at
  ## `claw co update` time, so that step IS required).
  let toolOpt = tool_manifest.toolByName(toolName)
  if toolOpt.isNone:
    return "Error: tool '" & toolName & "' not found in manifest. " &
           "Use `claw tools list` to see available names."
  let path = serviceDir / "tool_grants.json"
  var j: JsonNode
  if fileExists(path):
    try: j = parseJson(readFile(path))
    except CatchableError: j = newJObject()
  else:
    j = newJObject()
  if j.kind != JObject: j = newJObject()
  if not j.hasKey("grants"): j["grants"] = newJArray()
  if not j.hasKey("revokes"): j["revokes"] = newJArray()
  # Idempotent: if already granted, don't add a duplicate
  for g in j["grants"]:
    if g{"agent"}.getStr().toLowerAscii == agentName.toLowerAscii and
       g{"tool"}.getStr() == toolName:
      return "Already granted: " & toolName & " → " & agentName
  # Remove any matching revoke (grant supersedes)
  var newRevokes = newJArray()
  for r in j["revokes"]:
    if not (r{"agent"}.getStr().toLowerAscii == agentName.toLowerAscii and
            r{"tool"}.getStr() == toolName):
      newRevokes.add(r)
  j["revokes"] = newRevokes
  let nowTs = epochTime()
  j["grants"].add(%*{
    "agent": agentName,
    "tool": toolName,
    "ts": nowTs,
    "by": byUser
  })
  try: writeFile(path, pretty(j, 2))
  except CatchableError as e: return "Error: failed to write " & path & ": " & e.msg
  return "Granted " & toolName & " → " & agentName & ". " &
         "Run `claw co update` to materialize into BASE.json " &
         "(restart not required if gateway re-reads on next prompt build)."

proc runToolsRevoke*(serviceDir, toolName, agentName, byUser: string): string =
  ## `claw tools revoke <name> --agent <a>` — add a revoke entry.
  ## Revokes are the final word — they remove the tool even if it
  ## would otherwise be granted via defaults or a skill.
  let path = serviceDir / "tool_grants.json"
  var j: JsonNode
  if fileExists(path):
    try: j = parseJson(readFile(path))
    except CatchableError: j = newJObject()
  else:
    j = newJObject()
  if j.kind != JObject: j = newJObject()
  if not j.hasKey("grants"): j["grants"] = newJArray()
  if not j.hasKey("revokes"): j["revokes"] = newJArray()
  for r in j["revokes"]:
    if r{"agent"}.getStr().toLowerAscii == agentName.toLowerAscii and
       r{"tool"}.getStr() == toolName:
      return "Already revoked: " & toolName & " ← " & agentName
  # Remove any matching grant (revoke supersedes)
  var newGrants = newJArray()
  for g in j["grants"]:
    if not (g{"agent"}.getStr().toLowerAscii == agentName.toLowerAscii and
            g{"tool"}.getStr() == toolName):
      newGrants.add(g)
  j["grants"] = newGrants
  let nowTs = epochTime()
  j["revokes"].add(%*{
    "agent": agentName,
    "tool": toolName,
    "ts": nowTs,
    "by": byUser
  })
  try: writeFile(path, pretty(j, 2))
  except CatchableError as e: return "Error: failed to write " & path & ": " & e.msg
  return "Revoked " & toolName & " ← " & agentName & ". " &
         "Run `claw co update` to materialize into BASE.json."

proc runToolsValidate*(): tuple[ok: bool, output: string] =
  ## `claw tools validate` — static manifest consistency check.
  ## Exits non-zero on drift. Doesn't talk to the running gateway —
  ## that's the boot-time guard's job. This validates the manifest
  ## itself: name uniqueness, domain non-empty, version present.
  var issues: seq[string] = @[]
  var seenNames: seq[string] = @[]
  for s in tool_manifest.AllTools:
    if s.name in seenNames:
      issues.add("DUPLICATE name in manifest: " & s.name)
    seenNames.add(s.name)
    if s.name.len == 0:
      issues.add("Empty name in manifest entry")
    if s.domain.len == 0:
      issues.add("Empty domain for tool: " & s.name)
    if s.version.len == 0:
      issues.add("Empty version for tool: " & s.name)
    if s.description.len == 0:
      issues.add("Empty description for tool: " & s.name)
  if issues.len == 0:
    return (true, "Manifest validation: OK (" & $tool_manifest.AllTools.len & " tools)")
  var report = "Manifest validation: FAIL (" & $issues.len & " issue(s))\n"
  for i, issue in issues:
    report.add("  " & $(i + 1) & ". " & issue & "\n")
  (false, report)
