import std/[json, strutils, asyncdispatch, tables, locks, os, options, sets, algorithm]
import ../bus, ../bus_types, ../config, ../logger, ../providers/types as providers_types, ../session, ../utils
import ../providers/models_catalog
import ../providers/sanitize
import ../providers/fallback as providers_fallback
import ../providers/tool_loop
export sanitize.sanitizeForProvider
import ../skill_grant
import ../billing/[subscription as sub_mod, usage as usage_mod]
import context as agent_context
import memory as agent_memory
import xml_tools
import ../schema
import ../tools/registry as tools_registry
import ../tools/base as tools_base
import ../tools/loop_detector
import ../tools/solar_unified
import ../tools/fs_unified
import ../tools/file_unified
import ../tools/finder_unified
import ../tools/system/system
import ../tools/office/office
import ../tools/company/company
import ../tools/shell/shell
import ../tools/agent/[focus, subagent, memory_unified, todo_unified, find]
import ../tools/workstation/workstation
import ../tools/knowledge_unified
import ../tools/comm/[mail_unified, chat_unified, delegate, lark]
import ../tools/channel_unified
import ../tools/payment_unified
import ../tools/collaborate_unified
import ../tools/web/[web_unified, browser_unified, playwright]
import ../tools/search_unified
import ../tools/sched/schedule
# (admin/* tools folded into other tools:
#   set_api_key   → provider method=set_key
#   feishu_add_app→ channel method=add_app vendor=feishu
#  feishu_add_app's runFeishuAddApp proc is imported by channel_unified)
import ../tools/provider_unified
import ../tools/model_unified
import ../tools/capability_unified
import ../tools/social_unified
# image_info.nim retained as a helper module (imageMetaForFile is
# imported by fs_unified.nim for the image-aware fs info extension).
import ../tools/mcp/mcp_unified
import ../tools/skill/skill_unified
import ../services/scheduler as cron_service
import ../lib/curl as curly
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

  SessionStatus* = object
    ## Snapshot of one session's context-window utilisation. Returned
    ## by `sessionStatus` and rendered into a human-readable string by
    ## `formatSessionStatus`. Surfaced via `/session status` so an
    ## operator can see how close a thread is to triggering the
    ## summariser without grepping logs.
    sessionKey*: string
    agentName*: string
    model*: string
    messageCount*: int
    tokenEstimate*: int
    contextWindow*: int       ## from `resolveContextWindow` for the model
    threshold*: int           ## tokens at which `maybeSummarize` fires (75%)
    pctOfContext*: int        ## tokenEstimate / contextWindow × 100
    summaryLen*: int          ## chars in stored summary, 0 if none
    summarizing*: bool        ## currently running a summarisation pass

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
    techCommDefault*: bool      ## Build-time default for technical-
                                ## communication mode (auto-emit
                                ## visibility messages on tool calls).
                                ## True when this agent's `practices`
                                ## list contains "technical-communication".
                                ## Resolved per-session by also
                                ## consulting `SessionMeta.techCommOverride`
                                ## via `effectiveTechComm` below.
    sendCallback*: tools_base.SendCallback
                                ## Outbound message callback, exposed
                                ## here so the framework auto-emit path
                                ## in `runAgentLoop` can send synthetic
                                ## visibility messages on the agent's
                                ## behalf without going through a tool.
    chatTool*: ChatTool
                                ## Plan-state lives on `chat reply`
                                ## (with optional `progress=[...]`
                                ## payload). Held here so the
                                ## dispatch loop can read item counts +
                                ## recent completion timestamps for
                                ## plan-derived iteration-budget scaling
                                ## and the 80% productive-progress
                                ## auto-extend gate. nil when the tool
                                ## isn't registered (always is in the
                                ## standard newAgentLoop path).
    larkTool*: LarkCliTool
                                ## Held so framework auto-emit can call
                                ## `createDocViaBot` for large `write_file`
                                ## results — uploads the file as a Lark
                                ## Doc and embeds a clickable link in the
                                ## snippet message (single message UX,
                                ## replaces the prior separate file-
                                ## attachment second message). nil if
                                ## lark-cli binary isn't found.
    cancelRequested*: Table[string, bool]
                                ## Per-session cancellation flag set by
                                ## `/session stop`. The dispatch loop
                                ## reads it at the top of each iteration
                                ## AND before each tool dispatch — when
                                ## true, breaks with a "cancelled by
                                ## user" finalContent and clears the
                                ## flag. Lock-protected since the slash
                                ## command handler runs in a different
                                ## async chain than the dispatch loop.
    cancelLock*: Lock
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

proc effectiveTechComm*(al: AgentLoop, sessionKey: string): bool =
  ## Resolve the effective technical-communication mode for a session.
  ##
  ## Resolution order (first non-empty wins):
  ##   1. SessionMeta.techCommOverride — set by `/session technical
  ##      [on|off]` per session at runtime.
  ##   2. AgentLoop.techCommDefault — derived from the agent's
  ##      `practices "technical-communication"` declaration in
  ##      BASE.nims at office construction.
  ##
  ## When true on a code-block-rendering channel (currently `feishu`),
  ## the dispatch loop auto-emits Pattern 5 visibility messages
  ## (file path + code snippet, bash command + output excerpt) after
  ## non-comm tool calls, on the agent's behalf.
  if al.sessions != nil:
    let s = al.sessions.getOrCreate(sessionKey)
    let ovr = s.meta.techCommOverride.toLowerAscii
    if ovr == "on": return true
    if ovr == "off": return false
  al.techCommDefault

proc requestCancel*(al: AgentLoop, sessionKey: string) =
  ## Set the cancel flag for `sessionKey`. The dispatch loop checks
  ## this between iterations and before each tool dispatch — when
  ## set, it breaks with a "cancelled by user" finalContent and
  ## clears the flag. Called from the `/session stop` slash command
  ## handler in gateway.nim.
  acquire(al.cancelLock)
  defer: release(al.cancelLock)
  al.cancelRequested[sessionKey] = true

proc isCancelRequested*(al: AgentLoop, sessionKey: string): bool =
  acquire(al.cancelLock)
  defer: release(al.cancelLock)
  al.cancelRequested.getOrDefault(sessionKey, false)

proc clearCancel*(al: AgentLoop, sessionKey: string) =
  acquire(al.cancelLock)
  defer: release(al.cancelLock)
  al.cancelRequested.del(sessionKey)

proc chatWithCancel*(al: AgentLoop, sessionKey: string,
                     messages: seq[providers_types.Message],
                     tools: seq[providers_types.ToolDefinition],
                     model: string,
                     options: Table[string, JsonNode]):
                     Future[providers_types.LLMResponse] {.async.} =
  ## Wraps `provider.chat()` with cancellation polling so `/session stop`
  ## can interrupt a hung HTTP call mid-flight. Polls the per-session
  ## cancel flag every 200ms while waiting for the chat future to
  ## complete; if set, raises a sentinel IOError that the agent loop
  ## catches and converts to a clean cancellation finalContent.
  ##
  ## On cancel we call provider.cancelInFlight() so the underlying
  ## HTTP transport aborts immediately rather than running its full
  ## timeout. Use only on per-turn agent calls — heartbeat and
  ## internal summary calls don't need cancellation responsiveness
  ## and the polling adds latency.
  let chatFuture = al.provider.chat(messages, tools, model, options)
  while not chatFuture.finished:
    await sleepAsync(200)
    if al.isCancelRequested(sessionKey):
      al.provider.cancelInFlight()
      raise newException(IOError,
        "Cancelled by /session stop (mid-LLM-call)")
  return chatFuture.read

proc inferLangFromPath(path: string): string =
  ## Map a file extension to a markdown code-block language tag.
  ## Empty string for unknown extensions; callers render an unlabeled
  ## ``` block when this is empty (Feishu still highlights generic
  ## blocks reasonably; tagged is just better).
  let ext = path.toLowerAscii.splitFile.ext
  case ext
  of ".py": "python"
  of ".nim", ".nims": "nim"
  of ".sh", ".bash": "bash"
  of ".js", ".mjs", ".cjs": "javascript"
  of ".ts", ".tsx": "typescript"
  of ".json": "json"
  of ".yaml", ".yml": "yaml"
  of ".toml": "toml"
  of ".md", ".markdown": "markdown"
  of ".html", ".htm": "html"
  of ".css": "css"
  of ".sql": "sql"
  of ".go": "go"
  of ".rs": "rust"
  of ".c", ".h": "c"
  of ".cpp", ".cc", ".hpp", ".hh": "cpp"
  of ".java": "java"
  of ".rb": "ruby"
  of ".php": "php"
  of ".lua": "lua"
  of ".r": "r"
  else: ""

proc detectPositiveMarker*(message: string):
                            tuple[matched: bool, marker: string, weight: float] =
  ## Light keyword/regex scan for explicit positive feedback in a
  ## user message. Returns (true, the matched marker, suggested
  ## weight) or (false, "", 0). No LLM call. Multilingual; weights
  ## tuned for SunGrowCN's English/Mandarin operator base —
  ## "做得真好" carries strong intent in CN, while "谢谢" is closer
  ## to reflexive politeness and gets a lower weight.
  ##
  ## Phase 1 is intentionally conservative: only fire on markers
  ## clearly tied to recognising work, not bare politeness. False
  ## negatives (missed praise) are cheap; false positives pollute
  ## the experience file. We can loosen as the synthesizer surfaces
  ## what's actually useful.
  if message.len == 0: return (false, "", 0.0)
  let m = message.toLowerAscii()
  # Strong markers — clearly recognising the agent's work
  for marker in [
    "good work", "great job", "great work", "well done", "excellent",
    "perfect", "amazing job", "nicely done", "great answer",
    "做得好", "做得真好", "干得漂亮", "干得好", "辛苦了"]:
    if marker.toLowerAscii in m:
      return (true, marker, 1.0)
  # Medium markers — positive reinforcement, less explicitly tied to work
  for marker in ["great!", "thanks!", "very helpful", "much appreciated",
                  "不错", "很好", "棒"]:
    if marker.toLowerAscii in m:
      return (true, marker, 0.6)
  return (false, "", 0.0)

proc summarizeRecentAssistantTurn(messages: seq[providers_types.Message]): string =
  ## Short preview of the most recent assistant content that the
  ## user is likely praising. Walks back to the last assistant
  ## message that has either content or tool calls. Used as the
  ## `content` field on positive_feedback experience entries.
  for i in countdown(messages.high, 0):
    let msg = messages[i]
    if not msg.isAssistant: continue
    if msg.content.len > 0:
      let preview =
        if msg.content.len > 100: msg.content[0 ..< 100] & "…"
        else: msg.content
      return preview
    if msg.tool_calls.len > 0:
      let tc = msg.tool_calls[^1]
      let name =
        if tc.function.name.len > 0: tc.function.name
        elif tc.name.len > 0: tc.name
        else: "<unnamed>"
      return name
  return ""

proc summarizeCancelledTurn(messages: seq[providers_types.Message],
                              iteration: int): string =
  ## Short human-readable preview of what the agent was attempting
  ## right before /session stop fired. Used as the `content` field
  ## on the cancellation experience entry. Walks backward through
  ## the cancelled turn's messages to find the most recent assistant
  ## tool call — that's the action the user objected to. Falls back
  ## to "iter N (no tool call yet)" when the cancellation came
  ## before any tool dispatch.
  for i in countdown(messages.high, 0):
    let m = messages[i]
    if m.isAssistant and m.tool_calls.len > 0:
      let tc = m.tool_calls[^1]
      let name =
        if tc.function.name.len > 0: tc.function.name
        elif tc.name.len > 0: tc.name
        else: "<unnamed>"
      var argsPreview = tc.function.arguments
      if argsPreview.len > 80:
        argsPreview = argsPreview[0 ..< 80] & "…"
      return "iter " & $iteration & ": " & name & "(" & argsPreview & ")"
  return "iter " & $iteration & " (no tool call yet)"

