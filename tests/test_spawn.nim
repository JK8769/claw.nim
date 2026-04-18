import std/unittest
import ../src/nimclaw/tools/spawn
import ../src/nimclaw/tools/subagent
import std/[json, tables, asyncdispatch, strutils]

suite "Spawn Tool Unit Tests":
  test "spawn missing task parameter fails":
    var st = newSpawnTool(nil)
    let args = {"label": %"test"}.toTable
    let result = waitFor st.execute(args)
    check result.contains("Missing 'task'")

  test "spawn empty task string fails":
    var st = newSpawnTool(nil)
    let args = {"task": %"   "}.toTable
    let result = waitFor st.execute(args)
    check result.contains("must not be empty")

  test "spawn empty agent string fails":
    var st = newSpawnTool(nil)
    let args = {
      "task": %"do something",
      "agent": %"  "
    }.toTable
    let result = waitFor st.execute(args)
    check result.contains("must not be empty")

  test "spawn without manager fails":
    var st = newSpawnTool(nil)
    let args = {"task": %"do something"}.toTable
    let result = waitFor st.execute(args)
    check result.contains("SubagentManager")

  test "spawn schema includes agent property":
    var st = newSpawnTool(nil)
    let schema = st.parameters()
    check schema["properties"].hasKey("agent")
