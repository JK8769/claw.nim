## task_list — agent-managed plan items.
##
## A TodoWrite-style state primitive: the agent passes the FULL current
## list each call (idempotent set semantics, no partial updates), and
## the framework persists it per session. Two purposes:
##
##   1. **External progress signal** — the agent loop's productive-
##      progress gate (see `loop.nim`) checks "did any todo move to
##      `completed` in the last N iterations?" as one of the inputs
##      to "should I auto-extend the iteration cap or terminate?"
##
##   2. **Plan-derived budget scaling** — the FIRST `task_list` call
##      with N items in a session triggers a budget bump to
##      `max(current, min(N × 8, HardCap))`. Long structured plans
##      announce themselves before consuming their iterations.
##
## Item schema:
##   - `content`: short plan-step description (≤80 chars typical)
##   - `status`: "pending" | "in_progress" | "completed"
##
## The tool stores the list on `AgentLoop.taskLists[sessionKey]`. It
## does NOT auto-emit visibility — the agent decides when/how to
## surface the list to the user (typically via reply_progress with
## a markdown rendering, or as a follow-up Feishu interactive card
## with checkmark icons; both are out-of-scope for this tool).

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

  TaskListTool* = ref object of ContextualTool
    lists*: Table[string, seq[TaskItem]]
      ## Per-session current list. Replaced wholesale on each tool
      ## call (TodoWrite-style — agent sends the full state).
    completionTimestamps*: Table[string, seq[(int, float)]]
      ## Per-session log of (item_index, ts_completed) pairs. Used by
      ## the productive-progress gate in loop.nim to detect "did any
      ## todo finish recently?" without reconstructing diffs.

proc newTaskListTool*(): TaskListTool =
  TaskListTool(
    lists: initTable[string, seq[TaskItem]](),
    completionTimestamps: initTable[string, seq[(int, float)]]()
  )

proc parseStatus(s: string): Option[TaskItemStatus] =
  case s.toLowerAscii.strip
  of "pending": some(tisPending)
  of "in_progress", "in-progress", "inprogress": some(tisInProgress)
  of "completed", "done": some(tisCompleted)
  else: none(TaskItemStatus)

method name*(t: TaskListTool): string = "task_list"

method description*(t: TaskListTool): string =
  "Maintain your task list for the current session — a TodoWrite-style state primitive. Pass the FULL current list each call (the framework replaces; no partial updates). Each item has `content` (short plan-step description) and `status` (`pending` | `in_progress` | `completed`). Use this AT THE START of any analytical task with ≥3 steps so the framework can: (1) scale your iteration budget to `min(N × 8, 150)` based on item count, and (2) check recent todo completions when deciding whether to auto-extend the budget at 80% utilization. Mark items in_progress when you start them; mark completed when done. Calls return the current authoritative list back as JSON, plus the framework's iteration-budget decision."

method parameters*(t: TaskListTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "items": {
        "type": "array",
        "description": "The full current list of plan items, in order. Framework replaces the prior list with this one.",
        "items": {
          "type": "object",
          "properties": {
            "content": {
              "type": "string",
              "description": "Short description of this plan step (e.g. 'Load 2025 training data'). Keep ≤80 chars."
            },
            "status": {
              "type": "string",
              "enum": ["pending", "in_progress", "completed"],
              "description": "Current state of this item."
            }
          },
          "required": ["content", "status"]
        }
      }
    },
    "required": %["items"]
  }.toTable

method execute*(t: TaskListTool, args: Table[string, JsonNode]):
                Future[string] {.async.} =
  if not args.hasKey("items"):
    return "Error: items array is required"
  let arr = args["items"]
  if arr.kind != JArray:
    return "Error: items must be an array"

  # Parse the new list
  var newItems: seq[TaskItem]
  for v in arr:
    if v.kind != JObject:
      return "Error: each item must be an object with content + status"
    let content = v.getOrDefault("content").getStr().strip()
    let statusStr = v.getOrDefault("status").getStr().strip()
    if content.len == 0:
      return "Error: each item's content must be non-empty"
    let statusOpt = parseStatus(statusStr)
    if statusOpt.isNone:
      return "Error: status must be one of pending|in_progress|completed, got: " & statusStr
    newItems.add(TaskItem(content: content, status: statusOpt.get))

  let key = if t.sessionKey.len > 0: t.sessionKey else: "_default"

  # Detect newly-completed items vs the prior list — log timestamps for
  # the productive-progress gate.
  let prior = t.lists.getOrDefault(key, @[])
  var newlyCompletedCount = 0
  for i, ni in newItems:
    if ni.status == tisCompleted:
      let wasCompletedBefore =
        i < prior.len and prior[i].status == tisCompleted
      if not wasCompletedBefore:
        newlyCompletedCount.inc
        # Timestamp recorded as iteration-relative is hard from here;
        # use a simple monotonic float (unix epoch) and let the loop
        # gate compare to its own clock.
        let nowF = epochTime()
        if not t.completionTimestamps.hasKey(key):
          t.completionTimestamps[key] = @[]
        t.completionTimestamps[key].add((i, nowF))

  t.lists[key] = newItems

  # Render a compact JSON of the resulting list back to the LLM so it
  # has an authoritative view of state. The loop.nim layer reads
  # `lists[key]` directly for budget calculations; this return value
  # is just for the agent's own context.
  var resp = %*{
    "ok": true,
    "items": [],
    "newly_completed": newlyCompletedCount
  }
  for i, item in newItems:
    resp["items"].add(%*{
      "i": i,
      "content": item.content,
      "status": $item.status
    })
  return $resp