proc displayPath(path: string): string =
  ## Strip the agent's workspace prefix from a path so visibility
  ## messages don't burn screen space on `/Users/owaf/.nimclaw-Foo/
  ## workspace/offices/lexi/workstation/`. Anything containing
  ## `/workstation/` collapses to `workstation/<rest>`; paths
  ## outside the workstation (system files, /tmp scratch, etc.)
  ## return unchanged.
  let marker = "/workstation/"
  let idx = path.find(marker)
  if idx >= 0:
    return "workstation" & path[idx + marker.len - 1 ..< path.len]
  return path

proc firstNLines(s: string, n: int): string =
  ## Return the first `n` lines of `s` (newline-delimited). Used for
  ## visibility-message snippets — keeps chat orientation-only, not
  ## full delivery.
  if n <= 0 or s.len == 0: return ""
  var count = 0
  var i = 0
  while i < s.len:
    if s[i] == '\n':
      count.inc
      if count >= n:
        return s[0 ..< i]
    i.inc
  return s

proc countLines(s: string): int =
  ## Count newline-delimited lines in `s`. Empty string → 0.
  if s.len == 0: return 0
  result = 1
  for ch in s:
    if ch == '\n': result.inc

proc fileSnippet(path, content: string,
                  shortCap = 30, mediumCap = 40,
                  longCap = 30): string =
  ## Render a code-block file snippet with smart truncation. Feishu
  ## scrolls within fenced code blocks and shows a copy button, so we
  ## can be generous — but still cap on huge files to avoid chat
  ## floods. Behavior by total line count:
  ##   ≤ shortCap  → full content (no truncation marker)
  ##   ≤ mediumCap*2 → first `mediumCap` lines + truncation footer
  ##   else        → first `longCap` lines + footer + Doc-handoff hint
  let lang = inferLangFromPath(path)
  let total = countLines(content)
  var snippet = ""
  var footer = ""
  if total <= shortCap:
    snippet = content.strip(leading = false)
  elif total <= mediumCap * 2:
    snippet = firstNLines(content, mediumCap)
    footer = "\n\n_…(" & $(total - mediumCap) & " more lines, full file at `" & displayPath(path) & "`)_"
  else:
    snippet = firstNLines(content, longCap)
    footer = "\n\n_…(" & $(total - longCap) & " more lines. For files this size, consider `lark docs +create` to make the full content shareable.)_"
  var sb = ""
  if lang.len > 0:
    sb.add("```" & lang & "\n" & snippet & "\n```")
  else:
    sb.add("```\n" & snippet & "\n```")
  sb.add(footer)
  return sb

proc outputSnippet(toolResult: string, cap = 40): string =
  ## Render a code-block output excerpt with truncation marker.
  ## Feishu's code-block scrolls vertically; cap at `cap` lines to
  ## keep the chat orientation-only on long stdout.
  let stripped = toolResult.strip()
  if stripped.len == 0: return ""
  let total = countLines(stripped)
  if total <= cap:
    return "```\n" & stripped & "\n```"
  let snippet = firstNLines(stripped, cap)
  return "```\n" & snippet & "\n```\n\n_…(" & $(total - cap) & " more lines truncated)_"

proc formatVisibilityMessage*(toolName: string,
                                args: Table[string, JsonNode],
                                toolResult: string): string =
  ## Synthesize a Pattern 5 visibility message from a tool call's
  ## args and result. Returns an empty string for tools without a
  ## meaningful visibility shape (read_file, mcp_*, jq, etc) — those
  ## don't emit. Length-bounded with smart truncation: small files
  ## go in full, medium files show ~40 lines, large files show ~30
  ## lines with a Doc-handoff hint. Output excerpts cap at 40 lines.
  case toolName
  of "write_file":
    if not args.hasKey("path") or not args.hasKey("content"): return ""
    let path = args["path"].getStr()
    let content = args["content"].getStr()
    if path.len == 0 or content.len == 0: return ""
    var sb = "📝 Wrote `" & displayPath(path) & "`\n\n"
    sb.add(fileSnippet(path, content))
    return sb
  of "edit":
    if not args.hasKey("file_path"): return ""
    let path = args["file_path"].getStr()
    if path.len == 0: return ""
    var sb = "✏️ Edited `" & displayPath(path) & "`"
    if args.hasKey("new_string"):
      let newStr = args["new_string"].getStr()
      if newStr.len > 0:
        sb.add("\n\n")
        sb.add(fileSnippet(path, newStr,
                            shortCap = 20, mediumCap = 30, longCap = 20))
    return sb
  of "focus":
    if not args.hasKey("task"): return ""
    let task = args["task"].getStr()
    if task.len == 0: return ""
    var cmd = ""
    let execIdx = task.find("Execute: ")
    if execIdx >= 0:
      let after = task[execIdx + 9 ..< task.len]
      let lineEnd = after.find('\n')
      cmd = if lineEnd < 0: after.strip() else: after[0 ..< lineEnd].strip()
    # Title-only auto-emit. Subagent results are intermediate —
    # structured markdown the parent agent consumes and synthesizes,
    # not raw stdout to show the user verbatim. Two prior bugs made
    # showing the output bad UX:
    #   - the result often contains its own ```fenced``` blocks; the
    #     outputSnippet wrap broke at the first inner fence and only
    #     a prefix rendered (looked like "title only, no content").
    #   - when the result was cleanly truncatable, "(N more lines
    #     truncated)" became the last visible message and the parent
    #     agent treated it as "I already replied", skipping the
    #     final reply_progress / reply that the user expects.
    # Trust the parent to emit a substantive summary after the
    # subagent returns; only announce the task here.
    var sb = "⚙️ "
    if cmd.len > 0:
      sb.add("Ran:\n```bash\n" & cmd & "\n```")
    else:
      let label = if args.hasKey("label"): args["label"].getStr() else: ""
      let preview = if task.len > 80: task[0 ..< 80] & "..." else: task
      if label.len > 0:
        sb.add("Subagent task `" & label & "`: " & preview)
      else:
        sb.add("Subagent task: " & preview)
    return sb
  of "shell":
    if not args.hasKey("command"): return ""
    let cmd = args["command"].getStr()
    if cmd.len == 0: return ""
    var sb = "⚙️ Ran:\n```bash\n" & cmd & "\n```"
    let outBlock = outputSnippet(toolResult)
    if outBlock.len > 0:
      sb.add("\n\n" & outBlock)
    return sb
  else:
    return ""

proc stop*(al: AgentLoop) =
  al.running = false
  if al.tools != nil:
    al.tools.stopAllMcpClients()
  if al.curly != nil:
    try: al.curly.close()
    except: discard

proc registerTool*(al: AgentLoop, tool: Tool) =
  al.tools.register(tool)

const MaxBytesPerMessage* = 32_000
  ## Per-message hard cap on the LLM-facing serialised size (~8K
  ## tokens). Single tool results bigger than this are replaced with
  ## an abbreviated stub when fetching the history for the LLM.
  ##
  ## Why: even after summariser runs, the *verbatim live tail* keeps
  ## the most recent ~30 messages full-fidelity. When those messages
  ## are tool results from data-heavy MCP servers (sungrow plant
  ## history dumps, anygen task blobs, multi-page reports), each can
  ## be 50–100KB on its own — 30 such messages overflow any
  ## provider's context window even though message COUNT is small.
  ##
  ## The on-disk JSONL keeps the original bytes for audit; only the
  ## copy handed to the LLM is shrunk. The stub preserves role +
  ## tool name + tool_call_id + first ~800 chars of the original
  ## content, so the agent can still tell what a given result was
  ## for and re-call the tool if it actually needs the data.
  ##
  ## Long-term replacement: MCP tools should emit
  ## `{summary, key_metrics, ref_path}` by default and only return
  ## verbatim data on explicit request (Anthropic's `_meta`
  ## annotation pattern — see HANDBOOK note on context engineering).
  ## Until each MCP is migrated, this cap is the safety net.

proc capMessageSize*(msg: providers_types.Message): providers_types.Message =
  ## Replace an oversized message's content with an abbreviated stub.
  ## See `MaxBytesPerMessage` doc for rationale. Returns the input
  ## unchanged if the serialised size is under the cap.
  var totalBytes = msg.content.len + msg.reasoning_content.len +
                   msg.tool_call_id.len + msg.name.len
  for tc in msg.tool_calls:
    totalBytes += tc.id.len + tc.`type`.len + tc.function.name.len +
                  tc.function.arguments.len + tc.name.len
    for k, v in tc.arguments.pairs:
      totalBytes += k.len + ($v).len
  if totalBytes <= MaxBytesPerMessage: return msg

  let preview =
    if msg.content.len > 800: msg.content[0 ..< 800] & "…"
    else: msg.content
  var stub = "[abbreviated for context budget — original "
  stub.add($totalBytes)
  stub.add(" bytes")
  if msg.name.len > 0:
    stub.add(", tool=")
    stub.add(msg.name)
  stub.add(". Re-call the tool if you need the full payload. ")
  stub.add("First chars: ")
  stub.add(preview)
  stub.add("]")

  result = providers_types.Message(
    role: msg.role,
    content: stub,
    # Drop reasoning_content entirely — it's a thinking trace that
    # only mattered to the turn that produced it; downstream turns
    # don't reference it directly. Keeping a stub of it is noise.
    reasoning_content: "",
    # Preserve tool_calls + linkage fields so the conversation
    # structure (assistant→tool pairings, function call IDs) stays
    # intact and the sanitizer still validates the message graph.
    tool_calls: msg.tool_calls,
    tool_call_id: msg.tool_call_id,
    name: msg.name)

proc getCappedHistory(al: AgentLoop, sessionKey: string):
                      seq[providers_types.Message] =
  ## Same as `al.sessions.getHistory`, but with `capMessageSize`
  ## applied to every entry. All four downstream consumers
  ## (estimateTokens, the threshold check in maybeSummarize, the
  ## actual LLM call, the /session status display) see a consistent
  ## post-cap view, so the threshold and the LLM-input agree.
  let raw = al.sessions.getHistory(sessionKey)
  result = newSeq[providers_types.Message](raw.len)
  for i, m in raw:
    result[i] = capMessageSize(m)

proc effectiveContextWindow*(al: AgentLoop): int =
  ## Resolve the contextWindow that summarisation thresholds should
  ## use for THIS turn. When the agent's provider is a fallback
  ## chain, defers to the chain's `effectiveContextWindow` — which
  ## returns the primary's window when primary is healthy, or the
  ## smallest currently-usable fallback's window when primary is
  ## degraded. Falls back to the construction-time `al.contextWindow`
  ## when the chain has no usable entries with known windows (or the
  ## provider isn't a fallback wrapper at all).
  ##
  ## Why: Lexi's primary (deepseek-v4-flash) has a 1M window, her
  ## fallback (kimi-k2.5) has 200K. With both healthy, summarising
  ## at the primary's 75% (750K) preserves headroom. The moment
  ## deepseek 402's, the next call goes to kimi — which can't take
  ## 750K. Summarising at the FALLBACK's 75% (150K) lets the chain
  ## stay operational instead of size-exhausting every turn.
  if al.provider of providers_fallback.FallbackLLMProvider:
    let fp = providers_fallback.FallbackLLMProvider(al.provider)
    let dyn = fp.effectiveContextWindow()
    if dyn > 0: return dyn
  al.contextWindow

proc estimateTokens(messages: seq[providers_types.Message]): int =
  ## Token estimate over every wire-field of the message history.
  ## User-content fields (`content`, `reasoning_content`) get the
  ## rune-aware count from `providers_fallback.roughTokenCount`, so
  ## CJK-heavy threads aren't undercounted by 1.3-1.5× the way pure
  ## `bytes/4` was. JSON-structural fields (tool_call ids, types,
  ## arguments — almost always ASCII) stay on the cheap `bytes/4`
  ## path.
  ##
  ## Earlier evolution:
  ##   v1: only counted `content`. 5-7× under on tool-heavy sessions
  ##       (Jerry's nc_5 was 672K tokens of tool_calls vs 147K of
  ##       content), so the 75% summarisation threshold never fired.
  ##   v2: summed every wire-field, divided by 4. Right for ASCII;
  ##       under by 1.3× on Chinese — the 265K Moonshot rejection
  ##       slipped past a 196K cap because the Chinese-heavy turn
  ##       byte-counted at ~199K.
  ##   v3 (this): rune-aware on the user-content fields. Pure ASCII
  ##       behaves as before; pure CJK now counts ~1 token/char
  ##       (matches BPE behaviour); mixed content scales linearly.
  var asciiBytes = 0
  var richTokens = 0
  for m in messages:
    richTokens += providers_fallback.roughTokenCount(m.content)
    richTokens += providers_fallback.roughTokenCount(m.reasoning_content)
    richTokens += providers_fallback.roughTokenCount(m.name)
    asciiBytes += m.tool_call_id.len
    for tc in m.tool_calls:
      asciiBytes += tc.id.len + tc.`type`.len + tc.function.name.len
      richTokens += providers_fallback.roughTokenCount(tc.function.arguments)
      richTokens += providers_fallback.roughTokenCount(tc.name)
      for k, v in tc.arguments.pairs:
        asciiBytes += k.len
        richTokens += providers_fallback.roughTokenCount($v)
  return richTokens + (asciiBytes div 4)

