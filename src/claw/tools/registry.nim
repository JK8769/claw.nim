import std/[asyncdispatch, tables, json, locks, times, strutils, sets, algorithm, options]
import types, ../mcp
import ../logger
import ../providers/types as providers_types
import ../schema
import registry/manifest as tool_manifest
export tool_manifest

const
  ExternalUserRoles = ["guest", "customer"]
  # Heartbeat allowlist: maintenance-shaped tools only. The heartbeat
  # session ("Check if there are any tasks I should be aware of...")
  # has been the dominant token sink because the agent saw all 30+
  # tool schemas every tick and reached for them open-endedly (clock
  # was the top one — redundant with the time already in the prompt;
  # mcp_sungrow_* polled APIs on every tick; `social action=redeem` was
  # being hallucinated). The minimum useful set for "scan inbox, deliver
  # queued forwards, review memory, escalate if urgent":
  #   - read_file / list_dir   review HEARTBEAT.md, scan mail/
  #   - forward                deliver queued cross-user messages
  #   - social action=update   apply pending name updates
  #   - reply                  high-priority output (per prompt's
  #                            "do NOT communicate unless urgent")
  #   - delegate               hand urgent work to a peer agent
  # If a faster cadence on a specific tool is needed, schedule a
  # separate cron task — that cost is visible as cron, not heartbeat.
  # Synthetic sender id the gateway uses when the heartbeat service
  # invokes processDirect — agent/loop matches on this to apply the
  # allowlist below.
  SystemHeartbeatSender* = "system:heartbeat"
  MaxToolNameLen* = 64
  MaxResultSize* = 30_000

# SSOT: tool name lists derive from the framework manifest.
# Every list with `XxxSafe = true` / `externalAllowed = true` /
# `category = "..."` in `registry/manifest.nim`. Initialized at
# module load. Edit the manifest to change the list — never edit a
# hand-maintained const here.
let HeartbeatAllowedTools* = tool_manifest.heartbeatSafeToolNames()
let ExternalAllowedTools* = tool_manifest.externalAllowedToolNames()

const
  TaxonomyExcludedTags = ["core"]  ## Tags that are not shown as discoverable groups

type
  ToolRegistry* = ref object
    tools: Table[string, Tool]
    hiddenTools: HashSet[string]  ## Tool names registered as hidden (deferred loading)
    prefixAliases: Table[string, string]  ## expanded name -> prefix (e.g., "playwright" -> "pw")
    mcpClients: Table[string, McpClient] # serverName -> client
    sessionMcpServers: Table[string, HashSet[string]] # sessionKey -> set of serverNames
    sessionTools: Table[string, HashSet[string]] # sessionKey -> set of sanitized tool names
    lock: Lock

proc fnv32a*(s: string): uint32 =
  ## FNV-32a hash — deterministic, portable, no dependencies.
  ## Used for tool name collision disambiguation.
  result = 2166136261'u32
  for c in s:
    result = result xor uint32(c)
    result = result * 16777619'u32

proc toHexLower(v: uint32): string =
  const digits = "0123456789abcdef"
  result = newString(8)
  var n = v
  for i in countdown(7, 0):
    result[i] = digits[n and 0xF]
    n = n shr 4

proc sanitizeToolName*(name: string): string =
  ## Ensures a tool name is safe for LLM providers (DeepSeek, OpenAI, etc).
  ## Allows: a-z, A-Z, 0-9, _, -
  ## Enforces 64-char max length with FNV-32a hash suffix for truncated names.
  result = ""
  for c in name:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      result.add(c)
    else:
      result.add('_')
  if result.len > MaxToolNameLen:
    # Truncate to 55 chars + "_" + 8 hex hash = 64
    let h = fnv32a(name)  # Hash the ORIGINAL name for stability
    result = result[0..54] & "_" & toHexLower(h)

proc newToolRegistry*(): ToolRegistry =
  ## Creates a new, thread-safe ToolRegistry.
  ##
  runnableExamples:
    let tr = newToolRegistry()
    doAssert tr.count == 0
  ##
  var tr = ToolRegistry(
    tools: initTable[string, Tool](),
    hiddenTools: initHashSet[string](),
    prefixAliases: initTable[string, string](),
    mcpClients: initTable[string, McpClient](),
    sessionMcpServers: initTable[string, HashSet[string]](),
    sessionTools: initTable[string, HashSet[string]]()
  )
  initLock(tr.lock)
  return tr

