import std/[asyncdispatch, json, tables, strutils, locks, times]
import ../types
import ../spec
import subagent

const ToolSpec* = spec(
  name = "spawn",
  description = "spawn autonomous sub-agents for tasks (focus_modes)",
  tags = @["agent", "automation"],
  domain = "agent",
  default = true,
  heartbeatSafe = false,
  category = "self-management",
)

const
  AwaitPollIntervalMs = 200    ## Sleep between status polls.
  AwaitTimeoutMs = 10 * 60 * 1000
                               ## Hard deadline on `await: true` (10
                               ## minutes). Beyond this we surface a
                               ## timeout error rather than block the
                               ## parent loop forever — a stuck
                               ## subagent should not deadlock its
                               ## caller.

type
  SpawnTool* = ref object of ContextualTool
    manager*: SubagentManager
    cachedDescription: string  ## Built the first time `description`
                               ## runs and reused after. Focus modes
                               ## are fixed at construction, so the
                               ## per-iteration `toolToSchema` path
                               ## doesn't need to re-render the list.

proc newSpawnTool*(manager: SubagentManager): SpawnTool =
  SpawnTool(
    manager: manager
  )

method name*(t: SpawnTool): string = "spawn"
method description*(t: SpawnTool): string =
  ## Includes the registered focus modes so the LLM sees what's
  ## available without the operator maintaining a parallel doc.
  ## Cached after first build — focus modes don't change at runtime.
  ##
  ## Spawn is INTRA-AGENT (same identity, different hat). Use
  ## `delegate` for cross-agent dispatch — the previous `agent:`
  ## override on this tool was a footgun that duplicated delegate
  ## with worse semantics; it has been removed.
  if t.cachedDescription.len > 0: return t.cachedDescription
  var d = "Spawn a focused subtask of yourself. The subagent runs as " &
          "you (same identity, same authority, same model) but with " &
          "an optional FOCUS_MODE that constrains its tools and adds " &
          "a focused prompt. Use this when you want to do a chunk of " &
          "work in a different mental mode — same agent wearing a " &
          "different hat.\n\n" &
          "For cross-agent dispatch (handing work to a peer agent), " &
          "use the `delegate` tool instead.\n\n" &
          "Pass `await: true` to block on the result and return it " &
          "directly (cognitively simplest). Pass `await: false` (or " &
          "omit) for fire-and-forget — the result arrives later as a " &
          "separate notification."
  if t.manager != nil:
    let modes = t.manager.availableFocusModes()
    if modes.len > 0:
      d.add("\n\nAvailable focus_modes:")
      for m in modes:
        d.add("\n  - `" & m.name & "`: " & m.description)
  t.cachedDescription = d
  d

method parameters*(t: SpawnTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "task": {
        "type": "string",
        "description": "The task for the subagent to complete. Be specific — the subagent doesn't see your conversation history, only this prompt."
      },
      "label": {
        "type": "string",
        "description": "Short label for display (e.g. 'plan-v6-refactor', 'find-auth-handling')"
      },
      "focus_mode": {
        "type": "string",
        "description": "Focus mode the subagent runs in (Plan / Implement / Review / etc — see tool description for what's available). Empty = default focus_mode (full tool access)."
      },
      "await": {
        "type": "boolean",
        "description": "If true, block until the subagent completes and return its result as the tool's value. Use this when the result informs your next decision. If false (default), fire-and-forget — return a task ID and the result arrives later."
      }
    },
    "required": %["task"]
  }.toTable

method execute*(t: SpawnTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("task"): return "Error: Missing 'task' parameter"
  let task = args["task"].getStr().strip()
  if task == "": return "Error: 'task' must not be empty"

  let label = if args.hasKey("label"): args["label"].getStr() else: "subagent"

  # Reject any caller still passing `agent:`. The parameter has been
  # removed — direct them at the right tool. Soft-fail with a clear
  # message rather than silently dropping the override.
  if args.hasKey("agent") and args["agent"].kind == JString and
     args["agent"].getStr().strip().len > 0:
    return "Error: `spawn` no longer accepts an `agent:` override. " &
           "Use the `delegate` tool to hand work to a peer agent " &
           "(different identity). `spawn` is intra-agent only — same " &
           "identity, focus_mode changes the hat."

  let focusMode =
    if args.hasKey("focus_mode"): args["focus_mode"].getStr().strip()
    else: ""
  let waitForResult = args.hasKey("await") and
                      args["await"].kind == JBool and
                      args["await"].getBool()

  if t.manager == nil:
    return "Error: Spawn tool not connected to SubagentManager"

  if focusMode.len > 0 and not t.manager.hasFocusMode(focusMode):
    let available = t.manager.availableFocusModes()
    var names: seq[string]
    for m in available: names.add(m.name)
    return "Error: unknown focus_mode '" & focusMode & "'. " &
           (if names.len > 0: "Available: " & names.join(", ")
            else: "No focus_modes are configured for this company.")

  let taskObj = t.manager.spawn(task, label, t.channel, t.chatID,
                                t.sessionKey, t.senderID, t.recipientID,
                                t.role, t.agentName, t.agentID,
                                t.logicalUserID, "", focusMode,
                                awaitMode = waitForResult)

  if waitForResult:
    # Synchronous shape: poll until the task finishes, then return its
    # result as the tool's value. The status is mutated by `runTask`
    # under `manager.lock`, so we acquire the lock for the read — a
    # bare unsynchronised access is a data race in the Nim memory model.
    # The deadline guards against a hung subagent deadlocking the
    # parent loop indefinitely.
    let started = getTime().toUnix * 1000
    while true:
      acquire(t.manager.lock)
      let status = taskObj.status
      release(t.manager.lock)
      if status == "completed" or status == "failed": break
      if (getTime().toUnix * 1000) - started > AwaitTimeoutMs:
        return "Error: subagent '" & label & "' (id " & taskObj.id &
               ") did not complete within " & $(AwaitTimeoutMs div 60000) &
               " minutes. It may still finish — its result will arrive " &
               "as a separate notification."
      await sleepAsync(AwaitPollIntervalMs)
    return taskObj.result

  return "Spawned subagent '" & label & "' (id " & taskObj.id & ")" &
         (if focusMode.len > 0: " in focus_mode '" & focusMode & "'" else: "") &
         " for task: " & task
