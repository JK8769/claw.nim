## Shared tool-execution helpers for any agent-style loop that
## consumes `LLMResponse.tool_calls`, runs them, and appends results.
##
## Why this lives here (not in agent/loop.nim or tools/subagent.nim):
## both files do almost the same thing once they get tool_calls back —
## execute each via the tool registry, append a `role: tool` message
## with the matching `tool_call_id`, and log a one-line preview.
## Putting that in one place means a future protocol fix (e.g. how
## tool errors get encoded into the result message, or how attachments
## propagate) lands in ONE site and both loops inherit it
## automatically.
##
## What this DOESN'T share (intentionally): per-loop UX concerns —
## loop detection, permission gating, session persistence,
## streaming, retry-on-empty-name, forced summary on cap. Those live
## in their respective loops because they're agent-loop UX features,
## not protocol mechanics.

import std/[asyncdispatch, tables]
import types as providers_types
import ../tools/registry as tools_registry
import ../tools/base as tools_base

proc formatToolPreview*(s: string, maxLen = 80): string =
  ## One-line preview of a tool result for the iteration log. Stable
  ## format so logs remain greppable across the codebase.
  if s.len > maxLen: s[0 ..< maxLen] & "..."
  else: s

proc makeToolResult*(tc: providers_types.ToolCall,
                     content: string): providers_types.Message {.inline.} =
  ## Build a properly-formed `role: tool` message that responds to
  ## an assistant's tool_call. Uses the canonical `RoleTool` constant
  ## and binds `tool_call_id` + `name` so the protocol pairing is
  ## structurally complete — no risk of a call site forgetting one
  ## of the fields, which would silently break the strict pairing
  ## rule and surface as a 400.
  ##
  ## Callers that ALSO need to persist or otherwise reference the
  ## constructed message use this and then append/save themselves;
  ## callers that just want fire-and-forget use the higher-level
  ## `executeAndAppendToolResults` below.
  providers_types.Message(
    role: RoleTool,
    content: content,
    tool_call_id: tc.id,
    name: tc.name)

proc appendToolResult*(messages: var seq[providers_types.Message],
                       tc: providers_types.ToolCall,
                       content: string) {.inline.} =
  ## Convenience wrapper for `makeToolResult` + append.
  messages.add(makeToolResult(tc, content))

proc formatToolLogEntry*(tc: providers_types.ToolCall,
                         resultText: string,
                         iteration: int = 0): string {.inline.} =
  ## Stable shape for the tool-iteration log: `[N] name → preview`.
  ## Both agent loops (main + subagent) call it so log lines are
  ## visually identical regardless of which loop produced them.
  let prefix = if iteration > 0: "[" & $iteration & "] " else: ""
  prefix & tc.name & " → " & formatToolPreview(resultText)

# Note: there's no shared `executeAndAppendToolResults` proc.
# Nim's async-closure rules don't allow safely capturing a
# `var seq[Message]` across an `await`. Each caller writes its own
# 3-line loop using `makeToolResult` + `formatToolLogEntry`. The
# real shared piece is the message construction (which is the
# protocol-correctness piece); the loop body is just iteration.
