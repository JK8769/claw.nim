import std/[json, tables, strutils, options, asyncdispatch, strformat]
import types
import ../config
import ../agent/cortex
import ../providers/http as providers_http
import ../providers/types as providers_types

type
  ## Callback wired in by the gateway at AgentLoop construction time —
  ## runs the target agent's full `processDirect` path (graph reload,
  ## her own tool registry, trust gate, sessions). Returns the peer's
  ## reply text. Delegation goes through this when present so the peer
  ## actually has access to her tools (e.g. Lexi's sungrow MCP) rather
  ## than being a tool-less persona-swap LLM call.
  AskPeer* = proc(agentName, prompt, senderAlias, callerSessionKey: string): Future[string] {.async.}

  DelegateTool* = ref object of ContextualTool
    workspace*: string
    agents*: seq[NamedAgentConfig]
    fallbackApiKey*: Option[string]
    depth*: int
    askPeer*: AskPeer

proc newDelegateTool*(workspace: string, agents: seq[NamedAgentConfig] = @[], fallbackApiKey: Option[string] = none(string), depth: int = 0, askPeer: AskPeer = nil): DelegateTool =
  return DelegateTool(workspace: workspace, agents: agents, fallbackApiKey: fallbackApiKey, depth: depth, askPeer: askPeer)

method name*(t: DelegateTool): string = "delegate"
method description*(t: DelegateTool): string =
  ## Enumerate declared peers so the LLM picks a real agent (not a
  ## skill name, not a hallucinated one). Include each peer's
  ## jobTitle + skills so the LLM has enough context to route.
  var lines: seq[string] = @[
    "Delegate a sub-task to a peer agent in this company. Use when " &
    "the task requires a tool or expertise that you don't have but a " &
    "peer does — the peer answers, you relay."]
  if t.agents.len > 0:
    lines.add("")
    lines.add("Available peer agents (pick by exact name):")
    for a in t.agents:
      var bits: seq[string] = @[]
      if a.role.isSome and a.role.get().len > 0: bits.add("role: " & a.role.get())
      if a.skills.len > 0: bits.add("skills: " & a.skills.join(", "))
      let detail = if bits.len > 0: " — " & bits.join(" · ") else: ""
      lines.add("  - \"" & a.name & "\"" & detail)
  lines.join("\n")

method parameters*(t: DelegateTool): Table[string, JsonNode] =
  var agentParam = %*{
    "type": "string",
    "minLength": 1,
    "description": "Exact name of the peer agent to delegate to. Must match one of the declared agents listed in this tool's description — NOT a skill name."
  }
  # Constrain the agent name to a real enum so the LLM can't hallucinate.
  if t.agents.len > 0:
    var names = newJArray()
    for a in t.agents: names.add(%a.name)
    agentParam["enum"] = names
  {
    "type": %"object",
    "properties": %*{
      "agent": agentParam,
      "prompt": {
        "type": "string",
        "minLength": 1,
        "description": "The task/prompt to send to the peer. Include caller's nc:id, verbatim question, and any format hint (table, brief, per-plant, etc.)."
      },
      "context": {
        "type": "string",
        "description": "Optional context to prepend."
      }
    },
    "required": %["agent", "prompt"]
  }.toTable

proc findAgent(t: DelegateTool, name: string): Option[NamedAgentConfig] =
  for ac in t.agents:
    if ac.name == name: return some(ac)
  return none(NamedAgentConfig)