proc register*(r: ToolRegistry, tool: Tool, hidden: bool = false, allowOverride: bool = false) =
  ## Registers a tool. Hidden tools can be executed but their schemas
  ## are not sent to the LLM unless activated via find_tools.
  ## First registration wins unless allowOverride is true.
  acquire(r.lock)
  defer: release(r.lock)
  let sname = sanitizeToolName(tool.name())
  if r.tools.hasKey(sname) and not allowOverride:
    warnCF("tool", "Tool name conflict, keeping existing", {"name": sname}.toTable)
    return
  r.tools[sname] = tool
  if hidden:
    r.hiddenTools.incl(sname)

proc registerHidden*(r: ToolRegistry, tool: Tool, allowOverride: bool = false) =
  ## Convenience wrapper: registers a tool as hidden.
  r.register(tool, hidden = true, allowOverride = allowOverride)

proc isHidden*(r: ToolRegistry, name: string): bool =
  acquire(r.lock)
  defer: release(r.lock)
  sanitizeToolName(name) in r.hiddenTools

proc addPrefixAlias*(r: ToolRegistry, expanded, prefix: string) =
  ## Register a prefix alias so find_tools can resolve expanded names to prefixed tool names.
  ## e.g., addPrefixAlias("playwright", "pw") means find_tools("playwright") matches pw_* tools.
  acquire(r.lock)
  defer: release(r.lock)
  r.prefixAliases[expanded.toLowerAscii()] = prefix.toLowerAscii()

proc registerMcpServer*(tr: ToolRegistry, command: string, args: seq[string] = @[], sessionKey: string = "", sandbox: seq[string] = @[], namePrefix: string = "", hidden: bool = true): Future[void] {.async.} =
  let client = await connectMcpServer(command, args, sandbox)
  if namePrefix.len > 0:
    client.namePrefix = namePrefix

  acquire(tr.lock)
  tr.mcpClients[client.serverName] = client
  # Record alias so find_tools("playwright") matches "pw_*" tools by name
  if namePrefix.len > 0:
    tr.prefixAliases[client.serverName.toLowerAscii()] = namePrefix.toLowerAscii()
  if sessionKey != "":
    if not tr.sessionMcpServers.hasKey(sessionKey):
      tr.sessionMcpServers[sessionKey] = initHashSet[string]()
    tr.sessionMcpServers[sessionKey].incl(client.serverName)
  release(tr.lock)

  let mcpTools = await client.listTools()
  for t in mcpTools:
    if hidden:
      tr.registerHidden(t)
    else:
      tr.register(t)
  if sessionKey != "":
    acquire(tr.lock)
    if not tr.sessionTools.hasKey(sessionKey):
      tr.sessionTools[sessionKey] = initHashSet[string]()
    for t in mcpTools:
      tr.sessionTools[sessionKey].incl(sanitizeToolName(t.name()))
    release(tr.lock)
  infoCF("tool", "Registered MCP server tools", {"server": client.serverName, "count": $mcpTools.len, "hidden": $hidden}.toTable)

proc getSessionTools*(r: ToolRegistry, sessionKey: string): seq[string] =
  ## Return all tool names registered via MCP servers tied to this session.
  ## Used by the agent loop to auto-expose an agent's workstation-forged tools.
  acquire(r.lock)
  defer: release(r.lock)
  if not r.sessionTools.hasKey(sessionKey): return
  for toolName in r.sessionTools[sessionKey]:
    result.add(toolName)

proc unregister*(r: ToolRegistry, name: string) =
  acquire(r.lock)
  defer: release(r.lock)
  r.tools.del(sanitizeToolName(name))

proc unregisterMcpServer*(r: ToolRegistry, serverName: string) =
  acquire(r.lock)
  let ok = r.mcpClients.hasKey(serverName)
  var client: McpClient = nil
  if ok:
    client = r.mcpClients[serverName]
    r.mcpClients.del(serverName)
  release(r.lock)

  if client != nil:
    client.stop()
    
    # Remove all tools prefixed with mcp_[serverName]_
    let prefix = "mcp_" & serverName & "_"
    var toRemove: seq[string] = @[]
    
    acquire(r.lock)
    for k in r.tools.keys:
      if k.startsWith(prefix):
        toRemove.add(k)
    for k in toRemove:
      r.tools.del(k)
    release(r.lock)
    infoCF("tool", "Unregistered MCP server tools", {"server": serverName, "count": $toRemove.len}.toTable)

