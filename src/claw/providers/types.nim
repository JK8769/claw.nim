import std/[tables, json, asyncdispatch]

type
  ToolFunctionCall* = object
    name*: string
    arguments*: string

  ToolCall* = object
    id*: string
    `type`*: string
    function*: ToolFunctionCall
    name*: string
    arguments*: Table[string, JsonNode]

  UsageInfo* = object
    prompt_tokens*: int
    completion_tokens*: int
    total_tokens*: int

  LLMResponse* = object
    content*: string
    reasoning_content*: string
    tool_calls*: seq[ToolCall]
    finish_reason*: string
    usage*: UsageInfo

  Message* = object
    role*: string
    content*: string
    reasoning_content*: string
    tool_calls*: seq[ToolCall]
    tool_call_id*: string
    name*: string

  ToolFunctionDefinition* = object
    name*: string
    description*: string
    parameters*: JsonNode

  ToolDefinition* = object
    `type`*: string
    function*: ToolFunctionDefinition

  LLMProvider* = ref object of RootObj

method chat*(p: LLMProvider, messages: seq[Message], tools: seq[ToolDefinition], model: string, options: Table[string, JsonNode]): Future[LLMResponse] {.base, async.} =
  discard

method getDefaultModel*(p: LLMProvider): string {.base.} =
  return ""

# ── Role constants and semantic predicates ───────────────────────────
# Centralise the canonical role string values so a typo (`"asistant"`)
# becomes a compile error, and a future rename catches every site in
# one pass. Wire format stays string — the protocol is stringly-typed,
# these are just one-source-of-truth constants for its values.
const
  RoleSystem*    = "system"
  RoleUser*      = "user"
  RoleAssistant* = "assistant"
  RoleTool*      = "tool"

# Semantic predicates — answer "what KIND of message is this?"
# instead of hand-rolling `m.role == "..."` everywhere. Same wire
# representation, cleaner reads at the call site, and any future
# semantic refinement (e.g. "is this a final-answer assistant turn?")
# lives in one place.
proc isSystem*(m: Message): bool {.inline.} = m.role == RoleSystem
proc isUser*(m: Message): bool {.inline.} = m.role == RoleUser
proc isAssistant*(m: Message): bool {.inline.} = m.role == RoleAssistant
proc isTool*(m: Message): bool {.inline.} = m.role == RoleTool

proc hasToolCalls*(m: Message): bool {.inline.} =
  ## True iff this is an assistant message with at least one tool
  ## call. Only assistants are supposed to emit tool_calls in the
  ## OpenAI/DeepSeek protocol; binding both checks together stops
  ## any caller from accidentally treating a non-assistant message
  ## with stray tool_calls (legacy serialisation, etc.) as one.
  m.isAssistant and m.tool_calls.len > 0
