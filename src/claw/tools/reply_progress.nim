## reply_progress — checkpoint communication tool for long-running tasks.
##
## Same delivery primitive as `reply`, semantically distinct. Used by agents
## doing analytical / multi-step work to send progress updates BETWEEN tool
## clusters, so the user knows what's happening rather than staring at
## "agent typing..." for minutes.
##
## Why a separate tool from `reply`:
##
##   - Different LLM intent: the docstring nudges the agent to use this for
##     "status during a task" vs `reply` for "the final answer". Without this
##     distinction, agents tend to either send 0 progress messages (single
##     final reply) or send too many (treating every thought as worth
##     sharing).
##
##   - Different log routing: tool calls show up in JSONL with their tool
##     name, so debugging filters can distinguish "checkpoint" from
##     "answer" without parsing content.
##
##   - Different display affordance: a small "📊" marker is prepended so
##     the user can visually distinguish progress from a final answer.
##
## Conscious non-departure from `reply`: this tool does NOT use a streaming
## flag on `stream_intermediary`. That feature dumps the LLM's between-tool
## narration to chat unconditionally, which is noisy. The agent's
## reply_progress calls are CHOSEN checkpoints, not raw narration. Keeps
## the user-facing channel professional; raw narration stays in JSONL logs
## for debugging.

import std/[asyncdispatch, json, tables, strutils]
import types

type
  ReplyProgressTool* = ref object of ContextualTool
    sendCallback*: types.SendCallback

proc newReplyProgressTool*(): ReplyProgressTool =
  ReplyProgressTool()

proc setSendCallback*(t: ReplyProgressTool, callback: types.SendCallback) =
  t.sendCallback = callback

method name*(t: ReplyProgressTool): string = "reply_progress"

method description*(t: ReplyProgressTool): string =
  "Send a checkpoint update during a long-running task. Use this BETWEEN tool clusters to keep the user informed of progress — e.g. \"Step 1 done: loaded 35K rows, 9.6% have negative prices. Now computing regime statistics.\" Distinct from `reply` (which is for the final answer): use reply_progress for in-flight status, use reply for the conclusive answer at the end. Markdown formatting is supported. The user sees these as small status messages in the chat."

method parameters*(t: ReplyProgressTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "content": {
        "type": "string",
        "description": "The checkpoint update text. 1-3 sentences ideal. Should report what was done and what's next, with concrete numbers/findings. Markdown supported."
      },
      "format": {
        "type": "string",
        "description": "Message format: 'text' (default) or 'markdown'. Use markdown for tables / structured findings."
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

  try:
    await t.sendCallback(t.channel, t.chatID, content, t.agentName,
                          t.replyToMessageID, t.appID, metadata)
    return "Progress update sent successfully"
  except Exception as e:
    return "Error sending progress update: " & e.msg