proc sessionStatus*(al: AgentLoop, sessionKey: string): SessionStatus =
  ## Read-only snapshot of a session's context utilisation. Same
  ## numbers `maybeSummarize` uses internally — exposed publicly so
  ## the gateway's `/session status` command (and any future dashboard)
  ## can surface them to the operator without duplicating the math.
  let history = al.getCappedHistory(sessionKey)
  let summary = al.sessions.getSummary(sessionKey)
  let tokens = estimateTokens(history)
  # `effectiveContextWindow` reflects the chain's CURRENT routing —
  # so when the primary is unhealthy, /session status reports the
  # threshold the loop is actually using (smaller fallback's), not
  # the primary's. Saves operators wondering why summarisation
  # fired at 150K instead of 750K.
  let cw = al.effectiveContextWindow()
  let thr = (cw * 75) div 100
  acquire(al.summarizingLock)
  let summarising = al.summarizing.getOrDefault(sessionKey, false)
  release(al.summarizingLock)
  result = SessionStatus(
    sessionKey: sessionKey,
    agentName: al.agentName,
    model: al.model,
    messageCount: history.len,
    tokenEstimate: tokens,
    contextWindow: cw,
    threshold: thr,
    pctOfContext: if cw > 0: (tokens * 100) div cw else: 0,
    summaryLen: summary.len,
    summarizing: summarising)

proc allSessionStatuses*(al: AgentLoop): seq[SessionStatus] =
  ## One `SessionStatus` per loaded session. Used by the operator-level
  ## `/session status <agent>` (no nc:id) to surface every conversation
  ## the agent is carrying, sorted by token weight so the heaviest
  ## thread is visible first.
  for key in al.sessions.sessions.keys:
    result.add(al.sessionStatus(key))
  # Sort heaviest first — operator usually wants to know which session
  # is closest to the summarisation threshold.
  result.sort(proc(a, b: SessionStatus): int =
    cmp(b.tokenEstimate, a.tokenEstimate))

proc formatSessionList*(statuses: seq[SessionStatus],
                        agentName, model: string,
                        contextWindow, threshold: int,
                        nameByKey: Table[string, string] = initTable[string, string]()): string =
  ## Compact one-line-per-session table for the operator overview.
  ## Detail (full bar, summary state, etc.) lives in `formatSessionStatus`
  ## — drill down via `/session status <agent> <nc:id>`.
  result = "**" & agentName & "** (" & model & ") — " & $statuses.len &
           " session(s) loaded\n\n"
  if statuses.len == 0:
    result.add("No sessions yet for this agent.\n")
    return
  # Compact bar: 12 cells wide, no threshold marker.
  const barWidth = 12
  for s in statuses:
    let filled =
      if contextWindow <= 0: 0
      else: max(0, min(barWidth, (s.tokenEstimate * barWidth) div contextWindow))
    var bar = ""
    for i in 0 ..< barWidth:
      if i < filled: bar.add("█")
      else: bar.add("░")
    let displayName = nameByKey.getOrDefault(s.sessionKey, "")
    let nameCol =
      if displayName.len > 0: displayName
      else: s.sessionKey
    # Right-pad nameCol to a stable width for alignment in monospaced
    # rendering. Markdown clients usually preserve spaces inside code-
    # fenced blocks; for chat bubbles, the table is still readable
    # without strict alignment.
    var paddedName = nameCol
    while paddedName.len < 12: paddedName.add(" ")
    result.add("  `" & s.sessionKey & "` " & paddedName &
               " " & align($s.messageCount & " msg", 9) &
               " · ~" & align($s.tokenEstimate & "t", 10) &
               " (" & align($s.pctOfContext & "%", 4) & ")  [" & bar & "]")
    if s.summarizing: result.add(" ⚙️")
    result.add("\n")
  result.add("\nThreshold: " & $threshold & " tokens (75% of " &
             $contextWindow & "). Use `/session status " & agentName &
             " nc:N` for detail on a specific session.\n")

proc formatSessionStatus*(s: SessionStatus): string =
  ## Markdown-friendly rendering of a `SessionStatus` for chat output.
  ## Bar is 20 cells wide, with a `▼` marker at the 75% threshold so
  ## the operator can see at a glance how close they are to summarising.
  const barWidth = 20
  const thresholdCell = (barWidth * 75) div 100  # = 15
  let filled =
    if s.contextWindow <= 0: 0
    else: max(0, min(barWidth, (s.tokenEstimate * barWidth) div s.contextWindow))
  var bar = ""
  for i in 0 ..< barWidth:
    if i < filled: bar.add("█")
    else: bar.add("░")
  # Marker line above the bar showing the 75% point
  var marker = ""
  for i in 0 ..< barWidth:
    if i == thresholdCell: marker.add("▼")
    else: marker.add(" ")
  result = "**" & s.agentName & "** (" & s.model & ") · session `" &
           s.sessionKey & "`\n"
  result.add("Messages: " & $s.messageCount & "\n")
  result.add("Tokens:   ~" & $s.tokenEstimate & " / " & $s.contextWindow &
             "  (" & $s.pctOfContext & "% of context)\n")
  result.add("           " & marker & "  ← 75% threshold\n")
  result.add("          [" & bar & "]\n")
  if s.summaryLen > 0:
    result.add("Summary:  " & $s.summaryLen &
               " chars (history was compacted at least once)\n")
  else:
    result.add("Summary:  none yet\n")
  if s.summarizing:
    result.add("Status:   summarising in background\n")
  elif s.tokenEstimate >= s.threshold:
    result.add("Status:   over threshold — summarisation will fire on next turn\n")
  else:
    let toGo = s.threshold - s.tokenEstimate
    result.add("Status:   active (~" & $toGo & " tokens to threshold)\n")

proc resolveContextWindow*(modelName: string, fallback: int): int =
  ## Look up the model's INPUT limit from `res/models.json`. Used to size
  ## the summarisation / size-guard thresholds, NOT the per-request
  ## `max_tokens` field.
  ##
  ## Tries (in order):
  ##   1. exact canonical id match (e.g. "deepseek/deepseek-v4-flash")
  ##   2. canonical id with `<vendor>/` prefix scan
  ##   3. per-provider models[] by id (e.g. providers["OpenCode Go"].models
  ##      contains `mimo-v2.5` with context_length: 1_000_000)
  ##         a. if the entry links to a canonical via its `model` field
  ##            AND that canonical has contextLength, prefer canonical
  ##            (richer metadata, hand-curated)
  ##         b. otherwise use the entry's inline contextLen
  ##   4. fallback to caller-supplied default (typically 32K)
  ##
  ## Without step 3, models in the per-provider catalog (most OpenCode Go
  ## entries, vendor-specific aggregator listings, etc.) silently fell
  ## back to 32K — undersizing the size-guard threshold and making
  ## tool-heavy turns trip the guard far below the model's real capacity.
  if modelName.len == 0: return fallback
  let cat = effectiveCatalog()
  # 1. Direct canonical match
  if cat.canonical.hasKey(modelName):
    let ctx = cat.canonical[modelName].contextLength
    if ctx > 0: return ctx
  # 2. <vendor>/<modelName> canonical scan
  for canonicalId, canonical in cat.canonical.pairs:
    if canonicalId.endsWith("/" & modelName):
      if canonical.contextLength > 0: return canonical.contextLength
  # 3. Per-provider models[] — prefer canonical link if available,
  #    fall back to the per-provider inline contextLen.
  for provName, provCat in cat.providers.pairs:
    for m in provCat.models:
      if m.id == modelName:
        if m.canonical.len > 0 and cat.canonical.hasKey(m.canonical):
          let ctx = cat.canonical[m.canonical].contextLength
          if ctx > 0: return ctx
        if m.contextLen > 0: return m.contextLen
  fallback

proc resolveMaxOutputTokens*(modelName: string, requested: int): int =
  ## Bound the per-request output cap by the model's published
  ## `max_output_tokens`. Operators set `agents.defaults.max_tokens`
  ## (the *requested* output cap) without knowing each provider's
  ## ceiling — sending above the ceiling triggers 400. We clamp here
  ## so a high request like 32k still works on a model whose ceiling
  ## is 8k or 384k, without operator guesswork per-model.
  ##
  ## Lookup order mirrors resolveContextWindow:
  ##   1. exact canonical id
  ##   2. `<vendor>/<modelName>` canonical scan
  ##   3. per-provider models[] → linked canonical (if any)
  ##   4. fallback to requested value (defer to provider's own enforcement)
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
  if modelCap == 0:
    # Per-provider entry → follow `canonical` link if present
    for provName, provCat in cat.providers.pairs:
      for m in provCat.models:
        if m.id == modelName and m.canonical.len > 0 and
           cat.canonical.hasKey(m.canonical):
          modelCap = cat.canonical[m.canonical].maxOutputTokens
          if modelCap > 0: break
      if modelCap > 0: break
  if modelCap > 0 and requested > modelCap: return modelCap
  requested

proc summarizeBatch(al: AgentLoop, batch: seq[providers_types.Message], existingSummary: string, sessionKey: string = ""): Future[string] {.async.} =
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

  var summaryOpts = initTable[string, JsonNode]()
  if sessionKey.len > 0:
    summaryOpts[providers_fallback.SessionKeyOption] = %sessionKey
  let response = await al.provider.chat(@[providers_types.Message(role: providers_types.RoleUser, content: prompt)], @[], al.model, summaryOpts)
  return response.content

const SummaryChunkBudgetTokens* = 100_000
  ## Per-chunk size cap for the chunked-fallback summariser. When the
  ## single-shot path fails with context overflow, we split
  ## `validMessages` into chunks of ~this many tokens and fold each
  ## into a running summary. 100K is comfortably under any current
  ## provider's window (deepseek-v4-flash ~128K, kimi-k2.5 262K,
  ## claude/gpt 200K+) leaving headroom for the prompt skeleton +
  ## prior facts sheet.

proc summarizeBatchOrChunked(al: AgentLoop,
                              batch: seq[providers_types.Message],
                              existingSummary: string,
                              sessionKey: string = ""): Future[string] {.async.} =
  ## Single-shot summarise; if the LLM call rejects the request as
  ## over its context window, transparently fall back to chunked:
  ## walk the batch in ~SummaryChunkBudgetTokens chunks, fold each
  ## into the running summary, return the final.
  ##
  ## Why two paths: single-shot is cheaper and produces a cleaner
  ## summary because the LLM sees the whole arc in one go. Chunked
  ## is the safety net for sessions that have already accumulated
  ## past any single-call window — without it, the summariser dies
  ## on its own size and the session stays stuck at the live-tail
  ## limit forever.
  try:
    return await al.summarizeBatch(batch, existingSummary, sessionKey)
  except IOError as e:
    let msg = e.msg
    let isOverflow = "context length" in msg or
                     "context_length_exceeded" in msg or
                     "maximum context" in msg
    if not isOverflow:
      raise e
    warnCF("agent",
           "Summariser hit context overflow — falling back to chunked",
           {"batch_size": $batch.len,
            "err_preview": msg[0 ..< min(msg.len, 200)]}.toTable)

  var running = existingSummary
  var i = 0
  while i < batch.len:
    var j = i
    var chunkChars = 0
    let chunkBudgetChars = SummaryChunkBudgetTokens * 4
    while j < batch.len and chunkChars < chunkBudgetChars:
      chunkChars += batch[j].content.len + batch[j].reasoning_content.len
      j += 1
    if j == i: j = i + 1   # always advance — defensive
    let chunk = batch[i ..< j]
    infoCF("agent", "Summariser chunk",
           {"start": $i, "end": $j, "of_total": $batch.len,
            "chars": $chunkChars}.toTable)
    running = await al.summarizeBatch(chunk, running, sessionKey)
    i = j
  return running