proc stopAllMcpClients*(r: ToolRegistry) =
  ## Stops all registered MCP clients and clears the registry.
  var clients: seq[McpClient] = @[]
  acquire(r.lock)
  for c in r.mcpClients.values:
    clients.add(c)
  r.mcpClients.clear()
  r.tools.clear() # Optional: also clear tools associated with MCPs
  release(r.lock)
  
  for client in clients:
    try: client.stop()
    except: discard

proc purgeSession*(r: ToolRegistry, sessionKey: string) =
  var servers: seq[string] = @[]
  acquire(r.lock)
  if r.sessionMcpServers.hasKey(sessionKey):
    for s in r.sessionMcpServers[sessionKey]:
      servers.add(s)
    r.sessionMcpServers.del(sessionKey)
  if r.sessionTools.hasKey(sessionKey):
    r.sessionTools.del(sessionKey)
  release(r.lock)
  
  for s in servers:
    r.unregisterMcpServer(s)

proc get*(r: ToolRegistry, name: string): (Tool, bool) =
  acquire(r.lock)
  defer: release(r.lock)
  let sname = sanitizeToolName(name)
  if r.tools.hasKey(sname):
    return (r.tools[sname], true)
  else:
    return (nil, false)

proc sortedKeys(r: ToolRegistry): seq[string] =
  ## Returns tool names in sorted order (deterministic for KV cache stability).
  for k in r.tools.keys:
    result.add(k)
  result.sort()

proc list*(r: ToolRegistry): seq[string] =
  ## Returns a list of all registered tool names in sorted order.
  acquire(r.lock)
  defer: release(r.lock)
  return r.sortedKeys()

proc count*(r: ToolRegistry): int =
  ## Returns the total number of registered tools.
  acquire(r.lock)
  defer: release(r.lock)
  r.tools.len

proc getSummaries*(r: ToolRegistry): seq[string] =
  acquire(r.lock)
  defer: release(r.lock)
  for k in r.sortedKeys():
    let tool = r.tools[k]
    result.add("- `" & k & "` - " & tool.description())

proc hasHiddenTools*(r: ToolRegistry): bool =
  acquire(r.lock)
  defer: release(r.lock)
  r.hiddenTools.len > 0

proc listByPrefix*(r: ToolRegistry, prefix: string): seq[string] =
  ## Registered tool names starting with `prefix` (case-insensitive).
  ## Used by skill-scope resolution: `mcp_<skill>_*` pulls every tool
  ## the skill's MCP server currently exposes straight from the live
  ## registry, no cached tool list required.
  let lower = prefix.toLowerAscii
  if lower.len == 0: return
  acquire(r.lock)
  defer: release(r.lock)
  for k in r.tools.keys:
    if k.toLowerAscii.startsWith(lower): result.add(k)

proc kwOverlap(needle, haystack: string): bool {.inline.} =
  ## Substring/equality match used by every searchTools scoring branch.
  ## Both strings must already be lowercased by the caller.
  needle == haystack or needle in haystack or haystack in needle

