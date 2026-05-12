## collaborate — multi-agent orchestration (the navigator) of the
## social/delegate/collaborate trio.
##
##   social     — the WORLD GRAPH (the sea): who exists, what they know,
##                trust + identifiers + roles. Read/write the relationship
##                map.
##   delegate   — peer task HANDOFF (the ship): hand ONE task to ONE peer
##                synchronously (or defer to her todo queue). Returns her
##                reply.
##   collaborate — multi-agent ORCHESTRATION (the navigator): chart a
##                course across MULTIPLE delegates toward a single goal.
##                Same recursion as `capability action=invoke` over LLM
##                models: a single tool call coordinates many specialist
##                calls under the hood.
##
## Two actions in this draft (Phase A+B):
##
##   action=fan_out  — dispatch the SAME task to N agents in parallel.
##                     Returns one structured envelope with each agent's
##                     reply (or a [TIMEOUT] marker for any that didn't
##                     return inside the timeout window). Use to gather
##                     diverse perspectives, run parallel research, or
##                     compare answers across specialists before deciding.
##
##   action=pipeline — sequential A → B → C: each stage receives the prior
##                     stage's output as context plus the original task,
##                     and returns its own output. Returns the final stage's
##                     output plus an audit trail summarizing each stage.
##                     Use for "draft → critique → polish" or "research →
##                     analysis → presentation" chains where each agent
##                     specializes in a step.
##
## Both actions go through the SAME `askPeer` callback that `delegate`
## uses — so peer agents run their full processDirect path (own tools,
## own session, own trust gate). collaborate is a thin coordinator: it
## launches delegate-shaped calls and aggregates the results. No new
## agent-loop-internal state, no new IAM gate, no parallel session
## machinery.
##
## TODOs left for v2 (deliberately out of scope here):
##
##   • action=consensus — fan_out + a follow-up "decide" call that asks
##                        a designated arbiter (or the calling agent's
##                        own model) to reconcile divergent replies. The
##                        skeleton is fan_out + one extra `askPeer`; the
##                        hard part is prompt engineering for the arbiter
##                        and policy on tie-breaks.
##   • action=route     — pick THE ONE best agent for a task based on
##                        skills/role match and dispatch to only that one.
##                        Same primitive as `capability action=route` but
##                        over agents instead of models. Useful when the
##                        caller doesn't know who to delegate to and would
##                        otherwise have to call `social action=query`
##                        first to read the team graph.
##   • Error-recovery semantics — pipeline currently aborts on first
##                        failure. v2 should support `on_error="skip"`
##                        (continue with prior output as input to the next
##                        stage), `on_error="retry_once"` (retry the
##                        failing stage with a fresh future), and
##                        `on_error="ask_caller"` (return a structured
##                        error and let the LLM decide whether to retry,
##                        skip, or restart).
##   • Stage-specific timeouts in pipeline (some stages legitimately
##                        take longer than others). Currently one global
##                        timeout per agent.
##   • fan_out result reduction — currently always returns the full
##                        per-agent envelope. v2 could accept an optional
##                        `reduce_prompt` that fan-outs to peers AND then
##                        invokes the caller's own model on the gathered
##                        replies to produce a summary. For now the
##                        caller does that themselves with a follow-up
##                        prompt — explicit and easy to inspect.
##
## ---------------------------------------------------------------------------
## Registration changes for src/claw/agent/loop.nim
## ---------------------------------------------------------------------------
##
## Add to the imports block (line ~23, sibling of the comm/* import line):
##
##   import ../tools/collaborate_unified
##
## Add immediately AFTER the `newDelegateTool` registration (line ~2956):
##
##   regTagged(newCollaborateTool(workspace, cfg.agents.named, askPeer = askPeer),
##             ["agent", "delegation", "orchestration", "core"],
##             "fan out parallel pipeline orchestrate multiple agents collaborate")
##
## Add to tools/registry/manifest.nim (in the "Communication (unified)" block,
## right after the `delegate` spec):
##
##   spec(name = "collaborate",
##        description = "multi-agent orchestration (action=fan_out|pipeline). " &
##                      "fan_out: same task to N agents in parallel; pipeline: " &
##                      "sequential A→B→C with each stage seeing the prior output. " &
##                      "Goes through the delegate primitive — peers run their " &
##                      "own tools and trust gate.",
##        tags = @["agent", "delegation", "orchestration", "core"],
##        searchKeywords = @["fan-out", "fanout", "parallel", "pipeline",
##                            "orchestrate", "coordinate", "multi-agent",
##                            "broadcast", "chain", "sequential", "all agents",
##                            "ensemble", "scatter-gather", "navigator"],
##        domain = "comm",
##        default = true, heartbeatSafe = false, category = "comm"),

