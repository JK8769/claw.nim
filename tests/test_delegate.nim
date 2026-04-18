import std/[unittest, json, jsonutils, options, asyncdispatch, tables, strutils]
import ../src/nimclaw/config
import ../src/nimclaw/tools/[types, delegate]

suite "Delegate Tool":
  setup:
    var dt = newDelegateTool(
      agents = @[
        NamedAgentConfig(name: "researcher", provider: "test", model: "test", maxDepth: 3),
        NamedAgentConfig(name: "shallow", provider: "test", model: "test", maxDepth: 1),
        NamedAgentConfig(name: "deep", provider: "test", model: "test", maxDepth: 10)
      ],
      fallbackApiKey = some("sk-test"),
      depth = 1
    )
    let t = dt

  test "delegate tool name":
    check t.name() == "delegate"

  test "delegate schema has agent and prompt":
    let schema = t.parameters()
    check schema.hasKey("properties")
    check schema["properties"].hasKey("agent")
    check schema["properties"].hasKey("prompt")
    check schema["properties"].hasKey("context")
    check schema.hasKey("required")

  test "delegate blank agent rejected":
    let args = {"agent": %"  ", "prompt": %"test"}.toTable
    let res = waitFor t.execute(args)
    check res.contains("must not be empty")

  test "delegate blank prompt rejected":
    let args = {"agent": %"researcher", "prompt": %"  "}.toTable
    let res = waitFor t.execute(args)
    check res.contains("must not be empty")

  test "delegate depth limit enforced":
    var shallowDt = newDelegateTool(
      agents = @[NamedAgentConfig(name: "researcher", provider: "test", model: "test", maxDepth: 3)],
      fallbackApiKey = some("sk-test"),
      depth = 3
    )
    let shallowT = shallowDt
    let args = {"agent": %"researcher", "prompt": %"test"}.toTable
    let res = waitFor shallowT.execute(args)
    check res.contains("depth limit reached")

  test "delegate per-agent max_depth":
    let argsShallow = {"agent": %"shallow", "prompt": %"test"}.toTable
    let resShallow = waitFor t.execute(argsShallow)
    check resShallow.contains("depth limit reached")

    let argsDeep = {"agent": %"deep", "prompt": %"test"}.toTable
    let resDeep = waitFor t.execute(argsDeep)
    check not resDeep.contains("depth") # Fails for other reasons (provider mock), not depth