proc searchTools*(r: ToolRegistry, keywords: seq[string]): seq[tuple[name, description: string]] =
  ## Search tools by keywords. Scoring tiers (gap reflects signal strength):
  ##   name        7  — direct intent; LLM already knows the tool
  ##   primary tag 5  — decays by position to a floor of 2 (later tags less canonical)
  ##   searchKeys  4  — author-curated task vocabulary (e.g. "modify" → edit_file)
  ##   searchHint  3  — short curated phrase, fallback for unknown names
  ##   description 1  — tie-breaker only; descriptions are noisy
  ## Results sorted by score descending. The 7→5→4→3→1 spread is wide enough
  ## that a name match always outranks any combination of weaker signals.
  acquire(r.lock)
  defer: release(r.lock)
  # Pre-lowercase keywords once
  var kwLows: seq[string] = @[]
  for kw in keywords:
    if kw.len >= 2: kwLows.add(kw.toLowerAscii())
  # Collect prefixes that have wrappers — tools starting with these are internal MCP backing
  var wrappedPrefixes: seq[string] = @[]
  for expanded, prefix in r.prefixAliases.pairs:
    wrappedPrefixes.add(prefix & "_")

  var scored: seq[tuple[name, description: string, score: int]] = @[]
  for sname, tool in r.tools.pairs:
    let tname = sname.toLowerAscii()  # Keys are already sanitized at registration
    # Skip internal MCP tools that have a wrapper (e.g. pw_browser_navigate → use playwright)
    var isWrapped = false
    for wp in wrappedPrefixes:
      if tname.startsWith(wp):
        isWrapped = true
        break
    if isWrapped: continue
    # Pre-normalize per-tool fields once (description, tags, hint, searchKeywords) —
    # the inner keyword loop runs len(kwLows) times, so any per-keyword normalization
    # would multiply the work. Manifest lookup is also hoisted here: O(1) via the
    # cached name table in registry/manifest.nim.
    let tdesc = tool.description().toLowerAscii()
    var tagsLow: seq[string] = @[]
    for tag in tool.tags(): tagsLow.add(tag.toLowerAscii())
    let thint = tool.searchHint.toLowerAscii()
    var keywordsLow: seq[string] = @[]
    let manifestEntry = tool_manifest.toolByName(sname)
    if manifestEntry.isSome:
      for kw in manifestEntry.get.searchKeywords:
        keywordsLow.add(kw.toLowerAscii())
    var score = 0
    for kwLow in kwLows:
      # Name match — 7pts (direct intent, LLM knows what it wants)
      if kwLow in tname:
        score += 7
      else:
        # Check prefix aliases: "playwright" -> "pw" means "playwright" matches "pw_click"
        for expanded, prefix in r.prefixAliases.pairs:
          if kwLow in expanded and tname.startsWith(prefix & "_"):
            score += 7
            break
      # Tag match — positional: primary tag 5pts, decays to 2pts minimum
      for i, tagLow in tagsLow:
        if kwOverlap(kwLow, tagLow):
          score += max(5 - i, 2)
          break
      # searchHint match — 3pts (vocabulary bridge for unknown tools)
      if thint.len > 0 and kwLow in thint:
        score += 3
      # searchKeywords match — 4pts (deliberate task-vocabulary added by
      # tool author for discovery; e.g. "modify"/"change" matches edit_file
      # even though those words aren't in name or description)
      for kwSpec in keywordsLow:
        if kwOverlap(kwLow, kwSpec):
          score += 4
          break
      # Description match — 1pt (tie-breaker)
      if kwLow in tdesc: score += 1
    if score > 0:
      scored.add((name: sname, description: tool.description(), score: score))
  scored.sort(proc(a, b: tuple[name, description: string, score: int]): int = b.score - a.score)
  for s in scored:
    result.add((name: s.name, description: s.description))

proc getTagGroups*(r: ToolRegistry): Table[string, int] =
  ## Returns a map of tag -> number of tools with that tag.
  acquire(r.lock)
  defer: release(r.lock)
  result = initTable[string, int]()
  for tool in r.tools.values:
    for tag in tool.tags():
      let tl = tag.toLowerAscii()
      if result.hasKey(tl):
        result[tl] += 1
      else:
        result[tl] = 1

proc getSummariesFiltered*(r: ToolRegistry, allowed: seq[string]): seq[string] =
  var allowedSet = initHashSet[string]()
  for a in allowed:
    allowedSet.incl(sanitizeToolName(a))
  acquire(r.lock)
  defer: release(r.lock)
  for k in r.sortedKeys():
    if allowedSet.contains(k):
      result.add("- `" & k & "` - " & r.tools[k].description())


proc toolToSchema*(tool: Tool, strategy: CleaningStrategy): ToolDefinition =
  let rawParams = %*(tool.parameters())
  # Ensure parameters have "type": "object" wrapper — required by strict providers (DeepSeek, OpenAI)
  var params = rawParams
  if params.kind != JObject or not params.hasKey("type") or params["type"].getStr() != "object":
    # Wrap bare properties in proper JSON Schema object
    var wrapped = newJObject()
    wrapped["type"] = %"object"
    if params.kind == JObject and params.len > 0:
      wrapped["properties"] = params
    else:
      wrapped["properties"] = newJObject()
    params = wrapped
  let cleanedParams = cleanForStrategy(params, strategy)
  ToolDefinition(
    `type`: "function",
    function: ToolFunctionDefinition(
      name: sanitizeToolName(tool.name()),
      description: tool.description(),
      parameters: cleanedParams
    )
  )

