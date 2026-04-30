import std/[json, strutils, asyncdispatch, tables, locks, os, options, sets]
import ../bus, ../bus_types, ../config, ../logger, ../providers/types as providers_types, ../session, ../utils
import ../providers/models_catalog
import ../skill_grant
import ../billing/[subscription as sub_mod, usage as usage_mod]
import context as agent_context
import xml_tools
import ../schema
import ../tools/registry as tools_registry
import ../tools/base as tools_base
import ../tools/loop_detector
import ../tools/[filesystem, edit, shell, spawn, subagent, web, message, reply, forward, remember, memory_unified, http_request, git, pushover, screenshot, image_info, image_analyze, browser_open, hardware_unified, delegate, cron, find, mcp_unified, invite, query_graph, skill_install, config_tools, tasks_unified, update_contact, jq, clock, lark, playwright, learn_skill, provider_auth, model_list, feishu_add_app, create_customer_invite, my_customers]
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
    unionID*: string  ## Feishu tenant-stable ID (cross-app). Resolver
                      ## uses it when the per-app key misses.
    userID*: string   ## Feishu tenant-internal employee ID. Only present
                      ## for tenant members (not external invitees); used
                      ## as a third resolver fallback.
    userMessage*: string
    defaultResponse*: string
    enableSummary*: bool
    sendResponse*: bool
    userRole*: string
    streamIntermediary*: bool
    botDisplayName*: string  ## Channel-resolved bot display name for
                              ## THIS chat (per-chat, not per-agent).
                              ## Threads into the system prompt so the
                              ## agent introduces itself correctly.
                              ## Empty → agent uses its internal name.
    mentionsJson*: string    ## JSON array of Feishu mentions for this
                              ## message. Rendered in the system prompt
                              ## as a Mentions block so tools that need
                              ## @mentioned users' identifiers (e.g.
                              ## `create_customer_invite.bind_identifiers`)
                              ## can reference them.
    preloadedGraph*: WorldGraph  ## Optional — if non-nil, runAgentLoop
                                  ## uses it instead of reloading
                                  ## BASE.json. Gateway threads its
                                  ## per-message graph to skip the
                                  ## duplicate parse.

  TaskSnapshot* = ref object
    ## Per-turn observable state for /agent. One instance per in-flight
    ## turn, keyed by sessionKey on AgentLoop.liveTasks. After the turn
    ## ends the snapshot is moved to AgentLoop.liveLastFinished so the
    ## idle view can show how the last turn wrapped up.
    sessionKey*: string
    senderID*: string
    messagePreview*: string
    startedAt*: float        ## epochTime when the turn began
    finishedAt*: float       ## 0 while running; set when the task ends
    iteration*: int
    maxIterations*: int
    lastTool*: string
    toolLog*: seq[string]
    lastError*: string       ## empty on success
    tokens*: int             ## total tokens consumed this turn (prompt+completion)
    tokensIn*: int           ## prompt_tokens
    tokensOut*: int          ## completion_tokens
    model*: string           ## model name used for this turn (for cost calc)

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
    contextWindow*: int        ## Model's INPUT capacity from the
                               ## canonical catalog (e.g. 1_000_000 for
                               ## deepseek-v4-flash). Drives the
                               ## summarisation threshold — NOT the
                               ## per-request max_tokens.
    maxResponseTokens*: int    ## Per-request OUTPUT cap. Sent as the
                               ## API's `max_tokens` field. From
                               ## `cfg.agents.defaults.max_tokens`,
                               ## bounded by the model's
                               ## `max_output_tokens` if the catalog
                               ## records it.
    temperature*: float
    thinking*: Option[bool]   ## DeepSeek-V4 mode toggle. None = pass
                              ## nothing through; some(false) = disable
                              ## thinking; some(true) = explicitly
                              ## enable. Loaded from cfg.agents.named.
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
    deniedTools*: seq[string]   ## Tool names to exclude
    workstationEnabled*: bool   ## Auto-expose this agent's forged workstation tools
    skillScope*: seq[string]    ## Skill names from ClawDSL `uses` — at turn time
                                ## we prefix-match `mcp_<skill>_*` against the
                                ## live registry. Treats MCP `listTools()` as
                                ## the source of truth rather than the static
                                ## tool list SKILL.md / BASE.json shadow-copies
                                ## (which goes stale on skill refactors).
    # Live state — observable via `/agent <name>` from chat. One entry per
    # in-flight task so concurrent turns (e.g. Jerry + 杰瑞 both on Atlas)
    # each get their own snapshot. Keyed by session_key — same-session
    # messages serialize via the gateway chain, so at most one entry per
    # sessionKey exists at any time.
    liveTasks*: Table[string, TaskSnapshot]  ## currently-running tasks
    liveLastFinished*: TaskSnapshot          ## most recently completed; nil if never ran
    liveTurnCount*: int                      ## monotonic count of completed turns
    liveTokensTotal*: int                    ## cumulative tokens since gateway start
    liveTokensInTotal*: int                  ## cumulative prompt_tokens
    liveTokensOutTotal*: int                 ## cumulative completion_tokens

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

