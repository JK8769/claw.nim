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
method description*(t: SpawnTool): string = "Spawn a subagent to handle a task in the background. Use this for complex or time-consuming tasks that can run independently. The subagent will complete the task and report back when done."
method parameters*(t: SpawnTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "task": {
        "type": "string",
        "description": "The task for subagent to complete"
      },
      "label": {
        "type": "string",
        "description": "Optional short label for the task (for display)"
      },
      "agent": {
        "type": "string",
        "description": "Optional named agent profile for provider/model override"
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

  if t.manager == nil:
    return "Error: Spawn tool not connected to SubagentManager"

  let taskObj = t.manager.spawn(task, label, t.channel, t.chatID, t.sessionKey, t.senderID, t.recipientID, t.role, t.agentName, t.agentID, t.logicalUserID, agentName)
  return "Spawned subagent '" & label & "' with ID " & taskObj.id & " for task: " & task
