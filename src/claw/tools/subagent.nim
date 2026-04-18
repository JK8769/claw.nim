import std/[asyncdispatch, tables, locks, times, json, strutils]
import ../providers/types as providers_types
import ../bus
import ../bus_types
import ../agent/xml_tools
import ../tools/registry as tools_registry
import ../tools/base as tools_base
import ../schema
import ../agent/cortex

type
  SubagentTask* = ref object
    id*: string
    task*: string
    label*: string
    originChannel*: string
    originChatID*: string
    originSessionKey*: string
    originSenderID*: string
    originRecipientID*: string
    originRole*: string
    originAgentName*: string
    originAgentID*: string
    originLogicalUserID*: string
    agentOverride*: string
    status*: string
    result*: string
    created*: int64

  SubagentManager* = ref object
    tasks*: Table[string, SubagentTask]
    lock*: Lock
    provider*: providers_types.LLMProvider
    bus*: MessageBus
    workspace*: string
    tools*: tools_registry.ToolRegistry
    graph*: WorldGraph
    nextID*: int

proc newSubagentManager*(provider: providers_types.LLMProvider, workspace: string, bus: MessageBus, tools: tools_registry.ToolRegistry = nil, graph: WorldGraph = nil): SubagentManager =
  var sm = SubagentManager(
    tasks: initTable[string, SubagentTask](),
    provider: provider,
    bus: bus,
    workspace: workspace,
    tools: tools,
    graph: graph,
    nextID: 1
  )
  initLock(sm.lock)
  return sm

proc isXmlToolProvider(model: string): bool =
  model.startsWith("opencode/") or model.startsWith("opencode-go/")
  # TODO: deduplicate with agent/loop.isXmlToolProvider once circular import is resolved

proc runTask*(sm: SubagentManager, task: SubagentTask) {.async.} =
  task.status = "running"
  task.created = getTime().toUnix * 1000

  let model = if task.agentOverride != "": task.agentOverride else: sm.provider.getDefaultModel()
  let useXmlTools = isXmlToolProvider(model)
  let toolCtx = tools_base.ToolContext(
    channel: task.originChannel,
    chatID: task.originChatID,
    sessionKey: task.originSessionKey,
    senderID: task.originSenderID,
    recipientID: task.originRecipientID,
    role: task.originRole,
    agentName: task.originAgentName,
    agentID: task.originAgentID,
    logicalUserID: task.originLogicalUserID,
    graph: sm.graph
  )
  
  var currentMessages: seq[providers_types.Message] = @[]
  
  if useXmlTools and sm.tools != nil:
    let systemPrompt = "You are a subagent. Complete the given task independently and report the result.\n\n" & 
                      buildToolInstructions(sm.tools)
    currentMessages.add(providers_types.Message(role: "system", content: systemPrompt))
  else:
    currentMessages.add(providers_types.Message(role: "system", content: "You are a subagent. Complete the given task independently and report the result."))
  
  currentMessages.add(providers_types.Message(role: "user", content: task.task))

  var iteration = 0
  let maxIterations = 5

  try:
    while iteration < maxIterations:
      iteration += 1
      
      let strategy = inferStrategy(model)

      let toolDefs = if useXmlTools or sm.tools == nil: @[] else: sm.tools.getDefinitions(strategy)
      let response = await sm.provider.chat(currentMessages, toolDefs, model, initTable[string, JsonNode]())

      if useXmlTools:
        let xmlCalls = parseXmlToolCalls(response.content)
        if xmlCalls.len == 0:
          task.result = response.content
          break
        
        currentMessages.add(providers_types.Message(role: "assistant", content: response.content))
        
        var xmlResults: seq[XmlToolResult] = @[]
        for xmlCall in xmlCalls:
          let result = await sm.tools.executeWithContext(xmlCall.name, xmlCall.arguments, toolCtx)
          xmlResults.add(XmlToolResult(name: xmlCall.name, output: result, success: not result.startsWith("Error:")))
        
        currentMessages.add(providers_types.Message(role: "user", content: formatToolResults(xmlResults)))
      else:
        if response.tool_calls.len == 0:
          task.result = response.content
          break
        
        currentMessages.add(providers_types.Message(role: "assistant", content: response.content, tool_calls: response.tool_calls))
        
        for tc in response.tool_calls:
          let result = await sm.tools.executeWithContext(tc.name, tc.arguments, toolCtx)
          currentMessages.add(providers_types.Message(role: "tool", content: result, tool_call_id: tc.id, name: tc.name))

    acquire(sm.lock)
    task.status = "completed"
    if task.result == "": task.result = "No response from model (max iterations reached)"
    release(sm.lock)
  except Exception as e:
    acquire(sm.lock)
    task.status = "failed"
    task.result = "Error: " & e.msg
    release(sm.lock)

  if sm.bus != nil:
    let announceContent = strutils.format("Task '$1' completed.\n\nResult:\n$2", task.label, task.result)
    sm.bus.publishInbound(InboundMessage(
      channel: task.originChannel,
      sender_id: "system:subagent:" & task.id,
      chat_id: task.originChatID,
      content: announceContent,
      session_key: task.originSessionKey
    ))

proc spawn*(sm: SubagentManager, task, label, originChannel, originChatID, originSessionKey, originSenderID, originRecipientID, originRole, originAgentName, originAgentID, originLogicalUserID: string, agentOverride: string = ""): SubagentTask =
  acquire(sm.lock)
  let taskID = "subagent-" & $sm.nextID
  sm.nextID += 1

  let subagentTask = SubagentTask(
    id: taskID,
    task: task,
    label: label,
    originChannel: originChannel,
    originChatID: originChatID,
    originSessionKey: originSessionKey,
    originSenderID: originSenderID,
    originRecipientID: originRecipientID,
    originRole: originRole,
    originAgentName: originAgentName,
    originAgentID: originAgentID,
    originLogicalUserID: originLogicalUserID,
    agentOverride: agentOverride,
    status: "running",
    created: getTime().toUnix * 1000
  )
  sm.tasks[taskID] = subagentTask
  release(sm.lock)

  discard sm.runTask(subagentTask)
  return subagentTask
