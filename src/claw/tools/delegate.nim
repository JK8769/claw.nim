import std/[json, tables, strutils, options, asyncdispatch, strformat]
import types
import ../config
import ../agent/cortex
import ../providers/http as providers_http
import ../providers/types as providers_types

type
  DelegateTool* = ref object of ContextualTool
    workspace*: string
    agents*: seq[NamedAgentConfig]
    fallbackApiKey*: Option[string]
    depth*: int

proc newDelegateTool*(workspace: string, agents: seq[NamedAgentConfig] = @[], fallbackApiKey: Option[string] = none(string), depth: int = 0): DelegateTool =
  return DelegateTool(workspace: workspace, agents: agents, fallbackApiKey: fallbackApiKey, depth: depth)

method name*(t: DelegateTool): string = "delegate"
method description*(t: DelegateTool): string = "Delegate a subtask to a specialized agent. Use when a task benefits from a different model."
method parameters*(t: DelegateTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "agent": {
        "type": "string",
        "minLength": 1,
        "description": "Name of the agent to delegate to"
      },
      "prompt": {
        "type": "string",
        "minLength": 1,
        "description": "The task/prompt to send to the sub-agent"
      },
      "context": {
        "type": "string",
        "description": "Optional context to prepend"
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
    
    # Fallback for provider resolution if still empty
    if tech.apiKey == "":
      let providerKey = if tech.model.contains("/"): tech.model.split("/")[0] else: cfg.default_provider
      if graph.providers.hasKey(providerKey):
        let pNode = graph.providers[providerKey]
        tech.apiKey = pNode{"apiKey"}.getStr("")
        tech.apiBase = pNode{"apiBase"}.getStr("")

  try:
    let provider = createProvider(tech.model, tech.apiKey, tech.apiBase)
    let messages = @[
      providers_types.Message(role: "system", content: sysPrompt),
      providers_types.Message(role: "user", content: fullPrompt)
    ]
    var options = initTable[string, JsonNode]()
    options["temperature"] = %temperature
    
    let response = await provider.chat(messages, @[], tech.model, options)
    return response.content
  except Exception as e:
    return fmt"Error: Delegation to agent '{agentName}' failed: {e.msg}"
