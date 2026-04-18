## XML Tool Calling Protocol for providers that don't support native tool_calls.
##
## When a provider (like Opencode) can't handle native OpenAI-spec tool calling,
## we fall back to an XML-based text protocol:
## 1. Tool descriptions and usage instructions go into the system prompt
## 2. The LLM outputs <tool_call>{"name": "...", "arguments": {...}}</tool_call>
##    - Also supports <tool> tags and case-insensitive matching.
## 3. We parse the tags, execute the tools, and format results as <tool_result>
## 4. Results go back as a plain "user" message, and we loop

import std/[strutils, json, tables]
import ../tools/registry as tools_registry
import ../tools/types


type
  XmlToolCall* = object
    name*: string
    arguments*: Table[string, JsonNode]

  XmlToolResult* = object
    name*: string
    output*: string
    success*: bool

proc parseXmlToolCalls*(response: string): seq[XmlToolCall] =
  ## Parse <tool_call> or <tool> tags from LLM response text.
  ## Returns a sequence of parsed tool calls. Text outside tags is ignored.
  result = @[]

  proc parseProviderToolCallTokens(): seq[XmlToolCall] =
    ## Parse OpenAI-function-call style sentinel tokens occasionally emitted by some models:
    ## <|tool_call_begin|> functions.<name>:<idx> <|tool_call_argument_begin|> {json} <|tool_call_end|>
    result = @[]
    let s = response
    let lower = s.toLowerAscii()
    var i = 0
    while true:
      let beginIdx = lower.find("<|tool_call_begin|>", i)
      if beginIdx < 0:
        break
      let fnIdx = lower.find("functions.", beginIdx)
      if fnIdx < 0:
        i = beginIdx + 1
        continue
      let nameStart = fnIdx + "functions.".len
      let nameEnd = lower.find(":", nameStart)
      if nameEnd < 0:
        i = beginIdx + 1
        continue
      let toolName = s[nameStart ..< nameEnd].strip()
      let argBegin = lower.find("<|tool_call_argument_begin|>", nameEnd)
      if argBegin < 0:
        i = beginIdx + 1
        continue
      let jsonStart = argBegin + "<|tool_call_argument_begin|>".len
      let endIdx = lower.find("<|tool_call_end|>", jsonStart)
      if endIdx < 0:
        i = beginIdx + 1
        continue
      let jsonStr = s[jsonStart ..< endIdx].strip()
      if toolName.len == 0 or jsonStr.len == 0:
        i = endIdx + 1
        continue
      try:
        let parsed = parseJson(jsonStr)
        var args = initTable[string, JsonNode]()
        if parsed.kind == JObject:
          for k, v in parsed.pairs:
            args[k] = v
        else:
          args["value"] = parsed
        result.add(XmlToolCall(name: toolName, arguments: args))
      except:
        discard
      i = endIdx + "<|tool_call_end|>".len

  let tokenCalls = parseProviderToolCallTokens()
  if tokenCalls.len > 0:
    return tokenCalls

  let lowerResponse = response.toLowerAscii()
  var lastIdx = 0

  while true:
    # Find next opening tag (case-insensitive)
    var openIdx = -1
    var tagLen = 0
    var isBracket = false

    let lowerRemaining = lowerResponse[lastIdx .. ^1]
    
    let tcMatch = lowerRemaining.find("<tool_call>")
    let tMatch = lowerRemaining.find("<tool>")
    let bMatch = lowerRemaining.find("[tool_call]")
    let bTMatch = lowerRemaining.find("[tool]")

    if tcMatch >= 0 and (tMatch < 0 or tcMatch < tMatch) and (bMatch < 0 or tcMatch < bMatch):
      openIdx = lastIdx + tcMatch
      tagLen = 11
    elif tMatch >= 0 and (bMatch < 0 or tMatch < bMatch):
      openIdx = lastIdx + tMatch
      tagLen = 6
    elif bMatch >= 0:
      openIdx = lastIdx + bMatch
      tagLen = 11
      isBracket = true
    elif bTMatch >= 0:
      openIdx = lastIdx + bTMatch
      tagLen = 6
      isBracket = true
    else:
      break

    let startContent = openIdx + tagLen
    let closeTag = if isBracket: (if tagLen == 11: "[/tool_call]" else: "[/tool]")
                   else: (if tagLen == 11: "</tool_call>" else: "</tool>")
    
    let closeIdx = lowerResponse.find(closeTag, startContent)
    
    var jsonStr = ""
    if closeIdx < 0:
      # Recovery: if tag unclosed, try to find next tag or end of string
      jsonStr = response[startContent .. ^1].strip()
      lastIdx = response.len
    else:
      jsonStr = response[startContent ..< closeIdx].strip()
      lastIdx = closeIdx + closeTag.len

    if jsonStr.len == 0: continue

    # Strip markdown code fences
    if jsonStr.contains("```"):
      var lines = jsonStr.splitLines()
      var cleaned: seq[string] = @[]
      var inFence = false
      for line in lines:
        let t = line.strip()
        if t.startsWith("```"):
          inFence = not inFence
          continue
        cleaned.add(line)
      jsonStr = cleaned.join("\n").strip()

    # Try parsing as Anthropic-style XML first
    if jsonStr.contains("<name>") and jsonStr.contains("</name>"):
      let nameStart = jsonStr.find("<name>")
      let nameEnd = jsonStr.find("</name>")
      if nameStart >= 0 and nameEnd > nameStart:
        let toolName = jsonStr[nameStart+6 ..< nameEnd].strip()
        var args = initTable[string, JsonNode]()
        
        let argsStart = jsonStr.find("<arguments>")
        let argsEnd = jsonStr.rfind("</arguments>")
        
        if argsStart >= 0 and argsEnd > argsStart:
          let argsContent = jsonStr[argsStart+11 ..< argsEnd]
          var i = 0
          while i < argsContent.len:
            let startTagOpen = argsContent.find('<', i)
            if startTagOpen < 0: break
            let startTagClose = argsContent.find('>', startTagOpen)
            if startTagClose < 0: break
            
            let key = argsContent[startTagOpen+1 ..< startTagClose].strip()
            if key.len == 0 or key.contains(' ') or key.contains('/') or key.contains('\n'):
              i = startTagOpen + 1
              continue
              
            let endTag = "</" & key & ">"
            let endIdx = argsContent.find(endTag, startTagClose)
            if endIdx < 0:
              i = startTagOpen + 1
              continue
              
            let valStr = argsContent[startTagClose+1 ..< endIdx].strip()
            # If the value looks like a JSON object or array, try to parse it, else treat as string
            try:
              if (valStr.startsWith("{") and valStr.endsWith("}")) or (valStr.startsWith("[") and valStr.endsWith("]")):
                args[key] = parseJson(valStr)
              elif valStr.len > 0 and (valStr[0] in {'0'..'9', '-'}):
                # Try parsing as a number if it looks like one
                try:
                  args[key] = parseJson(valStr)
                except:
                  args[key] = %valStr
              else:
                args[key] = %valStr
            except:
              args[key] = %valStr
              
            i = endIdx + endTag.len
            
        result.add(XmlToolCall(name: toolName, arguments: args))
        continue
        
    try:
      # Robust JSON parsing: handle unescaped newlines in large blocks if possible
      var jsonToParse = jsonStr
      try:
        discard parseJson(jsonToParse)
      except:
        # If strict JSON fails, it's often due to unescaped newlines in the 'code' string.
        var inQuotes = false
        var escaped = ""
        for i in 0 ..< jsonStr.len:
          let c = jsonStr[i]
          if c == '"' and (i == 0 or jsonStr[i-1] != '\\'):
            inQuotes = not inQuotes
          
          if c == '\n' and inQuotes:
            escaped.add("\\n")
          elif c == '\r' and inQuotes:
            discard
          else:
            escaped.add(c)
        jsonToParse = escaped

      let parsed = parseJson(jsonToParse)
      if parsed.hasKey("name"):
        var args = initTable[string, JsonNode]()
        if parsed.hasKey("arguments"):
          for k, v in parsed["arguments"].pairs:
            args[k] = v
        result.add(XmlToolCall(name: parsed["name"].getStr(), arguments: args))
    except:
      # If still fails, we've logged it in loop.nim
      discard

