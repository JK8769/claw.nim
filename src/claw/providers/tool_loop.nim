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

import std/strutils
import types as providers_types

proc isXmlToolProvider*(model: string): bool {.inline.} =
  ## Providers that need XML tool calling instead of native tools.
  ## Lives here so both the main agent loop and the subagent runner
  ## share one definition (any future provider added must update one
  ## place, not two).
  model.startsWith("opencode/") or model.startsWith("opencode-go/")

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
                         iteration: int = 0,
                         maxLen = 80): string {.inline.} =
  ## Stable shape for the tool-iteration log: `[N] name → preview`.
  ## Both agent loops (main + subagent) call it so log lines are
  ## visually identical regardless of which loop produced them.
  ## `maxLen` lets the main loop keep its longer preview (it feeds
  ## into the forced-summary context) while subagents stay terse.
  let prefix = if iteration > 0: "[" & $iteration & "] " else: ""
  prefix & tc.name & " → " & formatToolPreview(resultText, maxLen)

proc formatToolLogEntry*(name: string,
                         resultText: string,
                         iteration: int = 0,
                         maxLen = 80): string {.inline.} =
  ## Overload for callers that don't have a `ToolCall` (e.g. the XML
  ## branch, where calls are parsed into a different struct).
  let prefix = if iteration > 0: "[" & $iteration & "] " else: ""
  prefix & name & " → " & formatToolPreview(resultText, maxLen)
