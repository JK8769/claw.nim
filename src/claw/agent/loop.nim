import std/[json, strutils, asyncdispatch, tables, locks, os, options, sets]
import ../bus, ../bus_types, ../config, ../logger, ../providers/types as providers_types, ../session, ../utils
import context as agent_context
import xml_tools
import ../schema
import ../tools/registry as tools_registry
import ../tools/base as tools_base
import ../tools/loop_detector
import ../tools/[filesystem, edit, shell, spawn, subagent, web, message, reply, forward, remember, memory_unified, http_request, git, pushover, screenshot, image_info, image_analyze, browser_open, hardware_unified, delegate, cron, find, mcp_unified, invite, query_graph, skill_install, config_tools, tasks_unified, update_contact, jq, clock, lark, playwright, learn_skill, provider_auth, model_list]
import ../services/cron as cron_service
import curly
import ../lib/malebolgia
import ../skills/installer as skills_installer
import ../skills/loader as skills_loader
import cortex, invites, times

type
  ActionType* = enum
    atStart = "start"
    atFinish = "finish"
    atCancel = "cancel"
    atInference = "inference"
    atToolCall = "tool_call"
    atStatus = "status"

  TaskContext* = ref object
    id*: string
    openedAt*: string
    tokensTotal*: int
    responseSent*: bool

type
  ProcessOptions* = object
    sessionKey*: string
    senderID*: string
    recipientID*: string
    channel*: string
    chatID*: string
    chatKind*: ChatKind
    replyToMessageID*: string
    appID*: string
    userMessage*: string
    defaultResponse*: string
    enableSummary*: bool
    sendResponse*: bool
    userRole*: string
    streamIntermediary*: bool

  AgentLoop* = ref object
    cfg*: Config
    bus*: MessageBus
    provider*: LLMProvider
    workspace*: string
    officeDir*: string
    agentName*: string
    role*: string
    entity*: string
    identity*: string
    model*: string
    contextWindow*: int
    temperature*: float
    maxIterations*: int
    sessions*: SessionManager
    contextBuilder*: ContextBuilder
    tools*: ToolRegistry
    findTool*: FindTools
    cronService*: CronService
    running*: bool
    summarizing*: Table[string, bool]
    summarizingLock*: Lock
    taskCounter*: int
    agentId*: string
    curly*: Curly  # shared HTTP client, closed in stop()
    # Per-agent capability scoping (resolved by ClawDSL → BASE.json)
    allowedTools*: seq[string]  ## If non-empty, only these tools exposed to LLM
    memTool*: UnifiedMemoryTool  ## retained for per-turn sender/trust refresh
    turnAllowedTools*: seq[string]
      ## Dispatch-time allow-list from the current requester's role.grant.
      ## Computed per turn by setRequesterTurnContext. Empty = unrestricted.
      ## When non-empty, tool calls not in this list are refused BEFORE
      ## execution — the role.grant list becomes authoritative, not cosmetic.
    deniedTools*: seq[string]   ## Tool names to exclude
    workstationEnabled*: bool   ## Auto-expose this agent's forged workstation tools

proc stop*(al: AgentLoop) =
  al.running = false
  if al.tools != nil:
    al.tools.stopAllMcpClients()
  if al.curly != nil:
    try: al.curly.close()
    except: discard

proc registerTool*(al: AgentLoop, tool: Tool) =
  al.tools.register(tool)

proc estimateTokens(messages: seq[providers_types.Message]): int =
  var total = 0
  for m in messages:
    total += m.content.len div 4
  return total

proc summarizeBatch(al: AgentLoop, batch: seq[providers_types.Message], existingSummary: string): Future[string] {.async.} =
  var prompt = "Provide a concise summary of this conversation segment, preserving core context and key points.\n"
  if existingSummary != "":
    prompt.add("Existing context: " & existingSummary & "\n")
  prompt.add("\nCONVERSATION:\n")
  for m in batch:
    prompt.add(m.role & ": " & m.content & "\n")

  let response = await al.provider.chat(@[providers_types.Message(role: "user", content: prompt)], @[], al.model, initTable[string, JsonNode]())
  return response.content

proc summarizeSession(al: AgentLoop, sessionKey: string) {.async.} =
  let history = al.sessions.getHistory(sessionKey)
  let summary = al.sessions.getSummary(sessionKey)

  if history.len <= 4: return
  let toSummarize = history[0 .. ^5]

  # Oversized Message Guard
  let maxMessageTokens = al.contextWindow div 2
  var validMessages: seq[providers_types.Message] = @[]
  for m in toSummarize:
    if m.role == "user" or m.role == "assistant":
      if (m.content.len div 4) < maxMessageTokens:
        validMessages.add(m)

  if validMessages.len == 0: return

  let finalSummary = await al.summarizeBatch(validMessages, summary)

  if finalSummary != "":
    al.sessions.setSummary(sessionKey, finalSummary)
    al.sessions.truncateHistory(sessionKey, 4)
    al.sessions.save(al.sessions.getOrCreate(sessionKey))

const MaxJournalSize = 1_000_000 # 1MB before rotation

proc appendJournal(al: AgentLoop, entry: JsonNode) =
  ## Append a JSON entry to activity.jsonl with size-based rotation.
  let journalPath = al.officeDir / "activity.jsonl"
  try:
    if fileExists(journalPath) and getFileSize(journalPath) > MaxJournalSize:
      let archivePath = al.officeDir / "activity.jsonl.1"
      try: removeFile(archivePath)
      except: discard
      moveFile(journalPath, archivePath)
    let f = open(journalPath, fmAppend)
    f.writeLine($entry)
    f.close()
  except: discard

proc updateSnapshot(al: AgentLoop, entry: JsonNode, remove: bool = false) =
  let snapshotPath = al.officeDir / "status.json"
  try:
    if remove: removeFile(snapshotPath)
    else: writeFile(snapshotPath, $entry)
  except: discard

proc logTaskHeader*(al: AgentLoop, ctx: TaskContext, action: ActionType) =
  let ts = now().format("yyyy-MM-dd'T'HH:mm:sszzz")
  if ctx.openedAt == "": ctx.openedAt = ts

  var entry = newJObject()
  entry["taskId"] = %ctx.id
  entry["ts"] = %ts
  entry["action"] = %($action)

  if action == atStart:
    entry["provider"] = %(if al.model.contains("/"): al.model.split("/")[0] else: "default")
    entry["model"] = %al.model
    entry["hostPid"] = %getCurrentProcessId()
  elif action == atFinish or action == atCancel:
    entry["tokensTotal"] = %ctx.tokensTotal

  al.appendJournal(entry)

  if action == atStart:
    al.updateSnapshot(entry)
  elif action == atFinish or action == atCancel:
    al.updateSnapshot(entry, remove = true)

proc logAction*(al: AgentLoop, ctx: TaskContext, action: ActionType, tokens: int = 0, metadata: JsonNode = newJObject()) =
  let ts = now().format("yyyy-MM-dd'T'HH:mm:sszzz")
  var entry = newJObject()
  entry["taskId"] = %ctx.id
  entry["ts"] = %ts
  entry["action"] = %($action)
  if tokens > 0: entry["tokens"] = %tokens

  for k, v in metadata.pairs:
    entry[k] = v

  al.appendJournal(entry)
  al.updateSnapshot(entry)

proc updateStatus*(al: AgentLoop, ctx: TaskContext, status: string, detail: string = "", iter: int = 0) =
  var meta = newJObject()
  meta["status"] = %status
  meta["detail"] = %detail
  if iter > 0: meta["iteration"] = %iter
  al.logAction(ctx, atStatus, 0, meta)


proc maybeSummarize(al: AgentLoop, sessionKey: string) =
  acquire(al.summarizingLock)
  if al.summarizing.hasKey(sessionKey) and al.summarizing[sessionKey]:
    release(al.summarizingLock)
    return

  let history = al.sessions.getHistory(sessionKey)
  let tokenEstimate = estimateTokens(history)
  let threshold = (al.contextWindow * 75) div 100

  if history.len > 20 or tokenEstimate > threshold:
    al.summarizing[sessionKey] = true
    release(al.summarizingLock)
    discard (proc() {.async.} =
      await summarizeSession(al, sessionKey)
      acquire(al.summarizingLock)
      al.summarizing[sessionKey] = false
      release(al.summarizingLock)
    )()
  else:
    release(al.summarizingLock)

proc isXmlToolProvider*(model: string): bool =
  ## Returns true for providers that need XML tool calling instead of native tools.
  model.startsWith("opencode/") or model.startsWith("opencode-go/")

