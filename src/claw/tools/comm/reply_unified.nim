## reply — unified output tool for current-partner communication.
##
## Replaces two split tools: reply, reply_progress.
##
## Actions:
##
##   final     — Terminal reply for the turn. Carries Feishu format
##               guards (markdown table row threshold, line threshold,
##               trailing-numbered-options auto-promotion to CardKit
##               interactive cards, retry-counter discipline). This is
##               what the agent calls when answering; channel adapters
##               see this as the canonical "answer" message.
##
##   progress  — Interim status checkpoint during a long task. Carries
##               the plan-state surface (`items[]` with per-step
##               status). Framework reads items each call to (1) scale
##               iteration budget, (2) detect productive completions
##               for the 80% auto-extend gate. Skips the Feishu guards
##               (progress updates are short by definition).
##
## Status enum (the say-do gap fix):
##
##   pending        — not started
##   in_progress    — started, not done
##   claimed_done   — agent believes it's done; no proof yet
##   verified_done  — post-condition checked; verification field required
##
## verified_done items REQUIRE a non-empty `verification` field. The
## tool rejects them otherwise and tells the agent to either provide
## evidence or use claimed_done. This forces the agent to articulate
## what proves the post-condition holds — closes the say-do gap on
## the self-claimed-completion surface.
##
## Default action: if missing, treated as "final" (sensible default,
## not a back-compat hack — most calls are final replies).

import std/[asyncdispatch, json, tables, strutils, options, parseutils,
            sequtils, algorithm, times]
import ../types
import ../spec

const ToolSpec* = spec(
  name = "reply",
  description = "send a message to current conversation partner (action=final|progress; verified_done items require verification field)",
  tags = @["messaging", "core"],
  domain = "comm",
  default = true,
  heartbeatSafe = true,
  category = "comm",
)

# ── Feishu format guards (preserved verbatim from the old reply tool) ──

const
  GuardTableRowThreshold* = 6
    ## Reject Feishu replies whose total markdown table data-row
    ## count meets or exceeds this. Aligned with technical-
    ## communication's `>5 rows → sheet` MUST-rule.
  GuardLineThreshold* = 300
    ## Reject Feishu replies whose line count exceeds this. Aligned
    ## with feishu-rich-format SKILL.md's `>300 lines → Doc` rule.
  GuardMaxRetries* = 2
    ## After this many guard-rejections in a row for the same
    ## session, let the reply through with a discipline-violation
    ## prefix. Stops the model from spinning.

# ── Status enum + TaskItem ───────────────────────────────────────

type
  TaskItemStatus* = enum
    tisPending = "pending"
    tisInProgress = "in_progress"
    tisClaimedDone = "claimed_done"
    tisVerifiedDone = "verified_done"

  TaskItem* = object
    content*: string
    status*: TaskItemStatus
    verification*: string  ## Required when status=verified_done

  ReplyTool* = ref object of ContextualTool
    sendCallback*: types.SendCallback
    guardRetryCount*: Table[string, int]
      ## Per-session count of Feishu format-guard rejections.
      ## Increments on rejection; resets on a successful send.
    items*: Table[string, seq[TaskItem]]
      ## Per-session current plan list. Replaced wholesale on each
      ## `progress` call that includes `items`. TodoWrite-style.
    completionTimestamps*: Table[string, seq[(int, float)]]
      ## Per-session log of (item_index, ts_completed) pairs for the
      ## productive-progress auto-extend gate. Logs both
      ## claimed_done and verified_done as "completion."

proc newReplyTool*(): ReplyTool =
  ReplyTool(
    guardRetryCount: initTable[string, int](),
    items: initTable[string, seq[TaskItem]](),
    completionTimestamps: initTable[string, seq[(int, float)]]()
  )

proc setSendCallback*(t: ReplyTool, callback: types.SendCallback) =
  t.sendCallback = callback

proc parseStatus(s: string): Option[TaskItemStatus] =
  case s.toLowerAscii.strip
  of "pending": some(tisPending)
  of "in_progress", "in-progress", "inprogress": some(tisInProgress)
  of "claimed_done", "claimed-done": some(tisClaimedDone)
  of "verified_done", "verified-done": some(tisVerifiedDone)
  # back-compat for the old 3-status enum: accept 'completed' as
  # claimed_done (the safer assumption — completion without
  # verification reads as a claim, not proof)
  of "completed", "done": some(tisClaimedDone)
  else: none(TaskItemStatus)

proc isCompleted*(s: TaskItemStatus): bool {.inline.} =
  s == tisClaimedDone or s == tisVerifiedDone