proc resolveContextWindow*(modelName: string, fallback: int): int =
  ## Look up the model's INPUT limit from the canonical catalog
  ## (`res/models.json`). Used to size the summarisation threshold,
  ## NOT to set the per-request `max_tokens` field.
  ##
  ## Tries (in order):
  ##   1. exact id (e.g. "deepseek/deepseek-v4-flash")
  ##   2. as canonical id with `<vendor>/` prefix scan
  ##   3. fallback to caller-supplied default
  if modelName.len == 0: return fallback
  let cat = effectiveCatalog()
  if cat.canonical.hasKey(modelName):
    let ctx = cat.canonical[modelName].contextLength
    if ctx > 0: return ctx
  for canonicalId, canonical in cat.canonical.pairs:
    if canonicalId.endsWith("/" & modelName):
      if canonical.contextLength > 0: return canonical.contextLength
  fallback

proc resolveMaxOutputTokens*(modelName: string, requested: int): int =
  ## Bound the per-request output cap by the model's published
  ## `max_output_tokens`. Operators set `agents.defaults.max_tokens`
  ## (the *requested* output cap) without knowing each provider's
  ## ceiling — sending above the ceiling triggers 400. We clamp here
  ## so a high request like 32k still works on a model whose ceiling
  ## is 8k or 384k, without operator guesswork per-model.
  ##
  ## If the catalog doesn't record a cap, the requested value is
  ## returned unchanged (defer to the operator's setting and let the
  ## provider enforce its own limit if any).
  if modelName.len == 0: return requested
  let cat = effectiveCatalog()
  var modelCap = 0
  if cat.canonical.hasKey(modelName):
    modelCap = cat.canonical[modelName].maxOutputTokens
  if modelCap == 0:
    for canonicalId, canonical in cat.canonical.pairs:
      if canonicalId.endsWith("/" & modelName):
        modelCap = canonical.maxOutputTokens
        if modelCap > 0: break
  if modelCap > 0 and requested > modelCap: return modelCap
  requested

proc summarizeBatch(al: AgentLoop, batch: seq[providers_types.Message], existingSummary: string): Future[string] {.async.} =
  ## Structured facts-sheet summary instead of narrative prose. Each
  ## summarisation cycle UPDATES sections (carry forward + add new
  ## entries + mark resolved) rather than rewriting prose, so concrete
  ## facts don't drift away across multiple cycles.
  ##
  ## Domain-neutral by design — the section schema applies equally to
  ## solar analysis, customer support, code review, scheduling, or
  ## anything else an agent does. Domain-specific guidance (what
  ## counts as a "key fact" for THIS competency) belongs in the
  ## agent's competency HANDBOOK, not here.
  var prompt = """You are summarising a working conversation between a
user and an AI agent. Your output IS the agent's only memory of this
segment in future turns — write a structured facts sheet, not a
narrative.

Use exactly these markdown section headers. Omit a section only when
it would be genuinely empty for this conversation.

## Goal
One line: what the user is ultimately trying to achieve in this
thread. If the goal shifted, note when and to what.

## Established Facts
Concrete things that became true during the conversation: values
discovered, results computed, files created, identities confirmed,
external state observed. One per line. Quote numbers, paths, names,
ids verbatim from the conversation. If a value isn't in the
messages, write `(unspecified)` rather than guess.

## Decisions
What was tried, what was kept, what was rejected and the reason.
Format each as either:
- DECIDED <date>: <decision> — <one-line rationale>
- REJECTED <date>: <option> — <reason>

## Current State
What's running, what's pending, what artifacts exist. Concrete and
checkable — paths, process ids, statuses, not adjectives.

## Open Questions
Things the user explicitly asked about but didn't get a final answer
on, or that the agent flagged as needing review.

## Recent Tool Outputs
Consequential tool runs in this segment with their result shape (not
full content). Helps the agent recall what it has already computed
without re-running.

CARRY-FORWARD RULES:
- Keep prior facts that are still relevant.
- Mark superseded ones `(SUPERSEDED <date>)` rather than deleting,
  so the audit trail stays intact.
- Don't paraphrase numbers, paths, or names from the conversation —
  copy them verbatim. If you can't find a value, write
  `(unspecified)`.
- No filler, no re-narration of dialogue.

"""
  if existingSummary != "":
    prompt.add("PREVIOUS FACTS SHEET (carry forward what still applies):\n")
    prompt.add(existingSummary)
    prompt.add("\n\n")
  prompt.add("CONVERSATION SEGMENT TO INCORPORATE:\n")
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
    # Keep more raw turns visible after summarisation. The previous
    # value (4 messages = ~2 user/assistant pairs) was set when the
    # context budget was being treated as 8k, so the live window had
    # to stay tiny. With a 1M-token model and token-based triggering,
    # 30 leaves Lexi enough recent context to recall last hour's work
    # without the LLM seeing everything since the dawn of the session.
    al.sessions.truncateHistory(sessionKey, 30)
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
  # 75% of the model's actual context window. Pure token-based —
  # no message-count short-circuit. The old `history.len > 20` cap
  # fired at <1% of a 1M-token model's capacity and was responsible
  # for the "Lexi forgets everything" pattern: long analytical
  # threads got summarised every ~10-20 messages, and each rewrite
  # diluted the previous summary, so older facts vanished into a
  # one-paragraph blob.
  let threshold = (al.contextWindow * 75) div 100

  if tokenEstimate > threshold:
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