proc buildToolContext(al: AgentLoop, opts: ProcessOptions, logicalUserID: string): tools_base.ToolContext =
  tools_base.ToolContext(
    channel: opts.channel,
    chatID: opts.chatID,
    sessionKey: opts.sessionKey,
    senderID: opts.senderID,
    recipientID: opts.recipientID,
    role: opts.userRole,
    agentName: al.agentName,
    agentID: al.agentId,
    logicalUserID: logicalUserID,
    appID: opts.appID,
    replyToMessageID: opts.replyToMessageID,
    graph: al.contextBuilder.graph,
    entity: al.entity,
    identity: al.identity
  )

proc runLLMIteration(al: AgentLoop, ctx: TaskContext, messages: seq[providers_types.Message], opts: ProcessOptions, logicalUserID: string): Future[(string, int, seq[providers_types.Message])] {.async.} =
  var iteration = 0
  var finalContent = ""
  var lastResponseContent = ""  # Track last response for loop exhaustion fallback
  var emptyNameRetries = 0
  var emptyRetries = 0
  var toolCallLog: seq[string] = @[]  # Track tool calls for forced summary
  var loopDetector = newLoopDetector()
  var currentMessages = messages
  let useXmlTools = isXmlToolProvider(al.model)
  let toolCtx = buildToolContext(al, opts, logicalUserID)

  # Sanitize: remove orphaned tool messages (tool without preceding tool_calls)
  block:
    var clean: seq[providers_types.Message] = @[]
    var lastHadToolCalls = false
    for m in currentMessages:
      if m.role == "tool":
        if not lastHadToolCalls:
          continue  # Skip orphaned tool result
      clean.add(m)
      lastHadToolCalls = (m.role == "assistant" and m.tool_calls.len > 0)
    if clean.len != currentMessages.len:
      warnCF("agent", "Removed orphaned tool messages from history", {"removed": $(currentMessages.len - clean.len)}.toTable)
      currentMessages = clean

  while iteration < al.maxIterations and finalContent == "":
    iteration += 1
    al.updateStatus(ctx, "Thinking", "Running iteration", iteration)

    infoCF("agent", "LLM iteration", {"iteration": $iteration, "max": $al.maxIterations, "xml_tools": $useXmlTools, "messages_count": $currentMessages.len}.toTable)

    let strategy = inferStrategy(al.model)

    # Tick TTL each iteration (tools expire after N turns of non-use)
    if al.findTool != nil and iteration > 1:
      al.findTool.tickTTL()

    # Deferred tool loading: core tools get full schemas, hidden tools listed in taxonomy
    if iteration == 1:
      infoCF("agent", "Getting tool definitions (deferred mode)", {"strategy": $strategy, "total": $al.tools.count()}.toTable)
    let toolDefs =
      if useXmlTools:
        @[]
      else:
        let roleLow = opts.userRole.toLowerAscii()
        # Per-agent allowlist takes priority (from ClawDSL uses)
        if al.allowedTools.len > 0:
          var final: seq[string]
          for t in al.allowedTools:
            if t notin al.deniedTools: final.add(t)
          al.tools.getDefinitionsFiltered(strategy, final)
        elif roleLow in ["guest", "customer"]:
          al.tools.getDefinitionsFiltered(strategy, @(tools_registry.ExternalAllowedTools))
        else:
          let activatedSet = if al.findTool != nil: al.findTool.getActivatedSet()
                             else: initHashSet[string]()
          let (defs, hiddenNames) = al.tools.getDefinitionsDeferred(strategy, activatedSet)
          # Inject taxonomy into system message on first iteration
          if iteration == 1 and hiddenNames.len > 0:
            let taxonomy = al.tools.generateTaxonomy()
            if taxonomy.len > 0 and currentMessages.len > 0 and currentMessages[0].role == "system":
              currentMessages[0].content.add("\n\n## Additional Tools\nUse `find_tools` to activate tools from these categories:\n" & taxonomy)
              infoCF("agent", "Deferred tool loading", {"core_schemas": $defs.len, "hidden": $hiddenNames.len, "activated": $activatedSet.len}.toTable)
          defs

    let options = {
      "max_tokens": %al.contextWindow,
      "temperature": %al.temperature
    }.toTable
    
    var response: LLMResponse
    try:
      response = await al.provider.chat(currentMessages, toolDefs, al.model, options)
    except Exception as e:
      errorCF("agent", "LLM API request failed", {"error": e.msg, "iteration": $iteration}.toTable)
      if finalContent == "":
        finalContent = "Error communicating with LLM provider: " & e.msg
      break

    # Accumulate tokens
    let tokens = response.usage.total_tokens
    ctx.tokensTotal += tokens
    
    var llmMeta = newJObject()
    llmMeta["iteration"] = %iteration
    if al.model != al.cfg.agents.defaults.model: llmMeta["model"] = %al.model
    al.logAction(ctx, atInference, tokens, llmMeta)
    
    # Track last non-empty response for fallback
    if response.content.len > 0:
      lastResponseContent = response.content
    infoCF("agent", "LLM response received", {"iteration": $iteration, "content_len": $response.content.len, "content_preview": truncate(response.content, 200)}.toTable)

    if useXmlTools:
      # XML tool calling path: parse <tool_call> tags from text response
      let xmlCalls = parseXmlToolCalls(response.content)

      if xmlCalls.len == 0:
        # No XML tool calls found — this is the final response
        if hasXmlToolCalls(response.content):
          warnCF("agent", "XML tags detected but parsing failed. Check JSON format.\nFull response:\n" & response.content, {"iteration": $iteration}.toTable)
        
        finalContent = response.content
        infoCF("agent", "LLM response without XML tool calls", {"iteration": $iteration}.toTable)
        break

      # Tool call telemetry
      var toolMeta = newJObject()
      var toolNames = newJArray()
      for tool in xmlCalls: toolNames.add(%tool.name)
      toolMeta["tools"] = toolNames
      toolMeta["iteration"] = %iteration
      al.logAction(ctx, atToolCall, 0, toolMeta)
      
      al.updateStatus(ctx, "Executing Tools", "Processing " & $xmlCalls.len & " tools", iteration)
      
      # Extract display text (text outside tool call tags)
      let displayText = extractTextFromResponse(response.content)
      if displayText.len > 0:
        infoCF("agent", "XML tool intermediary text: " & truncate(displayText, 120), {"iteration": $iteration}.toTable)
        if opts.streamIntermediary:
          al.bus.publishOutbound(newOutbound(opts.channel, opts.recipientID, opts.chatID, displayText, opts.replyToMessageID, opts.appID))

      # Save assistant message (with full content including tool call tags) to history
      let assistantMsg = providers_types.Message(role: "assistant", content: response.content, reasoning_content: response.reasoning_content)
      currentMessages.add(assistantMsg)
      al.sessions.addFullMessage(opts.sessionKey, assistantMsg)

      # Execute each XML tool call
      var xmlResults: seq[XmlToolResult] = @[]
      for xmlCall in xmlCalls:
        infoCF("agent", "XML Tool call: " & xmlCall.name, {"tool": xmlCall.name, "iteration": $iteration, "role": al.role}.toTable)
        if xmlCall.name == "reply" or xmlCall.name == "message":
          ctx.responseSent = true
        let result = await al.tools.executeWithContext(xmlCall.name, xmlCall.arguments, toolCtx)
        xmlResults.add(XmlToolResult(name: xmlCall.name, output: result, success: not result.startsWith("Error:")))

      # Format tool results and add as a user message
      let formattedResults = formatToolResults(xmlResults)
      let toolResultMsg = providers_types.Message(role: "user", content: formattedResults)
      currentMessages.add(toolResultMsg)
      al.sessions.addMessage(opts.sessionKey, "user", formattedResults)

    else:
      # Native tool calling path (unchanged)
      if response.tool_calls.len == 0:
        if response.content.len > 0:
          let trimmed = response.content.strip()
          # Detect incomplete responses: LLM describes next steps instead of giving results
          # Nudge up to 2 times if we're mid-task and response is short status text
          let looksIncomplete = iteration > 3 and toolCallLog.len >= 3 and trimmed.len < 200 and
            (trimmed.endsWith(":") or trimmed.endsWith("：") or trimmed.endsWith(",") or
             trimmed.endsWith("。") or trimmed.endsWith("."))
          if looksIncomplete and emptyRetries < 2:
            emptyRetries.inc
            warnCF("agent", "LLM returned short status without tool calls, nudging to continue", {"iteration": $iteration, "retry": $emptyRetries, "preview": trimmed[0..min(trimmed.len-1, 80)]}.toTable)
            currentMessages.add(providers_types.Message(role: "assistant", content: response.content))
            currentMessages.add(providers_types.Message(role: "user", content: "You described what you plan to do but did not do it. Use tools NOW to complete the task, then provide the final result to the user."))
            continue
          finalContent = response.content
        elif iteration > 1:
          # LLM returned empty after tool iterations — nudge to continue, then force summary
          emptyRetries.inc
          if emptyRetries <= 2:
            warnCF("agent", "LLM returned empty, nudging to continue", {"iteration": $iteration, "retry": $emptyRetries}.toTable)
            currentMessages.add(providers_types.Message(role: "user", content: "Continue with the task. Use tools to complete it, then reply to the user with the results."))
            continue
          else:
            warnCF("agent", "LLM returned empty 3 times, forcing summary", {"iteration": $iteration}.toTable)
            var summaryPrompt = "Provide your FINAL response to the user NOW."
            if toolCallLog.len > 0:
              summaryPrompt.add("\n\nHere is what you did so far:\n" & toolCallLog.join("\n") & "\n\nSummarize the results, including any errors or failures. If a step failed, tell the user.")
            else:
              summaryPrompt.add(" Summarize what you accomplished and any results from the tools you used.")
            # Build compact context to avoid overwhelming the model
            var summaryMessages: seq[providers_types.Message] = @[]
            summaryMessages.add(currentMessages[0])  # system message
            let recentStart = max(1, currentMessages.len - 4)
            for i in recentStart ..< currentMessages.len:
              summaryMessages.add(currentMessages[i])
            summaryMessages.add(providers_types.Message(role: "user", content: summaryPrompt))
            try:
              let summaryDefs: seq[ToolDefinition] = @[]
              let summaryOpts = {"max_tokens": %4096, "temperature": %al.temperature}.toTable
              let summaryResp = await al.provider.chat(summaryMessages, summaryDefs, al.model, summaryOpts)
              if summaryResp.content.len > 0:
                finalContent = summaryResp.content
            except Exception as e:
              warnCF("agent", "Summary call failed, using last content", {"error": e.msg}.toTable)
            if finalContent == "" and lastResponseContent.len > 0:
              finalContent = lastResponseContent
        infoCF("agent", "LLM response without tool calls", {"iteration": $iteration}.toTable)
        break

      # Filter out degenerate tool calls with empty names (DeepSeek failure mode)
      # Try to infer tool name from response content or arguments before discarding
      var validCalls: seq[providers_types.ToolCall] = @[]
      let allToolNames = al.tools.list()
      for tc in response.tool_calls:
        if tc.name.strip().len > 0:
          validCalls.add(tc)
        else:
          # Try to infer tool name from response content
          var inferred = ""
          let contentLow = response.content.toLowerAscii()
          for tn in allToolNames:
            if tn.toLowerAscii() in contentLow:
              if inferred.len == 0 or tn.len > inferred.len:  # prefer longest match
                inferred = tn
          if inferred.len > 0:
            warnCF("agent", "Inferred tool name from content", {"id": tc.id, "inferred": inferred, "iteration": $iteration}.toTable)
            var fixedTc = tc
            fixedTc.name = inferred
            validCalls.add(fixedTc)
          else:
            warnCF("agent", "Skipping tool call with empty name", {"id": tc.id, "iteration": $iteration}.toTable)

      if validCalls.len == 0:
        # All tool calls had empty names — nudge to retry (up to 3 times)
        emptyNameRetries += 1
        if emptyNameRetries > 3:
          warnCF("agent", "Too many empty tool name retries, breaking", {"iteration": $iteration}.toTable)
          if response.content.len > 0: finalContent = response.content
          break
        warnCF("agent", "LLM returned empty tool names, nudging to continue", {"iteration": $iteration, "retry": $emptyNameRetries}.toTable)
        if response.content.len > 0:
          currentMessages.add(providers_types.Message(role: "assistant", content: response.content))
        currentMessages.add(providers_types.Message(role: "user", content: "Your last tool call had an empty function name. Please call the tool again with the correct name. For browser actions, use the 'playwright' tool with an action parameter."))
        continue

      emptyNameRetries = 0  # Reset on successful tool calls
      if opts.streamIntermediary and response.content.len > 0:
        al.bus.publishOutbound(newOutbound(opts.channel, opts.recipientID, opts.chatID, response.content, opts.replyToMessageID, opts.appID))

      var assistantMsg = providers_types.Message(role: "assistant", content: response.content, reasoning_content: response.reasoning_content, tool_calls: validCalls)
      currentMessages.add(assistantMsg)
      al.sessions.addFullMessage(opts.sessionKey, assistantMsg)

      var toolMeta = newJObject()
      var toolNames = newJArray()
      for tc in validCalls: toolNames.add(%tc.name)
      if toolNames.len > 0:
        toolMeta["tools"] = toolNames
        toolMeta["iteration"] = %iteration
        al.logAction(ctx, atToolCall, 0, toolMeta)
        al.updateStatus(ctx, "Executing Tools", "Processing " & $toolNames.len & " tools", iteration)

      for tc in validCalls:
        # Loop detection: catch identical repeated tool calls
        let argsJson = if tc.arguments.len > 0: %*tc.arguments else: newJObject()
        let loopResult = loopDetector.record(tc.name, argsJson)
        if loopResult == lrStop:
          warnCF("agent", "Tool loop detected, forcing summary", {"tool": tc.name, "streak": $loopDetector.streak}.toTable)
          # Build compact summary context with tool call log
          var loopPrompt = "STOP. You have called `" & tc.name & "` with identical arguments " & $loopDetector.streak & " times — this is a stuck loop. Do NOT call any more tools. Provide your FINAL response to the user NOW."
          if toolCallLog.len > 0:
            loopPrompt.add("\n\nHere is what you did:\n" & toolCallLog.join("\n") & "\n\nSummarize the results, including any errors or failures. If a step failed, tell the user what went wrong and suggest they try manually.")
          var summaryMessages: seq[providers_types.Message] = @[]
          summaryMessages.add(currentMessages[0])
          let recentStart = max(1, currentMessages.len - 4)
          for i in recentStart ..< currentMessages.len:
            summaryMessages.add(currentMessages[i])
          summaryMessages.add(providers_types.Message(role: "user", content: loopPrompt))
          try:
            let toolDefs: seq[ToolDefinition] = @[]
            let summaryOpts = {"max_tokens": %4096, "temperature": %al.temperature}.toTable
            let summaryResp = await al.provider.chat(summaryMessages, toolDefs, al.model, summaryOpts)
            if summaryResp.content.len > 0:
              finalContent = summaryResp.content
          except Exception as e:
            errorCF("agent", "Loop summary call failed", {"error": e.msg}.toTable)
          if finalContent == "":
            finalContent = "I got stuck in a loop trying to use `" & tc.name & "`. The operation could not be completed. Please try a different approach."
          break
        elif loopResult == lrWarn:
          let msg = loopDetector.message()
          warnCF("agent", "Tool loop warning", {"tool": tc.name, "streak": $loopDetector.streak}.toTable)
          currentMessages.add(providers_types.Message(role: "tool", content: msg, tool_call_id: tc.id, name: tc.name))
          continue  # Skip execution, deliver the warning as the tool result

        infoCF("agent", "Tool call: " & tc.name, {"tool": tc.name, "iteration": $iteration, "role": al.role}.toTable)
        emptyRetries = 0  # Reset on successful tool call
        if tc.name == "reply" or tc.name == "message":
          ctx.responseSent = true

        # Dispatch-time gate: refuse tools outside the current requester's
        # role.grant. This turns role.grant into an enforcement boundary,
        # not a prompt decoration. A Guest asking the agent to call a
        # high-privilege tool gets a tool-result error, not execution.
        var result: string
        if al.turnAllowedTools.len > 0 and tc.name notin al.turnAllowedTools:
          warnCF("agent", "Tool refused — not in requester's role.grant",
            {"tool": tc.name, "allowed": al.turnAllowedTools.join(",")}.toTable)
          result = "Error: tool '" & tc.name & "' is not authorised at the current requester's trust level. Allowed tools are: " & al.turnAllowedTools.join(", ") & ". If the user needs a higher-privilege action, they must upgrade via redeem_invite or a SuperAdmin must edit BASE.nims."
        else:
          result = await al.tools.executeWithContext(tc.name, tc.arguments, toolCtx)
        # Record in tool call log for forced summary context
        let resultPreview = if result.len > 200: result[0..199] & "..." else: result
        toolCallLog.add("[" & $iteration & "] " & tc.name & " → " & resultPreview)
        let toolResultMsg = providers_types.Message(role: "tool", content: result, tool_call_id: tc.id, name: tc.name)
        currentMessages.add(toolResultMsg)
        al.sessions.addFullMessage(opts.sessionKey, toolResultMsg)

  # If loop exhausted maxIterations without breaking, make one final LLM call for summary
  if finalContent == "" and (lastResponseContent != "" or toolCallLog.len > 0):
    warnCF("agent", "Tool loop exhausted maxIterations without final response", {"iterations": $iteration, "max": $al.maxIterations, "tool_calls": $toolCallLog.len}.toTable)

    # Build a compact context for the summary call — full message history is too long for GLM-5
    infoCF("agent", "Making final summary LLM call after loop exhaustion", initTable[string, string]())
    var exhaustPrompt = "You were performing a task for the user but reached the maximum number of tool iterations (" & $al.maxIterations & "). Provide your FINAL response to the user NOW. Do NOT call any tools."
    if toolCallLog.len > 0:
      exhaustPrompt.add("\n\nHere is what you did:\n" & toolCallLog.join("\n") & "\n\nSummarize the results, including any errors or failures. If a step failed, tell the user what went wrong.")
    else:
      exhaustPrompt.add(" Summarize what you accomplished and any results from the tools you used.")
    # Use only system + last few messages + summary prompt to avoid context overflow
    var summaryMessages: seq[providers_types.Message] = @[]
    summaryMessages.add(currentMessages[0])  # system message
    let recentStart = max(1, currentMessages.len - 4)
    for i in recentStart ..< currentMessages.len:
      summaryMessages.add(currentMessages[i])
    summaryMessages.add(providers_types.Message(role: "user", content: exhaustPrompt))
    try:
      let toolDefs: seq[ToolDefinition] = @[]
      let summaryOpts = {"max_tokens": %4096, "temperature": %al.temperature}.toTable
      let summaryResp = await al.provider.chat(summaryMessages, toolDefs, al.model, summaryOpts)
      if summaryResp.content.len > 0:
        let cleaned = extractTextFromResponse(summaryResp.content)
        finalContent = if cleaned.len > 0: cleaned else: summaryResp.content
    except Exception as e:
      errorCF("agent", "Final summary LLM call failed", {"error": e.msg}.toTable)
      # Fall back to extracted intermediary text
      let extracted = extractTextFromResponse(lastResponseContent)
      if extracted.len > 0:
        finalContent = extracted
  elif finalContent == "":
    warnCF("agent", "Tool loop ended with empty finalContent", {"iterations": $iteration}.toTable)

  return (finalContent, iteration, currentMessages)