proc summarizeSession(al: AgentLoop, sessionKey: string) {.async.} =
  let history = al.getCappedHistory(sessionKey)
  let summary = al.sessions.getSummary(sessionKey)

  if history.len <= 4: return
  let toSummarize = history[0 .. ^5]

  # Oversized Message Guard — sized off the EFFECTIVE window so a
  # turn that has to fit the smaller fallback gets a tighter
  # per-message cap, not the primary's generous one.
  let maxMessageTokens = al.effectiveContextWindow() div 2
  var validMessages: seq[providers_types.Message] = @[]
  for m in toSummarize:
    if m.isUser or m.isAssistant:
      if (m.content.len div 4) < maxMessageTokens:
        validMessages.add(m)

  if validMessages.len == 0: return

  let finalSummary = await al.summarizeBatchOrChunked(validMessages, summary, sessionKey)

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


proc maybeSummarize(al: AgentLoop, opts: ProcessOptions) =
  ## Token-based summariser trigger. Fires when live history exceeds
  ## 75% of the model's context window — same threshold surfaced by
  ## `/session status` so the operator can see it coming.
  ##
  ## Publishes a one-line meta-message to the chat when summarisation
  ## starts and another when it completes. Without these notifications
  ## the user sees a long pause mid-conversation as if the agent froze;
  ## with them, they know the system is compacting earlier history.
  let sessionKey = opts.sessionKey
  acquire(al.summarizingLock)
  if al.summarizing.hasKey(sessionKey) and al.summarizing[sessionKey]:
    release(al.summarizingLock)
    return

  let history = al.getCappedHistory(sessionKey)
  let tokenEstimate = estimateTokens(history)
  # 75% of the EFFECTIVE context window. Tracks which chain entry
  # the next call would actually hit, so when the primary is
  # unhealthy and the fallback is smaller, summarisation fires
  # earlier — keeping the thread fitting whatever's currently
  # serving requests. With a healthy primary, this is identical to
  # using `al.contextWindow` directly.
  let cw = al.effectiveContextWindow()
  let threshold = (cw * 75) div 100

  if tokenEstimate > threshold:
    al.summarizing[sessionKey] = true
    release(al.summarizingLock)

    let pct = if cw > 0:
                (tokenEstimate * 100) div cw
              else: 0
    let canNotify = al.bus != nil and
                    opts.channel.len > 0 and
                    opts.chatID.len > 0
    if canNotify:
      let notice = "🗜️ Compacting earlier history (~" & $pct &
                   "% of context, threshold 75%). Recent turns stay " &
                   "verbatim; older content is being condensed into a " &
                   "structured summary. This takes ~10–30 seconds."
      al.bus.publishOutbound(newOutbound(opts.channel, al.agentName,
                                         opts.chatID, notice,
                                         "", opts.appID))

    discard (proc() {.async.} =
      await summarizeSession(al, sessionKey)
      acquire(al.summarizingLock)
      al.summarizing[sessionKey] = false
      release(al.summarizingLock)
      if canNotify:
        al.bus.publishOutbound(newOutbound(opts.channel, al.agentName,
                                           opts.chatID,
                                           "✓ Compaction complete.",
                                           "", opts.appID))
    )()
  else:
    release(al.summarizingLock)

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
                "Call `tools method=find query=\"…\"` to discover what's available.")
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

