import std/[asyncdispatch, json, tables, strutils, os, sequtils]
import types

type
  JqTool* = ref object of ContextualTool
    workspace*: string

proc newJqTool*(workspace: string): JqTool =
  JqTool(workspace: workspace)

method name*(t: JqTool): string = "json_query"
method description*(t: JqTool): string = "Query JSON/JSONL files using jq-like expressions. Supports field extraction (.field), filtering (select(.key == \"val\")), projection ({f1, f2}), and counting (length). Works on both JSON and JSONL files."
method parameters*(t: JqTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "file": {
        "type": "string",
        "description": "Path to the JSON or JSONL file to query"
      },
      "filter": {
        "type": "string",
        "description": "jq-style filter expression. Examples: '.' (all), '.field' (extract), 'select(.state == \"closed\")' (filter), '{taskId, tokensTotal}' (project), 'select(.tokensTotal > 5000) | {taskId, tokensTotal}' (chain), 'length' (count)"
      },
      "limit": {
        "type": "integer",
        "description": "Max results to return (default: 50)"
      }
    },
    "required": %["file"]
  }.toTable

# ── Filter Engine ──────────────────────────────────────────────────

type
  FilterOp = enum
    foIdentity      # .
    foField          # .field or .field.nested
    foSelect         # select(.field == "val")
    foProject        # {f1, f2}
    foLength         # length
    foChain          # expr | expr

  SelectComparator = enum
    scEq, scNeq, scGt, scLt, scGte, scLte, scContains

  FilterExpr = ref object
    case op: FilterOp
    of foIdentity: discard
    of foField:
      fieldPath: seq[string]
    of foSelect:
      selectField: seq[string]
      comparator: SelectComparator
      selectVal: JsonNode
    of foProject:
      projectFields: seq[string]
    of foLength: discard
    of foChain:
      left: FilterExpr
      right: FilterExpr

proc getNestedField(j: JsonNode, path: seq[string]): JsonNode =
  var current = j
  for p in path:
    if current.kind != JObject or not current.hasKey(p):
      return newJNull()
    current = current[p]
  return current

proc parseFieldPath(s: string): seq[string] =
  ## Parse ".field.nested" into @["field", "nested"]
  let clean = s.strip()
  if clean == "." or clean == "": return @[]
  var path = clean
  if path.startsWith("."): path = path[1..^1]
  return path.split(".")

proc parseSelectExpr(s: string): FilterExpr =
  ## Parse select(.field == "val") or select(.field > 100)
  var inner = s.strip()
  if inner.startsWith("select(") and inner.endsWith(")"):
    inner = inner[7..^2].strip()
  
  var comparator = scEq
  var parts: seq[string] = @[]
  
  if inner.contains("!="):
    parts = inner.split("!=", 1)
    comparator = scNeq
  elif inner.contains(">="):
    parts = inner.split(">=", 1)
    comparator = scGte
  elif inner.contains("<="):
    parts = inner.split("<=", 1)
    comparator = scLte
  elif inner.contains("=="):
    parts = inner.split("==", 1)
    comparator = scEq
  elif inner.contains(">"):
    parts = inner.split(">", 1)
    comparator = scGt
  elif inner.contains("<"):
    parts = inner.split("<", 1)
    comparator = scLt
  else:
    # Boolean field test: select(.field)
    let field = parseFieldPath(inner)
    return FilterExpr(op: foSelect, selectField: field, comparator: scNeq, selectVal: newJNull())
  
  if parts.len != 2:
    return FilterExpr(op: foIdentity)
  
  let field = parseFieldPath(parts[0].strip())
  let valStr = parts[1].strip()
  
  var val: JsonNode
  if valStr.startsWith("\"") and valStr.endsWith("\""):
    val = %valStr[1..^2]
  elif valStr == "true":
    val = %true
  elif valStr == "false":
    val = %false
  elif valStr == "null":
    val = newJNull()
  else:
    try:
      val = %parseInt(valStr)
    except:
      try:
        val = %parseFloat(valStr)
      except:
        val = %valStr
  
  return FilterExpr(op: foSelect, selectField: field, comparator: comparator, selectVal: val)

proc parseProjectExpr(s: string): FilterExpr =
  ## Parse {field1, field2, field3}
  var inner = s.strip()
  if inner.startsWith("{") and inner.endsWith("}"):
    inner = inner[1..^2]
  let fields = inner.split(",").mapIt(it.strip().strip(chars = {'.'}))
  return FilterExpr(op: foProject, projectFields: fields)

proc parseSingleExpr(s: string): FilterExpr =
  let trimmed = s.strip()
  if trimmed == ".":
    return FilterExpr(op: foIdentity)
  elif trimmed == "length":
    return FilterExpr(op: foLength)
  elif trimmed.startsWith("select("):
    return parseSelectExpr(trimmed)
  elif trimmed.startsWith("{"):
    return parseProjectExpr(trimmed)
  elif trimmed.startsWith("."):
    return FilterExpr(op: foField, fieldPath: parseFieldPath(trimmed))
  else:
    return FilterExpr(op: foIdentity)