proc channelIdentifierKey*(channel, appID: string): string =
  ## Graph-identifier slot key for this message.
  ##
  ## A company can run multiple Feishu apps side-by-side (cfg.channels.
  ## feishu.apps[]). Each app has its own `open_id` namespace — Alice's
  ## open_id under App A is unrelated to her open_id under App B. If we
  ## stored both under a plain `"feishu"` identifier, Alice-via-A and
  ## Alice-via-B would collide into whichever was registered first.
  ## Namespacing by app_id keeps them distinct.
  ##
  ## Single-app channels return the channel name unchanged; Feishu
  ## without a known app_id falls back the same way (no regression for
  ## callers that don't pass the metadata).
  if appID.len > 0 and channel in ["feishu"]:
    channel & ":" & appID
  else:
    channel

proc identitySessionKey(al: AgentLoop, opts: ProcessOptions): string =
  ## Produce the on-disk session key for this message.
  ##
  ##   system:heartbeat (gateway-synthetic)  → system_heartbeat
  ##   group chat                            → grp_<channel>_<chatID>
  ##                                           (one shared session for
  ##                                           everyone in the room;
  ##                                           speakers distinguished
  ##                                           per-message)
  ##   DM / unknown                          → key by the sender's nc:id:
  ##     resolved graph entity               → nc_N
  ##     first-time sender                   → add to graph as Guest,
  ##                                           return their fresh nc:N
  ##
  ## Groups don't yet get their own graph entity (ekGroup) — that's a
  ## follow-up. For now a channel+chat_id key is stable across turns
  ## and safely isolates group history from any participant's DMs.
  if opts.sessionKey.startsWith("system:"):
    return opts.sessionKey.replace(":", "_")

  # Group chats: single shared session file per room.
  if opts.chatKind == ckGroup and opts.chatID.len > 0:
    var chat = opts.chatID
    for c in mitems(chat):
      if c in {':', '/', '\\', ' ', '\t'}: c = '_'
    return "grp_" & opts.channel & "_" & chat
  if al.contextBuilder == nil or al.contextBuilder.graph == nil:
    # No graph at all (shouldn't happen in real runs) — degrade safely.
    var sid = opts.senderID
    for c in mitems(sid):
      if c == ':': c = '_'
    return "anon_" & opts.channel & "_" & sid

  let graph = al.contextBuilder.graph
  let recip = if opts.recipientID != "": opts.recipientID else: al.agentName
  var agentId = WorldEntityID(0)
  if recip != "" and graph.nameIndex.hasKey(recip):
    agentId = graph.nameIndex[recip]

  # Multi-app channels key on (channel, app_id) so each Feishu app's
  # open_id namespace stays isolated.
  let channelKey = channelIdentifierKey(opts.channel, opts.appID)

  let (resolvedID, _) = graph.resolveUserGraph(
    channelKey, opts.senderID, agentId)
  var entityID = resolvedID

  # Name-based fallback — CLI or any channel where the sender hasn't yet
  # been registered with a channel identifier. Matches resolveRequesterTrust
  # so session + trust agree on who's talking.
  if uint32(entityID) == 0 and graph.nameIndex.hasKey(opts.senderID):
    entityID = graph.nameIndex[opts.senderID]

  # First-time sender — mint a graph entity so everyone has a stable
  # nc:id from the first message. Trust 10 (Guest); the runtime's normal
  # role-transition paths (redeem_invite, SuperAdmin edit) take them up
  # from there. The channelKey isolates per-app identity so the same
  # Feishu open_id under a different app gets its own nc:id.
  if uint32(entityID) == 0:
    entityID = graph.addUserToGraph(
      opts.senderID,              # logical name — the raw ID for now
      opts.senderID,              # used as channel identifier value
      urGuest,
      agentId,
      10                          # trust — same as legacy default
    )
    # addUserToGraph currently stores the identifier under channel "nkn"
    # (legacy default); explicitly record it under the composite channel
    # key so future lookups via resolveUserGraph hit correctly.
    if graph.entities.hasKey(entityID):
      graph.entities[entityID].identifiers[channelKey] = opts.senderID
      graph.saveWorld()

  toAlias(entityID).replace(":", "_")