# ── Markdown table guard helpers ─────────────────────────────────

proc countMarkdownTableDataRows(content: string): int =
  var pipeLines = 0
  var sepLines = 0
  for line in content.splitLines():
    let s = line.strip()
    if not s.startsWith("|"): continue
    pipeLines += 1
    var isSep = true
    for ch in s:
      if ch notin {'|', '-', ':', ' '}:
        isSep = false
        break
    if isSep and s.len >= 3:
      sepLines += 1
  result = max(0, pipeLines - 2 * sepLines)

proc countLines(content: string): int =
  result = 1
  for ch in content:
    if ch == '\n': result.inc

# ── Trailing-numbered-options detection + CardKit promotion ──────

type ExtractedOptions = object
  found: bool
  prefix: string
  options: seq[string]

proc extractTrailingOptions(content: string): ExtractedOptions =
  let lines = content.splitLines()
  result.found = false
  if lines.len < 2: return

  var idx = lines.len - 1
  while idx >= 0 and lines[idx].strip.len == 0: dec idx

  type Collected = tuple[num: int, text: string, lineIdx: int]
  var collected: seq[Collected] = @[]
  while idx >= 0:
    let stripped = lines[idx].strip(leading = true, trailing = false)
    var num: int = 0
    let parsed = parseInt(stripped, num, 0)
    if parsed > 0 and parsed < stripped.len and stripped[parsed] == '.':
      let after = stripped[parsed+1 ..< stripped.len].strip()
      if after.len > 0 and num >= 1 and num <= 9:
        collected.add((num, after, idx))
        dec idx
        continue
    break

  if collected.len < 2 or collected.len > 4:
    return

  collected.reverse
  for i, c in collected:
    if c.num != i + 1: return

  result.found = true
  result.options = collected.mapIt(it.text)
  let firstOptLine = collected[0].lineIdx
  if firstOptLine > 0:
    var prefixLines = lines[0 ..< firstOptLine]
    while prefixLines.len > 0 and prefixLines[^1].strip.len == 0:
      prefixLines.setLen(prefixLines.len - 1)
    result.prefix = prefixLines.join("\n")
  else:
    result.prefix = ""

proc buildOptionsCard(prefix: string, options: seq[string]): string =
  let buttons = newJArray()
  for i, opt in options:
    let label = if opt.len > 28: opt[0 ..< 25] & "..." else: opt
    let btnType =
      if i == 0: "primary"
      elif options.len >= 3 and i == options.len - 1: "danger"
      else: "default"
    buttons.add(%*{
      "tag": "button",
      "text": {"tag": "plain_text", "content": label},
      "type": btnType,
      "value": {"action": opt}
    })

  let elements = newJArray()
  if prefix.strip.len > 0:
    elements.add(%*{"tag": "markdown", "content": prefix})
  elements.add(%*{"tag": "action", "actions": buttons})

  let card = %*{
    "schema": "2.0",
    "body": {"elements": elements}
  }

  return $(%*{
    "nimclaw_feishu": {
      "msg_type": "interactive",
      "card": card
    }
  })

# ── Tool surface ─────────────────────────────────────────────────

method name*(t: ReplyTool): string = "reply"

method description*(t: ReplyTool): string =
  "Send a message to the current conversation partner.\n\n" &
  "Actions:\n" &
  "  final     — terminal reply for the turn. For long tasks: TL;DR + " &
  "key findings + decisions, plus three explicit numbered next-step " &
  "options. Carries Feishu format guards (large tables → Lark Sheet, " &
  "long prose → Lark Doc).\n" &
  "  progress  — interim status checkpoint. Optional `items[]` carries " &
  "your plan with per-step status. Framework reads items to scale " &
  "iteration budget. Pass FULL list each call.\n\n" &
  "Status enum: pending | in_progress | claimed_done | verified_done. " &
  "Use `verified_done` ONLY with a non-empty `verification` field that " &
  "states the evidence (e.g. 'workstation verify_project sais → " &
  "verdict=clean', 'ls src/foo.py → present'). Use `claimed_done` " &
  "when you believe it's done but haven't checked. Don't use the old " &
  "'completed' — it's been split for clarity.\n\n" &
  "Default action is `final` if not specified."

