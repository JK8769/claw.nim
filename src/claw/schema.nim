import std/[json, strutils, options]

type
  CleaningStrategy* = enum
    Anthropic
    Gemini
    OpenAI
    Conservative

const GEMINI_UNSUPPORTED_KEYWORDS = [
  "$ref", "$schema", "$id", "$defs", "definitions",
  "additionalProperties", "patternProperties", "propertyNames",
  "minProperties", "maxProperties", "dependencies",
  "dependentRequired", "dependentSchemas", "if", "then", "else",
  "allOf", "anyOf", "oneOf", "not", "contains",
  "minContains", "maxContains", "unevaluatedItems",
  "unevaluatedProperties", "contentEncoding", "contentMediaType",
  "contentSchema", "const"
]

const ANTHROPIC_UNSUPPORTED_KEYWORDS = [
  "$schema", "$id", "$defs", "definitions", "additionalProperties"
]

const OPENAI_UNSUPPORTED_KEYWORDS = [
  "$schema"
]

const CONSERVATIVE_UNSUPPORTED_KEYWORDS = [
  "$schema", "$id", "$defs", "definitions", "additionalProperties"
]

# Keys to preserve when replacing a $ref with the resolved definition
const SCHEMA_META_KEYS = ["description", "title", "default"]

proc isUnsupported(key: string, strategy: CleaningStrategy): bool =
  case strategy:
    of Gemini:
      for k in GEMINI_UNSUPPORTED_KEYWORDS:
        if k == key: return true
    of Anthropic:
      for k in ANTHROPIC_UNSUPPORTED_KEYWORDS:
        if k == key: return true
    of OpenAI:
      for k in OPENAI_UNSUPPORTED_KEYWORDS:
        if k == key: return true
    of Conservative:
      for k in CONSERVATIVE_UNSUPPORTED_KEYWORDS:
        if k == key: return true
  return false

proc parseLocalRef(refValue: string): Option[string] =
  if refValue.startsWith("#/$defs/"):
    return some(refValue[8..^1])
  if refValue.startsWith("#/definitions/"):
    return some(refValue[14..^1])
  return none(string)

proc preserveMeta(orig: JsonNode, targetVal: JsonNode): JsonNode =
  if orig.kind != JObject or targetVal.kind != JObject:
    return targetVal
  
  var res = copy(targetVal)
  for k in SCHEMA_META_KEYS:
    if orig.hasKey(k) and not res.hasKey(k):
      res[k] = orig[k]
  return res

proc isNullTypeSchema(val: JsonNode): bool =
  if val.kind != JObject: return false
  if not val.hasKey("type"): return false
  
  let typ = val["type"]
  if typ.kind == JString and typ.getStr() == "null": return true
  
  if typ.kind == JArray:
    for item in typ:
      if item.kind == JString and item.getStr() == "null": return true
  
  return false

# Forward declarations for recursion
proc cleanValue(val: JsonNode, strategy: CleaningStrategy, defs: JsonNode, refStack: var seq[string]): JsonNode
proc cleanObject(obj: JsonNode, strategy: CleaningStrategy, defs: JsonNode, refStack: var seq[string]): JsonNode
proc trySimplifyUnion(obj: JsonNode, defs: JsonNode, strategy: CleaningStrategy, refStack: var seq[string]): Option[JsonNode]
proc cleanUnion(unionVal: JsonNode, strategy: CleaningStrategy, defs: JsonNode, refStack: var seq[string]): JsonNode

proc isJsonEqual(a, b: JsonNode): bool =
  if a.kind != b.kind: return false
  case a.kind:
  of JString: return a.getStr() == b.getStr()
  of JInt: return a.getInt() == b.getInt()
  of JFloat: return a.getFloat() == b.getFloat()
  of JBool: return a.getBool() == b.getBool()
  of JNull: return true
  of JArray:
    if a.len != b.len: return false
    for i in 0..<a.len:
      if not isJsonEqual(a[i], b[i]): return false
    return true
  of JObject:
    if a.len != b.len: return false
    for k, v in a.pairs:
      if not b.hasKey(k) or not isJsonEqual(b[k], v): return false
    return true

