## collaborate — multi-agent orchestration (the navigator) of the
## social/delegate/collaborate quartet.
##
##   social     — the WORLD GRAPH (the sea): who exists, what they know,
##                trust + identifiers + roles. Read/write the relationship
##                map.
##   delegate   — peer task HANDOFF (the ship): hand ONE task to ONE
##                NAMED peer synchronously (or defer to her todo queue).
##                Eager binding 1:1. Returns her reply.
##   collaborate — multi-agent ORCHESTRATION (the navigator). Two binding
##                strategies in one tool:
##                  • EAGER (push to named): fan_out / pipeline /
##                    consensus / route — caller picks the peers.
##                  • LATE (post to pool):  assign / claim / submit —
##                    caller posts to a TEAM board; whoever's
##                    qualified pulls. State machine: To Do → In
##                    Progress → Completed.
##                Same recursion as `capability method=invoke` over LLM
##                models: a single tool call coordinates many specialist
##                calls under the hood.
##
## Two actions in this draft (Phase A+B):
##
##   method=fan_out  — dispatch the SAME task to N agents in parallel.
##                     Returns one structured envelope with each agent's
##                     reply (or a [TIMEOUT] marker for any that didn't
##                     return inside the timeout window). Use to gather
##                     diverse perspectives, run parallel research, or
##                     compare answers across specialists before deciding.
##
##   method=pipeline — sequential A → B → C: each stage receives the prior
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
##   • method=consensus — fan_out + a follow-up "decide" call that asks
##                        a designated arbiter (or the calling agent's
##                        own model) to reconcile divergent replies. The
##                        skeleton is fan_out + one extra `askPeer`; the
##                        hard part is prompt engineering for the arbiter
##                        and policy on tie-breaks.
##   • method=route     — pick THE ONE best agent for a task based on
##                        skills/role match and dispatch to only that one.
##                        Same primitive as `capability method=route` but
##                        over agents instead of models. Useful when the
##                        caller doesn't know who to delegate to and would
##                        otherwise have to call `social method=query`
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
##        description = "multi-agent orchestration (method=fan_out|pipeline). " &
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

import std/[json, tables, strutils, options, asyncdispatch, strformat,
              algorithm, sets, os, times]
import ./types
import ./spec
import ../config
import ./comm/delegate as delegate_tool
import ./capability_unified