proc runAgentLoop*(al: AgentLoop, optsParam: ProcessOptions): Future[string] {.async.} =
  var opts = optsParam
  # CLI channel = owner's terminal. Trust as Admin unless explicitly set.
  if opts.userRole == "" and opts.channel == "cli": opts.userRole = "Admin"
  if opts.userRole == "": opts.userRole = "Guest"

  # Session persistence is identity-scoped, not channel-scoped. Replace
  # the transport-level key (channel:chatID:senderID from the channel
  # layer) with the identity key derived from the graph. All downstream
  # al.sessions.* calls read/write the identity-keyed session file.
  opts.sessionKey = identitySessionKey(al, opts)

  let epochMs = int(getTime().toUnixFloat() * 1000)
  al.taskCounter += 1
  let taskId = al.agentId & ":" & $epochMs & ":" & align($al.taskCounter, 3, '0')
  
  let ctx = TaskContext(
    id: taskId,
    openedAt: "",
    tokensTotal: 0
  )
  
  al.logTaskHeader(ctx, atStart)
  
  try:
    let history = al.sessions.getHistory(opts.sessionKey)
    let summary = al.sessions.getSummary(opts.sessionKey)
    let useXmlTools = isXmlToolProvider(al.model)
    # Perform sentiment analysis and update mood
    let (vDelta, aDelta) = cortex.analyzeSentiment(opts.userMessage)
    cortex.updateMood(al.contextBuilder.mood, vDelta, aDelta)
    cortex.saveMood(al.workspace, al.contextBuilder.mood)

    # Resolve raw senderID to logical userID
    var logicalUserID = opts.senderID
    var isKnown = false
    
    var activeRecipient = opts.recipientID
    if activeRecipient == "": activeRecipient = al.agentName
    
    if al.contextBuilder.graph != nil:
      var agentId = WorldEntityID(0)
      if activeRecipient != "" and al.contextBuilder.graph.nameIndex.hasKey(activeRecipient):
        agentId = al.contextBuilder.graph.nameIndex[activeRecipient]
        
      # Feishu multi-app: key on (channel, app_id) so two apps' open_id
      # namespaces don't collide. Non-multi-app channels pass through
      # unchanged via channelIdentifierKey.
      let chKey = channelIdentifierKey(opts.channel, opts.appID)
      let (resolvedID, annotOpt) = al.contextBuilder.graph.resolveUserGraph(chKey, opts.senderID, agentId)
      var entityID = resolvedID
      # Name-based fallback — catches CLI / first-contact cases where the
      # sender isn't yet mapped via a channel identifier. Matches the
      # identitySessionKey derivation and resolveRequesterTrust, so
      # session key / speaker / trust all agree on the same nc:id.
      if uint32(entityID) == 0 and
         al.contextBuilder.graph.nameIndex.hasKey(opts.senderID):
        entityID = al.contextBuilder.graph.nameIndex[opts.senderID]
      if uint32(entityID) > 0:
        logicalUserID = toAlias(entityID)
        isKnown = true
        
        # Calculate user role for tool execution context
        var toolRole = urGuest
        if annotOpt.isSome:
          toolRole = annotOpt.get().role
        else:
          let ent = al.contextBuilder.graph.entities[entityID]
          if ent.role.toLowerAscii in ["boss", "master", "admin", "superadmin"]:
            toolRole = if ent.role.toLowerAscii == "boss" or ent.role.toLowerAscii == "superadmin": urBoss else: urMaster
        opts.userRole = $toolRole
    
    if not isKnown:
      let (legacyID, found) = al.contextBuilder.relations.resolveUser(opts.channel, opts.senderID)
      if found:
        logicalUserID = legacyID
        isKnown = true

    if isKnown and opts.userRole == "Guest" and al.contextBuilder.relations.hasKey(logicalUserID):
      let ident = al.contextBuilder.relations[logicalUserID].identity
      # If the string maps to a valid UserRole, pass it; else fallback
      opts.userRole = ident

    # Check if this user is a NEW user for an agent
    if not isKnown and opts.recipientID.len > 0:
      var allInvites = loadInvites(al.workspace)
      let msgNormalized = opts.userMessage.strip().replace("-", "").toUpperAscii()
      
      for code, inv in allInvites.pairs:
        let codeNormalized = code.replace("-", "").toUpperAscii()
        # Match either pinless (Public mode) or explicit match of the PIN code
        let matchesPublic = inv.pinless and (opts.recipientID == "" or inv.agentName == opts.recipientID)
        let matchesPrivate = not inv.pinless and msgNormalized == codeNormalized and (opts.recipientID == "" or inv.agentName == opts.recipientID)
        
        if (matchesPublic or matchesPrivate) and isValid(inv):
          let sanitizedName = inv.customerName.replace(" ", "_").toLowerAscii()
          # professional ID pattern: customer_Alice_A4B
          let suffix = if opts.senderID.len >= 3: opts.senderID[0..2] else: "new"
          let newID = "customer_" & sanitizedName & "_" & suffix
          
          if al.contextBuilder.graph != nil:
            # Onboard to Graph
            var agentId = WorldEntityID(0)
            for id, ent in al.contextBuilder.graph.entities:
              if ent.kind == ekAI and ent.name == inv.agentName:
                agentId = id
                break
            
            let newEntityID = al.contextBuilder.graph.addUserToGraph(
              newID, 
              opts.senderID, 
              parseEnum[UserRole](inv.role, urGuest), 
              agentId, 
              50
            )
            logicalUserID = toAlias(newEntityID)
          else:
            # Legacy Onboarding
            var kind = ekPerson
            if opts.channel == "nkn" and opts.senderID.contains("."):
              kind = ekAI

            var rel = Relationship(
              name: newID,
              identity: $parseEnum[UserRole](inv.role, urGuest),
              trustLevel: 50,
              etiquette: "",
              kind: kind,
              identifiers: initTable[string, seq[string]]()
            )
            rel.identifiers[opts.channel] = @[opts.senderID]
            al.contextBuilder.relations[newID] = rel
            saveRelations(al.officeDir, al.contextBuilder.relations)
            logicalUserID = newID
          
          let modeText = if inv.pinless: "public mode" else: "PIN redemption"
          infoCF("agent", "Auto-onboarded via " & modeText, {"agent": opts.recipientID, "user": opts.senderID, "id": newID}.toTable)
          
          # Consume invite
          if inv.maxUses > 0:
            var mInv = inv
            mInv.maxUses -= 1
            if mInv.maxUses == 0: allInvites.del(code)
            else: allInvites[code] = mInv
            saveInvites(al.workspace, allInvites)
            
          if matchesPrivate:
            # Special case for Private Mode: Return redemption message directly and skip LLM
            return "Invite redeemed! Welcome, " & inv.customerName & ". How can I help you today?"
            
          break
      
      # Ensure Lexi keeps a record of who she's talking to
      if not isKnown:
        # Determine kind based on heuristics
        var kind = ekPerson
        if opts.channel == "nkn" and opts.senderID.contains("."):
          kind = ekAI # Has subname, likely an agent
        
        let newRel = Relationship(
          name: logicalUserID,
          identity: "Guest",
          trustLevel: 10,
          etiquette: "Professional guest service protocol.",
          kind: kind,
          identifiers: {opts.channel: @[opts.senderID]}.toTable
        )
        al.contextBuilder.relations[logicalUserID] = newRel
        saveRelations(al.officeDir, al.contextBuilder.relations)
        infoCF("agent", "Recorded new guest contact", {"id": logicalUserID, "kind": $kind, "channel": opts.channel}.toTable)
      else:
        # Update existing entry if needed (e.g. if identification changed)
        var rel = al.contextBuilder.relations[logicalUserID]
        var changed = false
        if not rel.identifiers.hasKey(opts.channel):
          rel.identifiers[opts.channel] = @[opts.senderID]
          changed = true
        elif opts.senderID notin rel.identifiers[opts.channel]:
          rel.identifiers[opts.channel].add(opts.senderID)
          changed = true
          
        if changed:
          al.contextBuilder.relations[logicalUserID] = rel
          saveRelations(al.officeDir, al.contextBuilder.relations)

    let targetRecipient = if opts.recipientID != "": opts.recipientID else: al.agentId

    # Refresh memory-tool context so store/recall scope to the current
    # partner's own isolated file. `logicalUserID` is already the nc:id
    # alias once the graph has resolved the sender (see above). Trust
    # comes from the graph edge (or legacy relationship) resolved above.
    let reqTrust = al.contextBuilder.resolveRequesterTrust(
      logicalUserID, targetRecipient, opts.channel)
    if al.memTool != nil:
      al.memTool.setRequesterContext(logicalUserID, reqTrust)

    # Dispatch-time tool gate. Role.grant in the ClawDSL `trust:` block was
    # previously a cosmetic schema filter (the LLM could still call any
    # tool by name). Now we resolve the requester's role every turn and
    # hold its grant list; the tool loop refuses any call outside it.
    al.turnAllowedTools = @[]
    if al.contextBuilder.trust.roles.len > 0:
      let reqRole = al.contextBuilder.resolveRequesterRole(
        logicalUserID, targetRecipient, opts.channel)
      let roleCfg = findTrustRole(al.contextBuilder.trust, reqRole)
      if roleCfg.isSome:
        let g = roleCfg.get.grant
        if g.len > 0 and "*" notin g:
          al.turnAllowedTools = g

    var messages = al.contextBuilder.buildMessages(logicalUserID, history, summary, opts.userMessage, opts.channel, opts.chatID, useXmlTools, targetRecipient)

    let historyLabel = if logicalUserID != "": logicalUserID else: opts.senderID
    al.sessions.addWithSpeaker(opts.sessionKey, "user",
      historyLabel & ": " & opts.userMessage, logicalUserID)

    # Immediate feedback: notify bus that bot is "typing"
    al.bus.publishOutbound(OutboundMessage(
      channel: opts.channel,
      sender_agent: opts.recipientID,
      chat_id: opts.chatID,
      kind: Typing,
      reply_to_message_id: opts.replyToMessageID,
      app_id: opts.appID
    ))

    let (finalContentRaw, iteration, _) = await al.runLLMIteration(ctx, messages, opts, logicalUserID)
    var finalContent = finalContentRaw

    if finalContent == "":
      finalContent = opts.defaultResponse

    if ctx.responseSent:
      infoCF("agent", "Response already sent via tools, skipping final return message", {"session_key": opts.session_key}.toTable)
      # Still add to history but return empty so gateway doesn't send it again
      al.sessions.addWithSpeaker(opts.sessionKey, "assistant", finalContent, al.agentId)
      return ""

    al.sessions.addWithSpeaker(opts.sessionKey, "assistant", finalContent, al.agentId)

    if opts.enableSummary:
      al.maybeSummarize(opts.sessionKey)

    infoCF("agent", "Response: " & truncate(finalContent, 120), {"session_key": opts.session_key, "iterations": $iteration}.toTable)
    
    # NOTE: Forged MCP tools are NOT purged here — they persist across turns within a session.
    # Use purge_mcp_tool explicitly to clean up, or tools are cleaned up on session timeout.
    
    return finalContent
  except Exception as e:
    var errMeta = newJObject()
    errMeta["error"] = %e.msg
    al.logAction(ctx, atCancel, 0, errMeta)
    al.logTaskHeader(ctx, atCancel)
    errorCF("agent", "Agent loop failed", {"error": e.msg, "agent": al.agentName}.toTable)
    return "Error: " & e.msg
  finally:
    al.logTaskHeader(ctx, atFinish)