proc tryFlattenLiteralUnion(variants: openArray[JsonNode]): Option[JsonNode] =
  # Only supported if all variants are const or enum strings
  if variants.len == 0: return none(JsonNode)
  
  var enumValues = newJArray()
  var commonDef: JsonNode = nil
  var firstDefSet = false
  
  for variant in variants:
    if variant.kind != JObject: return none(JsonNode)
    
    # Needs to be a string type
    if not variant.hasKey("type") or variant["type"].kind != JString or variant["type"].getStr() != "string":
      return none(JsonNode)
    
    if variant.hasKey("const"):
      let cVal = variant["const"]
      if cVal.kind != JString: return none(JsonNode)
      enumValues.add(cVal)
    elif variant.hasKey("enum"):
      let eVal = variant["enum"]
      if eVal.kind != JArray: return none(JsonNode)
      for e in eVal:
        if e.kind != JString: return none(JsonNode)
        enumValues.add(e)
    else:
      # Found a variant that is just a standard string without enum constraints.
      # This means we can't cleanly flatten the whole union into a strict string enum.
      return none(JsonNode)
      
    # Validate definitions matching by removing const and enum and verifying the rest
    var checkDef = newJObject()
    for k, v in variant.pairs:
      if k != "const" and k != "enum":
        checkDef[k] = v
    
    if commonDef == nil:
      commonDef = checkDef
    else:
      if not isJsonEqual(commonDef, checkDef): 
        return none(JsonNode)
      
  # Flattening success
  if commonDef == nil: return none(JsonNode)
  var res = copy(commonDef)
  res["enum"] = enumValues
  return some(res)


proc trySimplifyUnion(obj: JsonNode, defs: JsonNode, strategy: CleaningStrategy, refStack: var seq[string]): Option[JsonNode] =
  var unionKey = ""
  if obj.hasKey("anyOf"): unionKey = "anyOf"
  elif obj.hasKey("oneOf"): unionKey = "oneOf"
  else: return none(JsonNode)
  
  let variants = obj[unionKey]
  if variants.kind != JArray: return none(JsonNode)
  
  var nonNullVariants = newSeq[JsonNode]()
  var hasNull = false
  
  for rawVariant in variants:
    if isNullTypeSchema(rawVariant):
      hasNull = true
    else:
      nonNullVariants.add(rawVariant)
      
  # 1. Single non-null variant + null
  if nonNullVariants.len == 1 and hasNull:
    var simplified = copy(nonNullVariants[0])
    # Add null to types if it's an array or string
    if simplified.kind == JObject and simplified.hasKey("type"):
      let typ = simplified["type"]
      if typ.kind == JString:
        simplified["type"] = %*[typ.getStr(), "null"]
      elif typ.kind == JArray:
        var newTypes = copy(typ)
        newTypes.add(%*"null")
        simplified["type"] = newTypes
    return some(preserveMeta(obj, simplified))
  
  # 2. String literal union (e.g. enum merging)
  let flattened = tryFlattenLiteralUnion(nonNullVariants)
  if flattened.isSome:
    var simplified = flattened.get()
    if hasNull:
       if simplified.hasKey("type"):
         let typ = simplified["type"]
         if typ.kind == JString:
           simplified["type"] = %*[typ.getStr(), "null"]
         elif typ.kind == JArray:
           var newTypes = copy(typ)
           newTypes.add(%*"null")
           simplified["type"] = newTypes
    # For flattened literal unions, we actually need to bypass Gemini's strict "enum" unsupported block
    # so we return a magic wrapper or we just don't clean the enum property later.
    # Wait, the enum property is in GEMINI_UNSUPPORTED_KEYWORDS? No, "enum" is NOT unsupported by Gemini!
    # "const" is unsupported. "enum" is totally fine!
    return some(preserveMeta(obj, simplified))
      
  return none(JsonNode)


proc cleanUnion(unionVal: JsonNode, strategy: CleaningStrategy, defs: JsonNode, refStack: var seq[string]): JsonNode =
  if unionVal.kind != JArray:
    return cleanValue(unionVal, strategy, defs, refStack)
    
  var res = newJArray()
  for item in unionVal:
    res.add(cleanValue(item, strategy, defs, refStack))
  return res