const ToolSpec* = spec(
  name = "collaborate",
  description = "Multi-agent orchestration. EAGER (push to named peers): " &
                "fan_out | pipeline | consensus | route. LATE (post to a " &
                "team pool board, anyone qualified pulls): assign | claim | " &
                "submit. Eager actions use delegate under the hood; late " &
                "actions mutate <workspace>/collaboration/<team|lab>/TASKS.md.",
  tags = @["agent", "delegation", "orchestration", "core"],
  searchKeywords = @["fan-out", "fanout", "parallel", "pipeline",
                      "orchestrate", "coordinate", "multi-agent",
                      "broadcast", "chain", "sequential", "all agents",
                      "ensemble", "scatter-gather", "navigator",
                      "consensus", "synthesize", "vote", "reduce",
                      "route", "pick", "recommend", "best-fit",
                      "on-error", "skip", "retry", "stage-timeout",
                      "assign", "claim", "submit", "post", "pickup",
                      "complete", "finish", "task board", "pool",
                      "queue", "to do", "in progress", "completed",
                      "team board", "lab board"],
  domain = "comm",
  default = true,
  heartbeatSafe = false,  # makes N parallel LLM calls — never on the heartbeat
                          # hot path. Mirrors how `capability method=invoke` is
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
    "collaborate quartet. Two binding strategies:",
    "",
    "EAGER actions (push to NAMED peers — caller picks who):",
    "  fan_out   — dispatch the SAME task to N agents in parallel; collect " &
                  "all replies (or partial set if any timeout). Use for " &
                  "diverse perspectives, parallel research, or comparing " &
                  "specialist answers before deciding.",
    "  pipeline  — sequential A → B → C; each stage sees the prior stage's " &
                  "output as context. Supports stage_timeouts (per-stage " &
                  "override array) and on_error=abort|skip|retry_once.",
    "  consensus — fan_out + LLM synthesis: gather N replies then ask a " &
                  "reasoning-tagged model to reconcile them into one " &
                  "coherent answer (notes disagreements). Optional " &
                  "show_raw=true returns the raw replies too.",
    "  route     — DRY-RUN: pick the best peer for a task by scoring " &
                  "role/skills/practices keyword overlap. Returns a " &
                  "recommendation with reasoning; you call delegate yourself.",
    "",
    "LATE actions (post to TEAM POOL board — anyone qualified pulls):",
    "  assign    — append a task to the team's TASKS.md under '🔴 To Do'. " &
                  "Requires task. Optional team (default 'default_squad') " &
                  "or lab (overrides team).",
    "  claim     — match a To Do item by substring and move it to " &
                  "'🟡 In Progress' tagged with your name. Requires " &
                  "task_query. Same team/lab options as assign.",
    "  submit    — match an In Progress item and move it to '🟢 Completed'. " &
                  "Requires task_query. Optional briefing writes a " &
                  "<team>/briefings/briefing_<ts>_<agent>.md.",
  ]
  if t.agents.len > 0:
    lines.add("")
    lines.add("Available peer agents (pick by exact name; pass as a JSON array):")
    for a in t.agents:
      var bits: seq[string] = @[]
      if a.job_title.len > 0: bits.add("\"" & a.job_title & "\"")
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
  # `from_agents` (route only) constrains which peers to score over.
  var fromAgentsItem = %*{
    "type": "string",
    "minLength": 1,
    "description": "Exact name of a candidate peer to consider during routing."
  }
  if t.agents.len > 0:
    var names = newJArray()
    for a in t.agents: names.add(%a.name)
    fromAgentsItem["enum"] = names
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["fan_out", "pipeline", "consensus", "route",
                 "assign", "claim", "submit"],
        "description": "Orchestration mode. Default 'fan_out' if omitted. " &
                       "EAGER: fan_out (parallel) | pipeline (sequential) | " &
                       "consensus (fan_out + LLM synthesis) | route (pick " &
                       "best peer, dry-run). LATE/POOL: assign (post to " &
                       "team board) | claim (move To Do → In Progress) | " &
                       "submit (In Progress → Completed)."
      },
      "agents": {
        "type": "array",
        "items": agentItem,
        "minItems": 1,
        "maxItems": MaxAgentsPerCall,
        "description": "Ordered list of peer agent names. For fan_out & " &
                       "consensus the order is response order; for pipeline " &
                       "the order IS execution order (A→B→C). Not used by " &
                       "route (use from_agents instead)."
      },
      "task": {
        "type": "string",
        "minLength": 1,
        "description": "The task/prompt. fan_out & consensus: sent verbatim " &
                       "to every agent. pipeline: original goal threaded " &
                       "through each stage with prior output. route: the " &
                       "task to score peers against. assign: the task line " &
                       "appended to the team board. consensus calls this " &
                       "'question' but accepts 'task' as a synonym."
      },
      "question": {
        "type": "string",
        "description": "consensus only — the question to put to every agent. " &
                       "Synonym for 'task' in consensus mode."
      },
      "timeout_seconds": {
        "type": "integer",
        "minimum": 1,
        "maximum": MaxTimeoutSeconds,
        "description": fmt"Per-agent timeout in seconds. Default {DefaultTimeoutSeconds}, " &
                       fmt"cap {MaxTimeoutSeconds}. For fan_out applies to each " &
                       "future independently (slow peers don't block fast ones); " &
                       "for pipeline applies to each stage as the default " &
                       "when stage_timeouts is absent or short for that index."
      },
      "stage_timeouts": {
        "type": "array",
        "items": {"type": "integer", "minimum": 1, "maximum": MaxTimeoutSeconds},
        "description": "pipeline only — per-stage timeout overrides (seconds). " &
                       "Length must match agents.len. Each value clamped to " &
                       fmt"[1, {MaxTimeoutSeconds}]. Absent → use timeout_seconds " &
                       "for every stage."
      },
      "on_error": {
        "type": "string",
        "enum": ["abort", "skip", "retry_once"],
        "description": "pipeline only — failure policy. Default 'abort' " &
                       "(current behavior). 'skip' = log error, pass prior " &
                       "stage's output (or original task if first) to next. " &
                       "'retry_once' = retry the failing stage once; if " &
                       "still fails, fall through to abort."
      },
      "reduce_prompt": {
        "type": "string",
        "description": "consensus only — custom synthesis prompt. Default: " &
                       "'Synthesize a single coherent answer that reconciles " &
                       "the responses. Note any disagreement explicitly. " &
                       "Be concise.'"
      },
      "arbiter_tag": {
        "type": "string",
        "description": "consensus only — capability tag of the model that " &
                       "synthesizes the responses. Default 'reasoning'. " &
                       "Routes via the same path as `capability method=invoke`."
      },
      "show_raw": {
        "type": "boolean",
        "description": "consensus only — when true, prefix the synthesized " &
                       "answer with the raw fan_out envelope. Default false."
      },
      "from_agents": {
        "type": "array",
        "items": fromAgentsItem,
        "minItems": 1,
        "maxItems": MaxAgentsPerCall,
        "description": "route only — restrict scoring to this subset. " &
                       "Default: every declared peer except the caller."
      },
      "explain": {
        "type": "boolean",
        "description": "route only — when true, return full ranked list " &
                       "with each candidate's score breakdown. Default false " &
                       "(top recommendation only)."
      },
      "team": {
        "type": "string",
        "description": "assign/claim/submit — which team's TASKS.md board " &
                       "to operate on. Default 'default_squad'. Lab " &
                       "overrides team."
      },
      "lab": {
        "type": "string",
        "description": "assign/claim/submit — operate on a lab board " &
                       "(<workspace>/collaboration/labs/<lab>/TASKS.md) " &
                       "instead of a team board."
      },
      "task_query": {
        "type": "string",
        "description": "claim/submit — case-insensitive substring of the " &
                       "task line to match. First match in the relevant " &
                       "section wins."
      },
      "briefing": {
        "type": "string",
        "description": "submit (optional) — accomplishment summary. Saved " &
                       "as <board>/briefings/briefing_<ts>_<agent>.md when " &
                       "the briefings dir exists."
      }
    },
    "required": %["method"]
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

type
  FanOutOutcome = object
    ## One peer's reply (or non-reply). Reused by consensus to feed the
    ## arbiter; kept module-level so consensus doesn't have to re-derive
    ## what counts as "succeeded".
    name: string
    ok: bool
    text: string
    timedOut: bool

  FanOutResult = object
    outcomes: seq[FanOutOutcome]
    successCount: int
    timeoutCount: int
    errorCount: int
    timeoutMs: int

proc fanOutCore(t: CollaborateTool, names: seq[string], task: string,
                timeoutMs: int): Future[FanOutResult] {.async.} =
  ## Pure dispatch: launch N futures, gather outcomes with per-future
  ## timeouts. No envelope formatting — that's the caller's job (fan_out
  ## formats one way; consensus consumes the raw outcomes for synthesis).
  let alias = delegatorAlias(t)

  # Launch all futures eagerly (they start running on this tick) before
  # awaiting any of them. async/await + sleepAsync runs cooperatively:
  # because every askPeer call is itself I/O-bound (HTTP to the peer's
  # provider), this gives genuine concurrency on the asyncdispatch loop.
  var futures: seq[Future[string]] = @[]
  for name in names:
    futures.add(t.askPeer(name, task, alias, t.sessionKey))

  var res = FanOutResult(timeoutMs: timeoutMs)

  # Per-future timeout. Using `withTimeout` on each future independently
  # so a slow peer doesn't block fast peers — fan_out's whole value is
  # gathering whatever comes back inside the budget. `all()` would fail
  # the whole batch on the first slow one, which is wrong here.
  for i in 0 ..< futures.len:
    let fut = futures[i]
    let name = names[i]
    let completed = await withTimeout(fut, timeoutMs)
    if not completed:
      res.outcomes.add(FanOutOutcome(name: name, ok: false, text: "",
                                     timedOut: true))
      inc res.timeoutCount
      # NB: we don't `cancel(fut)` — Nim's asyncdispatch doesn't have a
      # safe cooperative cancel for arbitrary futures, and the underlying
      # askPeer is going to complete in the peer's own time regardless.
      # The future stays alive, garbage-collected once it resolves; from
      # the caller's perspective the slot is closed.
      continue
    if fut.failed:
      res.outcomes.add(FanOutOutcome(name: name, ok: false,
                                     text: "exception: " & fut.error.msg,
                                     timedOut: false))
      inc res.errorCount
      continue
    let text = fut.read()
    res.outcomes.add(FanOutOutcome(name: name, ok: true, text: text,
                                   timedOut: false))
    inc res.successCount
  res

