import std/[asyncdispatch, json, tables, strutils]
import types

type
  ReplyTool* = ref object of ContextualTool
    sendCallback*: types.SendCallback
    guardRetryCount*: Table[string, int]
      ## Per-session count of how many times a Feishu-channel reply
      ## was rejected by the format guards (markdown table rows, line
      ## count). After GuardMaxRetries, the reply is let through with
      ## a discipline-violation prefix so the user still gets an
      ## answer rather than the model spinning. Increments on
      ## rejection; resets on a successful send.

proc newReplyTool*(): ReplyTool =
  ReplyTool(guardRetryCount: initTable[string, int]())

proc setSendCallback*(t: ReplyTool, callback: types.SendCallback) =
  t.sendCallback = callback

# ── Feishu format guards ───────────────────────────────────────────
#
# Channel-aware pre-flight: when the agent calls `reply` on Feishu
# with content that should structurally have been a Lark Sheet
# (>=6 row markdown table) or a Lark Doc (>300 lines), the tool
# returns an error pointing the agent at the right format. This is
# framework-level enforcement of the discipline that prompt rules
# alone empirically did not internalize: rules say "use sheets for
# tabular >5 rows", model defaults to inline markdown anyway, guard
# blocks and forces a retry.

const
  GuardTableRowThreshold* = 6
    ## Reject Feishu replies whose total markdown table data-row
    ## count meets or exceeds this. Aligned with the technical-
    ## communication handbook's `>5 rows → sheet` MUST-rule.
  GuardLineThreshold* = 300
    ## Reject Feishu replies whose line count exceeds this. Aligned
    ## with the feishu-rich-format SKILL.md's `>300 lines → Doc` rule.
  GuardMaxRetries* = 2
    ## After this many guard-rejections in a row for the same
    ## session, let the reply through with a discipline-violation
    ## prefix. Stops the model from spinning when it cannot or will
    ## not switch format; the user still gets an answer, the
    ## violation is logged.

proc countMarkdownTableDataRows(content: string): int =
  ## Counts data rows across all markdown tables in `content`. A
  ## "data row" is a `|`-delimited line that is neither a header nor
  ## a `|---|---|`-style separator. Heuristic: pipe_lines - 2*sep_lines
  ## (one header + one separator per table), clamped at 0. Robust
  ## enough for the malformed tables LLMs sometimes emit; off by ±1
  ## for tables without separators (rare in agent output).
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

method name*(t: ReplyTool): string = "reply"
method description*(t: ReplyTool): string = "Send the FINAL answer for the current task to the user. For long tasks: a synthesis (TL;DR + key findings + decisions) plus three explicit numbered next-step options. On Feishu specifically: do NOT include file paths, bash commands, or full terminal output that the framework auto-emitted earlier in this turn — operators have already seen those. Focus the reply on what the work MEANS and what to do next. For short tasks: a direct answer is fine. NOT for in-flight progress (use `reply_progress` for that)."
method parameters*(t: ReplyTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "content": {
        "type": "string",
        "description": "The message content to send"
      },
      "message": {
        "type": "string",
        "description": "Alias of content (backwards compatibility). Prefer using content."
      },
      "format": {
        "type": "string",
        "description": "Message format: 'text' (default) or 'markdown' for rich formatting. Channels that support markdown will render it natively."
      },
      "image": {
        "type": "string",
        "description": "Send an image. Accepts a local file path or an image_key from a previous API call."
      },
      "file": {
        "type": "string",
        "description": "Send a file. Accepts a local file path or a file_key from a previous API call."
      },
      "reply_in_thread": {
        "type": "boolean",
        "description": "Reply in thread instead of main chat (supported on Feishu)."
      },
      "msg_type": {
        "type": "string",
        "description": "Feishu-only. Use 'interactive' to send a CardKit message."
      },
      "card": {
        "type": "object",
        "description": "Feishu-only. CardKit card JSON object. If provided with msg_type='interactive', sends an interactive card."
      },
      "feishu_card": {
        "type": "object",
        "description": "Feishu-only. CardKit card JSON object. Prefer using this for interactive cards."
      }
    },
    "required": %[]
  }.toTable

method execute*(t: ReplyTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sessionKey.startsWith("system:"):
    return "Error: Communication tools are disabled for background tasks. Please keep your response internal."

  var content = ""
  var metadata = initTable[string, string]()

  # Handle image/file media messages
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
  # Handle Feishu interactive cards
  elif args.hasKey("feishu_card") or (args.getOrDefault("msg_type").getStr("") == "interactive" and args.hasKey("card")):
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

  # Set format metadata
  let format = args.getOrDefault("format").getStr("text")
  if format == "markdown":
    metadata["format"] = "markdown"

  # Set reply-in-thread metadata
  if args.hasKey("reply_in_thread") and args["reply_in_thread"].getBool(false):
    metadata["reply_in_thread"] = "true"

  if t.channel == "" or t.chatID == "":
    return "Error: No active chat context found for reply"

  if t.sendCallback == nil:
    return "Error: Reply callback not configured"

  # Feishu format guards. Skip for cards/images/files (those have
  # already chosen a structured format). Run only on plain content
  # for the feishu channel. After GuardMaxRetries rejections in a
  # row, let the reply through with a violation prefix so the user
  # still gets an answer and the loop unblocks.
  let isPlainTextReply = not (args.hasKey("image") or args.hasKey("file") or
                               args.hasKey("feishu_card") or
                               (args.getOrDefault("msg_type").getStr("") == "interactive" and args.hasKey("card")))
  if t.channel == "feishu" and isPlainTextReply and content.len > 0:
    let curRetries = t.guardRetryCount.getOrDefault(t.sessionKey, 0)
    if curRetries < GuardMaxRetries:
      let rows = countMarkdownTableDataRows(content)
      let lines = countLines(content)
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
          "of the data. See the inlined `feishu_rich_format` recipe " &
          "(Pattern 2: Sheet append) in your prompt for the canonical " &
          "shape."
      elif lines > GuardLineThreshold:
        rejection = "Reply rejected by Feishu format guard: content is " &
          $lines & " lines (threshold: " & $GuardLineThreshold & "). On " &
          "Feishu, prose content this long MUST be delivered as a Lark " &
          "Doc, not inline — operators lose the chat scrollback. Steps: " &
          "(1) call `lark docs +create --title \"...\" --markdown <body>` " &
          "to get a doc URL, (2) call `reply` with the doc URL + a " &
          "3-bullet TL;DR. See `feishu_rich_format` Pattern 1 (Doc " &
          "handoff) in your prompt."
      if rejection.len > 0:
        t.guardRetryCount[t.sessionKey] = curRetries + 1
        return rejection
    # else: max retries reached — fall through to send with prefix
  let outboundContent =
    if t.channel == "feishu" and isPlainTextReply and
       t.guardRetryCount.getOrDefault(t.sessionKey, 0) >= GuardMaxRetries:
      "[discipline violation: format guards failed after " &
      $GuardMaxRetries & " retries — content sent as-is]\n\n" & content
    else:
      content

  try:
    await t.sendCallback(t.channel, t.chatID, outboundContent, t.agentName, t.replyToMessageID, t.appID, metadata)
    # Successful send → reset guard retry counter for this session.
    t.guardRetryCount[t.sessionKey] = 0
    return "Reply sent successfully to " & t.channel & ":" & t.chatID
  except Exception as e:
    return "Error sending reply: " & e.msg