import std/[json, tables, strutils, options, asyncdispatch, strformat]
import ./types
import ./spec
import ../config
import ./comm/delegate as delegate_tool

const ToolSpec* = spec(
  name = "collaborate",
  description = "Multi-agent orchestration — fan a task out to N peers in " &
                "parallel, or pipeline through them sequentially. Each step " &
                "uses the delegate primitive under the hood.",
  tags = @["agent", "delegation", "orchestration", "core"],
  searchKeywords = @["fan-out", "fanout", "parallel", "pipeline",
                      "orchestrate", "coordinate", "multi-agent",
                      "broadcast", "chain", "sequential", "all agents",
                      "ensemble", "scatter-gather", "navigator"],
  domain = "comm",
  default = true,
  heartbeatSafe = false,  # makes N parallel LLM calls — never on the heartbeat
                          # hot path. Mirrors how `capability action=invoke` is
                          # heartbeat-unsafe even though `has`/`route` aren't.
  externalAllowed = false,  # internal coordination tool. External callers
                             # going through `delegate` already cap at depth=1
                             # via the depth gate; collaborate would amplify
                             # an external request into N peer calls, which
                             # is not a behaviour we want guests to trigger.
                             # Internal staff and peer agents only.
  category = "comm",
)

const
  DefaultTimeoutSeconds = 60
    ## Per-agent timeout. Aligns with delegate's natural "answer in one
    ## LLM round-trip" expectation. A peer doing real work (fetching
    ## from sungrow, traversing a graph) might run 20–30s; 60s leaves
    ## headroom without letting a hung peer stall the whole orchestration.
  MaxTimeoutSeconds = 600
    ## Hard cap. 10 minutes is well past any reasonable single-task
    ## delegation; beyond this the right pattern is `delegate deferred=true`,
    ## not blocking the caller's loop.
  MaxAgentsPerCall = 12
    ## Soft cap to keep the response envelope readable AND to bound the
    ## blast radius if an LLM hallucinates a long agent list. A team of
    ## 12 specialists in parallel is plausibly the upper end of "useful";
    ## beyond that the caller should think harder about routing.

type
  CollaborateTool* = ref object of ContextualTool
    workspace*: string
    agents*: seq[NamedAgentConfig]
    askPeer*: delegate_tool.AskPeer

proc newCollaborateTool*(workspace: string,
                         agents: seq[NamedAgentConfig] = @[],
                         askPeer: delegate_tool.AskPeer = nil): CollaborateTool =
  ## Same essential dependency surface as DelegateTool: workspace (for
  ## per-agent office resolution if we ever need it for deferred fallback)
  ## + the declared peer list (for name validation + role lookup in the
  ## response envelope) + the askPeer callback (the actual peer-invocation
  ## RPC). No fallbackApiKey — if askPeer is nil we refuse to act rather
  ## than spinning up an apiKey-based fallback path; collaborate's whole
  ## point is orchestrating REAL peer agents, not impersonating them.
  CollaborateTool(workspace: workspace, agents: agents, askPeer: askPeer)

method name*(t: CollaborateTool): string = "collaborate"

method description*(t: CollaborateTool): string =
  ## Like delegate's description, enumerate available peers so the LLM
  ## picks real names — not skill names or hallucinations. Same role
  ## + skills hints so the LLM has the context to compose a good agent
  ## list.
  var lines: seq[string] = @[
    "Multi-agent orchestration — the navigator of the social/delegate/" &
    "collaborate trio. Fan a task out to N agents in parallel, or pipeline " &
    "through them sequentially. Each step uses delegate under the hood, " &
    "which uses social for peer identity + trust.",
    "",
    "Actions:",
    "  fan_out  — dispatch the SAME task to N agents in parallel; collect " &
                  "all replies (or partial set if any timeout). Use for " &
                  "diverse perspectives, parallel research, or comparing " &
                  "specialist answers before deciding.",
    "  pipeline — sequential A → B → C; each stage sees the prior stage's " &
                  "output as context. Use for draft→critique→polish or " &
                  "research→analysis→presentation chains.",
  ]
  if t.agents.len > 0:
    lines.add("")
    lines.add("Available peer agents (pick by exact name; pass as a JSON array):")
    for a in t.agents:
      var bits: seq[string] = @[]
      if a.role.isSome and a.role.get().len > 0: bits.add("role: " & a.role.get())
      if a.skills.len > 0: bits.add("skills: " & a.skills.join(", "))
      let detail = if bits.len > 0: " — " & bits.join(" · ") else: ""
      lines.add("  - \"" & a.name & "\"" & detail)
  lines.join("\n")