proc processMessage*(al: AgentLoop, msg: InboundMessage): Future[string] {.async.} =
  infoCF("agent", "Processing message from " & msg.channel & ":" & msg.sender_id, {"session_key": msg.session_key}.toTable)

  # Determine streamIntermediary based on channel config, fallback to agent defaults
  let channelStreamIntermediary = case msg.channel:
    of "feishu": al.cfg.channels.feishu.stream_intermediary
    of "nmobile": al.cfg.channels.nmobile.stream_intermediary
    of "zen": true  # Always stream intermediary to Zen for real-time chat UX
    else: al.cfg.agents.defaults.stream_intermediary

  # Removed manual setContext calls to message/spawn/cron tools here
  # since executeWithContext now passes channel, chatID, and sessionKey correctly.

  return await al.runAgentLoop(ProcessOptions(
    sessionKey: msg.session_key,
    senderID: msg.sender_id,
    recipientID: msg.recipient_id,
    channel: msg.channel,
    chatID: msg.chat_id,
    chatKind: msg.chat_kind,
    replyToMessageID: msg.metadata.getOrDefault("message_id", ""),
    appID: msg.metadata.getOrDefault("app_id", ""),
    userMessage: msg.content,
    defaultResponse: "I've completed processing but have no response to give.",
    enableSummary: true,
    sendResponse: false,
    streamIntermediary: channelStreamIntermediary
  ))