# sanitizeForProvider was inlined here originally; it was extracted to
# providers/sanitize.nim so subagent.nim can reuse the same rules
# without circular imports. This file re-exports it (see the import
# block at the top).

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

  # TC-2 enforcement: framework-level checkpoint discipline. Tracks
  # consecutive non-communication tool calls (write_file, spawn, shell,
  # etc) since the last `reply`/`reply_progress`/`message`/`forward`.
  # When the streak reaches the threshold, the agent loop injects a
  # synthetic system message into `currentMessages` BEFORE the next
  # LLM iteration — putting the "you must checkpoint now" reminder
  # in the model's most recent attention zone, where it cannot be
  # diluted by 100K+ tokens of prompt-rules. See comms-discipline
  # design notes: rule-only enforcement was empirically unreliable
  # at large prompt sizes; this counter makes TC-2 deterministic.
  # SSoT: comm tools derive from the framework manifest (every tool
  # with `category = "comm"` in `registry/manifest.nim`). The TC-2
  # nudge counter resets when any of these fire. Adding a new comm
  # tool = drop it in the manifest with category="comm" and it
  # automatically counts here.
  let CommTools = tool_manifest.commToolNames()
  const ConsecutiveNonCommThreshold = 2
  var consecutiveNonCommTools = 0
  var nudgeInjectedForStreak = false

  # Dynamic iteration budget. Starts at the agent's configured cap
  # (`al.maxIterations`) but can grow within this single processDirect
  # call based on two signals:
  #   1. Plan-derived scale: when the agent calls `task_list` with N
  #      items, bump to `min(N × 8, IterationHardCap)`.
  #   2. Productive-progress auto-extend: at 80% utilization, if the
  #      loop detector is quiet AND the task_list shows recent
  #      completions, silently extend by 20.
  # Local var (not modifying al.maxIterations) so concurrent sessions
  # for the same agent don't collide. See claude-code-style design
  # notes: the iteration counter conflates productive long work and
  # stuck loops, so we use signals (loop detector + plan completions)
  # to decide which case we're in.
  const IterationHardCap = 150
  const IterationSoftThresholdPct = 80
  var maxIter = al.maxIterations
  var budgetWarningInjected = false

  # See `sanitizeForProvider` below for the rules. Run once before
  # entering the iteration loop so anything stale from getHistory
  # gets cleaned up upfront.
  sanitizeForProvider(currentMessages)

  while iteration < maxIter and finalContent == "":
    # Cancellation check — set by /session stop. Clear flag and exit
    # cleanly with a marker that distinguishes "user cancelled" from
    # "iteration cap reached" or "loop detector tripped."
    if al.isCancelRequested(opts.sessionKey):
      al.clearCancel(opts.sessionKey)
      finalContent = "[Cancelled by /session stop. " &
        "Partial work may have completed before cancellation; " &
        "check the messages above. This conversation continues — " &
        "send a new prompt to resume.]"
      infoCF("agent", "Turn cancelled by /session stop", {
        "session": opts.sessionKey,
        "iteration": $iteration}.toTable)
      break
    iteration += 1
    snapshot.iteration = iteration
    al.updateStatus(ctx, "Thinking", "Running iteration", iteration)

    # Dynamic budget: at the soft threshold (80% used), check
    # productive-progress signals. If still working productively,
    # silently extend; either way (extended or not), inject a soft
    # warning ONCE per turn so the agent has a chance to wrap up
    # consciously instead of getting force-summarized at the wall.
    let usedPct = (iteration * 100) div max(maxIter, 1)
    if usedPct >= IterationSoftThresholdPct and
       maxIter < IterationHardCap and
       al.chatTool != nil:
      let list = al.chatTool.progressItems.getOrDefault(opts.sessionKey, @[])
      var completedCount = 0
      var unfinishedCount = 0
      for item in list:
        case item.status
        of chat_unified.tisClaimedDone, chat_unified.tisVerifiedDone: completedCount.inc
        of chat_unified.tisInProgress, chat_unified.tisPending: unfinishedCount.inc
      let loopQuiet = loopDetector.streak < 3
      let productive = unfinishedCount > 0 and completedCount > 0 and loopQuiet
      if productive:
        let extension = min(20, IterationHardCap - maxIter)
        if extension > 0:
          let oldMax = maxIter
          maxIter += extension
          infoCF("agent", "Iteration budget auto-extended (productive)", {
            "session": opts.sessionKey,
            "iteration": $iteration,
            "old_max": $oldMax,
            "new_max": $maxIter,
            "completed": $completedCount,
            "unfinished": $unfinishedCount,
            "loop_streak": $loopDetector.streak}.toTable)
    if usedPct >= IterationSoftThresholdPct and not budgetWarningInjected:
      let warning = "[FRAMEWORK NUDGE — iteration budget at " & $usedPct &
        "%] You have used " & $iteration & " of " & $maxIter & " iterations. " &
        "If your `chat reply ... progress=[…]` plan has unfinished items AND " &
        "you're making progress (completing items, varied tool calls), " &
        "the framework will auto-extend up to " & $IterationHardCap &
        " total. Otherwise, wrap up NOW with a terminal `chat reply` " &
        "(no interim) summarizing what you have. Hitting the hard cap " &
        "forces a synthetic summary with no chance for you to compose your own."
      let warningMsg = providers_types.Message(
        role: providers_types.RoleSystem, content: warning)
      currentMessages.add(warningMsg)
      al.sessions.addFullMessage(opts.sessionKey, warningMsg)
      budgetWarningInjected = true
      infoCF("agent", "Iteration budget soft warning injected", {
        "session": opts.sessionKey,
        "iteration": $iteration,
        "max": $maxIter}.toTable)

    # Mid-turn size guard. `maybeSummarize` runs at TURN boundaries
    # (post-loop), but a single turn's tool-call results can balloon
    # the conversation past the chain's smallest usable window
    # before the loop ever exits. When that happens — typically a
    # heartbeat or analytical task that pulls many large payloads —
    # the next chat() call will hit chain-exhausted-on-size, the
    # turn rolls back, and on the next attempt we repeat the same
    # accumulation. Detecting it between iterations gives operators
    # a specific, debuggable error pointing at the offending
    # iteration count and tool sequence. Surfaced via the same
    # `Error communicating with LLM provider:` prefix that the
    # post-call catch uses, so the existing rollback path picks it
    # up without a second branch.
    let midTurnTokens = estimateTokens(currentMessages)
    let midTurnCap = al.effectiveContextWindow()
    # Use the same headroom percentage as the chain's size-skip
    # filter so guard-trip and chain-skip agree on what "too big"
    # means. Single source of truth lives in providers/fallback.nim.
    let headroomPct = providers_fallback.ContextHeadroomPct
    # Per-iteration size telemetry — surfaces in the gateway log so
    # operators can correlate "the estimator said 200K, server saw
    # 265K" cases against actual rejections. INFO level (not debug)
    # because operators usually filter debug; this signal is too
    # important to lose in normal log filtering.
    infoCF("agent", "Mid-turn token estimate", {
      "session": opts.sessionKey,
      "iteration": $iteration,
      "estimate": $midTurnTokens,
      "cap": $midTurnCap,
      "headroom_pct": $headroomPct,
      "messages": $currentMessages.len}.toTable)
    if midTurnCap > 0 and
       midTurnTokens > (midTurnCap * headroomPct) div 100:
      let lastToolName =
        if currentMessages.len > 0 and
           currentMessages[^1].name.len > 0:
          currentMessages[^1].name
        else: "(none)"
      warnCF("agent", "Mid-turn size guard tripped", {
        "session": opts.sessionKey,
        "iteration": $iteration,
        "tokens": $midTurnTokens,
        "cap": $midTurnCap,
        "last_tool": lastToolName}.toTable)
      finalContent = "Error communicating with LLM provider: " &
        "mid-turn size guard tripped at iteration " & $iteration &
        " — history grew to ~" & $midTurnTokens & " tokens, over " &
        $headroomPct & "% of the chain's effective window (" &
        $midTurnCap & "). Last tool: `" & lastToolName & "`. Likely " &
        "cause: a tool returned an oversize inline payload — " &
        "migrate it to the {summary, ref_path} cache pattern."
      break

    infoCF("agent", "LLM iteration", {"iteration": $iteration, "max": $maxIter, "xml_tools": $useXmlTools, "messages_count": $currentMessages.len}.toTable)

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
      elif opts.senderID == tools_registry.SystemHeartbeatSender:
        # Heartbeat ticks see a tight maintenance allowlist instead
        # of every registered tool. The session is "is anything
        # pending?" — exposing 30+ schemas (sungrow polling, code
        # editors, etc.) just inflates per-tick token cost and
        # encourages open-ended tool calls. See registry.nim's
        # `HeartbeatAllowedTools` for the rationale + member list.
        al.tools.getDefinitionsFiltered(strategy,
          @(tools_registry.HeartbeatAllowedTools))
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
            if taxonomy.len > 0 and currentMessages.len > 0 and currentMessages[0].isSystem:
              currentMessages[0].content.add(
                "\n\n## Additional Tools (schemas NOT loaded)\n\n" &
                "The tools below are registered but their parameter " &
                "schemas are not in this turn's tool list. **You cannot " &
                "call them directly** — if you try, you will guess " &
                "parameter names and the call will fail.\n\n" &
                "To use any of these, FIRST call `tools method=find` with " &
                "relevant keywords (e.g. `tools method=find query=\"solar " &
                "history\"`). That activates the tool's schema for " &
                "the rest of this turn. Only then dispatch the tool.\n\n" &
                "Categories:\n" & taxonomy)
              infoCF("agent", "Deferred tool loading", {"core_schemas": $defs.len, "hidden": $hiddenNames.len, "activated": $activatedSet.len}.toTable)
          defs

    var options = {
      "max_tokens": %al.maxResponseTokens,
      "temperature": %al.temperature,
      # Sticky-fallback hint for FallbackLLMProvider. Stripped before
      # the underlying http provider sees it; non-fallback providers
      # ignore unknown options. See providers/fallback.nim.
      providers_fallback.SessionKeyOption: %opts.sessionKey
    }.toTable
    if al.thinking.isSome:
      # Surfaced to the HTTP provider, which translates it into the
      # provider-specific wire format (DeepSeek V4: extra_body
      # `thinking: {type: enabled|disabled}`). For models that don't
      # implement the toggle the provider ignores the option.
      options["thinking"] = %al.thinking.get

    # Re-sanitize before EACH provider call. The opening sanitize at
    # runLLMIteration's top covered loaded history, but mid-loop
    # state can drift: a tool can throw between adding the assistant
    # turn and adding the tool result, or a nudge can land between
    # assistant.tool_calls and its tool responses. Without this, the
    # broken state hits the provider as a 400 on the very next
    # iteration of the outer while-loop.
    sanitizeForProvider(currentMessages)
    var response: LLMResponse
    try:
      response = await al.chatWithCancel(opts.sessionKey,
                                          currentMessages, toolDefs,
                                          al.model, options)
    except Exception as e:
      # Specific handling for /session stop mid-LLM-call. The
      # exception message carries a sentinel string set by
      # chatWithCancel; on match, exit cleanly with a cancellation
      # marker (NOT the generic "Error communicating with LLM
      # provider" path which would look like a real failure to
      # operators reading logs).
      if "Cancelled by /session stop" in e.msg:
        al.clearCancel(opts.sessionKey)
        finalContent = "[Cancelled by /session stop. The in-flight " &
          "LLM call was interrupted mid-request; partial work earlier " &
          "in the turn (if any) is preserved in the conversation.]"
        infoCF("agent", "Turn cancelled mid-LLM-call by /session stop", {
          "session": opts.sessionKey,
          "iteration": $iteration}.toTable)
        break
      errorCF("agent", "LLM API request failed", {"error": e.msg, "iteration": $iteration}.toTable)
      snapshot.lastError = "LLM: " & e.msg
      # Estimator-vs-server calibration log. When the server rejects
      # with "exceeded model token limit: N (requested: M)", log the
      # gap between our estimate and M so the operator can read the
      # slop ratio directly. Format-tolerant — the substring search
      # works across opencode-go, OpenRouter wrap, etc., without
      # parsing JSON. If we can't find the requested-count, we skip.
      if "exceeded model token limit" in e.msg or
         "exceeded model context limit" in e.msg or
         "context length exceeded" in e.msg:
        var serverCount = ""
        let reqIdx = e.msg.find("requested: ")
        if reqIdx >= 0:
          let after = e.msg[reqIdx + 11 ..^ 1]
          for c in after:
            if c in {'0'..'9'}: serverCount.add(c)
            else: break
        let estLast = estimateTokens(currentMessages)
        let ratio =
          if serverCount.len > 0 and estLast > 0:
            let r = (try: parseInt(serverCount).float except: 0.0)
            if r > 0: r / estLast.float else: 0.0
          else: 0.0
        infoCF("agent", "Estimator vs server slop", {
          "session": opts.sessionKey,
          "iteration": $iteration,
          "our_estimate": $estLast,
          "server_count": serverCount,
          "ratio_server_over_estimate": $ratio,
          "model": al.model}.toTable)
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
    if al.model.len > 0: llmMeta["model"] = %al.model
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
      let assistantMsg = providers_types.Message(role: providers_types.RoleAssistant, content: response.content, reasoning_content: response.reasoning_content)
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
      let toolResultMsg = providers_types.Message(role: providers_types.RoleUser, content: formattedResults)
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
            currentMessages.add(providers_types.Message(role: providers_types.RoleAssistant,
              content: response.content,
              reasoning_content: response.reasoning_content))
            currentMessages.add(providers_types.Message(role: providers_types.RoleUser, content: "You described what you plan to do but did not call a tool. Take the action NOW: emit the tool call in this turn. Do not respond with words alone."))
            continue
          finalContent = response.content
        elif iteration > 1:
          # LLM returned empty after tool iterations — nudge to continue, then force summary
          emptyRetries.inc
          if emptyRetries <= 2:
            warnCF("agent", "LLM returned empty, nudging to continue", {"iteration": $iteration, "retry": $emptyRetries}.toTable)
            currentMessages.add(providers_types.Message(role: providers_types.RoleUser, content: "Continue with the task. Use tools to complete it, then reply to the user with the results."))
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
            summaryMessages.add(providers_types.Message(role: providers_types.RoleUser, content: summaryPrompt))
            try:
              let summaryDefs: seq[ToolDefinition] = @[]
              let summaryOpts = {"max_tokens": %4096, "temperature": %al.temperature, providers_fallback.SessionKeyOption: %opts.sessionKey}.toTable
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
          currentMessages.add(providers_types.Message(role: providers_types.RoleAssistant,
            content: response.content,
            reasoning_content: response.reasoning_content))
        currentMessages.add(providers_types.Message(role: providers_types.RoleUser, content: "Your last tool call had an empty function name. Please call the tool again with the correct name. For browser actions, use the 'playwright' tool with an action parameter."))
        continue

      emptyNameRetries = 0  # Reset on successful tool calls
      if opts.streamIntermediary and response.content.len > 0:
        al.bus.publishOutbound(newOutbound(opts.channel, opts.recipientID, opts.chatID, response.content, opts.replyToMessageID, opts.appID))

      var assistantMsg = providers_types.Message(role: providers_types.RoleAssistant, content: response.content, reasoning_content: response.reasoning_content, tool_calls: validCalls)
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
        # Cancellation check before each tool dispatch — gives
        # /session stop sub-second responsiveness even when the LLM
        # has queued multiple tool calls in a single iteration.
        if al.isCancelRequested(opts.sessionKey):
          al.clearCancel(opts.sessionKey)
          finalContent = "[Cancelled by /session stop. " &
            "Stopped before executing `" & tc.name & "`. Partial " &
            "work may have completed earlier; check messages above. " &
            "Send a new prompt to resume.]"
          infoCF("agent", "Turn cancelled mid-dispatch by /session stop", {
            "session": opts.sessionKey,
            "iteration": $iteration,
            "next_tool": tc.name}.toTable)
          break
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
          summaryMessages.add(providers_types.Message(role: providers_types.RoleUser, content: loopPrompt))
          try:
            let toolDefs: seq[ToolDefinition] = @[]
            let summaryOpts = {"max_tokens": %4096, "temperature": %al.temperature, providers_fallback.SessionKeyOption: %opts.sessionKey}.toTable
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
          appendToolResult(currentMessages, tc, msg)
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
        # Record in tool call log for forced summary context. 200-char
        # preview (vs subagent's 80) — this log feeds the forced-summary
        # prompt when the loop exhausts maxIterations, so the summariser
        # gets useful context.
        toolCallLog.add(formatToolLogEntry(tc, result, iteration, maxLen = 200))
        let toolResultMsg = makeToolResult(tc, result)
        currentMessages.add(toolResultMsg)
        al.sessions.addFullMessage(opts.sessionKey, toolResultMsg)

        # Framework auto-emit (Pattern 5 visibility): when this agent
        # is in technical-communication mode AND the channel renders
        # code blocks, synthesize a `reply_progress`-shape message
        # from the tool's args+result and send it on the agent's
        # behalf. Eliminates the failure mode where the agent
        # checkpoints with findings but skips file-paths/commands/
        # output, which `reply_progress` discipline alone empirically
        # could not enforce. Counts as a comm act for TC-2 streak
        # tracking — the user just received a message.
        var autoEmittedVisibility = false
        if tc.name notin CommTools and opts.channel == "feishu" and
           al.effectiveTechComm(opts.sessionKey):
          var viz = formatVisibilityMessage(tc.name, tc.arguments, result)
          if viz.len > 0 and al.sendCallback != nil:
            # For large `write_file` results, upload the FULL content
            # to a Lark Doc and append a clickable link to the
            # visibility message. Single-message UX (no separate file
            # attachment), and the user gets the full Doc treatment
            # (scroll + copy + share) when they click.
            if tc.name == "write_file" and
               tc.arguments.hasKey("path") and
               tc.arguments.hasKey("content") and
               al.larkTool != nil:
              let path = tc.arguments["path"].getStr()
              let content = tc.arguments["content"].getStr()
              if path.len > 0 and countLines(content) > 30:
                let basename = path.lastPathPart
                let docTitle = basename
                # Wrap in a fenced code block with the language tag
                # so lark-cli's markdown→Lark Doc converter renders
                # it as a syntax-highlighted code block element
                # rather than plain text paragraphs. Without this,
                # `--markdown content` treats Python source as
                # prose and the Doc UX is bad (no copy-with-format,
                # no syntax colours).
                let lang = inferLangFromPath(path)
                let docMarkdown =
                  if lang.len > 0: "```" & lang & "\n" & content & "\n```"
                  else: "```\n" & content & "\n```"
                let docUrlOpt = await al.larkTool.createDocViaBot(
                  docTitle, docMarkdown, opts.appID)
                if docUrlOpt.isSome:
                  let url = docUrlOpt.get
                  viz.add("\n\n📁 [Full file: " & basename &
                          "](" & url & ")")
                  infoCF("agent", "Auto-emit Lark Doc created",
                    {"path": path, "url": url,
                     "lines": $countLines(content)}.toTable)
                else:
                  # Fallback: doc creation failed (auth, scope, etc.).
                  # Just note the path; user can `cat` it locally.
                  viz.add("\n\n📁 Full file at: `" & displayPath(path) & "`")
                  warnCF("agent", "Auto-emit Lark Doc failed; " &
                                  "falling back to path text",
                    {"path": path,
                     "lines": $countLines(content)}.toTable)

            var meta = initTable[string, string]()
            meta["progress"] = "true"
            meta["format"] = "markdown"
            meta["framework_emit"] = "true"   # log-routing tag
            try:
              await al.sendCallback(opts.channel, opts.chatID, viz,
                                     al.agentName, opts.replyToMessageID,
                                     opts.appID, meta)
              # Persist as a synthetic assistant message so the LLM's
              # next turn knows what was already shown — avoids the
              # model re-emitting the same file/command/output in its
              # own reply_progress later. Speaker tagged so JSONL
              # operators can filter framework-emitted from
              # agent-emitted.
              let vizMsg = providers_types.Message(
                role: providers_types.RoleAssistant,
                content: viz)
              currentMessages.add(vizMsg)
              al.sessions.addWithSpeaker(opts.sessionKey,
                "assistant", viz, "framework:auto-emit")
              autoEmittedVisibility = true
              infoCF("agent", "Auto-emit visibility message", {
                "tool": tc.name,
                "session": opts.sessionKey,
                "chars": $viz.len,
                "iteration": $iteration}.toTable)
            except Exception as e:
              warnCF("agent", "Auto-emit failed",
                {"error": e.msg, "tool": tc.name}.toTable)

        # TC-2 streak tracking. Reset on a checkpoint-class tool OR
        # an auto-emit (framework just spoke for the agent); increment
        # otherwise. The injection check happens AFTER the whole
        # iteration's tool dispatch finishes (below the for loop) so
        # a single iteration with one non-comm + one comm tool is a
        # wash, not a violation.
        if tc.name in CommTools or autoEmittedVisibility:
          consecutiveNonCommTools = 0
          nudgeInjectedForStreak = false
        else:
          consecutiveNonCommTools += 1

        # Plan-derived budget scale: when `chat reply` is called with
        # the optional `progress=[...]` payload (TodoWrite-style plan),
        # bump the per-turn iteration cap to `min(N × 8, IterationHardCap)`.
        # Monotonic — only grows. The agent provides plan state on the
        # same tool that already announces progress.
        if tc.name == "chat" and al.chatTool != nil:
          let list = al.chatTool.progressItems.getOrDefault(opts.sessionKey, @[])
          if list.len > 0:
            let scaled = min(list.len * 8, IterationHardCap)
            if scaled > maxIter:
              let oldMax = maxIter
              maxIter = scaled
              infoCF("agent", "Iteration budget scaled from chat.progress", {
                "session": opts.sessionKey,
                "items": $list.len,
                "old_max": $oldMax,
                "new_max": $maxIter}.toTable)

      # reply/message already delivered the turn's final content — break
      # before the LLM gets another turn and calls reply again.
      if ctx.responseSent:
        break

      # TC-2 nudge: the streak just exceeded the threshold and we
      # haven't already nudged for this streak. Inject ONE synthetic
      # system message that the next LLM iteration sees in its most
      # recent context. Reset `nudgeInjectedForStreak` only happens on
      # a comm-tool call (above), so if the model ignores and does
      # another non-comm tool, no spam — but we still went on record.
      # Operators see the nudge in JSONL persistence; it's part of
      # the conversation now.
      if consecutiveNonCommTools >= ConsecutiveNonCommThreshold and
         not nudgeInjectedForStreak:
        let nudge = "[FRAMEWORK NUDGE — TC-2 enforcement] " &
          "You have made " & $consecutiveNonCommTools &
          " consecutive non-communication tool calls without a " &
          "checkpoint. Per rule TC-2, you MUST send a `chat reply " &
          "text=\"<concrete finding>\" interim=true` with the latest " &
          "result from your last tool BEFORE the next tool call. Do " &
          "not call another tool until you have sent the checkpoint. " &
          "The user has been waiting in silence and cannot see what " &
          "you are doing."
        let nudgeMsg = providers_types.Message(
          role: providers_types.RoleSystem, content: nudge)
        currentMessages.add(nudgeMsg)
        al.sessions.addFullMessage(opts.sessionKey, nudgeMsg)
        nudgeInjectedForStreak = true
        infoCF("agent", "TC-2 nudge injected", {
          "session": opts.sessionKey,
          "streak": $consecutiveNonCommTools,
          "iteration": $iteration}.toTable)

  # If the loop exited without producing finalContent AND without
  # the agent calling reply/message (which set ctx.responseSent),
  # make one final LLM call to recover a summary. Skipping when
  # ctx.responseSent is already true matters: the reply tool
  # delivers via sendCallback and never assigns to finalContent,
  # so naive `finalContent == ""` would treat every terminal-reply
  # turn as "exhausted" and burn a ~30K-prompt LLM call to produce
  # a summary that the post-loop persist path then discards via
  # the "Response already sent via tools, skipping final return
  # message" branch. ctx.responseSent is the truthful signal that
  # delivery happened.
  if not ctx.responseSent and finalContent == "" and
     (lastResponseContent != "" or toolCallLog.len > 0):
    warnCF("agent", "Tool loop ended without final response", {"iterations": $iteration, "max": $maxIter, "tool_calls": $toolCallLog.len}.toTable)

    # Build a compact context for the summary call — full message history is too long for GLM-5
    infoCF("agent", "Making final summary LLM call", initTable[string, string]())
    var exhaustPrompt = "You were performing a task for the user but reached the maximum number of tool iterations (" & $maxIter & "). Provide your FINAL response to the user NOW. Do NOT call any tools."
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
    summaryMessages.add(providers_types.Message(role: providers_types.RoleUser, content: exhaustPrompt))
    try:
      let toolDefs: seq[ToolDefinition] = @[]
      let summaryOpts = {"max_tokens": %4096, "temperature": %al.temperature, providers_fallback.SessionKeyOption: %opts.sessionKey}.toTable
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
  elif not ctx.responseSent and finalContent == "":
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
  ##     first-time sender                   → record in per-agent
  ##                                           guests.json, return
  ##                                           guest_<channel>_<sid>.
  ##                                           Guests get nc:ids only
  ##                                           via invite redemption —
  ##                                           the graph stays clean.
  ##
  ## Earlier design used a single shared session file per room. That
  ## broke when two users @mentioned the bot in the same group — the
  ## model saw both speakers' turns in a flat list and answered one
  ## person using the other's identity/context. Per-sender is strictly
  ## safer for @mention-triggered responses (groups don't auto-respond
  ## anyway as of the group-chat policy change).
  ##
  ## Transient sessions (those keyed with `TransientKeyPrefix` by Layer 2
  ## callers like the heartbeat orchestrator) are passed through
  ## verbatim. Otherwise the rewrite would clobber the prefix and make
  ## the SessionManager's transient-skip-disk path unreachable —
  ## defeating the no-bloat property the prefix exists to provide.
  if opts.sessionKey.isTransient:
    return opts.sessionKey
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

  # First-time sender — record in the per-agent `guests.json` ledger.
  # Guests do NOT get nc:ids; the graph is reserved for declared
  # entities (BASE.nims) and entities promoted via invite redemption
  # (which mints a Customer with a stable nc:id). Per-agent ledger is
  # the right home for first-contacts because they're ephemeral, high-
  # cardinality, and only meaningful to the agent currently talking
  # to them.
  #
  # Session key uses a `guest_<channel>_<senderID>` prefix — same
  # naming class as `grp_*` (group sessions) and `system_*` (internal):
  # all three are non-nc-id session families. When the guest later
  # redeems an invite, `redeem_invite` mints a graph entity with a
  # real nc:id; subsequent messages from them resolve through
  # `graph.resolveUserGraph` and key on `nc_<N>` instead.
  if uint32(entityID) == 0:
    if al.contextBuilder != nil:
      let guestKey = channelKey & ":" & opts.senderID
      if not al.contextBuilder.guests.hasKey(guestKey):
        al.contextBuilder.guests[guestKey] = newGuest(channelKey, opts.senderID)
        saveGuests(al.officeDir, al.contextBuilder.guests)
    return "guest_" & opts.channel & "_" & sanitize(opts.senderID)

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
  # Capture the key the snapshot is INSERTED under, so the defer
  # deletes the same entry. `opts.sessionKey` gets rewritten by
  # `identitySessionKey` further down (channel-keyed → identity-keyed
  # for normal users; transient keys pass through). Without this
  # capture, defer'd `liveTasks.del(opts.sessionKey)` runs against the
  # rewritten value and leaves the original entry stuck in the table.
  # Manifests for normal users as a same-key overwrite on the next
  # turn (silently fine), but for unique-per-call keys (heartbeat
  # ticks with timestamps) every tick leaks one entry that lives
  # until process restart, making /agent display tasks that finished
  # hours ago as still running.
  let snapshotKey = opts.sessionKey
  al.liveTasks[snapshotKey] = snapshot
  defer:
    snapshot.finishedAt = epochTime()
    al.liveLastFinished = snapshot
    al.liveTurnCount.inc
    al.liveTasks.del(snapshotKey)
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
    let history = al.getCappedHistory(opts.sessionKey)
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

    # Heartbeat-context override. SystemHeartbeatSender resolves via
    # graph fallback to "guest" (it's not an nc:id), which gives a
    # narrow grant. The heartbeat tick is the agent operating on her
    # OWN state, not an external party with limited trust — the
    # appropriate gate is HeartbeatAllowedTools (intentional minimal
    # set for batch-processing duties), not the Guest grant.
    if logicalUserID == tools_registry.SystemHeartbeatSender:
      allowedTools = @(tools_registry.HeartbeatAllowedTools)

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
    # Pass static defaults to the system-prompt builder so the
    # `## Iteration Budget` directive shows authoritative numbers.
    # Hard cap is the literal in IterationHardCap below; kept as a
    # literal here because the const lives in inner scope.
    var messages = al.contextBuilder.buildMessages(logicalUserID, history, summary, opts.userMessage, opts.channel, opts.chatID, useXmlTools, targetRecipient, opts.botDisplayName, opts.mentionsJson, opts.appID, maxIterations = al.maxIterations, hardCapIterations = 150)

    # Snapshot the session length BEFORE adding the user message.
    # If the LLM call fails transiently (provider outage, no real
    # assistant content produced), we roll back to this length so
    # the user's failed message doesn't persist — preventing the
    # session from accumulating duplicate user messages when they
    # retry during an outage.
    let preTurnMessageCount = al.sessions.messageCount(opts.sessionKey)

    # Store the user's message in history WITHOUT the nc:id prefix.
    # With per-sender session keys (see identitySessionKey for group
    # chats), the session only contains one speaker's turns anyway, so
    # the prefix is redundant. It also caused the LLM to echo the nc:id
    # back to the user in replies. `addWithSpeaker` preserves the
    # speaker's nc:id separately for any tool that cares.
    al.sessions.addWithSpeaker(opts.sessionKey, "user",
      opts.userMessage, logicalUserID)

    # Phase 1 outcome-signal capture: positive feedback. Scan the
    # user's inbound message for explicit recognition markers and
    # record an experience entry on the partner's experience file
    # tied to the most recent assistant turn (what the user is
    # praising). Cheap keyword check, no LLM call. The negative
    # counterpart fires in the cancellation-rollback path below.
    if logicalUserID.startsWith("nc:") and
       al.contextBuilder != nil and al.contextBuilder.memory != nil:
      let (matched, marker, weight) = detectPositiveMarker(opts.userMessage)
      if matched:
        let praisedWork = summarizeRecentAssistantTurn(messages)
        let content = "marker=\"" & marker & "\"; praised: " & praisedWork
        al.contextBuilder.memory.recordExperience(
          logicalUserID, "positive_feedback", content, weight)
        infoCF("agent", "Recorded positive_feedback experience",
               {"session_key": opts.session_key,
                "partner": logicalUserID,
                "marker": marker,
                "weight": $weight}.toTable)

    # Immediate feedback: notify bus that bot is "typing"
    al.bus.publishOutbound(OutboundMessage(
      channel: opts.channel,
      sender_agent: opts.recipientID,
      chat_id: opts.chatID,
      kind: Typing,
      reply_to_message_id: opts.replyToMessageID,
      app_id: opts.appID
    ))

    let (finalContentRaw, iteration, turnMessages) = await al.runLLMIteration(ctx, messages, opts, logicalUserID, allowedTools, snapshot)
    var finalContent = finalContentRaw

    if finalContent == "":
      finalContent = opts.defaultResponse

    # Two reasons to drop everything from this turn:
    #   - Transient LLM-error: the call itself failed (no real
    #     assistant content was produced); surfacing the
    #     "Error communicating with LLM provider: ..." string as
    #     Lexi's "last reply" makes the next turn apologise for /
    #     explain a system failure that wasn't hers.
    #   - /session stop: the user explicitly aborted the turn,
    #     usually because the agent was on the wrong track. Keeping
    #     the cancelled iterations' tool calls in history would bias
    #     the next turn toward continuing the wrong direction. Full
    #     rollback gives the user a clean retry surface — exactly
    #     the rollback semantics they asked for.
    # In both cases the message text is still returned to the
    # caller and shown to the user; only the JSONL record is
    # rolled back to the pre-turn snapshot.
    let isTransientError = finalContent.startsWith(
      "Error communicating with LLM provider:")
    let isCancelledTurn = finalContent.startsWith(
      "[Cancelled by /session stop")
    let shouldRollback = isTransientError or isCancelledTurn

    if shouldRollback:
      # Capture the cancellation as a partner experience BEFORE the
      # session JSONL is rolled back — this is the only signal we
      # have that the user pushed back, and we need it to land in
      # the partner's experience file so the offline synthesizer
      # can later spot recurring "wrong direction" patterns and
      # promote them into reflections / reflexes. Transient LLM
      # errors are NOT experiences — they're framework failures,
      # not signals about how the agent was doing.
      if isCancelledTurn and logicalUserID.startsWith("nc:") and
         al.contextBuilder != nil and al.contextBuilder.memory != nil:
        let preview = summarizeCancelledTurn(turnMessages, iteration)
        al.contextBuilder.memory.recordExperience(
          logicalUserID, "cancelled_turn", preview, -1.0)
        infoCF("agent", "Recorded cancellation experience",
               {"session_key": opts.session_key,
                "partner": logicalUserID,
                "preview": preview}.toTable)

      al.sessions.rollbackTo(opts.sessionKey, preTurnMessageCount)
      let kind =
        if isCancelledTurn: "user cancellation (/session stop)"
        else: "transient LLM-error"
      infoCF("agent",
             "Rolled back turn",
             {"session_key": opts.session_key,
              "reason": kind,
              "rolled_back_to": $preTurnMessageCount,
              "preview": finalContent[0 ..< min(finalContent.len, 120)]}.toTable)

    if ctx.responseSent:
      infoCF("agent", "Response already sent via tools, skipping final return message", {"session_key": opts.session_key}.toTable)
      # Still add to history but return empty so gateway doesn't send it again
      if not shouldRollback:
        al.sessions.addWithSpeaker(opts.sessionKey, "assistant", finalContent, al.agentId)
      return ""

    if not shouldRollback:
      al.sessions.addWithSpeaker(opts.sessionKey, "assistant", finalContent, al.agentId)

    if opts.enableSummary:
      al.maybeSummarize(opts)

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