method parameters*(t: CollaborateTool): Table[string, JsonNode] =
  var agentItem = %*{
    "type": "string",
    "minLength": 1,
    "description": "Exact name of a peer agent to include in the orchestration."
  }
  # Constrain agent items to the real declared set so the LLM can't
  # hallucinate. Same enum-narrowing pattern as DelegateTool.parameters.
  if t.agents.len > 0:
    var names = newJArray()
    for a in t.agents: names.add(%a.name)
    agentItem["enum"] = names
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["fan_out", "pipeline"],
        "description": "Orchestration mode. Default 'fan_out' if omitted."
      },
      "agents": {
        "type": "array",
        "items": agentItem,
        "minItems": 1,
        "maxItems": MaxAgentsPerCall,
        "description": "Ordered list of peer agent names. For fan_out the " &
                       "order is just the response order; for pipeline the " &
                       "order IS the execution order (A→B→C)."
      },
      "task": {
        "type": "string",
        "minLength": 1,
        "description": "The task/prompt. For fan_out it's sent verbatim to " &
                       "every agent. For pipeline it's the original goal — " &
                       "each downstream stage is told the prior stage's " &
                       "output AND the original task."
      },
      "timeout_seconds": {
        "type": "integer",
        "minimum": 1,
        "maximum": MaxTimeoutSeconds,
        "description": fmt"Per-agent timeout in seconds. Default {DefaultTimeoutSeconds}, " &
                       fmt"cap {MaxTimeoutSeconds}. For fan_out applies to each " &
                       "future independently (slow peers don't block fast ones); " &
                       "for pipeline applies to each stage (one stage timing out " &
                       "aborts the whole pipeline)."
      }
    },
    "required": %["agents", "task"]
  }.toTable

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

proc findAgent(t: CollaborateTool, name: string): Option[NamedAgentConfig] =
  ## Same lookup as DelegateTool.findAgent — case-sensitive exact match
  ## against the declared peer list.
  for ac in t.agents:
    if ac.name == name: return some(ac)
  none(NamedAgentConfig)

proc roleHint(t: CollaborateTool, name: string): string =
  ## Display-only role label for the response envelope, e.g. "(Tech Lead)".
  ## Returns "" if the agent has no role declared. Cosmetic; helps the
  ## caller's LLM read the envelope without cross-referencing the team
  ## graph.
  let ac = t.findAgent(name)
  if ac.isSome and ac.get().role.isSome and ac.get().role.get().len > 0:
    return " (" & ac.get().role.get() & ")"
  ""

proc parseAgentList(args: Table[string, JsonNode]): tuple[ok: bool, names: seq[string], err: string] =
  ## Parse + minimally validate the `agents` arg. Accepts JArray of strings.
  ## Empty list → error. Whitespace-only entries → silently dropped. Names
  ## are NOT deduped here (caller may want to fan out to the same agent
  ## twice for some reason; if pipeline does it, that's the caller's call).
  if not args.hasKey("agents"):
    return (false, @[], "Error: 'agents' is required (array of agent names)")
  let node = args["agents"]
  if node.kind != JArray:
    # Best-effort: accept a single string ("Atlas") or a comma-separated
    # form ("Atlas, Vega, Lyra") and split. Lenient like other unified
    # tools — LLMs occasionally serialize arrays as flat strings.
    if node.kind == JString:
      let raw = node.getStr().strip()
      if raw.len == 0:
        return (false, @[], "Error: 'agents' is empty")
      var names: seq[string] = @[]
      for tok in raw.split(','):
        let s = tok.strip()
        if s.len > 0: names.add(s)
      if names.len == 0:
        return (false, @[], "Error: 'agents' resolved to no names after split")
      return (true, names, "")
    return (false, @[], "Error: 'agents' must be an array of agent name strings")
  var names: seq[string] = @[]
  for item in node:
    let s = item.getStr("").strip()
    if s.len > 0: names.add(s)
  if names.len == 0:
    return (false, @[], "Error: 'agents' contains no usable names")
  if names.len > MaxAgentsPerCall:
    return (false, @[], fmt"Error: 'agents' has {names.len} names; cap is {MaxAgentsPerCall}")
  (true, names, "")