proc processDirect*(al: AgentLoop, content, sessionKey: string, senderID: string = "user", channel: string = "cli"): Future[string] {.async.} =
  let msg = InboundMessage(channel: channel, sender_id: senderID, recipient_id: al.agentName, chat_id: "direct", content: content, session_key: sessionKey)
  return await al.processMessage(msg)

proc run*(al: AgentLoop) {.async.} =
  al.running = true
  while al.running:
    let msg = await al.bus.consumeInbound()
    try:
      let response = await al.processMessage(msg)
      if response != "":
        al.bus.publishOutbound(newOutbound(msg.channel, msg.recipient_id, msg.chat_id, response, msg.metadata.getOrDefault("message_id", ""), msg.metadata.getOrDefault("app_id", "")))
    except Exception as e:
      errorCF("agent", "Failed to process message", {"error": e.msg, "session": msg.session_key}.toTable)
      al.bus.publishOutbound(newOutbound(msg.channel, msg.recipient_id, msg.chat_id,
        "I encountered an error while processing your request: " & e.msg,
        msg.metadata.getOrDefault("message_id", ""), msg.metadata.getOrDefault("app_id", "")
      ))

proc newAgentLoop*(cfg: Config, msgBus: MessageBus, provider: LLMProvider, agentName: string = "Lexi", cronService: CronService = nil, model: string = ""): AgentLoop =
  debugCF("agentLoop", "Initializing", {"agent": agentName}.toTable)
  let workspace = cfg.workspacePath()
  let officeDir = workspace / "offices" / agentName.toLowerAscii()
  
  # Load agent-specific environment from office dir
  let agentEnv = officeDir / ".env"
  if fileExists(agentEnv):
    infoCF("agent", "Loading office-specific .env", {"path": agentEnv, "agent": agentName}.toTable)
    for line in readFile(agentEnv).splitLines():
      let pair = line.split("=", 1)
      if pair.len == 2:
        let key = pair[0].strip()
        let val = pair[1].strip()
        if key.len > 0: putEnv(key, val)
  
  createDir(workspace)
  # Office subdirs — runtime state (mail, notes, memory, sessions) only.
  # Skills are discovered from Tier 2 (company) or Tier 3 (workstation/);
  # there is no per-agent human-curated skills tier, so no office/skills/ dir.
  for subdir in ["mail", "notes", "memory", "sessions"]:
    createDir(officeDir / subdir)
  # Workstation subdirs — Tier 3 agent-authored artifacts, all under workstation/
  for subdir in ["skills", "mcp", "script"]:
    createDir(officeDir / "workstation" / subdir)

  # Company-level dirs (foundation/, support/, channels/, logs/) are scaffolded
  # by `claw create` in clawdsl.nim's build step — not recreated here. Running
  # the gateway against a company that was never created is already broken
  # (BASE.json would be missing), so re-creating top-level dirs here would only
  # mask misconfigured state.

  var role = "Agent" # Default fallback
  var entity = "AI"
  var identity = "Agent"
  for a in cfg.agents.named:
    if a.name == agentName:
      if a.role.isSome:
        role = a.role.get()
      if a.entity != "":
        entity = a.entity
      if a.identity != "":
        identity = a.identity
      break

  let toolsRegistry = newToolRegistry()

  # Shared HTTP client for tools (closed in stop())
  let toolCurly = newCurly()

  # Register all tools faithfully as in Go
  var allowedPaths = cfg.agents.security.allowed_paths

  # Initialize SkillsLoader to discover all skill paths for the security allowlist.
  # Must match the paths used by contextBuilder's loader in context.nim — otherwise
  # the agent sees skills in the prompt but can't read/write their files.
  let workstationSkillsDir = workspace / "workstation" / "skills"
  let loader = skills_loader.newSkillsLoader(
    workspace,
    workspace / ".nimclaw" / "workspace" / "competencies",
    getNimClawDir() / "workspace" / "skills",   # Tier 2: company skills
    getNimClawDir() / "foundation" / "skills",           # Tier 1: foundation snapshot
    getEnv("OPENCLAW_EXTENSIONS", getHomeDir() / ".openclaw" / "extensions"),
    workstationSkillsDir
  )

  # Add all discovered skill locations to allowed paths
  for s in loader.listSkills():
    if s.location notin allowedPaths:
      allowedPaths.add(s.location)
  # Also allow the workstation/skills/ root so agents can create new Tier 3 skills
  if workstationSkillsDir notin allowedPaths:
    allowedPaths.add(workstationSkillsDir)

  # Helper: register a tool with tags and optional searchHint
  template regTagged(tool: untyped, tagList: openArray[string], hint: string = "") =
    let t = tool
    t.setTags(@tagList)
    if hint.len > 0: t.setSearchHint(hint)
    toolsRegistry.register(t)

  # --- Core tools (filesystem, exec, clock) ---
  regTagged(newReadFileTool(workspace, officeDir, allowedPaths), ["filesystem", "data", "core"], "read file contents from disk")
  regTagged(newWriteFileTool(workspace, officeDir, allowedPaths), ["filesystem", "data", "core"], "write or create files on disk")
  regTagged(newListDirTool(workspace, officeDir, allowedPaths), ["filesystem", "data", "core"], "list directory contents")
  regTagged(newExecTool(workspace), ["system", "dev", "automation", "core"], "run shell commands and scripts")
  regTagged(newClockTool(), ["utility", "core"], "get current date and time")

  # --- Web tools ---
  regTagged(newWebSearchTool(expandEnv(cfg.tools.web.search.api_key), cfg.tools.web.search.max_results, toolCurly, createMaster()), ["web", "search", "data"], "search the internet for information")
  regTagged(newWebFetchTool(50000, toolCurly, createMaster()), ["web", "http", "data"], "fetch webpage or URL content")
  regTagged(newHttpRequestTool(), ["web", "http", "api"], "make HTTP API requests with headers")

  # --- Dev tools ---
  regTagged(newGitTool(workspace, cfg.agents.security.allowed_paths, officeDir), ["git", "devops", "vcs"], "git version control operations")
  regTagged(newPushoverTool(workspace), ["messaging", "notification"], "send push notifications via Pushover")
  regTagged(newScreenshotTool(workspace), ["visual", "utility"], "capture screenshots of display")
  regTagged(newImageInfoTool(), ["visual", "data"], "get image dimensions and metadata")
  regTagged(newImageAnalyzeTool(), ["visual", "vision", "image"], "analyze image content using vision model")

  let allowedDomainsStr = getEnv("BROWSER_ALLOWED_DOMAINS", "")
  var allowedBrowserDomains: seq[string] = @[]
  if allowedDomainsStr.len > 0:
    for d in allowedDomainsStr.split(','):
      let t = d.strip()
      if t.len > 0: allowedBrowserDomains.add(t)

  regTagged(newBrowserOpenTool(allowedBrowserDomains), ["browser", "web"], "open URLs in web browser")

  let callback: SendCallback = proc(channel, chatID, content, senderAgent, replyToMessageID, appID: string, metadata: Table[string, string] = initTable[string, string]()): Future[void] {.async.} =
    msgBus.publishOutbound(newOutbound(channel, senderAgent, chatID, content, replyToMessageID, appID, metadata))



  # --- Agent & delegation ---
  let subagentManager = newSubagentManager(provider, workspace, msgBus, toolsRegistry, nil)
  regTagged(newSpawnTool(subagentManager), ["agent", "automation"], "spawn autonomous sub-agents for tasks")

  # --- Hardware (unified) ---
  regTagged(newUnifiedHardwareTool(cfg.peripherals.boards), ["hardware", "sensors", "i2c", "spi"], "I2C SPI board info memory read write hardware peripherals")
  regTagged(newDelegateTool(workspace, cfg.agents.named), ["agent", "delegation"], "delegate tasks to other named agents")
  regTagged(newRedeemInviteTool(), ["admin", "core"])

  # --- Tasks & orchestration (unified) ---
  regTagged(newNimclawTool(workspace), ["orchestration", "automation", "messaging"], "assign claim submit tasks send mail to agents")
  regTagged(newUpdateContactTool(officeDir), ["admin", "contacts", "core"], "update contact information in graph")

  # --- Filesystem (edit, append) ---
  regTagged(newEditFileTool(workspace), ["filesystem", "data", "core"], "edit files with find and replace")
  regTagged(newAppendFileTool(workspace), ["filesystem", "data"], "append content to existing files")

  # --- Admin & config ---
  regTagged(newUnifiedMcpTool(toolsRegistry, officeDir), ["admin", "mcp", "skills"], "forge persist purge MCP tool servers skills")
  # learn_skill: author a workstation SKILL.md from structured inputs (enforces invariants).
  # Only exposed to agents with workstation:true — see the auto-add below near the ClawDSL scope block.
  regTagged(newLearnSkillTool(officeDir, toolsRegistry), ["skills", "workstation"], "capture author workstation skill from repeated workflow")
  regTagged(newSetApiKeyTool(getConfigPath()), ["admin", "config"], "configure API keys and secrets")
  # provider_auth: read-only verify of the company's stored API keys. Never
  # exposes the key value to the LLM; never writes .env (that's CLI-only).
  regTagged(newProviderAuthTool(), ["admin", "diagnostics", "providers"],
            "verify provider api key deepseek openai anthropic reachable")
  regTagged(newModelListTool(), ["diagnostics", "providers", "models"],
            "list available llm models capabilities context pricing")
  regTagged(newJqTool(workspace), ["data", "utility"], "transform JSON data with jq expressions")

  let installer = newSkillInstaller(officeDir)
  regTagged(newSkillInstallTool(installer), ["admin", "skills"], "install skill plugins from URL or path")

  # TTS/STT is provided externally by the tts.nim nimble package.
  # Install via `claw skill install tts` — scaffolds workspace/skills/tts/
  # with a bin/tts shim that execs `tts_cli serve` as an MCP stdio server.
  # The generic MCP scan below picks it up; no in-tree engine or tool registration.

  let sessionsManager = newSessionManager(officeDir / "sessions")
  let contextBuilder = newContextBuilder(officeDir, workspace, cfg.agents.named)
  contextBuilder.tools = toolsRegistry # Manually bridge for now
  contextBuilder.agentName = agentName
  contextBuilder.trust = cfg.trust
  # Populate allowedSkills from this agent's ClawDSL uses
  for na in cfg.agents.named:
    if na.name.toLowerAscii() == agentName.toLowerAscii():
      contextBuilder.allowedSkills = na.skills
      break

  # --- Messaging (core) ---
  let msgTool = newMessageTool()
  msgTool.setSendCallback(callback)
  let injectCb: InjectSessionCallback = proc(sessionKey, role, content: string): Future[void] {.async.} =
    sessionsManager.addMessage(sessionKey, role, content)
    sessionsManager.save(sessionsManager.getOrCreate(sessionKey))
  msgTool.setInjectCallback(injectCb)
  msgTool.setTags(@["messaging", "core"])
  msgTool.setSearchHint("send message to a specific person")
  toolsRegistry.register(msgTool)

  let rTool = newReplyTool()
  rTool.setSendCallback(callback)
  rTool.setTags(@["messaging", "core"])
  rTool.setSearchHint("reply to current conversation")
  toolsRegistry.register(rTool)

  let larkTool = newLarkCliTool()
  if larkTool.larkCliBin.len > 0:
    larkTool.setTags(@["feishu", "lark", "docs", "calendar", "platform"])
    larkTool.setSearchHint("feishu lark docs sheets calendar tasks")
    toolsRegistry.register(larkTool)

  let fwdTool = newForwardTool(officeDir)
  fwdTool.setSendCallback(callback)
  fwdTool.setTags(@["messaging", "core"])
  fwdTool.setSearchHint("forward message to another chat")
  toolsRegistry.register(fwdTool)

  # --- Discovery & meta ---
  let findToolInstance = newFindTools(toolsRegistry)
  findToolInstance.setTags(@["utility", "core"])
  findToolInstance.setSearchHint("discover and activate hidden tools")
  toolsRegistry.register(findToolInstance)
  regTagged(newQueryGraphTool(contextBuilder), ["admin", "graph", "core"], "query world graph entities and relations")

  # Phase 400: Scan Tier 1 (foundation), Tier 2 (company), and system-wide MCPs.
  #
  # New layout (post skill-as-package refactor):
  #   Tier 2 Company:  <companyDir>/workspace/skills/<name>/bin/<binname>
  #                    (binaries live inside the skill's own directory)
  #   Tier 1 Found.:   <companyDir>/foundation/mcp/<name>/bin/<binname>
  #   System-wide:     ~/.nimclaw/os/, ~/.nimclaw/mcp/tools/
  #
  # Legacy paths (deprecated, scanned with warning for back-compat):
  #   <companyDir>/workspace/lab/mcp/   (pre-skill-as-package)
  #   <companyDir>/lab/mcp/, <companyDir>/mcp/   (older iterations)
  #   <companyDir>/base/mcp/   (pre-foundation-rename)
  let companyDir = getNimClawDir()
  let companySkillsDir = companyDir / "workspace" / "skills"
  let foundationMcp = companyDir / "foundation" / "mcp"
  let nimclawBase = getHomeDir() / ".nimclaw"
  var searchDirs: seq[(string, string)] = @[  # (path, source-label)
    (companySkillsDir, "company"),         # each skill's bin/ is scanned below
    (foundationMcp, "foundation"),
    (nimclawBase / "os", "system"),
    (nimclawBase / "mcp" / "tools", "system")
  ]
  # Legacy Tier 1 path
  let legacyBaseMcp = companyDir / "base" / "mcp"
  if dirExists(legacyBaseMcp):
    searchDirs.add((legacyBaseMcp, "foundation-legacy"))
    warnCF("agent", "Foundation MCP tools at legacy path — rename <companyDir>/base/ → <companyDir>/foundation/",
      {"legacy_path": legacyBaseMcp, "new_path": foundationMcp}.toTable)
  # Legacy Tier 2 paths
  for (legacyPath, label) in @[
    (companyDir / "workspace" / "lab" / "mcp", "company-legacy-workspace-lab"),
    (companyDir / "lab" / "mcp", "company-legacy-root-lab"),
    (companyDir / "mcp", "company-legacy-root")
  ]:
    if dirExists(legacyPath):
      searchDirs.add((legacyPath, label))
      warnCF("agent", "Company MCP tools at legacy path — move binaries to <companyDir>/workspace/skills/<name>/bin/",
        {"legacy_path": legacyPath, "new_path": companySkillsDir}.toTable)

  for (baseDir, srcLabel) in searchDirs:
    if not dirExists(baseDir): continue
    for kind, path in walkDir(baseDir):
      if kind == pcDir:
        let toolName = path.lastPathPart()
        let binName = if hostOS == "windows": toolName & ".exe" else: toolName
        # Prefer the <dir>/bin/<tool> layout (forge convention); fall back to <dir>/<tool>
        var binaryPath = path / "bin" / binName
        if not fileExists(binaryPath):
          binaryPath = path / binName
        if fileExists(binaryPath):
          infoCF("agent", "Loading persistent MCP tool",
            {"name": toolName, "path": binaryPath, "tier": srcLabel}.toTable)
          # Use 'system' as session key so these aren't purged by per-session cleanup
          discard toolsRegistry.registerMcpServer(binaryPath, @[], "system", @[])
  
  # Phase 401: Scan agent-specific forged MCP tools.
  # Primary path: officeDir/workstation/mcp/ (Tier 3, consistent with workstation/skills/).
  # Legacy paths:
  #   - officeDir/lab/mcp/  (previous generation — rename from "lab" → "workstation")
  #   - officeDir/mcp/      (oldest — pre-Tier-3 consolidation)
  # Legacy paths are scanned with a deprecation warning. Remove after a major release.
  let workstationMcpDir = officeDir / "workstation" / "mcp"
  let legacyLabMcpDir = officeDir / "lab" / "mcp"
  let legacyRootMcpDir = officeDir / "mcp"
  var mcpScanRoots: seq[(string, string)] = @[]  # (path, sourceLabel)
  if dirExists(workstationMcpDir):
    mcpScanRoots.add((workstationMcpDir, "workstation"))
  if dirExists(legacyLabMcpDir):
    mcpScanRoots.add((legacyLabMcpDir, "legacy-lab"))
    warnCF("agent", "Forged MCP tools at legacy path — rename officeDir/lab/ → officeDir/workstation/",
      {"legacy_path": legacyLabMcpDir, "new_path": workstationMcpDir, "agent": agentName}.toTable)
  if dirExists(legacyRootMcpDir):
    mcpScanRoots.add((legacyRootMcpDir, "legacy-root"))
    warnCF("agent", "Forged MCP tools at oldest legacy path — move to officeDir/workstation/mcp/",
      {"legacy_path": legacyRootMcpDir, "new_path": workstationMcpDir, "agent": agentName}.toTable)
  for (scanRoot, sourceLabel) in mcpScanRoots:
    for kind, path in walkDir(scanRoot):
      if kind == pcDir:
        let toolName = path.lastPathPart()
        let binName = if hostOS == "windows": toolName & ".exe" else: toolName
        # Check new structure (bin/tool)
        var binaryPath = path / "bin" / binName
        if not fileExists(binaryPath):
          # Fallback to old structure (root/tool)
          binaryPath = path / binName
        if fileExists(binaryPath):
          infoCF("agent", "Loading forged office-specific MCP tool",
            {"name": toolName, "path": binaryPath, "agent": agentName, "location": sourceLabel}.toTable)
          # Use agent's name as session key for personal forged tools so they persist.
          # Wait for registration so tool names are available for allowedTools merging below.
          try:
            waitFor toolsRegistry.registerMcpServer(binaryPath, @[], agentName, @[])
          except Exception as e:
            warnCF("agent", "Failed to register forged MCP tool",
              {"name": toolName, "error": e.msg}.toTable)
  
  # Phase 402: Register Playwright CLI tool (browser automation)
  # Uses @playwright/cli — a token-efficient CLI designed for AI agents.
  # Single tool with command parameter, replaces 21 individual MCP tools.
  # Browser profile state (cookies, cache, sessions) lives in support/playwright/
  # — not content, not logs, just state the external tool needs between calls.
  let npxPath = findExe("npx")
  if npxPath.len > 0:
    var pwDir = getNimClawDir() / "support" / "playwright"
    # Backward compat: migrate from legacy plugins/playwright/ if present
    let legacyDir = getNimClawDir() / "plugins" / "playwright"
    if dirExists(legacyDir) and not dirExists(pwDir):
      try:
        createDir(getNimClawDir() / "support")
        moveDir(legacyDir, pwDir)
        infoCF("agent", "Migrated playwright profile to support/", {"from": legacyDir, "to": pwDir}.toTable)
      except: discard
    try: createDir(pwDir)
    except: discard
    let pwTool = newPlaywrightTool(pwDir)
    regTagged(pwTool, ["browser", "web", "ui", "automation"], "browser navigate click type screenshot playwright web automation")

  # --- Memory (unified, trust-gated) ---
  # Shares the same MemoryStore the ContextBuilder uses for system-prompt
  # injection so both the auto-injected memory and explicit recall tool
  # calls see exactly the same data (filtered by the same authorisation).
  # The loop updates the tool's requester context before each LLM turn.
  let memTool = newUnifiedMemoryTool(contextBuilder.memory)
  regTagged(memTool, ["memory", "data", "core"], "store recall list forget memory facts preferences trust-gated")

  var al = AgentLoop(
    bus: msgBus,
    provider: provider,
    workspace: workspace,
    officeDir: officeDir,
    cfg: cfg,
    agentName: agentName,
    role: role,
    entity: entity,
    identity: identity,
    model: if model != "": model else: cfg.agents.defaults.model,
    contextWindow: cfg.agents.defaults.max_tokens,
    temperature: cfg.agents.defaults.temperature,
    maxIterations: cfg.agents.defaults.max_tool_iterations,
    sessions: sessionsManager,
    contextBuilder: contextBuilder,
    tools: toolsRegistry,
    findTool: findToolInstance,
    cronService: cronService,
    summarizing: initTable[string, bool](),
    agentId: "",
    curly: toolCurly,
    memTool: memTool
  )
  debugCF("agentLoop", "Instance created", {"agent": agentName}.toTable)
  initLock(al.summarizingLock)

  # Resolve agentId from WorldGraph (nc:ID format)
  if contextBuilder.graph != nil and contextBuilder.graph.nameIndex.hasKey(agentName):
    al.agentId = toAlias(contextBuilder.graph.nameIndex[agentName])
  else:
    al.agentId = agentName  # Fallback to name if no graph

  # Register CronTool using the loop instance for execution
  if cronService != nil:
    let cronExecutor = proc(content, sessionKey, channel, chatID: string): Future[string] {.async.} =
      let msg = InboundMessage(
        channel: channel,
        sender_id: "system:scheduler",
        recipient_id: "",
        chat_id: chatID,
        content: content,
        session_key: sessionKey
      )
      return await al.processMessage(msg)
    
    regTagged(newCronTool(cronService, cronExecutor, msgBus), ["scheduling", "automation", "cron"], "schedule recurring tasks with cron expressions")

  # Apply per-agent ClawDSL scoping (from cfg.agents.named)
  for na in cfg.agents.named:
    if na.name.toLowerAscii() == agentName.toLowerAscii():
      if na.tools.len > 0:
        al.allowedTools = na.tools
      if na.deny.len > 0:
        al.deniedTools = na.deny
      al.workstationEnabled = na.workstation
      if na.tools.len > 0 or na.deny.len > 0 or na.workstation:
        infoCF("agent", "Applied ClawDSL scope",
          {"agent": agentName, "allowed": $na.tools.len, "denied": $na.deny.len, "workstation": $na.workstation}.toTable)
      break

  # If workstation is enabled, auto-expose forged MCP tools registered under this agent's session key.
  # This lets agents call their own forged tools without having to declare them in ClawDSL.
  if al.workstationEnabled and al.allowedTools.len > 0:
    let workstationTools = toolsRegistry.getSessionTools(agentName)
    var added = 0
    for t in workstationTools:
      if t notin al.allowedTools:
        al.allowedTools.add(t)
        inc added
    if added > 0:
      infoCF("agent", "Auto-exposed workstation-forged tools",
        {"agent": agentName, "count": $added, "tools": workstationTools.join(",")}.toTable)
    # learn_skill is the workstation-authoring tool — always available when workstation is on
    if "learn_skill" notin al.allowedTools:
      al.allowedTools.add("learn_skill")

  return al

proc getStartupInfo*(al: AgentLoop): Table[string, JsonNode] =
  var info = initTable[string, JsonNode]()
  info["tools"] = %*{"count": al.tools.list().len, "names": al.tools.list()}
  info["skills"] = %al.contextBuilder.getSkillsInfo()
  return info
