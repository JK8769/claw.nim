import std/[asyncdispatch, tables, locks, times, json, strutils]
import ../providers/types as providers_types
import ../providers/sanitize
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
    maxIterations*: int       ## Per-task tool-call ceiling. Match the
                              ## parent agent's `max_tool_iterations`
                              ## so subagents have the same headroom
                              ## as their orchestrator. The previous
                              ## hardcoded `5` was too low for any
                              ## non-trivial analytical work — most
                              ## subagent failures we saw were
                              ## "max iterations reached" silent
                              ## failures, not real model failures.

proc newSubagentManager*(provider: providers_types.LLMProvider, workspace: string, bus: MessageBus, tools: tools_registry.ToolRegistry = nil, graph: WorldGraph = nil, maxIterations: int = 20): SubagentManager =
  var sm = SubagentManager(
    tasks: initTable[string, SubagentTask](),
    provider: provider,
    bus: bus,
    workspace: workspace,
    tools: tools,
    graph: graph,
    nextID: 1,
    maxIterations: maxIterations
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
    currentMessages.add(providers_types.Message(role: providers_types.RoleSystem, content: systemPrompt))
  else:
    currentMessages.add(providers_types.Message(role: providers_types.RoleSystem, content: "You are a subagent. Complete the given task independently and report the result."))
  
  currentMessages.add(providers_types.Message(role: providers_types.RoleUser, content: task.task))

  var iteration = 0
  let maxIterations = sm.maxIterations
  var toolCallLog: seq[string] = @[]

  try:
    while iteration < maxIterations:
      iteration += 1

      let strategy = inferStrategy(model)

      let toolDefs = if useXmlTools or sm.tools == nil: @[] else: sm.tools.getDefinitions(strategy)
      # Keep history protocol-clean before sending (parallel to the
      # main agent loop's per-iteration sanitize at loop.nim:629). A
      # subagent that drifts mid-loop hits the same 400s as the
      # main loop did before bcfa025.
      sanitizeForProvider(currentMessages)
      let response = await sm.provider.chat(currentMessages, toolDefs, model, initTable[string, JsonNode]())

      if useXmlTools:
        let xmlCalls = parseXmlToolCalls(response.content)
        if xmlCalls.len == 0:
          task.result = response.content
          break

        currentMessages.add(providers_types.Message(
          role: providers_types.RoleAssistant, content: response.content,
          reasoning_content: response.reasoning_content))

        var xmlResults: seq[XmlToolResult] = @[]
        for xmlCall in xmlCalls:
          let result = await sm.tools.executeWithContext(xmlCall.name, xmlCall.arguments, toolCtx)
          xmlResults.add(XmlToolResult(name: xmlCall.name, output: result, success: not result.startsWith("Error:")))
          let preview = if result.len > 80: result[0..79] & "..." else: result
          toolCallLog.add("[" & $iteration & "] " & xmlCall.name & " → " & preview)

        currentMessages.add(providers_types.Message(role: providers_types.RoleUser, content: formatToolResults(xmlResults)))
      else:
        if response.tool_calls.len == 0:
          task.result = response.content
          break

        currentMessages.add(providers_types.Message(
          role: providers_types.RoleAssistant, content: response.content,
          reasoning_content: response.reasoning_content,
          tool_calls: response.tool_calls))

        for tc in response.tool_calls:
          let result = await sm.tools.executeWithContext(tc.name, tc.arguments, toolCtx)
          currentMessages.add(providers_types.Message(role: providers_types.RoleTool, content: result, tool_call_id: tc.id, name: tc.name))
          let preview = if result.len > 80: result[0..79] & "..." else: result
          toolCallLog.add("[" & $iteration & "] " & tc.name & " → " & preview)

    acquire(sm.lock)
    task.status = "completed"
    if task.result == "":
      # Diagnostic-rich failure message instead of "No response from
      # model". Tells the operator (and the parent agent) what the
      # subagent actually attempted before bailing.
      var msg = "Subagent ran to its iteration ceiling (" & $maxIterations &
                ") without emitting a final answer."
      if toolCallLog.len > 0:
        msg.add("\n\nWhat it tried:\n" & toolCallLog.join("\n"))
      else:
        msg.add(" No tool calls were made — model returned empty " &
                "responses every iteration.")
      msg.add("\n\nRaise `agents.defaults.maxToolIterations` in BASE.nims " &
              "if the task genuinely needs more steps, or " &
              "split the task into smaller subagents.")
      task.result = msg
    release(sm.lock)
  except Exception as e:
    acquire(sm.lock)
    task.status = "failed"
    task.result = "Error: " & e.msg
    if toolCallLog.len > 0:
      task.result.add("\n\nTool calls before failure:\n" &
                      toolCallLog.join("\n"))
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