proc renderFanOutEnvelope(t: CollaborateTool, names: seq[string],
                          fr: FanOutResult): string =
  ## Format the multi-agent reply envelope. Header line is informative even
  ## when truncated — operator can see at a glance whether it's a clean
  ## fan-out or partial. Used by both fan_out and consensus (when show_raw).
  var lines: seq[string] = @[]
  var headerBits: seq[string] = @[$fr.successCount & " succeeded"]
  if fr.timeoutCount > 0: headerBits.add($fr.timeoutCount & " timed out")
  if fr.errorCount > 0:   headerBits.add($fr.errorCount & " errored")
  lines.add("Fan-out to " & $names.len & " agents (" & headerBits.join(", ") & "):")
  lines.add("")
  for o in fr.outcomes:
    let label = "## " & o.name & roleHint(t, o.name)
    if o.timedOut:
      lines.add(label & " [TIMEOUT after " & $(fr.timeoutMs div 1000) & "s]")
    elif not o.ok:
      lines.add(label & " [ERROR]")
      lines.add(o.text)
    else:
      lines.add(label)
      lines.add(o.text)
    lines.add("")
  lines.join("\n").strip(leading = false)

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
  let fr = await fanOutCore(t, names, task, timeoutMs)
  return renderFanOutEnvelope(t, names, fr)

# ---------------------------------------------------------------------------
# pipeline — sequential A → B → C with each stage seeing the prior output
# ---------------------------------------------------------------------------

type
  OnErrorPolicy = enum
    oeAbort       ## v1 default — first failure aborts the pipeline
    oeSkip        ## log + reuse prior output (or original task if first stage)
    oeRetryOnce   ## one retry on the failing stage; if still fails → abort

proc parseOnError(args: Table[string, JsonNode]): tuple[policy: OnErrorPolicy, err: string] =
  ## Default: abort (preserves v1 behavior).
  if not args.hasKey("on_error"): return (oeAbort, "")
  let raw = args["on_error"].getStr("").strip().toLowerAscii()
  case raw
  of "", "abort":          return (oeAbort, "")
  of "skip":               return (oeSkip, "")
  of "retry_once", "retry-once", "retry": return (oeRetryOnce, "")
  else:
    return (oeAbort, "Error: 'on_error' must be one of: abort, skip, retry_once " &
                     "(got '" & raw & "')")

proc parseStageTimeouts(args: Table[string, JsonNode], stageCount, fallbackMs: int):
                       tuple[timeoutsMs: seq[int], err: string] =
  ## Returns a per-stage timeout in MILLISECONDS. If `stage_timeouts` is
  ## absent, every slot gets `fallbackMs` (which is the global timeout).
  ## Length mismatch → error (the LLM should know precisely which stage
  ## got which budget). Each value is independently clamped to
  ## [1, MaxTimeoutSeconds].
  var timeouts: seq[int] = @[]
  if not args.hasKey("stage_timeouts"):
    for _ in 0 ..< stageCount: timeouts.add(fallbackMs)
    return (timeouts, "")
  let node = args["stage_timeouts"]
  if node.kind != JArray:
    return (@[], "Error: 'stage_timeouts' must be a JSON array of integers " &
                 "(one per agent in the pipeline)")
  if node.len != stageCount:
    return (@[], "Error: 'stage_timeouts' has " & $node.len &
                 " entries but agents has " & $stageCount &
                 ". Lengths must match (one timeout per stage).")
  for i, item in node:
    var seconds = fallbackMs div 1000
    case item.kind
    of JInt:    seconds = int(item.getInt(seconds))
    of JFloat:  seconds = int(item.getFloat(float(seconds)))
    of JString:
      try: seconds = parseInt(item.getStr().strip())
      except: discard
    else:
      return (@[], "Error: 'stage_timeouts[" & $i & "]' is not a number")
    if seconds < 1: seconds = 1
    if seconds > MaxTimeoutSeconds: seconds = MaxTimeoutSeconds
    timeouts.add(seconds * 1000)
  (timeouts, "")

type
  StageOutcome = enum
    soOk
    soTimeout
    soFailed
    soSkipped     ## on_error=skip — reused prior output, didn't actually fail-fast

  StageRecord = object
    idx: int           ## 1-based stage number for human-readable trail
    agent: string
    inputSummary: string
    outputSummary: string
    outcome: StageOutcome
    note: string       ## "retried after timeout", "skipped: TIMEOUT 60s", etc.