proc trySelfHealHiddenTool(al: AgentLoop, toolName, dispatchKind: string): Option[string] =
  ## If `toolName` is hidden and not activated this turn, activate it
  ## (so its schema shows in the next iteration's `tools:` field) and
  ## return an error-string payload containing the schema inline. The
  ## LLM reads the schema from the tool result and retries with correct
  ## params on the next iteration — no find_tools detour.
  ##
  ## Returns `none` when the tool should dispatch normally (not hidden,
  ## or already activated). Called from both JSON and XML dispatch.
  if al.findTool == nil: return none(string)
  if not al.tools.isHidden(toolName): return none(string)
  if toolName in al.findTool.getActivatedSet(): return none(string)
  let (tool, found) = al.tools.get(toolName)
  if not found:
    warnCF("agent", "Tool not found in registry", {"tool": toolName}.toTable)
    return some("Error: tool '" & toolName & "' is not registered. " &
                "Call find_tools(query=\"…\") to discover what's available.")
  al.findTool.activateWithTTL(toolName)
  let schema = toolToSchema(tool, inferStrategy(al.model))
  let schemaJson = (%*{
    "name": schema.function.name,
    "description": schema.function.description,
    "parameters": schema.function.parameters
  }).pretty(2)
  warnCF("agent", "Auto-activated deferred tool on " & dispatchKind & " direct call",
         {"tool": toolName}.toTable)
  some("Error: tool '" & toolName & "' was called without its schema " &
       "being in your tool list, so your arguments may not match the " &
       "real parameter names. I've activated it for this and the next " &
       "turn. Its actual schema is:\n\n" & schemaJson &
       "\n\nRetry the call with these parameter names.")