proc liveTaskCount*(al: AgentLoop): int {.inline.} =
  ## Layer 1 primitive: how many turns is this AgentLoop currently
  ## running concurrently? Used by Layer 2 schedulers (heartbeat
  ## orchestrators, system-event dispatchers) to apply skip-if-busy
  ## policy without reaching into AgentLoop internals.
  al.liveTasks.len

proc processOneShot*(al: AgentLoop, prompt: string,
                     senderID: string = tools_registry.SystemHeartbeatSender,
                     channel: string = "system"): Future[string] {.async.} =
  ## Layer 1 primitive: run a single agent turn whose conversation
  ## state does NOT persist to disk. The iteration loop runs
  ## normally — tools execute, the LLM responds, mid-turn size guards
  ## still apply — but every session write short-circuits because the
  ## sessionKey carries `TransientKeyPrefix`. After the turn completes
  ## the in-memory state is cleared.
  ##
  ## Used by Layer 2 callers (heartbeat orchestrator, system events)
  ## that want a turn to fire without leaving a session footprint or
  ## accumulating across-tick history. Stateful continuity, when
  ## actually wanted, is the caller's job — typically via explicit
  ## `memory_store` writes from inside the agent's tool surface.
  let key = TransientKeyPrefix & senderID & ":" & $epochTime()
  let msg = InboundMessage(
    channel: channel, sender_id: senderID,
    recipient_id: al.agentName, chat_id: "oneshot",
    content: prompt, session_key: key)
  try:
    result = await al.processMessage(msg)
  finally:
    # Drop the in-memory transient session so we don't accrue
    # ghost entries across many ticks. The disk paths were already
    # no-ops (TransientKeyPrefix), so this is a memory-only wipe.
    try: al.sessions.clearSession(key)
    except CatchableError: discard

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

  # --- Filesystem trio (sea / ship / navigator) + exec + clock ---
  # fs     = structural ops (list, mkdir, delete, move, copy, info, exists)
  # file   = single-file content I/O (read [offset/limit], write, edit, append)
  # finder = discovery: files by glob pattern OR content by ripgrep search
  # Replaces the prior read_file/write_file/list_dir/edit_file/append_file
  # quintet. Path-safety (workspace-bounded, refuse `..` traversal) preserved
  # verbatim through path_security helpers in each.
  regTagged(newFsTool(workspace, officeDir, allowedPaths),
            ["filesystem", "data", "core"],
            "structural fs ops: list mkdir delete move copy exists info (method=list|exists|info|mkdir|delete|move|copy)")
  regTagged(newFileTool(workspace, officeDir, allowedPaths),
            ["filesystem", "data", "core"],
            "single-file content I/O: read write edit append (method=read|write|edit|append)")
  regTagged(newFinderTool(workspace, officeDir, allowedPaths),
            ["filesystem", "search", "data", "core"],
            "discover files and content: glob path search and ripgrep content search (method=files|content)")
  regTagged(newShellTool(workspace), ["system", "dev", "automation", "core"], "process invocation: run command (sync or background); manage bg processes (read/kill/list)")
  # `clock` folded into `office method=clock` (timezone-aware, office-bound).
  regTagged(newOfficeTool(officeDir, workspace),
            ["agent", "core", "office"],
            "agent's vessel: clock/calendar/info/state/occupant/stats — read-only, self-only")
  # Derive company name from the workspace's parent dir basename
  # (`.nimclaw-<name>/workspace/` → `<name>`).
  let companyDirName = extractFilename(parentDir(workspace))
  let companyName = if companyDirName.startsWith(".nimclaw-"):
                      companyDirName[".nimclaw-".len .. ^1]
                    else: companyDirName
  let companyTool = newCompanyTool(workspace, companyName, cfg.agents.named)
  regTagged(companyTool,
            ["agent", "core", "company", "org"],
            "org-level navigator: info/memos/workforce/labs/business — trust-gated reads (Phase 1)")
  # The per-agent todo store lives at <officeDir>/notes/todo.jsonl;
  # pass officeDir not workspace, otherwise the tool writes to the
  # company root and the heartbeat dispatcher (which reads from the
  # office) can't see the tombstone.
  regTagged(newTodoTool(officeDir), ["agent", "core"], "untimed batch queue (defer/done); use schedule for time-anchored work")
  # `knowledge` is the ship in the memory/knowledge/skill trio — timeless
  # facts (vs memory's raw past, skill's procedural how-to). Actions:
  # consolidate | lookup | list | rank | top. Ranks are agent-decided
  # (1-10 with reason); aggregate displayed once ≥ 2 votes.
  regTagged(newKnowledgeTool(officeDir, agentName),
            ["agent", "core", "knowledge", "wiki"],
            "knowledge wiki: consolidate write append timeless facts; lookup read; rank agent-judgment 1-10; top sort by aggregate")
  # `mail` is the unified persistent / async messaging tool. Three
  # transport kinds: internal (file queue between agents), email
  # (SMTP/IMAP/Postmark/etc — needs an email-kind channel enabled),
  # shipment (FedEx/UPS/USPS/DHL — needs a shipment-kind channel).
  # The send callback handles email + shipment dispatch via the
  # MessageBus; internal kind dispatches directly via filesystem.
  # Callback is bound below once it's defined; until then internal kind
  # works (no callback needed) and email/shipment self-error if called.
  let mailTool = newMailTool(workspace, officeDir)
  regTagged(mailTool,
            ["comm", "mail", "messaging", "core"],
            "mail send reply forward archive track internal email shipment memo parcel")
  regTagged(newWorkstationTool(officeDir), ["agent", "core", "workstation"], "GitHub-like local platform: overview/repo/project/item/audit (per-agent under <office>/workstation/)")

  # Channel — vendor-level transport navigator (read-only). Lists enabled
  # channel vendors and their feature matrices (text length, markdown,
  # card kind, file/voice/react/edit/delete/threading, formatting). The
  # tool reaches the live manager via channels/access (gateway calls
  # bindChannelAccess once after initChannels).
  regTagged(newChannelTool(toolsRegistry), ["comm", "channel", "transport", "core"],
            "channel transport navigator: list vendors + features; routes vendor-specific docs/sheets/calendar/tasks to mcp_<vendor>_<op> tools")

  # Payment — channel-agnostic value-transfer protocol verbs (Phase 1:
  # READ-ONLY balance/status/history). Routes via vendor-rail skills
  # (nkn-suite today; btc/lightning/usdc-* future). Default off; operator
  # opts in by installing a payment-rail skill in BASE.nims.
  # `payment` folded under `company method=business.payment.<op>` (Phase 3).
  # Construct the tool but DON'T register as standalone — register as a
  # business domain on the company tool below.
  let paymentToolInstance = newPaymentTool(toolsRegistry)
  companyTool.registerBusinessDomain("payment", paymentToolInstance)

  # --- Web tools ---
  # Internet stack — sea / ship / navigator
  #   web    = the sea (HTTP fetch + raw request)
  #   browser= the ship (interactive Chromium)  — registered elsewhere via browser_unified
  #   search = the navigator (search engines: Brave w/ DDG fallback)
  regTagged(newWebTool(50000, toolCurly, createMaster()),
            ["web", "http", "data"],
            "HTTP fetching: page extraction and raw HTTP requests (method=fetch|request)")
  regTagged(newSearchTool(expandEnv(cfg.tools.web.search.api_key),
                          cfg.tools.web.search.max_results,
                          toolCurly, createMaster()),
            ["web", "search", "discovery", "core"],
            "search the web — find pages by query, returns title/url/snippet")

  # --- Dev tools ---
  # `git` tool dropped — use `shell run cmd="git ..."` per Claude Code convention.
  # Workflow discipline encoded in agent competencies, not in a separate tool.
  # (pushover folded into channels/pushover.nim — agents reach it via `chat send vendor=pushover`)
  regTagged(newSystemTool(workspace), ["system", "host", "core"], "host machine substrate: capture screenshot, host info, transports/introspection (Phase 2 stubs)")
  let allowedDomainsStr = getEnv("BROWSER_ALLOWED_DOMAINS", "")
  var allowedBrowserDomains: seq[string] = @[]
  if allowedDomainsStr.len > 0:
    for d in allowedDomainsStr.split(','):
      let t = d.strip()
      if t.len > 0: allowedBrowserDomains.add(t)

  # Browser tool registered later (after the conditional playwright availability check)

  let callback: SendCallback = proc(channel, chatID, content, senderAgent, replyToMessageID, appID: string, metadata: Table[string, string] = initTable[string, string]()): Future[void] {.async.} =
    msgBus.publishOutbound(newOutbound(channel, senderAgent, chatID, content, replyToMessageID, appID, metadata))



  # --- Agent & delegation ---
  let subagentManager = newSubagentManager(
    provider, workspace, msgBus, toolsRegistry, nil,
    maxIterations =
      max(1, cfg.agents.defaults.max_tool_iterations),
    focus_modes = cfg.focus_modes,
    namedAgents = cfg.agents.named)
  regTagged(newFocusTool(subagentManager), ["agent", "automation"], "concentrate on a subtask with a constrained tool surface (intra-agent)")

  # --- Hardware (unified) ---
  # hardware tool dropped — i2c/spi/mem_read/mem_write are embedded-only (option A).
  # Host-level board info lives in `system method=info`. If on-device peripheral
  # I/O is needed, install a separate skill.
  regTagged(newDelegateTool(workspace, cfg.agents.named, askPeer = askPeer), ["agent", "delegation"], "delegate tasks to other named agents")
  # Collaborate — multi-agent orchestration over delegate. The navigator
  # of the social/delegate/collaborate trio: fan_out (parallel) or
  # pipeline (sequential A→B→C). Internally calls askPeer N times.
  regTagged(newCollaborateTool(workspace, cfg.agents.named, askPeer = askPeer),
            ["agent", "delegation", "orchestration", "core"],
            "fan out parallel pipeline orchestrate multiple agents collaborate")
  # `social` (formerly query_graph + update_contact + my_customers +
  # create_customer_invite + invite/redeem) registered after
  # contextBuilder is created — see below.

  # (edit + append moved into `file` tool above — actions edit/append)
  # (the former standalone `task` tool — assign/claim/submit on the team
  #  TASKS.md board — folded into `collaborate` as its late-binding
  #  actions; the pool is just another shape of multi-agent coordination)

  # --- Admin & config ---
  # `mcp` folded under `tools method=mcp.<op>` (Phase 3). Construct the
  # tool but register as a sub-tool on the tools tool, not standalone.
  let mcpToolInstance = newUnifiedMcpTool(toolsRegistry, officeDir)
  # learn_skill: author a workstation SKILL.md from structured inputs (enforces invariants).
  # Only exposed to agents with workstation:true — see the auto-add below near the ClawDSL scope block.
  # Skill management — install registry/GitHub skills + author workstation Tier-3 skills (skill_unified)
  # set_api_key folded into `provider method=set_key name=<x> api_key=<y>`
  # — provider IS the LLM-credentials manager; key-setting belongs there.
  # Provider / model / capability — the sea / ship / navigator trio for
  # the LLM stack. Replaces provider_auth + model_list with three unified
  # tools sharing the framework catalog as substrate:
  #   provider   = LLM accounts (sea)   — list, verify, info
  #   model      = LLM models (ship)    — list, info, current
  #   capability = capability discovery (navigator) — list, find, has
  # `capability method=has` is heartbeat-safe and designed for framework-
  # internal feature gating (e.g., "does this agent's current model have
  # vision before we serve an image?").
  regTagged(newProviderTool(),
            ["admin", "providers", "diagnostics", "core"],
            "list verify info LLM provider api key endpoint")
  regTagged(newModelTool(),
            ["diagnostics", "providers", "models", "core"],
            "list info current LLM model capabilities context pricing")
  regTagged(newCapabilityTool(),
            ["diagnostics", "models", "capability", "core"],
            "find list has model capability tag vision tool-use reasoning")
  # feishu_add_app folded into `channel method=add_app vendor=feishu
  # app_id=cli_… app_secret=… agent=…`. Trust gate (SuperAdmin) lives
  # in runFeishuAddApp; channel_unified's add_app handler dispatches.
  # (Customer onboarding + my-customers + graph-query + update-contact +
  # redeem-invite all collapsed into the unified `social` tool, registered
  # below near the contextBuilder creation site since `social` needs the
  # ContextBuilder for its guest-rename path.)
  # json_query / jq tool dropped — use `shell run cmd="jq ..."` per the
  # primitives-not-wrappers convention. Same pattern as git.

  # Solar — vendor-agnostic facade for multi-vendor solar power
  # stations. Substrate in tools/solar/solar_adapter.nim; agent surface
  # is `solar` (one tool, five actions). Default off; the
  # solar-power-station template's solar-adapter skill declares it in
  # requires.tools so agents that opt in receive the grant.
  # `solar` folded under `company method=business.solar.<op>` (Phase 3).
  let solarToolInstance = newSolarTool(toolsRegistry)
  companyTool.registerBusinessDomain("solar", solarToolInstance)

  let installer = newSkillInstaller(officeDir)

  # TTS/STT is provided externally by the tts.nim nimble package.
  # Install via `claw skill install tts` — scaffolds workspace/skills/tts/
  # with a bin/tts shim that execs `tts_cli serve` as an MCP stdio server.
  # The generic MCP scan below picks it up; no in-tree engine or tool registration.

  let sessionsManager = newSessionManager(officeDir / "sessions")
  let contextBuilder = newContextBuilder(officeDir, workspace, cfg.agents.named)
  # SkillTool registers AFTER contextBuilder is constructed so it can share
  # the SkillsLoader (whose `loadedLazySkills` set is read by the prompt
  # builder). The allowedSkills closure resolves at call-time so a tool
  # invocation always sees the current resolved scope (set just below).
  regTagged(
    newSkillTool(
      installer, officeDir, toolsRegistry,
      contextBuilder.skillsLoader,
      proc (): seq[string] = contextBuilder.allowedSkills),
    ["admin", "skills", "workstation"],
    "skill management: list/load/unload session skills, install plugins, author workstation skills")
  contextBuilder.tools = toolsRegistry # Manually bridge for now
  contextBuilder.agentName = agentName
  contextBuilder.trust = cfg.trust
  # Populate allowedSkills from this agent's ClawDSL uses, and capture
  # practices so we can run the policy-update reconciliation below
  # plus derive the technical-communication default flag.
  var agentPractices: seq[string]
  for na in cfg.agents.named:
    if na.name.toLowerAscii() == agentName.toLowerAscii():
      contextBuilder.allowedSkills = na.skills
      agentPractices = na.practices
      break
  let techCommDefault = "technical-communication" in agentPractices

  # Policy-version reconciliation: when the agent's communication
  # policy (handbooks + Important Rules version) has changed since a
  # given session was last touched, append a system-role marker so the
  # LLM stops using prior turns as stylistic precedent. Without this,
  # the model imitates its own past style much more strongly than it
  # follows freshly-tightened abstract rules — long-running sessions
  # silently keep producing the old behavior even after the operator
  # ships a discipline update. Idempotent across restarts.
  let policyHash = contextBuilder.computePolicyHash(agentName, agentPractices)
  if policyHash.len > 0:
    let policyMarker = "[POLICY UPDATE — communication discipline tightened]\n\n" &
      "The communication-discipline rules in your system prompt have been " &
      "tightened since this session was last active. From this turn forward, " &
      "follow the UPDATED handbook strictly. Specifically: never go more than " &
      "2 consecutive tool calls without sending a `chat reply ... interim=true` " &
      "checkpoint, and end long-task replies with a terminal `chat reply` " &
      "(no interim) carrying three explicit numbered next-step options. " &
      "Prior turns in this conversation predate this rule and MUST NOT be " &
      "treated as stylistic precedent."
    let injected = sessionsManager.applyPolicyUpdate(policyHash, policyMarker)
    if injected > 0:
      infoCF("agent",
             "Policy-update marker injected into existing sessions",
             {"agent": agentName, "sessions": $injected,
              "hash": policyHash}.toTable)

  # Social — single tool for read/write of the world graph + customer
  # onboarding flow. Backed by cortex module. Consolidates the former
  # query_graph + update_contact + my_customers + create_customer_invite
  # + invite (the misnamed redeemer) tools. Action enum: query | who |
  # update | customers | invite | redeem.
  regTagged(newSocialTool(officeDir, workspace, contextBuilder),
            ["admin", "social", "graph", "customer", "invite", "core"],
            "query graph who entity rename contact customers onboard mint redeem invite pin code")

  # `chat` is the channel-agnostic protocol layer (send/reply/forward).
  # Format selection is capability-driven (consults `channel capabilities`)
  # — no hardcoded `t.channel == "feishu"` branches anywhere in this
  # tool. `reply` and `reply_progress` were folded into chat: agent calls
  # `chat reply text="..." [progress=[...]] [interim=true]`. Plan-state
  # in `progress=[]` powers iteration-budget scaling (read by the
  # AgentLoop dispatch loop via al.chatTool.progressItems).
  # Bind the send callback to mailTool now that callback is in scope.
  mailTool.setSendCallback(callback)

  let chatTool = newChatTool()
  chatTool.setSendCallback(callback)
  chatTool.setTags(@["comm", "chat", "messaging", "core"])
  chatTool.setSearchHint("send reply forward channel-agnostic chat")
  toolsRegistry.register(chatTool)

  # `larkTool` is constructed (Feishu vendor implementation surface)
  # but NOT registered in the agent-facing tool registry. It exposes
  # createDocViaBot as a Nim API used by the framework's auto-emit
  # feature (large write_file results uploaded as Lark Docs). Agent-
  # facing access to Feishu-unique features (docs / sheets / calendar /
  # tasks) will be exposed via `channel` vendor-action dispatch when
  # that's built — agents shouldn't see vendor implementation surface
  # directly.
  let larkTool = newLarkCliTool()

  # --- Discovery & meta ---
  let findToolInstance = newFindTools(toolsRegistry)
  findToolInstance.setTags(@["utility", "core"])
  findToolInstance.setSearchHint("discover and activate hidden tools")
  # Register mcp as a sub-tool of `tools` (folded — Phase 3).
  findToolInstance.registerSubTool("mcp", mcpToolInstance)
  toolsRegistry.register(findToolInstance)
  # (Graph query collapsed into `social method=query` — see registration above.)

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
  
  # Browser unified tool — wraps system-browser launch (always available)
  # plus Playwright CLI automation (only if npx is installed).
  # Browser profile state (cookies, cache, sessions) lives in support/playwright/
  # — not content, not logs, just state the external tool needs between calls.
  var pwTool: PlaywrightTool = nil
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
    pwTool = newPlaywrightTool(pwDir)
  regTagged(newBrowserTool(allowedBrowserDomains, pwTool), ["browser", "web", "ui", "automation"], "browser interaction: open URL (method=open) or playwright automation (method=automate)")

  # --- Memory (unified, trust-gated) ---
  # Shares the same MemoryStore the ContextBuilder uses for system-prompt
  # injection so both the auto-injected memory and explicit recall tool
  # calls see exactly the same data (filtered by the same authorisation).
  # The loop updates the tool's requester context before each LLM turn.
  let memTool = newUnifiedMemoryTool(contextBuilder.memory)
  regTagged(memTool, ["memory", "data", "core"], "store recall list forget memory facts preferences trust-gated")

  # Phase 8f — boot-time validation guard. After all framework tools
  # are registered above, compare the live registry to the manifest
  # SSOT. Any mismatch is logged so drift surfaces immediately.
  # Runs once per AgentLoop creation (which happens at first per-agent
  # message dispatch); cheap one-time cost, catches the entire drift
  # class we previously hit by hand-maintaining 5 separate lists.
  block validateManifest:
    let registered = toolsRegistry.list()
    var missingFromRegistry: seq[string] = @[]
    var missingFromManifest: seq[string] = @[]
    for s in tool_manifest.AllTools:
      if s.name notin registered:
        missingFromRegistry.add(s.name)
    for name in registered:
      if name.startsWith("mcp_"): continue   # MCP tools register dynamically
      if tool_manifest.toolByName(name).isNone:
        missingFromManifest.add(name)
    if missingFromRegistry.len > 0:
      warnCF("agent", "Manifest declares tools that are not registered",
        {"agent": agentName, "missing": missingFromRegistry.join(",")}.toTable)
    if missingFromManifest.len > 0:
      warnCF("agent", "Tools registered with no manifest entry (drift)",
        {"agent": agentName, "extra": missingFromManifest.join(",")}.toTable)

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
    model: model,
    contextWindow: resolveContextWindow(model,
      max(cfg.agents.defaults.max_tokens, 32000)),
    maxResponseTokens: resolveMaxOutputTokens(model,
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
    memTool: memTool,
    techCommDefault: techCommDefault,
    sendCallback: callback,
    chatTool: chatTool,
    larkTool: larkTool,
    cancelRequested: initTable[string, bool]()
  )
  debugCF("agentLoop", "Instance created", {"agent": agentName}.toTable)
  initLock(al.summarizingLock)
  initLock(al.cancelLock)

  # Resolve agentId from WorldGraph (nc:ID format)
  if contextBuilder.graph != nil and contextBuilder.graph.nameIndex.hasKey(agentName):
    al.agentId = toAlias(contextBuilder.graph.nameIndex[agentName])
  else:
    al.agentId = agentName  # Fallback to name if no graph

  # Register ScheduleTool using the loop instance for execution
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
    
    regTagged(newScheduleTool(cronService, cronExecutor, msgBus, officeDir), ["scheduling", "automation", "cron"], "time-anchored work — cron jobs and notes.org calendar TODOs")

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
    # `skill` (method=learn) is the workstation-authoring path; was
    # `learn_skill` standalone pre-Phase-3b. Always available when
    # `workstation true` is set on the agent.
    if "skill" notin al.allowedTools:
      al.allowedTools.add("skill")

  return al

proc getStartupInfo*(al: AgentLoop): Table[string, JsonNode] =
  var info = initTable[string, JsonNode]()
  info["tools"] = %*{"count": al.tools.list().len, "names": al.tools.list()}
  info["skills"] = %al.contextBuilder.getSkillsInfo()
  return info