proc validateAgentNames(t: CollaborateTool, names: seq[string]): string =
  ## Returns "" if every name resolves to a declared peer; else an error
  ## message naming the unknown(s). Catches the LLM hallucinating peer
  ## names BEFORE we burn N futures dispatching to them.
  if t.agents.len == 0:
    # Edge case: no declared peers at all → orchestration is impossible.
    return "Error: no peer agents are declared in this company; collaborate " &
           "needs at least one declared peer in `cfg.agents.named`."
  var unknown: seq[string] = @[]
  for n in names:
    if t.findAgent(n).isNone:
      unknown.add(n)
  if unknown.len > 0:
    var declared: seq[string] = @[]
    for a in t.agents: declared.add(a.name)
    return "Error: unknown agent name(s): " & unknown.join(", ") &
           ". Declared peers are: " & declared.join(", ") &
           ". Pick from those exact strings."
  ""

proc extractTimeout(args: Table[string, JsonNode]): int =
  ## Returns timeout in milliseconds. Clamped to [1s, MaxTimeoutSeconds].
  ## Lenient on the input shape — LLMs occasionally send floats / strings.
  var seconds = DefaultTimeoutSeconds
  if args.hasKey("timeout_seconds"):
    let n = args["timeout_seconds"]
    case n.kind
    of JInt: seconds = int(n.getInt(DefaultTimeoutSeconds))
    of JFloat: seconds = int(n.getFloat(float(DefaultTimeoutSeconds)))
    of JString:
      try: seconds = parseInt(n.getStr().strip())
      except: discard
    else: discard
  if seconds < 1: seconds = 1
  if seconds > MaxTimeoutSeconds: seconds = MaxTimeoutSeconds
  seconds * 1000

proc delegatorAlias(t: CollaborateTool): string =
  ## Mirrors delegate.nim's logic: prefer the agent's nc:id, fall back to
  ## `agent:<name>`. The peer's trust gate evaluates the request as if a
  ## peer staff member made it (NOT the original customer), so the peer
  ## can use her full toolset.
  if t.agentID.len > 0: t.agentID
  else: "agent:" & t.agentName

proc summarize(text: string, maxLen: int = 120): string =
  ## Tiny audit-trail summarizer. Single-line preview of a response —
  ## strips embedded newlines, truncates with an ellipsis. Used in the
  ## pipeline stage trail; full output is what gets returned at the end.
  var s = text.replace("\n", " ").replace("\r", " ").strip()
  if s.len > maxLen:
    s = s[0 ..< maxLen] & "…"
  s

# ---------------------------------------------------------------------------
# fan_out — dispatch the SAME task to N agents in parallel
# ---------------------------------------------------------------------------