proc renderTrail(t: CollaborateTool, trail: seq[StageRecord]): seq[string] =
  for r in trail:
    var marker = ""
    case r.outcome
    of soOk:      marker = ""
    of soTimeout: marker = "  [TIMEOUT]"
    of soFailed:  marker = "  [FAILED]"
    of soSkipped: marker = "  [SKIPPED]"
    result.add("  " & $r.idx & ". " & r.agent & roleHint(t, r.agent) & marker)
    result.add("     in:  " & r.inputSummary)
    result.add("     out: " & r.outputSummary)
    if r.note.len > 0:
      result.add("     note: " & r.note)

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

  let globalTimeoutMs = extractTimeout(args)
  let alias = delegatorAlias(t)

  let (policy, policyErr) = parseOnError(args)
  if policyErr.len > 0: return policyErr

  let (stageTimeoutsMs, stErr) =
    parseStageTimeouts(args, names.len, globalTimeoutMs)
  if stErr.len > 0: return stErr

  # Helper to build one stage's prompt — original task on stage 1, prior
  # output threaded through on subsequent stages.
  proc buildStagePrompt(stageIdx: int, prevAgent, prevOutput: string): string =
    if stageIdx == 0:
      return task
    "Previous step (Agent " & prevAgent & ") returned:\n" &
    prevOutput & "\n\nNow: " & task

  # Helper to dispatch one stage with a per-stage timeout. Returns:
  #   ok = true  → completed successfully, text holds the output
  #   ok = false → either timed out OR errored; fillMsg names which
  proc runStage(agent, prompt: string, timeoutMs: int):
                Future[tuple[ok: bool, text: string,
                             timedOut: bool, errMsg: string]] {.async.} =
    let fut = t.askPeer(agent, prompt, alias, t.sessionKey)
    let completed = await withTimeout(fut, timeoutMs)
    if not completed:
      return (false, "", true, "TIMEOUT after " & $(timeoutMs div 1000) & "s")
    if fut.failed:
      return (false, "", false, fut.error.msg)
    return (true, fut.read(), false, "")

  # Stage-by-stage. We build the audit trail as we go so an abort on
  # stage K still returns "stages 1..K-1 succeeded, stage K broke
  # because <reason>" rather than just "pipeline failed".
  var trail: seq[StageRecord] = @[]
  var prevOutput = ""   ## empty before stage 1; stage 1 sees just `task`
  var prevAgent = ""

  for i in 0 ..< names.len:
    let stageNum = i + 1
    let agent = names[i]
    let stageTimeoutMs = stageTimeoutsMs[i]
    let stagePrompt = buildStagePrompt(i, prevAgent, prevOutput)

    var (ok, output, timedOut, errMsg) =
      await runStage(agent, stagePrompt, stageTimeoutMs)
    var note = ""

    # retry_once: try the failing stage one more time before deciding.
    if not ok and policy == oeRetryOnce:
      let firstFailure = if timedOut: "TIMEOUT" else: "ERROR"
      let (ok2, output2, timedOut2, errMsg2) =
        await runStage(agent, stagePrompt, stageTimeoutMs)
      if ok2:
        ok = true
        output = output2
        note = "succeeded on retry after first " & firstFailure &
               " (" & errMsg & ")"
      else:
        # Retry also failed → fall through to the abort path with both
        # failures recorded in the note. This matches "if still fails,
        # fall through to abort behavior".
        ok = false
        timedOut = timedOut2
        errMsg = errMsg2
        note = "retry also failed (first " & firstFailure &
               ": " & (if errMsg.len > 0: errMsg else: "—") & ")"

    if not ok:
      # `skip` policy — record the failure in the trail and reuse prior
      # output (or the original task if this is the first stage). Don't
      # abort.
      if policy == oeSkip:
        let outcomeMarker = if timedOut: soTimeout else: soFailed
        trail.add(StageRecord(idx: stageNum, agent: agent,
                              inputSummary: summarize(stagePrompt),
                              outputSummary:
                                (if timedOut: "[TIMEOUT after " &
                                              $(stageTimeoutMs div 1000) & "s — skipped]"
                                 else: "[ERROR: " & errMsg & " — skipped]"),
                              outcome: outcomeMarker,
                              note: "on_error=skip; passing prior output to next stage"))
        # prevOutput / prevAgent stay as they were so the next stage
        # sees the last successful upstream result. If this is stage 1
        # the next stage will see the raw task again (because prevOutput
        # is "", and buildStagePrompt for i>0 with empty prevOutput
        # threads an empty "Previous step" block — that's a slightly
        # awkward shape, so handle the i==0-skipped case by leaving
        # prevAgent empty; the next iteration's buildStagePrompt(i>0)
        # will still wrap the empty string, which is unusual but
        # honest about the audit trail).
        continue

      # `abort` policy (default) and `retry_once` exhausted → bail with
      # the partial trail.
      let outcomeMarker = if timedOut: soTimeout else: soFailed
      let outSummary =
        if timedOut: "[TIMEOUT after " & $(stageTimeoutMs div 1000) & "s]"
        else: "[ERROR: " & errMsg & "]"
      trail.add(StageRecord(idx: stageNum, agent: agent,
                            inputSummary: summarize(stagePrompt),
                            outputSummary: outSummary,
                            outcome: outcomeMarker,
                            note: note))
      var lines: seq[string] = @[]
      let reason =
        if timedOut: "TIMEOUT after " & $(stageTimeoutMs div 1000) & "s"
        else: errMsg
      lines.add("Pipeline aborted at stage " & $stageNum & " (" & agent & "): " & reason &
                ".")
      if note.len > 0: lines.add("(" & note & ")")
      lines.add("")
      lines.add("Audit trail (stages completed before abort):")
      for ln in renderTrail(t, trail): lines.add(ln)
      return lines.join("\n")

    # Stage succeeded (possibly via retry).
    trail.add(StageRecord(idx: stageNum, agent: agent,
                          inputSummary: summarize(stagePrompt),
                          outputSummary: summarize(output),
                          outcome: soOk,
                          note: note))
    prevOutput = output
    prevAgent = agent

  # Final output. With on_error=skip and ALL stages skipped (every stage
  # failed), prevOutput stays "" — return a clear error rather than an
  # empty-looking success.
  if prevOutput.len == 0:
    var lines: seq[string] = @[]
    lines.add("Pipeline completed but produced no output — every stage " &
              "failed under on_error=skip.")
    lines.add("")
    lines.add("Audit trail:")
    for ln in renderTrail(t, trail): lines.add(ln)
    return lines.join("\n")

  # All stages succeeded (or skipped with at least one prior output to
  # carry forward). Return the final output FIRST so the downstream
  # consumer gets the actionable content without skipping past the trail.
  var lines: seq[string] = @[]
  lines.add("# Final output (from " & prevAgent & roleHint(t, prevAgent) & ")")
  lines.add("")
  lines.add(prevOutput)
  lines.add("")
  lines.add("---")
  lines.add("Audit trail (" & $names.len & " stages):")
  for ln in renderTrail(t, trail): lines.add(ln)
  lines.join("\n")

# ---------------------------------------------------------------------------
# consensus — fan_out + LLM synthesis (the arbiter reconciles the replies)
# ---------------------------------------------------------------------------

const DefaultReducePrompt =
  "Synthesize a single coherent answer that reconciles the responses. " &
  "Note any disagreement explicitly. Be concise."

const DefaultArbiterTag = "reasoning"