proc runLLMIteration(al: AgentLoop, ctx: TaskContext, messages: seq[providers_types.Message], opts: ProcessOptions, logicalUserID: string, allowedTools: seq[string], snapshot: TaskSnapshot): Future[(string, int, seq[providers_types.Message])] {.async.} =
  ## `allowedTools` is the dispatch-time allowlist for THIS turn (role.grant +
  ## allowed_skills expansion). Passed by value so concurrent turns on the
  ## same agent don't clobber each other.
  ## `snapshot` is this task's live-state record on AgentLoop.liveTasks —
  ## mutate iteration, lastTool, tokens etc. through it rather than on `al`.
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

  # Sanitize history before sending to the provider. Two failure modes
  # to handle:
  #
  # 1) Tool message without a preceding assistant.tool_calls — orphan.
  #    Drop it. (Original behaviour.)
  #
  # 2) Assistant.tool_calls without all tool_call_ids covered by
  #    immediately-following `tool` messages — incomplete pairing.
  #    Strip the tool_calls field; otherwise the provider rejects with
  #    400 "An assistant message with 'tool_calls' must be followed by
  #    tool messages responding to each tool_call_id". This happens
  #    when (a) tool results were stored as `role: "user"` in legacy
  #    sessions and lost their pairing on replay, or (b) the gateway
  #    crashed mid-tool-execution and the session has the assistant
  #    turn but not the tool results.
  block:
    var clean: seq[providers_types.Message] = @[]
    var droppedOrphans = 0
    var strippedTcs = 0
    var i = 0
    while i < currentMessages.len:
      var m = currentMessages[i]
      if m.role == "tool":
        let prevHadTcs =
          clean.len > 0 and clean[^1].role == "assistant" and
          clean[^1].tool_calls.len > 0
        if not prevHadTcs:
          inc droppedOrphans
          inc i
          continue
      elif m.role == "assistant" and m.tool_calls.len > 0:
        var expected = initHashSet[string]()
        for tc in m.tool_calls:
          if tc.id.len > 0: expected.incl(tc.id)
        var responded = initHashSet[string]()
        var j = i + 1
        while j < currentMessages.len and currentMessages[j].role == "tool":
          if currentMessages[j].tool_call_id.len > 0:
            responded.incl(currentMessages[j].tool_call_id)
          inc j
        var allCovered = true
        for need in expected:
          if need notin responded:
            allCovered = false
            break
        if not allCovered:
          m.tool_calls = @[]
          if m.content.len == 0:
            m.content = "[tool execution interrupted — results not preserved]"
          inc strippedTcs
      clean.add(m)
      inc i
    if droppedOrphans > 0 or strippedTcs > 0:
      warnCF("agent", "Sanitized history",
             {"orphan_tools_dropped": $droppedOrphans,
              "incomplete_tool_calls_stripped": $strippedTcs}.toTable)
      currentMessages = clean

  while iteration < al.maxIterations and finalContent == "":
    iteration += 1
    snapshot.iteration = iteration
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
        if al.allowedTools.len > 0 or al.skillScope.len > 0:
          var final: seq[string]
          var seen = initHashSet[string]()
          template addTool(name: string) =
            if name notin seen and name notin al.deniedTools:
              seen.incl(name); final.add(name)
          for t in al.allowedTools: addTool(t)
          # Skill-prefix expansion — `uses "sungrow"` in ClawDSL means
          # "whatever the sungrow skill's MCP server currently exposes."
          # We match `mcp_<skill>_*` against the live registry each turn
          # so a skill refactor (new tool names, deprecated ones) takes
          # effect without a `co update` + BASE.json regeneration. MCP's
          # `listTools()` is the source of truth; BASE.json's `tools: [...]`
          # becomes advisory.
          if al.skillScope.len > 0:
            for sk in al.skillScope:
              for t in al.tools.listByPrefix("mcp_" & sk & "_"):
                addTool(t)
          # Include tools explicitly activated via `find_tools` this
          # turn — activation is an explicit gesture and needed as a
          # last-resort escape hatch when a tool lives outside any
          # declared skill.
          if al.findTool != nil:
            for t in al.findTool.getActivatedSet(): addTool(t)
          al.tools.getDefinitionsFiltered(strategy, final)
        elif roleLow in ["guest", "customer"]:
          al.tools.getDefinitionsFiltered(strategy, @(tools_registry.ExternalAllowedTools))
        else:
          let activatedSet = if al.findTool != nil: al.findTool.getActivatedSet()
                             else: initHashSet[string]()
          let (defs, hiddenNames) = al.tools.getDefinitionsDeferred(strategy, activatedSet)
          # Inject taxonomy into system message on first iteration.
          # The banner is blunt because some models otherwise see a
          # tool listed by name and dispatch it with guessed parameter
          # names. The tools below have no schemas loaded this turn;
          # the LLM cannot call them directly.
          if iteration == 1 and hiddenNames.len > 0:
            let taxonomy = al.tools.generateTaxonomy()
            if taxonomy.len > 0 and currentMessages.len > 0 and currentMessages[0].role == "system":
              currentMessages[0].content.add(
                "\n\n## Additional Tools (schemas NOT loaded)\n\n" &
                "The tools below are registered but their parameter " &
                "schemas are not in this turn's tool list. **You cannot " &
                "call them directly** — if you try, you will guess " &
                "parameter names and the call will fail.\n\n" &
                "To use any of these, FIRST call `find_tools` with " &
                "relevant keywords (e.g. `find_tools(query=\"solar " &
                "history\")`). That activates the tool's schema for " &
                "the rest of this turn. Only then dispatch the tool.\n\n" &
                "Categories:\n" & taxonomy)
              infoCF("agent", "Deferred tool loading", {"core_schemas": $defs.len, "hidden": $hiddenNames.len, "activated": $activatedSet.len}.toTable)
          defs

    var options = {
      "max_tokens": %al.maxResponseTokens,
      "temperature": %al.temperature
    }.toTable
    if al.thinking.isSome:
      # Surfaced to the HTTP provider, which translates it into the
      # provider-specific wire format (DeepSeek V4: extra_body
      # `thinking: {type: enabled|disabled}`). For models that don't
      # implement the toggle the provider ignores the option.
      options["thinking"] = %al.thinking.get
    
    var response: LLMResponse
    try:
      response = await al.provider.chat(currentMessages, toolDefs, al.model, options)
    except Exception as e:
      errorCF("agent", "LLM API request failed", {"error": e.msg, "iteration": $iteration}.toTable)
      snapshot.lastError = "LLM: " & e.msg
      if finalContent == "":
        finalContent = "Error communicating with LLM provider: " & e.msg
      break

    # Accumulate tokens — per-task (for logAction telemetry), per-turn
    # snapshot (for /agent display), and per-agent totals (for /status
    # and /cost). Split input/output so /cost can apply the right
    # per-M rate to each half.
    let tokens = response.usage.total_tokens
    let tokensIn = response.usage.prompt_tokens
    let tokensOut = response.usage.completion_tokens
    ctx.tokensTotal += tokens
    snapshot.tokens += tokens
    snapshot.tokensIn += tokensIn
    snapshot.tokensOut += tokensOut
    al.liveTokensTotal += tokens
    al.liveTokensInTotal += tokensIn
    al.liveTokensOutTotal += tokensOut

    # Billing accounting — accumulate into the per-customer UTC daily
    # counter so tomorrow's gate pre-check (`tokensToday >= dailyTokens`)
    # sees accurate usage. Only track nc:id-shaped users who actually
    # have a subscription stamped; internal users and legacy guests
    # have no cap to enforce, so tracking them would just churn files.
    # This runs per-LLM-iteration so multi-turn tool calls count all
    # their intermediate calls, not just the final response.
    if logicalUserID.startsWith("nc:") and loadSubscription(logicalUserID).isSome:
      discard addTokens(logicalUserID, tokensIn, tokensOut)
    
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
        var result: string
        let heal = trySelfHealHiddenTool(al, xmlCall.name, "XML")
        if heal.isSome:
          result = heal.get()
        else:
          result = await al.tools.executeWithContext(xmlCall.name, xmlCall.arguments, toolCtx)
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
          # Detect incomplete responses: LLM describes next steps instead of giving results.
          # Two patterns get nudged:
          #   (a) Mid-task: iteration > 3, we've been tool-calling, now short status text.
          #   (b) First turn narration: iteration 1, no tool calls yet, content announces
          #       intent ("让我...", "我将...", "I'll check") — classic DeepSeek lazy-narrate
          #       pattern where the model describes the next action instead of taking it.
          let endsPromisey = trimmed.endsWith(":") or trimmed.endsWith("：") or
                              trimmed.endsWith(",") or trimmed.endsWith("。") or
                              trimmed.endsWith(".")
          let looksIntentOnly =
            trimmed.contains("让我") or trimmed.contains("我将") or
            trimmed.contains("稍等") or trimmed.contains("马上") or
            trimmed.contains("I'll ") or trimmed.contains("I will ") or
            trimmed.contains("Let me ")
          let midTaskStall = iteration > 3 and toolCallLog.len >= 3 and
                              trimmed.len < 200 and endsPromisey
          let firstTurnNarration = iteration == 1 and toolCallLog.len == 0 and
                                    looksIntentOnly
          if (midTaskStall or firstTurnNarration) and emptyRetries < 2:
            emptyRetries.inc
            warnCF("agent", "LLM narrated intent without tool call, nudging to act",
                   {"iteration": $iteration, "retry": $emptyRetries,
                    "pattern": (if firstTurnNarration: "first-turn-narration" else: "mid-task-stall"),
                    "preview": trimmed[0..min(trimmed.len-1, 80)]}.toTable)
            currentMessages.add(providers_types.Message(role: "assistant",
              content: response.content,
              reasoning_content: response.reasoning_content))
            currentMessages.add(providers_types.Message(role: "user", content: "You described what you plan to do but did not call a tool. Take the action NOW: emit the tool call in this turn. Do not respond with words alone."))
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
        # Cap empty-name retries at 2; DeepSeek rarely self-corrects past
        # that and it's usually a schema / context-size issue, not a
        # transient glitch.
        emptyNameRetries += 1
        if emptyNameRetries > 2:
          warnCF("agent", "Too many empty tool name retries, breaking", {"iteration": $iteration}.toTable)
          snapshot.lastError = "Tool protocol: LLM emitted empty tool names " &
                             $emptyNameRetries & "× in a row — check tool schema / context size."
          # Skip the post-loop summary call — same schema would likely
          # trip it again.
          finalContent =
            if response.content.len > 0: response.content
            else: "I couldn't complete this task — the tool-calling protocol broke down (empty tool names). Please rephrase or try again. If this recurs, the tool schema may be too large for the model."
          break
        warnCF("agent", "LLM returned empty tool names, nudging to continue", {"iteration": $iteration, "retry": $emptyNameRetries}.toTable)
        if response.content.len > 0:
          currentMessages.add(providers_types.Message(role: "assistant",
            content: response.content,
            reasoning_content: response.reasoning_content))
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
        let heal = trySelfHealHiddenTool(al, tc.name, "JSON")
        if heal.isSome:
          result = heal.get()
        elif allowedTools.len > 0 and tc.name notin allowedTools:
          warnCF("agent", "Tool refused — not in requester's role.grant",
            {"tool": tc.name, "allowed": allowedTools.join(",")}.toTable)
          result = "Error: tool '" & tc.name & "' is not authorised at the current requester's trust level. Allowed tools are: " & allowedTools.join(", ") & ". If the user needs a higher-privilege action, they must upgrade via redeem_invite or a SuperAdmin must edit BASE.nims."
        else:
          snapshot.lastTool = tc.name
          snapshot.toolLog.add(tc.name)
          # Mark this call as pre-authorised when we have an explicit
          # role.grant + allowed_skills allowlist AND the tool cleared
          # it. The registry's blanket external-user gate will then
          # skip — an explicit grant overrides the safety-net floor.
          # Turns where turnAllowedTools is empty (no trust config)
          # keep preAuthorized=false so the floor still protects.
          var ctxForCall = toolCtx
          if allowedTools.len > 0 and tc.name in allowedTools:
            ctxForCall.preAuthorized = true
          result = await al.tools.executeWithContext(tc.name, tc.arguments, ctxForCall)
        # Record in tool call log for forced summary context
        let resultPreview = if result.len > 200: result[0..199] & "..." else: result
        toolCallLog.add("[" & $iteration & "] " & tc.name & " → " & resultPreview)
        let toolResultMsg = providers_types.Message(role: "tool", content: result, tool_call_id: tc.id, name: tc.name)
        currentMessages.add(toolResultMsg)
        al.sessions.addFullMessage(opts.sessionKey, toolResultMsg)

      # reply/message already delivered the turn's final content — break
      # before the LLM gets another turn and calls reply again.
      if ctx.responseSent:
        break

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
  ##   group chat                            → grp_<channel>_<chatID>_<senderID>
  ##                                           (per-sender inside the room;
  ##                                           each @mentioner has their own
  ##                                           conversation history with the
  ##                                           bot, so the LLM doesn't
  ##                                           interleave two participants'
  ##                                           turns and mix up who's asking)
  ##   DM / unknown                          → key by the sender's nc:id:
  ##     resolved graph entity               → nc_N
  ##     first-time sender                   → add to graph as Guest,
  ##                                           return their fresh nc:N
  ##
  ## Earlier design used a single shared session file per room. That
  ## broke when two users @mentioned the bot in the same group — the
  ## model saw both speakers' turns in a flat list and answered one
  ## person using the other's identity/context. Per-sender is strictly
  ## safer for @mention-triggered responses (groups don't auto-respond
  ## anyway as of the group-chat policy change).
  if opts.sessionKey.startsWith("system:"):
    return opts.sessionKey.replace(":", "_")

  proc sanitize(s: string): string =
    result = s
    for c in mitems(result):
      if c in {':', '/', '\\', ' ', '\t'}: c = '_'

  # Group chats: per-(chat, sender) session so each @mentioning user
  # has an isolated conversation with the bot.
  if opts.chatKind == ckGroup and opts.chatID.len > 0:
    let sid = if opts.senderID.len > 0: opts.senderID else: "anon"
    return "grp_" & opts.channel & "_" &
           sanitize(opts.chatID) & "_" & sanitize(sid)
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

  # Feishu cross-app fallback chain: union_id (per-tenant) → user_id
  # (tenant-internal employee ID) → auto-register. Fast-path caches
  # the per-app open_id on any hit.
  if uint32(entityID) == 0 and opts.channel == "feishu":
    if opts.unionID.len > 0:
      let (uID, _) = graph.resolveUserGraph(
        "feishu:union", opts.unionID, agentId)
      if uint32(uID) > 0: entityID = uID
    if uint32(entityID) == 0 and opts.userID.len > 0:
      let (uID, _) = graph.resolveUserGraph(
        "feishu:user", opts.userID, agentId)
      if uint32(uID) > 0: entityID = uID
    if uint32(entityID) > 0:
      # Stamp the per-app key for future fast-path lookups.
      var ent = graph.entities[entityID]
      ent.identifiers[channelKey] = opts.senderID
      graph.entities[entityID] = ent
      graph.saveWorld()

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