proc resolveRef(refValue: string, obj: JsonNode, defs: JsonNode, strategy: CleaningStrategy, refStack: var seq[string]): JsonNode =
  let localNameOpt = parseLocalRef(refValue)
  if localNameOpt.isSome:
    let localName = localNameOpt.get()
    
    # cycle detection
    for s in refStack:
      if s == localName:
        # cyclic ref, return empty obj + meta
        return preserveMeta(obj, newJObject())
        
    if defs.kind == JObject and defs.hasKey(localName):
      refStack.add(localName)
      defer: discard refStack.pop()
      
      let resolved = cleanValue(defs[localName], strategy, defs, refStack)
      return preserveMeta(obj, resolved)
      
  # Unresolvable ref: return empty obj + meta
  return preserveMeta(obj, newJObject())
  

proc cleanObject(obj: JsonNode, strategy: CleaningStrategy, defs: JsonNode, refStack: var seq[string]): JsonNode =
  # Handle $ref resolution
  if obj.hasKey("$ref") and obj["$ref"].kind == JString:
    return resolveRef(obj["$ref"].getStr(), obj, defs, strategy, refStack)
    
  # Try simplification for union arrays if this provider can't handle them
  if strategy == Gemini:
    let simplified = trySimplifyUnion(obj, defs, strategy, refStack)
    if simplified.isSome:
      return cleanValue(simplified.get(), strategy, defs, refStack)
      
  # Check if anything remains after potential simplifications
  var cleaned = newJObject()
  for key, value in obj.pairs:
    if isUnsupported(key, strategy):
       continue
       
    if key == "anyOf" or key == "oneOf" or key == "allOf":
      cleaned[key] = cleanUnion(value, strategy, defs, refStack)
    else:
      cleaned[key] = cleanValue(value, strategy, defs, refStack)
      
  return cleaned


proc cleanValue(val: JsonNode, strategy: CleaningStrategy, defs: JsonNode, refStack: var seq[string]): JsonNode =
  case val.kind:
  of JObject:
    return cleanObject(val, strategy, defs, refStack)
  of JArray:
    var arr = newJArray()
    for item in val:
      arr.add(cleanValue(item, strategy, defs, refStack))
    return arr
  else:
    return val

proc extractDefs(root: JsonNode): JsonNode =
  if root.kind != JObject:
    return newJObject()
    
  if root.hasKey("$defs"):
    let d = root["$defs"]
    if d.kind == JObject: return d
  
  if root.hasKey("definitions"):
    let d = root["definitions"]
    if d.kind == JObject: return d
    
  return newJObject()


proc cleanForStrategy*(schema: JsonNode, strategy: CleaningStrategy): JsonNode =
  ## Cleans a JSON schema according to the specified provider strategy
  ## Returns the modified clean JsonNode
  let defs = extractDefs(schema)
  var refStack = newSeq[string]()
  let cleaned = cleanValue(schema, strategy, defs, refStack)
  return cleaned

proc cleanForStrategy*(schemaJson: string, strategy: CleaningStrategy): string =
  ## Parses schema JSON strings, cleans them, and returns raw JSON string
  let j = parseJson(schemaJson)
  let cleaned = cleanForStrategy(j, strategy)
  return $cleaned

proc cleanForGemini*(schema: JsonNode): JsonNode =
  return cleanForStrategy(schema, Gemini)

proc cleanForAnthropic*(schema: JsonNode): JsonNode =
  return cleanForStrategy(schema, Anthropic)

proc cleanForOpenAI*(schema: JsonNode): JsonNode =
  return cleanForStrategy(schema, OpenAI)

proc inferStrategy*(model: string): CleaningStrategy =
  ## Infer the schema cleaning strategy from a model name.
  let lower = model.toLowerAscii
  if lower.contains("claude") or model.startsWith("anthropic/"):
    return Anthropic
  elif lower.contains("gpt") or model.startsWith("openai/") or model.startsWith("deepseek/"):
    return OpenAI
  return Gemini