proc extractTextFromResponse*(response: string): string =
  ## Extract the non-tool-call text from an LLM response.
  result = response
  let tags = @["<tool_call>", "</tool_call>", "<tool>", "</tool>", "[tool_call]", "[/tool_call]", "[tool]", "[/tool]"]
  for token in @["<|tool_calls_section_begin|>", "<|tool_calls_section_end|>", "<|tool_call_begin|>", "<|tool_call_end|>", "<|tool_call_argument_begin|>", "<|tool_call_argument_end|>"]:
    result = result.replace(token, "")
  
  # Remove all XML-like tags and their inner JSON content (roughly)
  # This is a bit complex for a one-pass, so we just remove the tags themselves
  # and let the JSON be filtered if it's not useful.
  # Actually, properly stripping blocks:
  var cleaned = response
  for t in @["tool_call", "tool"]:
    while true:
      let startTag = "<" & t & ">"
      let endTag = "</" & t & ">"
      let startIdx = cleaned.toLowerAscii().find(startTag)
      if startIdx < 0: break
      let endIdx = cleaned.toLowerAscii().find(endTag, startIdx)
      if endIdx < 0: 
        cleaned = cleaned[0 ..< startIdx]
        break
      cleaned = cleaned[0 ..< startIdx] & cleaned[endIdx + endTag.len .. ^1]
  
  # Also handle brackets
  for t in @["tool_call", "tool"]:
    while true:
      let startTag = "[" & t & "]"
      let endTag = "[/" & t & "]"
      let startIdx = cleaned.toLowerAscii().find(startTag)
      if startIdx < 0: break
      let endIdx = cleaned.toLowerAscii().find(endTag, startIdx)
      if endIdx < 0: 
        cleaned = cleaned[0 ..< startIdx]
        break
      cleaned = cleaned[0 ..< startIdx] & cleaned[endIdx + endTag.len .. ^1]
      
  return cleaned.strip()