method parameters*(t: ReplyTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["final", "progress"],
        "description": "Operation. final = terminal reply (default if absent). progress = interim status."
      },
      "content": {
        "type": "string",
        "description": "The message text. Markdown supported."
      },
      "message": {
        "type": "string",
        "description": "Alias of content (back-compat). Prefer content."
      },
      "format": {
        "type": "string",
        "description": "Message format: 'text' (default) or 'markdown'."
      },
      "image": {
        "type": "string",
        "description": "final only — image to send (path or image_key)."
      },
      "file": {
        "type": "string",
        "description": "final only — file to send (path or file_key)."
      },
      "reply_in_thread": {
        "type": "boolean",
        "description": "final only — reply in thread (Feishu)."
      },
      "msg_type": {
        "type": "string",
        "description": "final only — Feishu. Use 'interactive' for CardKit."
      },
      "card": {
        "type": "object",
        "description": "final only — Feishu CardKit card JSON."
      },
      "feishu_card": {
        "type": "object",
        "description": "final only — Feishu CardKit (preferred over card)."
      },
      "items": {
        "type": "array",
        "description": "progress only — full current plan list, replaces prior state. Pass at task start; update each call to reflect progress.",
        "items": {
          "type": "object",
          "properties": {
            "content": {"type": "string"},
            "status":  {"type": "string", "enum": ["pending", "in_progress", "claimed_done", "verified_done"]},
            "verification": {
              "type": "string",
              "description": "REQUIRED when status=verified_done. Brief evidence the post-condition holds — e.g. 'workstation verify_project sais → verdict=clean', 'ls src/models/*.py → 3 files'. Self-attested 'I think it's done' is NOT verification — use claimed_done for that."
            }
          },
          "required": ["content", "status"]
        }
      }
    },
    "required": %[]
  }.toTable

# ── action=final ─────────────────────────────────────────────────

