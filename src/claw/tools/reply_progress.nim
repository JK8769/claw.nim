## reply_progress — checkpoint communication + plan-state primitive.
##
## Same delivery primitive as `reply`, semantically distinct. Used by agents
## doing analytical / multi-step work to send progress updates BETWEEN tool
## clusters, so the user knows what's happening rather than staring at
## "agent typing..." for minutes.
##
## Plan-state (TodoWrite-style) is folded into this tool: an optional `items`
## parameter carries the agent's current plan with per-item statuses. The
## framework reads these items each call to:
##   1. Scale the per-turn iteration budget (item count × 8, capped at 150).
##   2. Detect productive progress (recent item completions) for the 80%
##      auto-extend gate.
## A separate `task_list` tool was previously used for this — folded back
## here on UX feedback ("two tools with overlapping purpose is friction").
##
## Why a separate tool from `reply`:
##
##   - Different LLM intent: this is for "status during a task" vs `reply`
##     for "the final answer". Without this distinction, agents tend to
##     either send 0 progress messages or treat every thought as worth
##     sharing.
##
##   - Different log routing: tool calls show up in JSONL with their tool
##     name, so debugging filters can distinguish "checkpoint" from
##     "answer" without parsing content.
##
##   - Different display affordance: a small "📊" marker is prepended so
##     the user can visually distinguish progress from a final answer.

import std/[asyncdispatch, json, tables, strutils, options, times]
import types

type
  TaskItemStatus* = enum
    tisPending = "pending"
    tisInProgress = "in_progress"
    tisCompleted = "completed"

  TaskItem* = object
    content*: string
    status*: TaskItemStatus

  ReplyProgressTool* = ref object of ContextualTool
    sendCallback*: types.SendCallback
    items*: Table[string, seq[TaskItem]]
      ## Per-session current plan list. Replaced wholesale on each call
      ## that includes `items`. TodoWrite-style — agent sends the full
      ## state each time. Read by the agent loop's iteration-budget
      ## logic in loop.nim (plan-derived scaling + productive-progress
      ## auto-extend gate).
    completionTimestamps*: Table[string, seq[(int, float)]]
      ## Per-session log of (item_index, ts_completed) pairs. Used by
      ## the productive-progress gate to detect "did any item finish
      ## recently?" without reconstructing diffs from history.

proc newReplyProgressTool*(): ReplyProgressTool =
  ReplyProgressTool(
    items: initTable[string, seq[TaskItem]](),
    completionTimestamps: initTable[string, seq[(int, float)]]()
  )

proc setSendCallback*(t: ReplyProgressTool, callback: types.SendCallback) =
  t.sendCallback = callback

proc parseStatus(s: string): Option[TaskItemStatus] =
  case s.toLowerAscii.strip
  of "pending": some(tisPending)
  of "in_progress", "in-progress", "inprogress": some(tisInProgress)
  of "completed", "done": some(tisCompleted)
  else: none(TaskItemStatus)

method name*(t: ReplyProgressTool): string = "reply_progress"

method description*(t: ReplyProgressTool): string =
  "Send an INTERPRETATION checkpoint during a long-running task — your plan, an analytical insight, a decision rationale, a pivot. NOT for showing tool work itself: file paths + code snippets, bash commands + terminal output are AUTO-EMITTED by the framework on Feishu when technical-communication mode is on. You don't manage that. " &
  "OPTIONAL `items` parameter carries your plan as a list with per-step statuses (pending|in_progress|completed). Pass items at the start of any task with ≥3 analytical steps so the framework can scale your iteration budget (`min(N × 8, 150)`) and check recent completions for the 80% auto-extend gate. Pass the FULL current list each call — framework replaces. Mark items in_progress when you start, completed when done. " &
  "Examples: (1) `{content: \"Plan: load → analyze → report\", items: [{content: \"Load 2025 data\", status: \"in_progress\"}, {content: \"Analyze\", status: \"pending\"}, {content: \"Report\", status: \"pending\"}]}` (2) `{content: \"Found 9.6% negative-price slots clustered Nov-Dec — model trained on uniform distributions will underestimate winter swings.\"}` (no items, just an interpretation update) (3) `{content: \"Pivoting to per-month threshold\", items: [...current list with step 1 marked completed...]}`. " &
  "Distinct from `reply` (final answer with TL;DR + 3 options). Markdown supported. Renders as a small 📊-prefixed status message in chat."