proc formatToolResults*(results: seq[XmlToolResult]): string =
  ## Format tool execution results as XML for the next LLM turn.
  ## Results are wrapped in <tool_result> tags and sent back as a user message.
  var parts: seq[string] = @["[Tool results]"]
  for r in results:
    let status = if r.success: "ok" else: "error"
    parts.add("<tool_result name=\"" & r.name & "\" status=\"" & status & "\">\n" & r.output & "\n</tool_result>")
  parts.add("\nReflect on the tool results above and decide your next steps. " &
    "If a tool failed, do not repeat the same call; explain the limitation or try a different approach.")
  return parts.join("\n")

proc buildToolInstructions*(registry: tools_registry.ToolRegistry): string =
  ## Build a COMPRESSED XML tool protocol section for limited context/proxy buffers.
  if registry == nil: return ""

  var sb = "\n## Tool Calling Protocol\n"
  sb.add("To use a tool, you MUST use Anthropic-style XML blocks instead of JSON strings. This prevents escaping errors.\n")
  sb.add("Wrap the tool call in <tool_call> tags. The arguments must be child XML elements.\n")
  sb.add("Format:\n<tool_call>\n  <name>tool_name</name>\n  <arguments>\n    <param_name>value</param_name>\n  </arguments>\n</tool_call>\n")
  sb.add("Example:\n<tool_call>\n  <name>read_file</name>\n  <arguments>\n    <path>main.nim</path>\n  </arguments>\n</tool_call>\n\n")

  # Get tool info from registry
  let toolNames = registry.list()
  for toolName in toolNames:
    let (tool, ok) = registry.get(toolName)
    if ok and tool != nil:
      let params = tool.parameters()
      var pNames: seq[string] = @[]
      # Extract actual parameter names from JSON Schema properties
      if params.hasKey("properties") and params["properties"].kind == JObject:
        for k in params["properties"].keys: pNames.add(k)
      elif params.hasKey("type"):
        # Already a schema wrapper — skip schema keys
        discard
      else:
        for k in params.keys: pNames.add(k)
      let pStr = if pNames.len > 0: "(" & pNames.join(", ") & ")" else: ""

      # Minimal one-line format
      sb.add("- " & tool.name() & pStr & ": " & tool.description() & "\n")

  return sb

proc buildToolInstructionsFiltered*(registry: tools_registry.ToolRegistry, allowed: seq[string]): string =
  if registry == nil: return ""
  var allowedSet = initTable[string, bool]()
  for a in allowed:
    allowedSet[tools_registry.sanitizeToolName(a)] = true

  var sb = "\n## Tool Calling Protocol\n"
  sb.add("To use a tool, you MUST use Anthropic-style XML blocks instead of JSON strings. This prevents escaping errors.\n")
  sb.add("Wrap the tool call in <tool_call> tags. The arguments must be child XML elements.\n")
  sb.add("Format:\n<tool_call>\n  <name>tool_name</name>\n  <arguments>\n    <param_name>value</param_name>\n  </arguments>\n</tool_call>\n")
  sb.add("Example:\n<tool_call>\n  <name>read_file</name>\n  <arguments>\n    <path>main.nim</path>\n  </arguments>\n</tool_call>\n\n")

  let toolNames = registry.list()
  for toolName in toolNames:
    let (tool, ok) = registry.get(toolName)
    if ok and tool != nil:
      let n = tools_registry.sanitizeToolName(tool.name())
      if not allowedSet.hasKey(n): continue
      let params = tool.parameters()
      var pNames: seq[string] = @[]
      if params.hasKey("properties") and params["properties"].kind == JObject:
        for k in params["properties"].keys: pNames.add(k)
      elif params.hasKey("type"):
        discard
      else:
        for k in params.keys: pNames.add(k)
      let pStr = if pNames.len > 0: "(" & pNames.join(", ") & ")" else: ""
      sb.add("- " & tool.name() & pStr & ": " & tool.description() & "\n")

  return sb

proc hasXmlToolCalls*(response: string): bool =
  ## Quick check if a response contains tool call markup.
  let r = response.toLowerAscii()
  return r.contains("<tool_call>") or
         r.contains("<tool>") or
         r.contains("[tool_call]") or
         r.contains("[tool]")