proc doFinal(t: ReplyTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sessionKey.startsWith("system:"):
    return "Error: Communication tools are disabled for background tasks. Please keep your response internal."

  var content = ""
  var metadata = initTable[string, string]()

  if args.hasKey("image"):
    metadata["image"] = args["image"].getStr()
    content = if args.hasKey("content"): args["content"].getStr()
              elif args.hasKey("message"): args["message"].getStr()
              else: ""
  elif args.hasKey("file"):
    metadata["file"] = args["file"].getStr()
    content = if args.hasKey("content"): args["content"].getStr()
              elif args.hasKey("message"): args["message"].getStr()
              else: ""
  elif args.hasKey("feishu_card") or
       (args.getOrDefault("msg_type").getStr("") == "interactive" and args.hasKey("card")):
    if t.channel != "feishu":
      return "Error: feishu_card can only be used in Feishu channel"
    let card = if args.hasKey("feishu_card"): args["feishu_card"] else: args["card"]
    if card.kind != JObject:
      return "Error: card must be a JSON object"
    content = $(%*{
      "nimclaw_feishu": {
        "msg_type": "interactive",
        "card": card
      }
    })
  else:
    if args.hasKey("content"):
      content = args["content"].getStr()
    elif args.hasKey("message"):
      content = args["message"].getStr()
    else:
      return "Error: content is required"

  let format = args.getOrDefault("format").getStr("text")
  if format == "markdown":
    metadata["format"] = "markdown"

  if args.hasKey("reply_in_thread") and args["reply_in_thread"].getBool(false):
    metadata["reply_in_thread"] = "true"

  if t.channel == "" or t.chatID == "":
    return "Error: No active chat context found for reply"
  if t.sendCallback == nil:
    return "Error: Reply callback not configured"

  let isPlainTextReply = not (args.hasKey("image") or args.hasKey("file") or
                               args.hasKey("feishu_card") or
                               (args.getOrDefault("msg_type").getStr("") == "interactive" and args.hasKey("card")))

  var extractedOptions: ExtractedOptions
  var bodyForGuards = content
  if t.channel == "feishu" and isPlainTextReply:
    extractedOptions = extractTrailingOptions(content)
    if extractedOptions.found:
      bodyForGuards = extractedOptions.prefix
  if t.channel == "feishu" and isPlainTextReply and bodyForGuards.len > 0:
    let curRetries = t.guardRetryCount.getOrDefault(t.sessionKey, 0)
    if curRetries < GuardMaxRetries:
      let rows = countMarkdownTableDataRows(bodyForGuards)
      let lines = countLines(bodyForGuards)
      var rejection = ""
      if rows >= GuardTableRowThreshold:
        rejection = "Reply rejected by Feishu format guard: detected " &
          $rows & "-row markdown table (threshold: " &
          $GuardTableRowThreshold & "). On Feishu, tabular content of " &
          "this size MUST be delivered as a Lark Sheet, not inline " &
          "markdown — operators cannot sort, filter, or share an inline " &
          "table. Steps: (1) call `lark sheets +create --title \"...\"` " &
          "to get a sheet_id+url, (2) call `lark sheets +append " &
          "--sheet-id <id> --range A1 --values <json>` with the rows, " &
          "(3) call `reply` again with the sheet URL + a 3-bullet TL;DR " &
          "of the data."
      elif lines > GuardLineThreshold:
        rejection = "Reply rejected by Feishu format guard: content is " &
          $lines & " lines (threshold: " & $GuardLineThreshold & "). On " &
          "Feishu, prose content this long MUST be delivered as a Lark " &
          "Doc, not inline — operators lose the chat scrollback. Steps: " &
          "(1) call `lark docs +create --title \"...\" --markdown <body>` " &
          "to get a doc URL, (2) call `reply` with the doc URL + a " &
          "3-bullet TL;DR."
      if rejection.len > 0:
        t.guardRetryCount[t.sessionKey] = curRetries + 1
        return rejection
  var outboundContent =
    if t.channel == "feishu" and isPlainTextReply and
       t.guardRetryCount.getOrDefault(t.sessionKey, 0) >= GuardMaxRetries:
      "[discipline violation: format guards failed after " &
      $GuardMaxRetries & " retries — content sent as-is]\n\n" & content
    else:
      content

  if t.channel == "feishu" and isPlainTextReply and extractedOptions.found:
    outboundContent = buildOptionsCard(extractedOptions.prefix,
                                        extractedOptions.options)
    metadata.del("format")

  try:
    await t.sendCallback(t.channel, t.chatID, outboundContent, t.agentName,
                         t.replyToMessageID, t.appID, metadata)
    t.guardRetryCount[t.sessionKey] = 0
    return "Reply sent successfully to " & t.channel & ":" & t.chatID
  except CatchableError as e:
    return "Error sending reply: " & e.msg

# ── action=progress ──────────────────────────────────────────────

proc doProgress(t: ReplyTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sessionKey.startsWith("system:"):
    return "Error: Communication tools are disabled for background tasks. Please keep your response internal."

  # `content` is optional when `items` are present — items-only updates
  # are valid plan-state nudges that don't need a narrative line. If
  # neither field is provided, refuse: a progress call with no payload
  # is meaningless.
  let hasContent = args.hasKey("content") and args["content"].getStr().len > 0
  let hasItems = args.hasKey("items") and args["items"].kind == JArray and
                 args["items"].len > 0
  if not hasContent and not hasItems:
    return "Error: progress requires either `content` (a narrative " &
           "checkpoint) or `items` (a plan-state update). Pass at " &
           "least one."

  let raw = if hasContent: args["content"].getStr() else: "(plan updated)"
  let content = "📊 " & raw

  var metadata = initTable[string, string]()
  metadata["progress"] = "true"

  let format = args.getOrDefault("format").getStr("text")
  if format == "markdown":
    metadata["format"] = "markdown"

  if t.channel == "" or t.chatID == "":
    return "Error: No active chat context found for progress reply"
  if t.sendCallback == nil:
    return "Error: Reply callback not configured"

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
      let verif = v.getOrDefault("verification").getStr().strip()
      if cText.len == 0:
        return "Error: each item's content must be non-empty"
      let sOpt = parseStatus(sText)
      if sOpt.isNone:
        return "Error: status must be one of pending|in_progress|claimed_done|verified_done, got: " & sText
      # Verification gate — the say-do gap fix on the self-claim surface.
      if sOpt.get == tisVerifiedDone and verif.len == 0:
        return "Error: item '" & cText & "' marked verified_done but " &
               "verification field is empty. What evidence proves the " &
               "post-condition holds? Examples: 'workstation verify_project " &
               "X → verdict=clean', 'ls path → present', 'curl ... → 200'. " &
               "If you don't have proof yet, use claimed_done instead."
      newItems.add(TaskItem(content: cText, status: sOpt.get,
                             verification: verif))

    let key = if t.sessionKey.len > 0: t.sessionKey else: "_default"
    let prior = t.items.getOrDefault(key, @[])
    for i, ni in newItems:
      if ni.status.isCompleted:
        let wasCompletedBefore =
          i < prior.len and prior[i].status.isCompleted
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
  except CatchableError as e:
    return "Error sending progress update: " & e.msg

# ── dispatch ─────────────────────────────────────────────────────

method execute*(t: ReplyTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let action =
    if args.hasKey("action"): args["action"].getStr().strip().toLowerAscii
    else: "final"
  case action
  of "final":    return await doFinal(t, args)
  of "progress": return await doProgress(t, args)
  else:
    return "Error: Unknown action '" & action & "'. Use: final | progress"