proc buildSynthesisPrompt(t: CollaborateTool, question: string,
                          fr: FanOutResult, reducePrompt: string): string =
  ## Compose the arbiter's input. Header = the original question; body =
  ## one section per agent (only successful responses; timeouts/errors
  ## get a labeled placeholder so the arbiter knows the input was partial).
  ## Footer = the reduce instruction.
  var lines: seq[string] = @[]
  lines.add("Question: " & question)
  lines.add("")
  lines.add("Responses from each agent:")
  for o in fr.outcomes:
    lines.add("")
    let label = "## " & o.name & roleHint(t, o.name)
    if o.timedOut:
      lines.add(label)
      lines.add("[no response — timed out after " &
                $(fr.timeoutMs div 1000) & "s]")
    elif not o.ok:
      lines.add(label)
      lines.add("[no response — error: " & o.text & "]")
    else:
      lines.add(label)
      lines.add(o.text)
  lines.add("")
  lines.add(reducePrompt)
  lines.join("\n")

proc invokeArbiter(t: CollaborateTool, tag, prompt: string,
                   timeoutMs: int): Future[tuple[ok: bool, text: string,
                                                 err: string]] {.async.} =
  ## Compose the synthesis call by delegating to capability_unified's
  ## `invoke` action. We construct a fresh CapabilityTool, propagate the
  ## minimal context fields it needs (agentName for primary-model
  ## preference, sessionKey/role for the path-safety fallback paths),
  ## then call `execute({"action":"invoke", "tag":..., "input":<prompt>,
  ## "prompt":""})`. Single source of truth for LLM routing — no
  ## duplicate HTTP shape inline.
  let cap = newCapabilityTool()
  cap.agentName = t.agentName
  cap.agentID = t.agentID
  cap.sessionKey = t.sessionKey
  cap.role = t.role
  # We deliberately don't pass `input` as a file — the prompt is text,
  # so capability_unified's resolveInvokeInput will fall through the
  # path-checks and treat it as inline text. That's why we leave
  # workspaceDir/officeDir/allowedPaths unset (capability will derive
  # fallbacks from config if it ever needed them, which it doesn't here).

  # capability_unified's `invoke` requires both `input` and `prompt`.
  # We put the WHOLE synthesis text into `input` (the multimodal block
  # is text-only here) and a short `prompt` instructing the arbiter how
  # to read it. Splitting like this matches the wire shape — invoke
  # builds a 2-block content array (text=prompt, then text=input).
  var capArgs = initTable[string, JsonNode]()
  capArgs["action"] = %"invoke"
  capArgs["tag"] = %tag
  capArgs["input"] = %prompt
  capArgs["prompt"] = %("You are an arbiter. Read the multi-agent " &
                        "responses below and produce the synthesized " &
                        "answer the user asked for.")

  # Capability's invoke awaits its own HTTP call; wrap the whole thing
  # with our own timeout so a slow arbiter doesn't stall the calling
  # agent. We use the per-agent timeout × 2 — synthesis on a reasoning
  # model is generally slower than a peer's single response.
  let arbiterTimeoutMs = min(timeoutMs * 2, MaxTimeoutSeconds * 1000)
  let fut = cap.execute(capArgs)
  let completed = await withTimeout(fut, arbiterTimeoutMs)
  if not completed:
    return (false, "",
            "arbiter LLM call timed out after " &
            $(arbiterTimeoutMs div 1000) & "s")
  if fut.failed:
    return (false, "", "arbiter LLM call failed: " & fut.error.msg)
  let resp = fut.read()
  # capability_unified prefixes successful responses with
  # "[via <model> (<provider>)]\n<content>" and prefixes failures with
  # "Error:". Detect the latter and surface it as an error so we can
  # fall back gracefully.
  if resp.startsWith("Error:"):
    return (false, "", resp)
  return (true, resp, "")