proc getDefinitions*(r: ToolRegistry, strategy: CleaningStrategy): seq[ToolDefinition] =
  acquire(r.lock)
  defer: release(r.lock)
  for k in r.sortedKeys():
    result.add(toolToSchema(r.tools[k], strategy))

proc getDefinitionsFiltered*(r: ToolRegistry, strategy: CleaningStrategy, allowed: seq[string]): seq[ToolDefinition] =
  var allowedSet = initHashSet[string]()
  for a in allowed:
    allowedSet.incl(sanitizeToolName(a))
  acquire(r.lock)
  defer: release(r.lock)
  for k in r.sortedKeys():
    if allowedSet.contains(k):
      result.add(toolToSchema(r.tools[k], strategy))

proc isWrappedInternal(r: ToolRegistry, name: string): bool =
  ## Returns true if the tool is an internal MCP backing tool with a wrapper.
  let tl = name.toLowerAscii()
  for expanded, prefix in r.prefixAliases.pairs:
    if tl.startsWith(prefix & "_"): return true
  return false

proc getSummariesEager*(r: ToolRegistry, activated: HashSet[string] = initHashSet[string]()): seq[string] =
  ## Summaries for tools whose schemas are actually loaded for the LLM
  ## in deferred mode: non-hidden tools + tools the LLM has activated via
  ## `find_tools`. Hidden-but-not-activated tools go through the taxonomy
  ## block (see `generateTaxonomy`) rather than the main "Available
  ## Tools" list, so the LLM isn't tempted to call them with guessed
  ## parameters before their schema is loaded.
  acquire(r.lock)
  defer: release(r.lock)
  for k in r.sortedKeys():
    if r.isWrappedInternal(k): continue
    if k in r.hiddenTools and k notin activated: continue
    result.add("- `" & k & "` - " & r.tools[k].description())

proc getSummariesEagerFiltered*(r: ToolRegistry, allowed: seq[string],
                                activated: HashSet[string] = initHashSet[string]()): seq[string] =
  ## Same as `getSummariesFiltered` but also drops hidden-not-activated
  ## tools. For deferred-mode agents that also have a ClawDSL scope.
  var allowedSet = initHashSet[string]()
  for a in allowed:
    allowedSet.incl(sanitizeToolName(a))
  acquire(r.lock)
  defer: release(r.lock)
  for k in r.sortedKeys():
    if not allowedSet.contains(k): continue
    if k in r.hiddenTools and k notin activated: continue
    result.add("- `" & k & "` - " & r.tools[k].description())

proc getDefinitionsDeferred*(r: ToolRegistry, strategy: CleaningStrategy, activated: HashSet[string] = initHashSet[string]()): tuple[definitions: seq[ToolDefinition], hiddenNames: seq[string]] =
  ## Returns full schemas for core (non-hidden) + activated tools,
  ## and a list of hidden tool names (for system prompt taxonomy).
  ## Internal MCP tools with wrappers (e.g. pw_*) are always excluded.
  acquire(r.lock)
  defer: release(r.lock)
  var defs: seq[ToolDefinition] = @[]
  var hidden: seq[string] = @[]
  for k in r.sortedKeys():
    if r.isWrappedInternal(k): continue  # Never expose internal MCP backing tools
    if k notin r.hiddenTools or k in activated:
      defs.add(toolToSchema(r.tools[k], strategy))
    else:
      hidden.add(k)
  return (definitions: defs, hiddenNames: hidden)

