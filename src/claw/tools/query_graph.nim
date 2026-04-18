import std/[json, asyncdispatch, tables]
import ../tools/base
import ../agent/cortex
import ../agent/context

type
  QueryGraphTool* = ref object of Tool
    builder*: ContextBuilder

proc newQueryGraphTool*(builder: ContextBuilder): QueryGraphTool =
  result = QueryGraphTool(builder: builder)

method name*(t: QueryGraphTool): string = "query_graph"

method description*(t: QueryGraphTool): string = 
  "Query the agent-customer graph using JSE (JSON Structural Expression) logic. Use for complex filtering, traversal, and data retrieval."

method parameters*(t: QueryGraphTool): Table[string, JsonNode] = 
  {
    "type": %"object",
    "properties": %*{
      "expression": %*{
        "type": "array",
        "items": { "type": "string" }, # Important: item type must be specified for OpenAI compatibility
        "description": "A JSE array: [function, ...args]. Example: [\"filter\", \"Person\"] or [\"relationships\", \"nc:1\", \"serves\"]"
      }
    },
    "required": %["expression"]
  }.toTable

method execute*(t: QueryGraphTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.builder.graph == nil:
    return "Error: World Graph is not initialized."

  if not args.hasKey("expression"):
    return "Error: Missing 'expression' argument."

  let jse = args["expression"]
  try:
    let result = t.builder.graph.evalJSE(jse)
    return result.pretty()
  except:
    return "Error evaluating JSE: " & getCurrentExceptionMsg()