proc requesterGrantedSkills(graph: WorldGraph, logicalUserID: string): seq[string] =
  ## Resolve the requester's entity (by nc:id) and return the lowercased
  ## `skill` name for each entry in their `custom.allowed_skills`. Empty
  ## seq when the id doesn't resolve, the entity has no `custom`, or the
  ## field is missing/malformed. Used by the dispatch gate to expand
  ## turnAllowedTools on top of role.grant for per-requester skill access.
  if graph == nil: return
  let id = parseAlias(logicalUserID)
  if uint32(id) == 0 or not graph.entities.hasKey(id): return
  let ent = graph.entities[id]
  if ent.custom == nil or not ent.custom.hasKey("allowed_skills"): return
  let arr = ent.custom["allowed_skills"]
  if arr.kind != JArray: return
  for raw in arr:
    let (ok, g, _) = parseSkillGrant(raw.getStr(""))
    if ok and g.skill.len > 0:
      let s = g.skill.toLowerAscii()
      if s notin result: result.add(s)

proc runAgentLoop*(al: AgentLoop, optsParam: ProcessOptions): Future[string] {.async.} =
  var opts = optsParam
  # CLI channel = owner's terminal. Trust as Admin unless explicitly set.
  if opts.userRole == "" and opts.channel == "cli": opts.userRole = "Admin"
  if opts.userRole == "": opts.userRole = "Guest"

  # Stamp live state so `/agent <name>` can observe in-flight work from
  # chat. One snapshot per sessionKey lives in al.liveTasks while running;
  # when this turn exits we move it to al.liveLastFinished for the idle-
  # view post-mortem (iteration, tool log, error).
  let snapshot = TaskSnapshot(
    sessionKey: opts.sessionKey,
    senderID: opts.senderID,
    messagePreview: (if opts.userMessage.len > 80: opts.userMessage[0 ..< 80] & "…"
                     else: opts.userMessage),
    startedAt: epochTime(),
    maxIterations: al.maxIterations,
    toolLog: @[],
    model: al.model)
  al.liveTasks[opts.sessionKey] = snapshot
  defer:
    snapshot.finishedAt = epochTime()
    al.liveLastFinished = snapshot
    al.liveTurnCount.inc
    al.liveTasks.del(opts.sessionKey)
  # Refresh the cached graph so identifiers stamped by the gateway's
  # bind/invite pipeline are visible for resolution. If the caller
  # already loaded (and possibly mutated) a graph for this message,
  # reuse it — saves a redundant BASE.json parse and keeps the pre-LLM
  # intercepts consistent with runAgentLoop's view.
  if al.contextBuilder != nil:
    al.contextBuilder.graph =
      if opts.preloadedGraph != nil: opts.preloadedGraph
      else: loadWorld(al.workspace)

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
    cortex.saveMood(al.officeDir, al.contextBuilder.mood)

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
      # Feishu cross-app fallback chain: union_id → user_id → register.
      # Stamps the per-app key on any hit for fast-path future lookups.
      if uint32(entityID) == 0 and opts.channel == "feishu":
        if opts.unionID.len > 0:
          let (uID, _) = al.contextBuilder.graph.resolveUserGraph(
            "feishu:union", opts.unionID, agentId)
          if uint32(uID) > 0: entityID = uID
        if uint32(entityID) == 0 and opts.userID.len > 0:
          let (uID, _) = al.contextBuilder.graph.resolveUserGraph(
            "feishu:user", opts.userID, agentId)
          if uint32(uID) > 0: entityID = uID
        if uint32(entityID) > 0:
          var ent = al.contextBuilder.graph.entities[entityID]
          ent.identifiers[chKey] = opts.senderID
          al.contextBuilder.graph.entities[entityID] = ent
          al.contextBuilder.graph.saveWorld()
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
      let (legacyID, found) = al.contextBuilder.guests.resolveUser(opts.channel, opts.senderID)
      if found:
        logicalUserID = legacyID
        isKnown = true

    if isKnown and opts.userRole == "Guest" and al.contextBuilder.guests.hasKey(logicalUserID):
      let ident = al.contextBuilder.guests[logicalUserID].identity
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
            
            # Invite carries the customer's human name → ekPerson.
            let newEntityID = al.contextBuilder.graph.addUserToGraph(
              newID,
              opts.senderID,
              parseEnum[UserRole](inv.role, urGuest),
              agentId,
              50,
              ekPerson
            )
            logicalUserID = toAlias(newEntityID)
          else:
            # Legacy Onboarding — kind defaults to unknown; only NKN
            # subname pattern is strong evidence (service/AI agent).
            var kind = ekUnknown
            if opts.channel == "nkn" and opts.senderID.contains("."):
              kind = ekAI

            al.contextBuilder.guests[newID] = newGuest(
              opts.channel, opts.senderID,
              name = newID,
              identity = $parseEnum[UserRole](inv.role, urGuest),
              trustLevel = 50, kind = kind)
            saveGuests(al.officeDir, al.contextBuilder.guests)
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
        # Default: unknown. Only classify as AI on strong evidence
        # (NKN subname means a service/agent address).
        var kind = ekUnknown
        if opts.channel == "nkn" and opts.senderID.contains("."):
          kind = ekAI
        
        al.contextBuilder.guests[logicalUserID] = newGuest(
          opts.channel, opts.senderID,
          name = logicalUserID, kind = kind,
          etiquette = "Professional guest service protocol.")
        saveGuests(al.officeDir, al.contextBuilder.guests)
        infoCF("agent", "Recorded new guest contact", {"id": logicalUserID, "kind": $kind, "channel": opts.channel}.toTable)
      else:
        # Update existing entry if needed (e.g. if identification changed)
        var rel = al.contextBuilder.guests[logicalUserID]
        var changed = false
        if not rel.identifiers.hasKey(opts.channel):
          rel.identifiers[opts.channel] = @[opts.senderID]
          changed = true
        elif opts.senderID notin rel.identifiers[opts.channel]:
          rel.identifiers[opts.channel].add(opts.senderID)
          changed = true
          
        if changed:
          al.contextBuilder.guests[logicalUserID] = rel
          saveGuests(al.officeDir, al.contextBuilder.guests)

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
    # Local var (not an AgentLoop field) so concurrent same-agent turns
    # don't clobber each other's allowlist mid-dispatch.
    var allowedTools: seq[string] = @[]
    let reqRole = al.contextBuilder.resolveRequesterRole(
      logicalUserID, targetRecipient, opts.channel)
    # Propagate the resolved role onto ProcessOptions so the tool
    # context (buildToolContext → ToolContext.role) reflects it —
    # tools like feishu_add_app use this for their own permission
    # checks. Falls back to the declared entity-level permission
    # (ent.role) when no relationship annotation exists.
    if reqRole.len > 0:
      opts.userRole = reqRole
    if al.contextBuilder.trust.roles.len > 0:
      let roleCfg = findTrustRole(al.contextBuilder.trust, reqRole)
      if roleCfg.isSome:
        let g = roleCfg.get.grant
        if g.len > 0 and "*" notin g:
          allowedTools = g

    # Per-requester skill grants. The requester's Person entity can carry
    # `custom.allowed_skills = ["[user@]skill[/resource,…]", …]` — each
    # entry grants this specific requester the tools from that skill,
    # *on top of* their role's generic grant. This is the per-customer
    # isolation path: a Customer role can stay locked down for writes/
    # admin tools, while an individual customer (e.g. JK with
    # `njmkuser@sungrow`) gets sungrow read tools they're entitled to.
    # Resource-level scoping (`sungrow/627305`) is declared but enforced
    # at the tool-call argument layer — still a follow-up.
    if allowedTools.len > 0 and
       al.contextBuilder != nil and al.contextBuilder.graph != nil and
       logicalUserID.startsWith("nc:"):
      let grantedSkills = requesterGrantedSkills(al.contextBuilder.graph, logicalUserID)
      if grantedSkills.len > 0:
        var extra: seq[string]
        # MCP server tools land as `mcp_<server>_<tool>` and the server
        # name IS the skill name — scan the registry for any granted prefix.
        for tn in al.tools.list():
          let lower = tn.toLowerAscii()
          for sk in grantedSkills:
            if lower.startsWith("mcp_" & sk & "_") and tn notin allowedTools:
              extra.add(tn)
              break
        if extra.len > 0:
          infoCF("agent", "Per-requester skill grants expanded role.grant",
                 {"requester": logicalUserID,
                  "skills": grantedSkills.join(","),
                  "tools_added": $extra.len}.toTable)
          for t in extra: allowedTools.add(t)

    infoCF("agent", "Resolved sender",
           {"raw_sender": opts.senderID,
            "logicalUserID": logicalUserID,
            "session_key": opts.sessionKey,
            "chat_kind": $opts.chatKind}.toTable)
    var messages = al.contextBuilder.buildMessages(logicalUserID, history, summary, opts.userMessage, opts.channel, opts.chatID, useXmlTools, targetRecipient, opts.botDisplayName, opts.mentionsJson, opts.appID)

    # Store the user's message in history WITHOUT the nc:id prefix.
    # With per-sender session keys (see identitySessionKey for group
    # chats), the session only contains one speaker's turns anyway, so
    # the prefix is redundant. It also caused the LLM to echo the nc:id
    # back to the user in replies. `addWithSpeaker` preserves the
    # speaker's nc:id separately for any tool that cares.
    al.sessions.addWithSpeaker(opts.sessionKey, "user",
      opts.userMessage, logicalUserID)

    # Immediate feedback: notify bus that bot is "typing"
    al.bus.publishOutbound(OutboundMessage(
      channel: opts.channel,
      sender_agent: opts.recipientID,
      chat_id: opts.chatID,
      kind: Typing,
      reply_to_message_id: opts.replyToMessageID,
      app_id: opts.appID
    ))

    let (finalContentRaw, iteration, _) = await al.runLLMIteration(ctx, messages, opts, logicalUserID, allowedTools, snapshot)
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