method parameters*(t: ReplyProgressTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "content": {
        "type": "string",
        "description": "The checkpoint update text. 1-3 sentences ideal. Should report your interpretation/decision/finding, with concrete numbers. Markdown supported."
      },
      "format": {
        "type": "string",
        "description": "Message format: 'text' (default) or 'markdown'. Use markdown for tables / structured findings."
      },
      "items": {
        "type": "array",
        "description": "Optional. Your full current plan list — replaces prior state. Pass at task start (all pending or first as in_progress); update each call to mark progress. Each item has content (≤80 chars) and status (pending|in_progress|completed). Framework reads this for iteration budget scaling and progress signals.",
        "items": {
          "type": "object",
          "properties": {
            "content": {"type": "string"},
            "status": {"type": "string", "enum": ["pending", "in_progress", "completed"]}
          },
          "required": ["content", "status"]
        }
      }
    },
    "required": %["content"]
  }.toTable

method execute*(t: ReplyProgressTool, args: Table[string, JsonNode]):
                Future[string] {.async.} =
  if t.sessionKey.startsWith("system:"):
    return "Error: Communication tools are disabled for background tasks. Please keep your response internal."

  if not args.hasKey("content"):
    return "Error: content is required"

  let raw = args["content"].getStr()
  if raw.len == 0:
    return "Error: content cannot be empty"

  # Prepend a subtle marker so the user can visually distinguish progress
  # updates from final answers in the chat. The marker is intentionally
  # small — we want to inform without dominating the message.
  let content = "📊 " & raw

  var metadata = initTable[string, string]()
  metadata["progress"] = "true"   # log-routing tag

  # Format passthrough; default text. reply_progress in markdown is fine —
  # tables and bullet lists render cleanly on Feishu.
  let format = args.getOrDefault("format").getStr("text")
  if format == "markdown":
    metadata["format"] = "markdown"

  if t.channel == "" or t.chatID == "":
    return "Error: No active chat context found for progress reply"
  if t.sendCallback == nil:
    return "Error: Reply callback not configured"

  # Process optional items (plan state). When provided, replaces prior
  # state for this session and logs new completions for the
  # productive-progress gate.
  var newlyCompletedCount = 0
  if args.hasKey("items"):
    let arr = args["items"]
    if arr.kind != JArray:
      return "Error: items must be an array"
    var newItems: seq[TaskItem]
    for v in arr:
      if v.kind != JObject:
        return "Error: each item must be an object with content + status"
      let cText = v.getOrDefault("content").getStr().strip()
      let sText = v.getOrDefault("status").getStr().strip()
      if cText.len == 0:
        return "Error: each item's content must be non-empty"
      let sOpt = parseStatus(sText)
      if sOpt.isNone:
        return "Error: status must be one of pending|in_progress|completed, got: " & sText
      newItems.add(TaskItem(content: cText, status: sOpt.get))

    let key = if t.sessionKey.len > 0: t.sessionKey else: "_default"
    let prior = t.items.getOrDefault(key, @[])
    for i, ni in newItems:
      if ni.status == tisCompleted:
        let wasCompletedBefore =
          i < prior.len and prior[i].status == tisCompleted
        if not wasCompletedBefore:
          newlyCompletedCount.inc
          if not t.completionTimestamps.hasKey(key):
            t.completionTimestamps[key] = @[]
          t.completionTimestamps[key].add((i, epochTime()))
    t.items[key] = newItems

  try:
    await t.sendCallback(t.channel, t.chatID, content, t.agentName,
                          t.replyToMessageID, t.appID, metadata)
    if newlyCompletedCount > 0:
      return "Progress update sent successfully (" &
             $newlyCompletedCount & " item(s) newly completed)"
    return "Progress update sent successfully"
  except Exception as e:
    return "Error sending progress update: " & e.msg