proc doConsensus(t: CollaborateTool,
                 args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.askPeer == nil:
    return "Error: collaborate requires a wired askPeer callback. " &
           "If this fires in production it means the agent loop registered " &
           "collaborate without passing askPeer — fix the registration."

  let parsed = parseAgentList(args)
  if not parsed.ok: return parsed.err
  let names = parsed.names

  # `question` is the canonical key; `task` accepted as synonym for
  # consistency with the other actions.
  var question = ""
  if args.hasKey("question"):
    question = args["question"].getStr().strip()
  elif args.hasKey("task"):
    question = args["task"].getStr().strip()
  if question.len == 0:
    return "Error: 'question' (or 'task') is required (the question to put " &
           "to every agent)"

  let validateErr = validateAgentNames(t, names)
  if validateErr.len > 0: return validateErr

  let timeoutMs = extractTimeout(args)
  let reducePrompt =
    if args.hasKey("reduce_prompt"):
      let r = args["reduce_prompt"].getStr().strip()
      if r.len > 0: r else: DefaultReducePrompt
    else: DefaultReducePrompt
  let arbiterTag =
    if args.hasKey("arbiter_tag"):
      let a = args["arbiter_tag"].getStr().strip()
      if a.len > 0: a else: DefaultArbiterTag
    else: DefaultArbiterTag
  var showRaw = false
  if args.hasKey("show_raw"):
    let n = args["show_raw"]
    case n.kind
    of JBool:   showRaw = n.getBool()
    of JString: showRaw = n.getStr().toLowerAscii() in ["true", "yes", "1"]
    of JInt:    showRaw = n.getInt() != 0
    else: discard

  # 1. Fan-out to collect raw responses.
  let fr = await fanOutCore(t, names, question, timeoutMs)

  # 2. Edge case: zero successful responses. Synthesis would have nothing
  # to reconcile — degrade gracefully with the raw envelope and an error
  # note rather than spending an arbiter call on a guaranteed failure.
  if fr.successCount == 0:
    var lines: seq[string] = @[]
    lines.add("Consensus failed: no agents responded successfully.")
    lines.add("")
    lines.add(renderFanOutEnvelope(t, names, fr))
    return lines.join("\n")

  # 3. Build synthesis prompt + call the arbiter.
  let synthPrompt = buildSynthesisPrompt(t, question, fr, reducePrompt)
  let (arbOk, arbText, arbErr) =
    await invokeArbiter(t, arbiterTag, synthPrompt, timeoutMs)

  # 4. Compose the response.
  var lines: seq[string] = @[]

  # Soft warning when fewer than 2 succeeded — synthesis still runs (one
  # answer is at least an answer) but the caller should know it's not
  # really a "consensus".
  if fr.successCount < 2:
    lines.add("Note: only " & $fr.successCount & " of " & $names.len &
              " agents responded — synthesizing from a single voice.")
    lines.add("")

  if showRaw:
    lines.add(renderFanOutEnvelope(t, names, fr))
    lines.add("")
    lines.add("---")
    lines.add("# Synthesis")
    lines.add("")

  if arbOk:
    lines.add(arbText)
  else:
    # 5. Arbiter failed — fall back to the raw envelope + an error note.
    # The caller's primary model can still read the raw replies and
    # synthesize manually.
    lines.add("[arbiter synthesis failed: " & arbErr & "]")
    lines.add("[falling back to raw fan-out so the caller can synthesize " &
              "manually]")
    lines.add("")
    if not showRaw:
      # When the arbiter fails AND show_raw was off, surface the raw
      # envelope anyway — otherwise the caller is stranded with just an
      # error message.
      lines.add(renderFanOutEnvelope(t, names, fr))
  lines.join("\n")

# ---------------------------------------------------------------------------
# route — pick THE ONE best peer for a task by skills/role keyword overlap
# ---------------------------------------------------------------------------
#
# Pure inspection — does NOT dispatch the task. The caller takes the
# recommendation and calls `delegate` themselves. Mirrors the
# `capability method=route` vs `capability method=invoke` separation:
# preview the routing, then commit (or override) explicitly.

const Stopwords = [
  # Tiny English stopword list — keeps token overlap from being dominated
  # by "the", "of", "a", etc. Not exhaustive; just the highest-frequency
  # noise words. Don't add domain-specific terms here (they ARE the signal).
  "the", "of", "a", "an", "and", "or", "but", "to", "in", "on", "for",
  "with", "by", "at", "from", "is", "are", "was", "were", "be", "been",
  "this", "that", "these", "those", "it", "its", "as", "if", "then",
  "i", "we", "you", "they", "he", "she", "do", "did", "does", "have",
  "has", "had", "can", "could", "should", "would", "will", "may",
  "might", "shall", "what", "which", "who", "when", "where", "why",
  "how", "about", "into", "than", "so", "no", "not", "all", "any",
  "some", "more", "most", "less", "few", "such", "very", "just"
].toHashSet

proc tokenize(s: string): HashSet[string] =
  ## Lowercase + alphanumeric-only token split. Drops stopwords and
  ## tokens shorter than 2 chars (single letters are always noise).
  result = initHashSet[string]()
  var current = ""
  for ch in s:
    if ch.isAlphaNumeric:
      current.add(ch.toLowerAscii)
    else:
      if current.len >= 2 and current notin Stopwords:
        result.incl(current)
      current = ""
  if current.len >= 2 and current notin Stopwords:
    result.incl(current)

proc overlapCount(a, b: HashSet[string]): tuple[count: int, terms: seq[string]] =
  ## Returns (intersection size, sorted intersection terms) — the terms
  ## are surfaced in the explanation so the operator can see WHY the
  ## scorer chose a candidate.
  var hit: seq[string] = @[]
  for tok in a:
    if tok in b: hit.add(tok)
  hit.sort()
  (hit.len, hit)

type
  RouteScore = object
    name: string
    score: float
    role: string                   ## display copy of role (Option unwrapped)
    titleHits: seq[string]         ## tokens matched in jobTitle/role
    skillHits: seq[string]         ## tokens matched in skills (the `skills` field)
    practiceHits: seq[string]      ## tokens matched in practices/competencies
    soulHits: seq[string]          ## tokens matched in system_prompt (proxy for soul)
    roleBias: float                ## +/- bias from role tier
    breakdown: string              ## human-readable score recipe
    reachable: bool                ## false → agent has no usable id (rare)

proc roleTierBias(roleStr: string, taskTokens: HashSet[string]): float =
  ## Mild bias for Admin on complex tasks; lower for Member on trivial.
  ## "Complex" is heuristically inferred from task length; a longer task
  ## is, on average, more complex than a one-liner. This is intentionally
  ## soft — the operator can still pick anyone they want; this is just
  ## the recommended ordering.
  let role = roleStr.toLowerAscii()
  let isComplex = taskTokens.len >= 8
  case role
  of "admin", "superadmin": return (if isComplex: 0.5 else: 0.1)
  of "staff":               return 0.0
  of "member":              return (if isComplex: -0.3 else: 0.0)
  else:                     return 0.0

proc lookupNamedAgent(t: CollaborateTool, name: string): Option[NamedAgentConfig] =
  for a in t.agents:
    if a.name == name: return some(a)
  none(NamedAgentConfig)

proc scoreCandidate(t: CollaborateTool, ac: NamedAgentConfig,
                    taskTokens: HashSet[string]): RouteScore =
  ## Compute a candidate's match score. Weights:
  ##   jobTitle/role  = 3.0  (the strongest signal — what they DO)
  ##   skills         = 2.0  (declared via `skills` on NamedAgentConfig)
  ##   competencies   = 2.0  (declared via `practices`)
  ##   soul/sys-prompt= 0.5  (weakest — system prompts contain a lot of
  ##                          generic scaffolding; only a few overlap
  ##                          tokens are meaningful)
  ## roleBias is added (small +/- for Admin/Member tier).
  result.name = ac.name
  result.role = if ac.role.isSome: ac.role.get() else: ""
  # NamedAgentConfig now surfaces `job_title` (set from the DSL `jobTitle`
  # field on the agent block). Score against jobTitle PLUS role: jobTitle
  # is what they DO ("Customer Support", "Performance Analyst"); role is
  # the trust tier (Admin/Staff). Both are weak-evidence keyword signals
  # for routing. Concatenating them maximises substring/token overlap
  # with task vocabulary.
  let titleTok = tokenize(ac.job_title & " " & result.role)
  let skillTok = tokenize(ac.skills.join(" "))
  let practiceTok = tokenize(ac.practices.join(" "))
  let soulTok =
    if ac.system_prompt.isSome: tokenize(ac.system_prompt.get())
    else: initHashSet[string]()

  let (titleN, titleHit)       = overlapCount(taskTokens, titleTok)
  let (skillN, skillHit)       = overlapCount(taskTokens, skillTok)
  let (practiceN, practiceHit) = overlapCount(taskTokens, practiceTok)
  let (soulN, soulHit)         = overlapCount(taskTokens, soulTok)

  result.titleHits = titleHit
  result.skillHits = skillHit
  result.practiceHits = practiceHit
  result.soulHits = soulHit
  result.roleBias = roleTierBias(result.role, taskTokens)

  result.score = float(titleN) * 3.0 +
                 float(skillN) * 2.0 +
                 float(practiceN) * 2.0 +
                 float(soulN) * 0.5 +
                 result.roleBias

  # NamedAgentConfig doesn't carry per-agent channel identifiers (those
  # live on channel configs). For now treat every declared peer as
  # reachable — askPeer will surface a real "no route" error at dispatch
  # time if it's actually unreachable. This keeps route from suppressing
  # valid candidates over a signal we can't reliably read.
  result.reachable = true

  # Build the explanation string. Only include sub-scores that contributed.
  var bits: seq[string] = @[]
  if titleN > 0:    bits.add("title +" & $(titleN * 3) & " on [" & titleHit.join(", ") & "]")
  if skillN > 0:    bits.add("skills +" & $(skillN * 2) & " on [" & skillHit.join(", ") & "]")
  if practiceN > 0: bits.add("competencies +" & $(practiceN * 2) & " on [" & practiceHit.join(", ") & "]")
  if soulN > 0:     bits.add("soul +" & $(soulN.float * 0.5) & " on [" & soulHit.join(", ") & "]")
  if result.roleBias != 0.0:
    bits.add("role(" & result.role & ") " &
             (if result.roleBias > 0: "+" else: "") & $result.roleBias)
  if bits.len == 0:
    result.breakdown = "no signal — score 0 (no overlap with role/skills/competencies/soul)"
  else:
    result.breakdown = bits.join(" · ")

proc doRoute(t: CollaborateTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("task"):
    return "Error: 'task' is required (the task to score peers against)"
  let task = args["task"].getStr().strip()
  if task.len == 0:
    return "Error: 'task' must be non-empty"

  if t.agents.len == 0:
    return "Error: no peer agents are declared in this company; route has " &
           "nothing to score against."

  # Determine candidate set.
  var candidates: seq[NamedAgentConfig] = @[]
  if args.hasKey("from_agents"):
    # Reuse parseAgentList for shape lenience (JArray of strings or comma
    # form). Wrap in a synthetic table because parseAgentList expects
    # `agents` as the key.
    var synth = initTable[string, JsonNode]()
    synth["agents"] = args["from_agents"]
    let parsed = parseAgentList(synth)
    if not parsed.ok:
      return parsed.err.replace("'agents'", "'from_agents'")
    let validateErr = validateAgentNames(t, parsed.names)
    if validateErr.len > 0:
      return validateErr.replace("Pick from those exact strings.",
                                 "Pick from those exact strings or omit " &
                                 "from_agents to score over all peers.")
    for n in parsed.names:
      let a = lookupNamedAgent(t, n)
      if a.isSome: candidates.add(a.get())
  else:
    # All declared peers EXCEPT the calling agent (you don't recommend
    # someone delegate to themselves).
    for ac in t.agents:
      if ac.name == t.agentName: continue
      candidates.add(ac)
    if candidates.len == 0:
      # Fallback: if the only declared peer IS the caller (or there's no
      # caller context), include them so route still has something to say.
      for ac in t.agents: candidates.add(ac)

  if candidates.len == 0:
    return "Error: no candidate agents available for routing (after filtering)."

  # Tokenize the task once — same set used against every candidate's
  # signals.
  let taskTokens = tokenize(task)
  if taskTokens.len == 0:
    return "Error: task has no scoreable tokens after stopword removal " &
           "(only stopwords?). Try a more descriptive task description."

  var explain = false
  if args.hasKey("explain"):
    let n = args["explain"]
    case n.kind
    of JBool:   explain = n.getBool()
    of JString: explain = n.getStr().toLowerAscii() in ["true", "yes", "1"]
    of JInt:    explain = n.getInt() != 0
    else: discard

  # Score every candidate.
  var scores: seq[RouteScore] = @[]
  for ac in candidates:
    scores.add(scoreCandidate(t, ac, taskTokens))

  # Rank: highest score first; on tie, prefer reachable; on further tie,
  # alphabetical (deterministic).
  scores.sort(proc(a, b: RouteScore): int =
    if a.score > b.score: return -1
    if a.score < b.score: return 1
    if a.reachable and not b.reachable: return -1
    if b.reachable and not a.reachable: return 1
    return cmp(a.name, b.name))

  let top = scores[0]

  # Compose the response.
  var lines: seq[string] = @[]

  if top.score == 0:
    # No signal at all — make this explicit. The recommendation is the
    # alphabetically-first peer, which is essentially a coin flip; the
    # caller should pick deliberately.
    lines.add("Routing recommendation for task: \"" &
              (if task.len > 80: task[0..79] & "…" else: task) & "\"")
    lines.add("")
    lines.add("→ No clear best-fit found (no role/skill/competency overlap with " &
              "any candidate). Listing all candidates so you can pick:")
    for s in scores:
      lines.add("  - " & s.name &
                (if s.role.len > 0: " (" & s.role & ")" else: "") &
                "  score " & $s.score)
    lines.add("")
    lines.add("Tip: a more descriptive task (with terms that match a peer's " &
              "role/skills/competencies) would let route make a confident pick.")
    return lines.join("\n")

  lines.add("Routing recommendation for task: \"" &
            (if task.len > 80: task[0..79] & "…" else: task) & "\"")
  lines.add("")
  lines.add("→ " & top.name & roleHint(t, top.name) &
            "   score " & $top.score)
  lines.add("   why: " & top.breakdown)
  lines.add("")
  lines.add("To dispatch: collaborate method=fan_out agents=[\"" &
            top.name & "\"] task=...   (or use delegate for a single peer)")

  if explain:
    lines.add("")
    lines.add("---")
    lines.add("Full ranked list (" & $scores.len & " candidates):")
    for i, s in scores:
      lines.add("  " & $(i + 1) & ". " & s.name &
                (if s.role.len > 0: " (" & s.role & ")" else: "") &
                "   score " & $s.score)
      lines.add("     " & s.breakdown)

  lines.join("\n")

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

# ── Pool actions: assign / claim / submit ──────────────────────────
#
# Late-binding orchestration over a TASKS.md board. Caller posts
# (assign), anyone qualified pulls (claim), submitter closes (submit).
# Distinct from fan_out/pipeline/consensus/route — those are eager
# binding to NAMED peers; these are post-to-pool with state machine.
# Folded in from the former standalone `task` tool.

proc getTasksPath(t: CollaborateTool, team, lab: string): string =
  if lab != "":
    return t.workspace / "collaboration" / "labs" / lab / "TASKS.md"
  let teamName = if team == "": "default_squad" else: team
  return t.workspace / "collaboration" / "teams" / teamName / "TASKS.md"

proc doAssign(t: CollaborateTool, args: Table[string, JsonNode]): string =
  let task = if args.hasKey("task"): args["task"].getStr() else: ""
  if task == "": return "Error: 'task' is required for assign"
  let team = if args.hasKey("team"): args["team"].getStr() else: "default_squad"
  let lab = if args.hasKey("lab"): args["lab"].getStr() else: ""
  let path = t.getTasksPath(team, lab)
  if not fileExists(path): return "Error: Task board not found at " & path
  try:
    var lines = readFile(path).splitLines()
    var inserted = false
    var newLines: seq[string] = @[]
    for line in lines:
      newLines.add(line)
      if line.contains("## 🔴 To Do"):
        newLines.add("- [ ] " & task)
        inserted = true
    if not inserted:
      newLines.add("\n## 🔴 To Do")
      newLines.add("- [ ] " & task)
    writeFile(path, newLines.join("\n"))
    return "Task added to " & (if lab != "": lab else: team) & " board."
  except Exception as e:
    return "Error: " & e.msg

proc doClaim(t: CollaborateTool, args: Table[string, JsonNode]): string =
  let query = if args.hasKey("task_query"): args["task_query"].getStr().toLowerAscii() else: ""
  if query == "": return "Error: 'task_query' is required for claim"
  let team = if args.hasKey("team"): args["team"].getStr() else: "default_squad"
  let lab = if args.hasKey("lab"): args["lab"].getStr() else: ""
  let path = t.getTasksPath(team, lab)
  if not fileExists(path): return "Error: Task board not found."
  try:
    var lines = readFile(path).splitLines()
    var taskLineIdx = -1
    var inTodo = false
    for i, line in lines:
      if line.contains("## 🔴 To Do"): inTodo = true
      elif line.startsWith("##"): inTodo = false
      if inTodo and line.toLowerAscii().contains(query) and line.contains("[ ]"):
        taskLineIdx = i
        break
    if taskLineIdx == -1:
      return "Error: Task not found in 'To Do' section or already claimed."
    let taskText = lines[taskLineIdx].replace("- [ ]", "").strip()
    lines.delete(taskLineIdx)
    var inProgressIdx = -1
    for i, line in lines:
      if line.contains("## 🟡 In Progress"):
        inProgressIdx = i
        break
    let claimedLine = "- [ ] " & taskText & " @" & t.agentName
    if inProgressIdx != -1:
      lines.insert(claimedLine, inProgressIdx + 1)
    else:
      lines.add("\n## 🟡 In Progress")
      lines.add(claimedLine)
    writeFile(path, lines.join("\n"))
    return "Task claimed: '" & taskText & "'."
  except Exception as e:
    return "Error: " & e.msg

proc doSubmit(t: CollaborateTool, args: Table[string, JsonNode]): string =
  let query = if args.hasKey("task_query"): args["task_query"].getStr().toLowerAscii() else: ""
  if query == "": return "Error: 'task_query' is required for submit"
  let briefing = if args.hasKey("briefing"): args["briefing"].getStr() else: ""
  let team = if args.hasKey("team"): args["team"].getStr() else: "default_squad"
  let lab = if args.hasKey("lab"): args["lab"].getStr() else: ""
  let path = t.getTasksPath(team, lab)
  if not fileExists(path): return "Error: Task board not found."
  try:
    var lines = readFile(path).splitLines()
    var taskLineIdx = -1
    var inProgress = false
    for i, line in lines:
      if line.contains("## 🟡 In Progress"): inProgress = true
      elif line.startsWith("##") and not line.contains("In Progress"): inProgress = false
      if inProgress and line.toLowerAscii().contains(query):
        taskLineIdx = i
        break
    if taskLineIdx == -1:
      return "Error: Task not found in 'In Progress' list."
    let taskText = lines[taskLineIdx].replace("- [ ]", "").replace("@" & t.agentName, "").strip()
    lines.delete(taskLineIdx)
    var completedIdx = -1
    for i, line in lines:
      if line.contains("## 🟢 Completed"):
        completedIdx = i
        break
    let completedLine = "- [x] " & taskText
    if completedIdx != -1:
      lines.insert(completedLine, completedIdx + 1)
    else:
      lines.add("\n## 🟢 Completed")
      lines.add(completedLine)
    writeFile(path, lines.join("\n"))
    if briefing != "":
      let briefingDir = if lab != "": t.workspace / "collaboration" / "labs" / lab / "briefings"
                        else: t.workspace / "collaboration" / "teams" / team / "briefings"
      if dirExists(briefingDir):
        let bPath = briefingDir / "briefing_" & now().format("yyyyMMdd'_'HHmmss") & "_" & t.agentName.toLowerAscii() & ".md"
        writeFile(bPath, "# Briefing: " & taskText & "\n\nSubmitted by: " & t.agentName & "\n\n" & briefing)
        return "Task completed. Briefing saved."
    return "Task marked as completed."
  except Exception as e:
    return "Error: " & e.msg

method execute*(t: CollaborateTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  # Lenient on missing action — defaults to fan_out. Matches social /
  # capability defaulting style; reduces friction for the LLM's first
  # tool call.
  let action =
    if args.hasKey("method"): getMethodArg(args).strip().toLowerAscii()
    else: "fan_out"
  case action
  of "fan_out", "fanout", "fan-out":
    return await doFanOut(t, args)
  of "pipeline", "chain", "sequential":
    return await doPipeline(t, args)
  of "consensus", "vote", "synthesize":
    return await doConsensus(t, args)
  of "route", "pick", "recommend":
    return doRoute(t, args)
  of "assign", "post":
    return doAssign(t, args)
  of "claim", "pickup":
    return doClaim(t, args)
  of "submit", "complete", "finish":
    return doSubmit(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Eager (push to named): fan_out | pipeline | consensus | route. " &
           "Late (post to pool): assign | claim | submit."
