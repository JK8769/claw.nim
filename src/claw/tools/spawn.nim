import std/[asyncdispatch, json, tables, strutils]
import types
import subagent

type
  SpawnTool* = ref object of ContextualTool
    manager*: SubagentManager

proc newSpawnTool*(manager: SubagentManager): SpawnTool =
  SpawnTool(
    manager: manager
  )

method name*(t: SpawnTool): string = "spawn"
method description*(t: SpawnTool): string =
  ## Description includes the registered modes so the LLM sees what
  ## focus modes are available without the operator having to keep a
  ## parallel doc in sync.
  var d = "Spawn a focused subtask of yourself. The subagent runs as " &
          "you (same identity, same authority) but with an optional " &
          "MODE that constrains its tools and adds a focused prompt. " &
          "Use this when you want to do a chunk of work in parallel " &
          "or in isolation — same agent wearing a different hat.\n\n" &
          "Pass `await: true` to block on the result and return it " &
          "directly (cognitively simplest). Pass `await: false` (or " &
          "omit) for fire-and-forget — the result arrives later as a " &
          "separate notification."
  if t.manager != nil:
    let modes = t.manager.availableModes()
    if modes.len > 0:
      d.add("\n\nAvailable modes:")
      for m in modes:
        d.add("\n  - `" & m.name & "`: " & m.description)
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
      "mode": {
        "type": "string",
        "description": "Focus mode the subagent runs in (Plan / Explore / etc — see tool description for what's available). Empty = default mode (full tool access)."
      },
      "await": {
        "type": "boolean",
        "description": "If true, block until the subagent completes and return its result as the tool's value. Use this when the result informs your next decision. If false (default), fire-and-forget — return a task ID and the result arrives later."
      },
      "agent": {
        "type": "string",
        "description": "Optional override to run AS A DIFFERENT AGENT (e.g. delegate to Atlas). Different from `mode` — this swaps identity, mode just changes focus within your own identity."
      }
    },
    "required": %["task"]
  }.toTable

method execute*(t: SpawnTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("task"): return "Error: Missing 'task' parameter"
  let task = args["task"].getStr().strip()
  if task == "": return "Error: 'task' must not be empty"

  let label = if args.hasKey("label"): args["label"].getStr() else: "subagent"

  var agentName = ""
  if args.hasKey("agent"):
    agentName = args["agent"].getStr().strip()
    if agentName == "": return "Error: 'agent' must not be empty"

  let mode = if args.hasKey("mode"): args["mode"].getStr().strip() else: ""
  let waitForResult = args.hasKey("await") and
                      args["await"].kind == JBool and
                      args["await"].getBool()

  if t.manager == nil:
    return "Error: Spawn tool not connected to SubagentManager"

  if mode.len > 0 and not t.manager.modes.hasKey(mode):
    var available: seq[string]
    for m in t.manager.modes.keys: available.add(m)
    return "Error: unknown mode '" & mode & "'. " &
           (if available.len > 0: "Available: " & available.join(", ")
            else: "No modes are configured for this company.")

  let taskObj = t.manager.spawn(task, label, t.channel, t.chatID,
                                t.sessionKey, t.senderID, t.recipientID,
                                t.role, t.agentName, t.agentID,
                                t.logicalUserID, agentName, mode)

  if waitForResult:
    # Synchronous shape: poll until the task finishes, then return its
    # result as the tool's value. Uses the same task-completion
    # mechanism as the fire-and-forget path; the difference is just
    # that we wait here instead of letting the bus surface the
    # result via a separate inbound.
    while taskObj.status notin ["completed", "failed"]:
      await sleepAsync(200)
    return taskObj.result

  return "Spawned subagent '" & label & "' with ID " & taskObj.id &
         (if mode.len > 0: " in mode '" & mode & "'" else: "") &
         " for task: " & task
