import std/[asyncdispatch, tables, locks, times, json, strutils, sets, sequtils]
import ../providers/types as providers_types
import ../providers/sanitize
import ../providers/tool_loop
import ../bus
import ../bus_types
import ../agent/xml_tools
import ../tools/registry as tools_registry
import ../tools/base as tools_base
import ../schema
import ../agent/cortex
import ../config as cfg_mod

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
    mode*: string             ## Focus-mode name (from cfg.modes); empty = default.
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
                              ## as their orchestrator.
    modes*: Table[string, cfg_mod.ModeConfig]
                              ## Focus modes available to subagent tasks,
                              ## keyed by name. Looked up at spawn time.

proc newSubagentManager*(provider: providers_types.LLMProvider,
                         workspace: string, bus: MessageBus,
                         tools: tools_registry.ToolRegistry = nil,
                         graph: WorldGraph = nil,
                         maxIterations: int = 20,
                         modes: seq[cfg_mod.ModeConfig] = @[]): SubagentManager =
  var sm = SubagentManager(
    tasks: initTable[string, SubagentTask](),
    provider: provider,
    bus: bus,
    workspace: workspace,
    tools: tools,
    graph: graph,
    nextID: 1,
    maxIterations: maxIterations,
    modes: initTable[string, cfg_mod.ModeConfig]()
  )
  for m in modes: sm.modes[m.name] = m
  initLock(sm.lock)
  return sm

proc availableModes*(sm: SubagentManager): seq[cfg_mod.ModeConfig] =
  ## List the registered modes — used by the spawn tool to render its
  ## description (so the LLM sees what modes are available without
  ## the operator having to maintain a parallel list).
  for m in sm.modes.values: result.add(m)

proc isXmlToolProvider(model: string): bool =
  model.startsWith("opencode/") or model.startsWith("opencode-go/")
  # TODO: deduplicate with agent/loop.isXmlToolProvider once circular import is resolved

proc runTask*(sm: SubagentManager, task: SubagentTask) {.async.} =
  task.status = "running"
  task.created = getTime().toUnix * 1000

  # Resolve focus mode (empty = default, no override).
  let mode =
    if task.mode.len > 0 and sm.modes.hasKey(task.mode):
      sm.modes[task.mode]
    else:
      cfg_mod.ModeConfig()

  # Model resolution: mode override > agent profile override > parent's default.
  let model =
    if mode.model.len > 0: mode.model
    elif task.agentOverride.len > 0: task.agentOverride
    else: sm.provider.getDefaultModel()
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

  # Compose the system prompt: identity + mode addendum.
  # Identity stays the parent agent's — a subagent in a focus mode is
  # the same agent wearing a different hat, not a different agent.
  # Pull soul/role from the graph if available so the subagent retains
  # the agent's voice; fall back to a generic line if the graph isn't
  # accessible (older test paths construct managers without one).
  var identity = "You are " & task.originAgentName &
                 ", running a focused subtask."
  if sm.graph != nil and task.originAgentID.len > 0:
    let entID = parseAlias(task.originAgentID)
    if uint32(entID) > 0 and sm.graph.entities.hasKey(entID):
      let agentEnt = sm.graph.entities[entID]
      if agentEnt.role.len > 0:
        identity.add("\nYour role: " & agentEnt.role & ".")
      if agentEnt.jobTitle.len > 0:
        identity.add("\nYour job title: " & agentEnt.jobTitle & ".")
      if agentEnt.soul.len > 0:
        identity.add("\n\n## Your soul\n" & agentEnt.soul.strip())

  var systemPrompt = identity
  if mode.name.len > 0:
    systemPrompt.add("\n\n## Current mode: " & mode.name)
    if mode.description.len > 0:
      systemPrompt.add("\n" & mode.description)
    if mode.promptAddendum.len > 0:
      systemPrompt.add("\n\n" & mode.promptAddendum.strip())
  if useXmlTools and sm.tools != nil:
    systemPrompt.add("\n\n" & buildToolInstructions(sm.tools))

  currentMessages.add(providers_types.Message(
    role: providers_types.RoleSystem, content: systemPrompt))
  currentMessages.add(providers_types.Message(
    role: providers_types.RoleUser, content: task.task))

  var iteration = 0
  let maxIterations = sm.maxIterations
  var toolCallLog: seq[string] = @[]

  try:
    while iteration < maxIterations:
      iteration += 1

      let strategy = inferStrategy(model)

      let toolDefs =
        if useXmlTools or sm.tools == nil:
          @[]
        elif mode.uses.len > 0:
          # Mode-restricted: filter to the mode's tool whitelist
          # minus any deny entries. The deny overlay lets a mode
          # express "everything in `uses` except this small set" —
          # similar to how agent profiles already mix uses + deny.
          var allowed = mode.uses
          if mode.deny.len > 0:
            let denySet = mode.deny.toHashSet
            allowed = allowed.filterIt(it notin denySet)
          sm.tools.getDefinitionsFiltered(strategy, allowed)
        else:
          sm.tools.getDefinitions(strategy)
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
          let res = await sm.tools.executeWithContext(
            tc.name, tc.arguments, toolCtx)
          appendToolResult(currentMessages, tc, res)
          toolCallLog.add(formatToolLogEntry(tc, res, iteration))

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

proc spawn*(sm: SubagentManager,
            task, label, originChannel, originChatID, originSessionKey,
            originSenderID, originRecipientID, originRole,
            originAgentName, originAgentID, originLogicalUserID: string,
            agentOverride: string = "",
            mode: string = ""): SubagentTask =
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
    mode: mode,
    status: "running",
    created: getTime().toUnix * 1000
  )
  sm.tasks[taskID] = subagentTask
  release(sm.lock)

  discard sm.runTask(subagentTask)
  return subagentTask