proc generateTaxonomy*(r: ToolRegistry): string =
  ## Generates a taxonomy string for hidden tools, grouped by their primary tag.
  ## Format: "  tag_name (N) — tool1, tool2, tool3"
  ## Used in the system prompt so the LLM knows what's available via find_tools.
  acquire(r.lock)
  defer: release(r.lock)

  # Collect hidden tools grouped by their first non-excluded tag
  var tagTools = initTable[string, seq[string]]()  # tag -> tool names
  var assignedTools = initHashSet[string]()

  for k in r.sortedKeys():
    if k notin r.hiddenTools: continue
    if r.isWrappedInternal(k): continue  # Skip internal MCP backing tools
    let tool = r.tools[k]
    var assigned = false
    for tag in tool.tags():
      let tl = tag.toLowerAscii()
      if tl in TaxonomyExcludedTags: continue
      if not tagTools.hasKey(tl):
        tagTools[tl] = @[]
      tagTools[tl].add(k)
      assigned = true
    if not assigned:
      # Untagged hidden tools go under "other"
      if not tagTools.hasKey("other"):
        tagTools["other"] = @[]
      tagTools["other"].add(k)

  if tagTools.len == 0:
    return ""

  # Build taxonomy string — pick the most specific tag per tool
  # (tools appear under multiple tags in tagTools, but that's fine for discovery)
  # Deduplicate: only show groups that have tools not fully covered by other groups
  var lines: seq[string] = @[]
  var sortedTags: seq[string] = @[]
  for t in tagTools.keys: sortedTags.add(t)
  sortedTags.sort()

  for tag in sortedTags:
    let tools = tagTools[tag]
    let toolList = if tools.len <= 5: tools.join(", ")
                   else: tools[0..4].join(", ") & ", ..."
    lines.add("  " & tag & " (" & $tools.len & ") — " & toolList)

  return lines.join("\n")

proc executeWithContext*(r: ToolRegistry, name: string, args: Table[string, JsonNode], ctx: ToolContext): Future[string] {.async.} =
  infoCF("tool", "Tool execution started", {"tool": name, "args": $args, "role": ctx.role, "entity": ctx.entity, "identity": ctx.identity}.toTable)

  let (tool, ok) = r.get(name)
  if not ok:
    errorCF("tool", "Tool not found", {"tool": name}.toTable)
    return "Error: tool '" & name & "' not found"

  # Block direct calls to wrapped internal tools — LLM should use the wrapper
  let sname = sanitizeToolName(name)
  if r.isWrappedInternal(sname):
    let wrapper = block:
      var found = ""
      for expanded, prefix in r.prefixAliases.pairs:
        if sname.toLowerAscii().startsWith(prefix & "_"):
          found = expanded
          break
      found
    warnCF("tool", "Blocked direct call to wrapped internal tool", {"tool": sname, "wrapper": wrapper}.toTable)
    return "Error: '" & sname & "' is an internal tool. Use the '" & wrapper & "' tool instead with action parameter."

  let roleLow = ctx.role.toLowerAscii()
  # Safety net for un-configured external users; skipped when the caller
  # has already authorised via ctx.preAuthorized.
  if roleLow in ExternalUserRoles and not ctx.preAuthorized:
    let tname = sanitizeToolName(name)
    if tname notin ExternalAllowedTools:
      return "Error: Tool '" & tname & "' is not available for external users."

  if tool of ContextualTool and ctx.channel != "" and ctx.chatID != "":
    (cast[ContextualTool](tool)).setContext(ctx)

  # Validate required parameters before executing
  if args.len == 0:
    let params = tool.parameters()
    if params.hasKey("required") and params["required"].kind == JArray:
      var missing: seq[string] = @[]
      for r in params["required"]:
        let key = r.getStr()
        if key.len > 0 and not args.hasKey(key):
          missing.add(key)
      if missing.len > 0:
        let msg = "Error: Missing required parameter(s): " & missing.join(", ") & ". Call " & name & " again with the required arguments."
        warnCF("tool", "Skipping tool with missing required args", {"tool": name, "missing": missing.join(", ")}.toTable)
        return msg

  let start = now()
  var result = ""
  try:
    result = await tool.execute(args)
  except Exception as e:
    let duration = (now() - start).inMilliseconds
    errorCF("tool", "Tool execution failed", {"tool": name, "duration": $duration, "error": e.msg}.toTable)
    return "Error: " & e.msg

  let duration = (now() - start).inMilliseconds
  if result.len > MaxResultSize:
    let fullLen = result.len
    result = result[0..<MaxResultSize] & "\n\n[Output truncated at " & $MaxResultSize & " chars (full size: " & $fullLen & "). Request a narrower query or use pagination.]"
    warnCF("tool", "Tool output truncated", {"tool": name, "full_size": $fullLen, "truncated_to": $MaxResultSize}.toTable)
  infoCF("tool", "Tool execution completed", {"tool": name, "duration_ms": $duration, "result_length": $result.len}.toTable)
  return result
