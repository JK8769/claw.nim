## Provider-protocol sanitisation for message lists.
##
## OpenAI / DeepSeek / most chat APIs enforce strict pairing rules:
##   - assistant.tool_calls must be immediately followed by `tool` messages,
##     one per tool_call_id, in order.
##   - `tool` messages without a preceding assistant.tool_calls are orphans.
##
## When either rule is violated, the API rejects with
##   400 "An assistant message with 'tool_calls' must be followed by tool
##        messages responding to each tool_call_id"
##   400 "tool message must be a response to a tool call"
##
## Causes of drift in practice:
##   - Legacy session entries that stored tool results as `role: "user"`
##   - Gateway crash mid-tool-execution
##   - A tool throws and the loop bails before adding the tool result
##   - A nudge / system message gets interleaved between assistant.tool_calls
##     and its tool responses
##
## Lives here (not in `agent/loop.nim`) so both the main agent loop and
## subagent — and any future hand-built message list — can call it
## without circular imports.

import std/[sets, tables]
import types as providers_types
import ../logger

proc sanitizeForProvider*(messages: var seq[providers_types.Message]) =
  ## Strict pairing enforcement. Mutates `messages` in place.
  ##
  ## Two passes folded into one walk:
  ##  1. Drop `tool` messages that aren't part of a valid tool-response run.
  ##  2. Strip `tool_calls` from assistant messages whose responses are
  ##     missing or short. Empty content gets a placeholder so the
  ##     resulting message isn't both content-empty AND tool-empty.
  var clean: seq[providers_types.Message] = @[]
  var droppedOrphans = 0
  var strippedTcs = 0
  # `lastHadToolCalls` reflects whether the most recent NON-tool
  # message in `clean` was an assistant with tool_calls. Tool messages
  # don't reset the flag — siblings in a multi-tool turn share the
  # same parent context.
  var lastHadToolCalls = false
  var i = 0
  while i < messages.len:
    var m = messages[i]
    if m.isTool:
      if not lastHadToolCalls:
        inc droppedOrphans
        inc i
        continue
      clean.add(m)
      inc i
      continue   # flag intentionally NOT updated
    # Below: m is NOT a tool message.
    if m.hasToolCalls:
      var expected = initHashSet[string]()
      for tc in m.tool_calls:
        if tc.id.len > 0: expected.incl(tc.id)
      var responded = initHashSet[string]()
      var followingTools = 0
      var j = i + 1
      while j < messages.len and messages[j].isTool:
        inc followingTools
        if messages[j].tool_call_id.len > 0:
          responded.incl(messages[j].tool_call_id)
        inc j
      var allCovered = followingTools >= m.tool_calls.len
      if allCovered:
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
    lastHadToolCalls = m.hasToolCalls
    inc i
  if droppedOrphans > 0 or strippedTcs > 0:
    warnCF("agent", "Sanitized history",
           {"orphan_tools_dropped": $droppedOrphans,
            "incomplete_tool_calls_stripped": $strippedTcs}.toTable)
    messages = clean