proc doFanOut(t: CollaborateTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.askPeer == nil:
    # No peer-RPC wired in — collaborate won't fall back to a tool-less
    # provider call (delegate has that path; collaborate doesn't, on
    # purpose: the whole point is orchestrating peers WITH their tools).
    return "Error: collaborate requires a wired askPeer callback. " &
           "If this fires in production it means the agent loop registered " &
           "collaborate without passing askPeer — fix the registration."

  let parsed = parseAgentList(args)
  if not parsed.ok: return parsed.err
  let names = parsed.names

  if not args.hasKey("task"):
    return "Error: 'task' is required (the prompt to send to every agent)"
  let task = args["task"].getStr().strip()
  if task.len == 0:
    return "Error: 'task' must be non-empty"

  let validateErr = validateAgentNames(t, names)
  if validateErr.len > 0: return validateErr

  let timeoutMs = extractTimeout(args)
  let alias = delegatorAlias(t)

  # Launch all futures eagerly (they start running on this tick) before
  # awaiting any of them. async/await + sleepAsync runs cooperatively:
  # because every askPeer call is itself I/O-bound (HTTP to the peer's
  # provider), this gives genuine concurrency on the asyncdispatch loop.
  var futures: seq[Future[string]] = @[]
  for name in names:
    futures.add(t.askPeer(name, task, alias, t.sessionKey))

  # Per-future timeout. Using `withTimeout` on each future independently
  # so a slow peer doesn't block fast peers — fan_out's whole value is
  # gathering whatever comes back inside the budget. `all()` would fail
  # the whole batch on the first slow one, which is wrong here.
  type Outcome = object
    name: string
    ok: bool
    text: string
    timedOut: bool
  var outcomes: seq[Outcome] = @[]
  var successCount = 0
  var timeoutCount = 0
  var errorCount = 0

  for i in 0 ..< futures.len:
    let fut = futures[i]
    let name = names[i]
    let completed = await withTimeout(fut, timeoutMs)
    if not completed:
      outcomes.add(Outcome(name: name, ok: false, text: "", timedOut: true))
      inc timeoutCount
      # NB: we don't `cancel(fut)` — Nim's asyncdispatch doesn't have a
      # safe cooperative cancel for arbitrary futures, and the underlying
      # askPeer is going to complete in the peer's own time regardless.
      # The future stays alive, garbage-collected once it resolves; from
      # the caller's perspective the slot is closed.
      continue
    if fut.failed:
      outcomes.add(Outcome(name: name, ok: false,
                           text: "exception: " & fut.error.msg, timedOut: false))
      inc errorCount
      continue
    let text = fut.read()
    outcomes.add(Outcome(name: name, ok: true, text: text, timedOut: false))
    inc successCount

  # Format the structured envelope. Header line is informative even when
  # truncated (e.g. truncated by the caller's context limit) — operator
  # can see at a glance whether it's a clean fan-out or partial.
  var lines: seq[string] = @[]
  var headerBits: seq[string] = @[$successCount & " succeeded"]
  if timeoutCount > 0: headerBits.add($timeoutCount & " timed out")
  if errorCount > 0:   headerBits.add($errorCount & " errored")
  lines.add("Fan-out to " & $names.len & " agents (" & headerBits.join(", ") & "):")
  lines.add("")
  for o in outcomes:
    let label = "## " & o.name & roleHint(t, o.name)
    if o.timedOut:
      lines.add(label & " [TIMEOUT after " & $(timeoutMs div 1000) & "s]")
    elif not o.ok:
      lines.add(label & " [ERROR]")
      lines.add(o.text)
    else:
      lines.add(label)
      lines.add(o.text)
    lines.add("")
  lines.join("\n").strip(leading = false)

# ---------------------------------------------------------------------------
# pipeline — sequential A → B → C with each stage seeing the prior output
# ---------------------------------------------------------------------------

proc doPipeline(t: CollaborateTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.askPeer == nil:
    return "Error: collaborate requires a wired askPeer callback. " &
           "If this fires in production it means the agent loop registered " &
           "collaborate without passing askPeer — fix the registration."

  let parsed = parseAgentList(args)
  if not parsed.ok: return parsed.err
  let names = parsed.names

  if not args.hasKey("task"):
    return "Error: 'task' is required (the original goal — passed to every stage along with the prior output)"
  let task = args["task"].getStr().strip()
  if task.len == 0:
    return "Error: 'task' must be non-empty"

  let validateErr = validateAgentNames(t, names)
  if validateErr.len > 0: return validateErr

  let timeoutMs = extractTimeout(args)
  let alias = delegatorAlias(t)

  # Special case: 1-element pipeline = a single delegate call. Don't
  # bother with stage prefixes; just run it.
  if names.len == 1:
    let only = names[0]
    let fut = t.askPeer(only, task, alias, t.sessionKey)
    let completed = await withTimeout(fut, timeoutMs)
    if not completed:
      return "Error: pipeline aborted at stage 1 (" & only & "): " &
             "TIMEOUT after " & $(timeoutMs div 1000) & "s"
    if fut.failed:
      return "Error: pipeline aborted at stage 1 (" & only & "): " & fut.error.msg
    return fut.read()

  # Stage-by-stage. We build the audit trail as we go so an abort on
  # stage K still returns "stages 1..K-1 succeeded, stage K broke
  # because <reason>" rather than just "pipeline failed".
  type StageRecord = object
    idx: int           ## 1-based stage number for human-readable trail
    agent: string
    inputSummary: string
    outputSummary: string
    ok: bool
  var trail: seq[StageRecord] = @[]
  var prevOutput = ""   ## empty before stage 1; stage 1 sees just `task`
  var prevAgent = ""

  for i in 0 ..< names.len:
    let stageNum = i + 1
    let agent = names[i]

    # Compose the per-stage prompt. Stage 1 just gets the raw task;
    # subsequent stages get the prior output prefixed with "Previous step
    # (Agent X) returned: ... Now: <task>". The phrasing matches what
    # the brief specifies and is concrete enough that the peer doesn't
    # have to guess what to do with it.
    let stagePrompt =
      if i == 0:
        task
      else:
        "Previous step (Agent " & prevAgent & ") returned:\n" &
        prevOutput & "\n\nNow: " & task

    let fut = t.askPeer(agent, stagePrompt, alias, t.sessionKey)
    let completed = await withTimeout(fut, timeoutMs)

    if not completed:
      # Build the partial trail and bail.
      trail.add(StageRecord(idx: stageNum, agent: agent,
                            inputSummary: summarize(stagePrompt),
                            outputSummary: "[TIMEOUT after " & $(timeoutMs div 1000) & "s]",
                            ok: false))
      var lines: seq[string] = @[]
      lines.add("Pipeline aborted at stage " & $stageNum & " (" & agent & "): TIMEOUT after " & $(timeoutMs div 1000) & "s.")
      lines.add("")
      lines.add("Audit trail (stages completed before abort):")
      for r in trail:
        lines.add("  " & $r.idx & ". " & r.agent & roleHint(t, r.agent) &
                  (if r.ok: "" else: "  [FAILED]"))
        lines.add("     in:  " & r.inputSummary)
        lines.add("     out: " & r.outputSummary)
      return lines.join("\n")

    if fut.failed:
      trail.add(StageRecord(idx: stageNum, agent: agent,
                            inputSummary: summarize(stagePrompt),
                            outputSummary: "[ERROR: " & fut.error.msg & "]",
                            ok: false))
      var lines: seq[string] = @[]
      lines.add("Pipeline aborted at stage " & $stageNum & " (" & agent & "): " & fut.error.msg)
      lines.add("")
      lines.add("Audit trail (stages completed before abort):")
      for r in trail:
        lines.add("  " & $r.idx & ". " & r.agent & roleHint(t, r.agent) &
                  (if r.ok: "" else: "  [FAILED]"))
        lines.add("     in:  " & r.inputSummary)
        lines.add("     out: " & r.outputSummary)
      return lines.join("\n")

    let output = fut.read()
    trail.add(StageRecord(idx: stageNum, agent: agent,
                          inputSummary: summarize(stagePrompt),
                          outputSummary: summarize(output),
                          ok: true))
    prevOutput = output
    prevAgent = agent

  # All stages succeeded. Return the final stage's full output + the
  # trail. Final output goes FIRST so the caller's downstream consumer
  # (an LLM, a relay, etc.) gets the actionable content without having
  # to skip past the trail.
  var lines: seq[string] = @[]
  lines.add("# Final output (from " & prevAgent & roleHint(t, prevAgent) & ")")
  lines.add("")
  lines.add(prevOutput)
  lines.add("")
  lines.add("---")
  lines.add("Audit trail (" & $names.len & " stages):")
  for r in trail:
    lines.add("  " & $r.idx & ". " & r.agent & roleHint(t, r.agent))
    lines.add("     in:  " & r.inputSummary)
    lines.add("     out: " & r.outputSummary)
  lines.join("\n")

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

method execute*(t: CollaborateTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  # Lenient on missing action — defaults to fan_out. Matches social /
  # capability defaulting style; reduces friction for the LLM's first
  # tool call.
  let action =
    if args.hasKey("action"): args["action"].getStr().strip().toLowerAscii()
    else: "fan_out"
  case action
  of "fan_out", "fanout", "fan-out":
    return await doFanOut(t, args)
  of "pipeline", "chain", "sequential":
    return await doPipeline(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: fan_out | pipeline"