proc parseFilter(s: string): FilterExpr =
  ## Parse a jq filter expression, supporting | chaining
  let trimmed = s.strip()
  if trimmed == "" or trimmed == ".":
    return FilterExpr(op: foIdentity)
  
  # Handle pipe chains: expr1 | expr2 | expr3
  # Be careful not to split pipes inside select()
  var parts: seq[string] = @[]
  var current = ""
  var parenDepth = 0
  for c in trimmed:
    if c == '(': parenDepth += 1
    elif c == ')': parenDepth -= 1
    elif c == '|' and parenDepth == 0:
      parts.add(current.strip())
      current = ""
      continue
    current.add(c)
  if current.strip() != "":
    parts.add(current.strip())
  
  if parts.len == 1:
    return parseSingleExpr(parts[0])
  
  # Build chain from left to right
  var chain = parseSingleExpr(parts[0])
  for i in 1 ..< parts.len:
    chain = FilterExpr(op: foChain, left: chain, right: parseSingleExpr(parts[i]))
  return chain

proc compareJson(a, b: JsonNode, cmp: SelectComparator): bool =
  case cmp
  of scEq:
    if a.kind != b.kind: return false
    case a.kind
    of JString: return a.getStr() == b.getStr()
    of JInt: return a.getInt() == b.getInt()
    of JFloat: return a.getFloat() == b.getFloat()
    of JBool: return a.getBool() == b.getBool()
    of JNull: return true
    else: return $a == $b
  of scNeq: return not compareJson(a, b, scEq)
  of scGt:
    if a.kind == JInt and b.kind == JInt: return a.getInt() > b.getInt()
    if a.kind == JFloat or b.kind == JFloat: return a.getFloat() > b.getFloat()
    return false
  of scLt:
    if a.kind == JInt and b.kind == JInt: return a.getInt() < b.getInt()
    if a.kind == JFloat or b.kind == JFloat: return a.getFloat() < b.getFloat()
    return false
  of scGte:
    if a.kind == JInt and b.kind == JInt: return a.getInt() >= b.getInt()
    if a.kind == JFloat or b.kind == JFloat: return a.getFloat() >= b.getFloat()
    return false
  of scLte:
    if a.kind == JInt and b.kind == JInt: return a.getInt() <= b.getInt()
    if a.kind == JFloat or b.kind == JFloat: return a.getFloat() <= b.getFloat()
    return false
  of scContains:
    if a.kind == JString and b.kind == JString:
      return b.getStr() in a.getStr()
    return false

proc applyFilter(j: JsonNode, expr: FilterExpr): (bool, JsonNode) =
  ## Returns (matched, result). matched=false means filter out this row.
  case expr.op
  of foIdentity:
    return (true, j)
  of foField:
    return (true, getNestedField(j, expr.fieldPath))
  of foSelect:
    let fieldVal = getNestedField(j, expr.selectField)
    if compareJson(fieldVal, expr.selectVal, expr.comparator):
      return (true, j)
    else:
      return (false, j)
  of foProject:
    var obj = newJObject()
    for f in expr.projectFields:
      let path = f.split(".")
      obj[f] = getNestedField(j, path)
    return (true, obj)
  of foLength:
    case j.kind
    of JArray: return (true, %j.len)
    of JObject: return (true, %j.len)
    of JString: return (true, %j.getStr().len)
    else: return (true, %0)
  of foChain:
    let (matched, intermediate) = applyFilter(j, expr.left)
    if not matched: return (false, j)
    return applyFilter(intermediate, expr.right)

# ── Tool Execution ─────────────────────────────────────────────────

method execute*(t: JqTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("file"):
    return "Error: 'file' parameter is required"
  
  let filePath = args["file"].getStr()
  let filter = if args.hasKey("filter"): args["filter"].getStr() else: "."
  let limit = if args.hasKey("limit"): args["limit"].getInt() else: 50
  
  if not fileExists(filePath):
    return "Error: File not found: " & filePath
  
  let expr = parseFilter(filter)
  let content = readFile(filePath)
  let isJsonl = filePath.endsWith(".jsonl") or filePath.endsWith(".ndjson")
  
  var results: seq[JsonNode] = @[]
  
  if isJsonl:
    # Process line by line
    for line in content.splitLines():
      let trimmed = line.strip()
      if trimmed == "": continue
      try:
        let j = parseJson(trimmed)
        let (matched, result) = applyFilter(j, expr)
        if matched:
          results.add(result)
          if results.len >= limit: break
      except:
        continue  # Skip malformed lines
  else:
    # Single JSON document
    try:
      let j = parseJson(content)
      if j.kind == JArray:
        for item in j:
          let (matched, result) = applyFilter(item, expr)
          if matched:
            results.add(result)
            if results.len >= limit: break
      else:
        let (matched, result) = applyFilter(j, expr)
        if matched:
          results.add(result)
    except Exception as e:
      return "Error parsing JSON: " & e.msg
  
  # Special case: length on the full result set
  if filter.strip() == "length":
    if isJsonl:
      # Count all matching lines
      var count = 0
      for line in content.splitLines():
        let trimmed = line.strip()
        if trimmed != "": count += 1
      return $count
    elif results.len == 1:
      return $results[0]
  
  if results.len == 0:
    return "No results matching filter: " & filter
  
  # Format output
  var output: seq[string] = @[]
  for r in results:
    if r.kind == JObject or r.kind == JArray:
      output.add(pretty(r))
    else:
      output.add($r)
  
  let joined = output.join("\n")
  
  # Truncate if too long
  let maxLen = 8000
  if joined.len > maxLen:
    return joined[0 ..< maxLen] & "\n... (truncated, " & $(results.len) & " total results)"
  
  return joined