method execute*(t: DelegateTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("agent"): return "Error: Missing 'agent' parameter"
  let agentName = args["agent"].getStr().strip()
  if agentName.len == 0: return "Error: 'agent' parameter must not be empty"

  if not args.hasKey("prompt"): return "Error: Missing 'prompt' parameter"
  let promptText = args["prompt"].getStr().strip()
  if promptText.len == 0: return "Error: 'prompt' parameter must not be empty"

  # Guard: delegation with `Depth: simple` is a handbook anti-pattern —
  # simple queries the caller is supposed to handle directly with their
  # own tools. Refusing here forces a course-correction at the agent loop
  # level rather than letting the caller burn iterations on a delegate
  # chain that compounds into a 20-iter narration loop.
  let promptLow = promptText.toLowerAscii()
  if promptLow.contains("depth: simple") or promptLow.contains("depth:simple"):
    return "Error: `delegate` refused — the prompt is tagged `Depth: simple`, " &
           "which means YOU are supposed to handle it directly with your own " &
           "tools (sungrow, etc.). Don't delegate simple retrieval; call the " &
           "relevant tool yourself. Reserve delegation for `Depth: analytical` " &
           "or `Depth: advisory`."

  var contextText: Option[string] = none(string)
  if args.hasKey("context"): contextText = some(args["context"].getStr())

  let agentCfgOpt = t.findAgent(agentName)

  if agentCfgOpt.isSome:
    let ac = agentCfgOpt.get()
    if t.depth >= ac.maxDepth:
      return fmt"Error: Delegation depth limit reached ({t.depth}/{ac.maxDepth}) for agent '{agentName}'"
  else:
    if t.depth >= 3:
      return "Error: Delegation depth limit reached (default max_depth=3)"

  let fullPrompt = if contextText.isSome:
    fmt"Context: {contextText.get()}{'\n'}{'\n'}{promptText}"
  else:
    promptText

  # Full delegation: route through the peer's AgentLoop so she has
  # her own tool registry (MCP servers, graph access, trust gate,
  # sessions). The senderAlias passed to the peer is THIS agent's
  # nc:id (e.g. Atlas's nc:3), NOT the original customer's —
  # otherwise the peer evaluates the request at the customer's trust
  # tier and refuses her own tools. Relaying Atlas's identity lets
  # Lexi run as if a peer staff member asked, which is the semantic
  # match (agent-to-agent trust). The peer answers with real data;
  # Atlas then relays it to the customer under customer-tier policy.
  if t.askPeer != nil:
    try:
      let delegatorAlias =
        if t.agentID.len > 0: t.agentID
        else: "agent:" & t.agentName
      return await t.askPeer(agentName, fullPrompt, delegatorAlias, t.sessionKey)
    except Exception as e:
      return "Error: delegation to '" & agentName & "' failed: " & e.msg

  let graph = loadWorld(t.workspace)
  var cfg = loadConfig(getConfigPath())
  
  var tech = (model: cfg.agents.defaults.model, apiKey: "", apiBase: "")
  var sysPrompt = "You are a helpful assistant. Respond concisely."
  var temperature = 0.7

  if graph.nameIndex.hasKey(agentName):
    let aid = graph.nameIndex[agentName]
    tech = graph.resolveTechnicalConfig(aid)
    let agent = graph.entities[aid]
    if agent.soul != "": sysPrompt = agent.soul
    # For now, temperature is global default or we could add to agent node
  else:
    # Try legacy named agents from config if any
    let agentCfgOpt = t.findAgent(agentName)
    if agentCfgOpt.isSome:
      let ac = agentCfgOpt.get()
      if ac.model.len > 0: tech.model = ac.model
      if ac.apiKey.isSome: tech.apiKey = ac.apiKey.get()
      if ac.systemPrompt.isSome: sysPrompt = ac.systemPrompt.get()
      if ac.temperature.isSome: temperature = ac.temperature.get()

  # If graph resolution left apiBase empty (common — agent graph
  # entities don't carry usesConfig), fall back to the agent's
  # declared `provider` in cfg.agents.named and read credentials from
  # the top-level providers vault. This mirrors what the main agent
  # loop does when constructing its own provider, keeping delegate's
  # tech resolution consistent with the rest of the system.
  if tech.apiBase == "":
    var providerKey = ""
    for ac in t.agents:
      if ac.name == agentName:
        providerKey = ac.provider
        if tech.model == "" or tech.model == cfg.agents.defaults.model:
          if ac.model.len > 0: tech.model = ac.model
        break
    if providerKey == "" and tech.model.contains("/"):
      providerKey = tech.model.split("/")[0]
    if providerKey == "": providerKey = cfg.default_provider
    if providerKey != "" and graph.providers != nil and
       graph.providers.hasKey(providerKey):
      let pNode = graph.providers[providerKey]
      if tech.apiKey == "": tech.apiKey = expandEnv(pNode{"apiKey"}.getStr(""))
      tech.apiBase = expandEnv(pNode{"apiBase"}.getStr(""))

  try:
    let provider = createProvider(tech.model, tech.apiKey, tech.apiBase)
    let messages = @[
      providers_types.Message(role: providers_types.RoleSystem, content: sysPrompt),
      providers_types.Message(role: providers_types.RoleUser, content: fullPrompt)
    ]
    var options = initTable[string, JsonNode]()
    options["temperature"] = %temperature
    
    let response = await provider.chat(messages, @[], tech.model, options)
    return response.content
  except Exception as e:
    return fmt"Error: Delegation to agent '{agentName}' failed: {e.msg}"