proc processMessage*(al: AgentLoop, msg: InboundMessage,
                     preloadedGraph: WorldGraph = nil): Future[string] {.async.} =
  ## If `preloadedGraph` is non-nil, runAgentLoop reuses it instead of
  ## doing its own `loadWorld`. Gateway threads its per-message graph
  ## through so the 4-block pre-LLM pipeline plus runAgentLoop share a
  ## single load per inbound message (down from 5).
  infoCF("agent", "Processing message from " & msg.channel & ":" & msg.sender_id,
    {"session_key": msg.session_key, "chat_kind": $msg.chat_kind, "chat_id": msg.chat_id}.toTable)

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
    unionID: msg.metadata.getOrDefault("union_id", ""),
    userID: msg.metadata.getOrDefault("user_id", ""),
    userMessage: msg.content,
    defaultResponse: "I've completed processing but have no response to give.",
    enableSummary: true,
    sendResponse: false,
    streamIntermediary: channelStreamIntermediary,
    preloadedGraph: preloadedGraph,
    botDisplayName: msg.metadata.getOrDefault("bot_display_name", ""),
    mentionsJson: msg.metadata.getOrDefault("mentions", "")
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

proc newAgentLoop*(cfg: Config, msgBus: MessageBus, provider: LLMProvider, agentName: string = "Lexi", cronService: CronService = nil, model: string = "", askPeer: delegate.AskPeer = nil): AgentLoop =
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
  regTagged(newDelegateTool(workspace, cfg.agents.named, askPeer = askPeer), ["agent", "delegation"], "delegate tasks to other named agents")
  regTagged(newRedeemInviteTool(), ["admin", "core"])

  # --- Tasks & orchestration (unified) ---
  regTagged(newNimclawTool(workspace), ["orchestration", "automation", "messaging"], "assign claim submit tasks send mail to agents")
  # update_contact moved to after contextBuilder creation — it needs
  # the ContextBuilder for Guest-ledger writes.

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
  # SuperAdmin-only: chat-driven Feishu app registration. Lets the
  # SuperAdmin add new apps without dropping to `claw channel auth`.
  regTagged(newFeishuAddAppTool(), ["admin", "channels", "feishu"],
            "register new feishu lark app id secret route agent")
  # SuperAdmin-only: chat-driven customer onboarding. Creates a Person
  # entity + invite code; returns an `nc:X/CODE` string to share.
  regTagged(newCreateCustomerInviteTool(), ["admin", "customer", "invite"],
            "create customer invite code onboarding nc:id bundled string")
  # Internal-tier self-service: lets any internal user ask their
  # agent "how many customers have I invited?" without a slash.
  regTagged(newMyCustomersTool(workspace), ["customer", "invite", "stats"],
            "my customers count list onboarded invited referrals")
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

  regTagged(newUpdateContactTool(officeDir, contextBuilder), ["admin", "contacts", "core"], "update contact information in graph or guest ledger")

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
          # Use 'system' as session key so these aren't purged by per-session cleanup.
          # `waitFor` instead of `discard` — otherwise the registration task is
          # scheduled but not guaranteed to complete before the first turn.
          # That leaves downstream consumers (e.g. per-requester skill-grant
          # expansion that scans `tools.list()` for `mcp_<skill>_*` prefixes)
          # querying an incomplete registry and finding nothing to grant.
          try:
            waitFor toolsRegistry.registerMcpServer(binaryPath, @[], "system", @[])
          except Exception as e:
            errorCF("agent", "Failed to register persistent MCP tool",
                    {"path": binaryPath, "error": e.msg}.toTable)
  
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
    contextWindow: resolveContextWindow(
      if model != "": model else: cfg.agents.defaults.model,
      max(cfg.agents.defaults.max_tokens, 32000)),
    maxResponseTokens: resolveMaxOutputTokens(
      if model != "": model else: cfg.agents.defaults.model,
      max(cfg.agents.defaults.max_tokens, 1)),
    temperature: cfg.agents.defaults.temperature,
    maxIterations: cfg.agents.defaults.max_tool_iterations,
    liveTasks: initTable[string, TaskSnapshot](),
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
      if na.skills.len > 0:
        al.skillScope = na.skills
      al.workstationEnabled = na.workstation
      if na.thinking.isSome:
        al.thinking = na.thinking
      if na.temperature.isSome:
        al.temperature = na.temperature.get
      if na.tools.len > 0 or na.deny.len > 0 or na.workstation or na.skills.len > 0:
        infoCF("agent", "Applied ClawDSL scope",
          {"agent": agentName, "allowed": $na.tools.len, "denied": $na.deny.len,
           "skills": na.skills.join(","), "workstation": $na.workstation,
           "thinking": (if na.thinking.isSome: $na.thinking.get else: "default")}.toTable)
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
