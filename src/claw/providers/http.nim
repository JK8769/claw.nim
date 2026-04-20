import std/[asyncdispatch, json, strutils, tables, os]
import curly, webby/httpheaders
import ../lib/malebolgia
import ../lib/http_retry
import types
import ../logger
from ../tools/registry import sanitizeToolName
import unicode

proc expandEnvVar(val: string): string =
  ## Expands ${VAR} using environment variables.
  if val.startsWith("${") and val.endsWith("}"):
    return getEnv(val[2..^2], val)
  return val

proc sanitizeUtf8(s: string): string =
  ## Ensure the string is valid UTF-8, replacing invalid segments with U+FFFD
  result = ""
  var i = 0
  while i < s.len:
    var length = runeLenAt(s, i)
    if length > 0:
      for _ in 1..length:
        result.add(s[i])
        inc i
    else:
      # Invalid sequence, append replacement character
      result.add("\uFFFD")
      inc i

type
  HTTPProvider* = ref object of LLMProvider
    apiKey*: string
    apiBase*: string
    defaultModel*: string
    curly*: Curly
    master*: Master
    timeout*: int

proc newHTTPProvider*(apiKey, apiBase, defaultModel: string, timeout: int): HTTPProvider =
  HTTPProvider(
    apiKey: apiKey,
    apiBase: apiBase,
    defaultModel: defaultModel,
    curly: newCurly(),
    master: createMaster(),
    timeout: timeout
  )

method getDefaultModel*(p: HTTPProvider): string =
  return p.defaultModel

method chat*(p: HTTPProvider, messages: seq[Message], tools: seq[ToolDefinition], model: string, options: Table[string, JsonNode]): Future[LLMResponse] {.async.} =
  if p.apiBase == "":
    raise newException(ValueError, "API base not configured")

  var actualModel = model
  # Only strip prefixes if we are hitting certain internal providers or if explicitly requested.
  # For many providers like NVIDIA/OpenRouter, the prefix IS part of the model ID.
  # We will only strip 'opencode/' prefixes for now as that's our legacy convention.
  if actualModel.startsWith("opencode/"):
    actualModel = actualModel.replace("opencode/", "")
  elif actualModel.startsWith("opencode-go/"):
    actualModel = actualModel.replace("opencode-go/", "")

  # We need to sanitize tool names in the history to avoid DeepSeek 400 errors
  # if previous calls used colons (like nc:submit).

  var jsonMessages = newJArray()
  for m in messages:
    var jMsg = %*{"role": m.role}
    let hasToolCalls = m.role == "assistant" and m.tool_calls.len > 0
    # Moonshot/Kimi rejects any assistant message with empty content,
    # even when tool_calls are present (DeepSeek/OpenAI tolerate ""
    # there). Normalize:
    #   - assistant + tool_calls + empty → omit `content` (OpenAI-spec fine)
    #   - assistant + no tool_calls + empty → substitute " " (prior sessions
    #       saved these before the fix; dropping the turn re-breaks the
    #       user↔assistant pairing)
    #   - other roles keep "" for parity with the old behaviour
    if m.content != "":
      jMsg["content"] = %sanitizeUtf8(m.content)
    elif hasToolCalls:
      discard   # content omitted
    elif m.role == "assistant":
      jMsg["content"] = %" "
    else:
      jMsg["content"] = %""
    if m.reasoning_content != "":
      jMsg["reasoning_content"] = %sanitizeUtf8(m.reasoning_content)
    if m.role == "tool":
      jMsg["tool_call_id"] = %m.tool_call_id
      if m.name != "": jMsg["name"] = %sanitizeToolName(m.name)
    elif hasToolCalls:
      var jCalls = newJArray()
      for tc in m.tool_calls:
        # `tc.name` is the canonical field (populated by the parser and
        # used everywhere in loop.nim); `tc.function.name` is a legacy
        # nested mirror that was never filled in — reading it produced
        # empty-name tool_calls in the history, which DeepSeek tolerated
        # but Xiaomi/Moonshot reject. Same for arguments.
        let argsStr = if tc.function.arguments.len > 0: tc.function.arguments
                      else: $(%*tc.arguments)
        jCalls.add(%*{
          "id": tc.id,
          "type": tc.`type`,
          "function": %*{
            "name": sanitizeToolName(tc.name),
            "arguments": argsStr
          }
        })
      jMsg["tool_calls"] = jCalls
    jsonMessages.add(jMsg)

  var requestBody = %*{
    "model": actualModel,
    "messages": jsonMessages
  }

  if tools.len > 0 and not model.startsWith("opencode/") and not model.startsWith("opencode-go/"):
    requestBody["tools"] = %tools

  if options.hasKey("max_tokens"):
    let lowerModel = model.toLowerAscii
    if lowerModel.contains("glm") or lowerModel.contains("o1"):
      requestBody["max_completion_tokens"] = options["max_tokens"]
    else:
      requestBody["max_tokens"] = options["max_tokens"]

  if options.hasKey("temperature"):
    requestBody["temperature"] = options["temperature"]

  var headers = emptyHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["HTTP-Referer"] = "https://github.com/claw/nimclaw"
  headers["X-Title"] = "Nimclaw"
  headers["User-Agent"] = "NimClaw/0.1.0"
  
  if p.apiKey != "":
    headers["Authorization"] = "Bearer " & p.apiKey

  let url = p.apiBase & "/chat/completions"
  
  # Mask API key for logging
  let maskedKey = if p.apiKey.len > 10: 
    p.apiKey[0..3] & "..." & p.apiKey[^4..^1] 
  else: 
    "***"
    
  infoCF("http_provider", "Sending LLM request (via curly)", {
    "url": url,
    "model": actualModel,
    "api_key_masked": maskedKey,
    "api_key_len": $p.apiKey.len
  }.toTable)

  if tools.len > 0:
    for t in tools:
      infoCF("http_provider", "Tool definition", {"name": t.function.name, "json": $(%t)}.toTable)
  
  debugCF("http_provider", "Full request body", {"json": $requestBody}.toTable)

  proc doRequest(c: Curly, url, body: string, headers: HttpHeaders, timeout: int): tuple[code: int, body: string] {.gcsafe.} =
    curlyPostWithRetry(c, url, body, headers, timeout)

  # Instrumentation for opencode_go debugging
  if url.contains("/go/"):
    let maskedKey = if p.apiKey.len > 10: 
      p.apiKey[0..9] & "..."
    else: 
      "***"
    infoCF("http_provider", "Opencode Go Request Details", {
      "url": url,
      "apiKey_masked": maskedKey,
      "body": $requestBody
    }.toTable)

  let fv = p.master.spawn doRequest(p.curly, url, $requestBody, headers, p.timeout)
  
  # Busy-wait for TaskVar in an async-friendly way
  while not fv.isReady:
    await sleepAsync(10)
    
  var (code, body) = fv.sync()

  # Retry on 429/529 rate limiting with exponential backoff
  if code in [429, 529]:
    for retryAttempt in 1..5:
      let delay = retryAttempt * retryAttempt * 2  # 2s, 8s, 18s, 32s, 50s
      warnCF("http_provider", "Rate limited (" & $code & "), retrying", {"attempt": $retryAttempt, "delay_s": $delay}.toTable)
      await sleepAsync(delay * 1000)
      let retryFv = p.master.spawn doRequest(p.curly, url, $requestBody, headers, p.timeout)
      while not retryFv.isReady:
        await sleepAsync(10)
      (code, body) = retryFv.sync()
      if code notin [429, 529]: break

  if code == -1:
    raise newException(IOError, "Curly request failed: " & body)

  if code < 200 or code >= 300:
    raise newException(IOError, "API error ($1): $2".format(code, body))

  let jsonResp = parseJson(body)

  var llmResp = LLMResponse()
  if jsonResp.hasKey("choices") and jsonResp["choices"].len > 0:
    let choice = jsonResp["choices"][0]
    let msg = choice["message"]
    if msg.hasKey("content") and msg["content"].kind != JNull:
      llmResp.content = msg["content"].getStr()
    
    # Reasoning field naming differs across providers:
    #   DeepSeek / o1    → "reasoning_content"
    #   Kimi (Moonshot)  → "reasoning"  (plus structured "reasoning_details")
    # Kimi's thinking mode requires the trace to be echoed back on the
    # next turn, so capturing it here is not optional — a missing trace
    # causes HTTP 400 on the follow-up call.
    if msg.hasKey("reasoning_content") and msg["reasoning_content"].kind != JNull:
      llmResp.reasoning_content = msg["reasoning_content"].getStr()
    elif msg.hasKey("reasoning") and msg["reasoning"].kind != JNull:
      llmResp.reasoning_content = msg["reasoning"].getStr()
    elif msg.hasKey("reasoning_details") and msg["reasoning_details"].kind == JArray:
      var parts: seq[string]
      for d in msg["reasoning_details"]:
        let t = d{"text"}.getStr("")
        if t.len > 0: parts.add(t)
      if parts.len > 0:
        llmResp.reasoning_content = parts.join("\n")

    if msg.hasKey("tool_calls") and msg["tool_calls"].kind == JArray:
      for tc in msg["tool_calls"]:
        infoCF("http_provider", "Raw tool_call from LLM", {"raw": $tc}.toTable)
        var toolCall = ToolCall(
          id: tc["id"].getStr(),
          `type`: tc.getOrDefault("type").getStr("function")
        )
        if tc.hasKey("function"):
          let fn = tc["function"]
          var rawName = fn["name"].getStr()
          let argsStr = fn["arguments"].getStr()

          # Fix malformed calls from LLMs that put args in the name field
          # Pattern 1: "playwright(action=\"click\", target=\"e81\")" → name + args
          let parenPos = rawName.find('(')
          if parenPos > 0 and rawName.endsWith(")"):
            let inlineArgs = rawName[parenPos + 1 .. ^2]  # strip parens
            rawName = rawName[0 ..< parenPos]
            for part in inlineArgs.split(","):
              let kv = part.strip().split("=", maxsplit = 1)
              if kv.len == 2:
                let k = kv[0].strip()
                var v = kv[1].strip()
                if v.len >= 2 and v[0] == '"' and v[^1] == '"':
                  v = v[1..^2]
                toolCall.arguments[k] = %v
            warnCF("http_provider", "Fixed malformed tool call name (parens)", {"original": fn["name"].getStr(), "fixed_name": rawName}.toTable)

          # Pattern 2: "playwright snapshot" → name="playwright", command="snapshot"
          elif ' ' in rawName:
            let spacePos = rawName.find(' ')
            let extra = rawName[spacePos + 1 .. ^1].strip()
            rawName = rawName[0 ..< spacePos]
            if extra.len > 0:
              toolCall.arguments["command"] = %extra
            warnCF("http_provider", "Fixed malformed tool call name (space)", {"original": fn["name"].getStr(), "fixed_name": rawName, "extracted_command": extra}.toTable)

          toolCall.name = rawName
          # Keep the raw JSON string as the canonical argument form — it's
          # what we echo back to the LLM on the next turn (some providers
          # are picky about quoting). The Table form is only used by the
          # tool-dispatch layer that wants typed access.
          toolCall.function.name = rawName
          toolCall.function.arguments = argsStr
          try:
            let argsJson = parseJson(argsStr)
            if argsJson.kind == JObject:
              for k, v in argsJson.fields:
                toolCall.arguments[k] = v
          except:
            if argsStr.len > 0 and argsStr != "{}":
              toolCall.arguments["raw"] = %argsStr
        llmResp.tool_calls.add(toolCall)

    llmResp.finish_reason = choice.getOrDefault("finish_reason").getStr("stop")

  if jsonResp.hasKey("usage") and jsonResp["usage"].kind == JObject:
    let usage = jsonResp["usage"]
    llmResp.usage = UsageInfo(
      prompt_tokens: if usage.hasKey("prompt_tokens"): usage["prompt_tokens"].getInt() else: 0,
      completion_tokens: if usage.hasKey("completion_tokens"): usage["completion_tokens"].getInt() else: 0,
      total_tokens: if usage.hasKey("total_tokens"): usage["total_tokens"].getInt() else: 0
    )

  return llmResp

proc createProvider*(model, apiKey, apiBase: string, timeout: int = 300): LLMProvider =
  return newHTTPProvider(apiKey, apiBase, model, timeout)

const PROVIDER_BASE_URLS* = {
  "opencode": "https://opencode.ai/zen/go/v1",
  "opencode-go": "https://opencode.ai/zen/go/v1",
  "deepseek": "https://api.deepseek.com",
  "openai": "https://api.openai.com/v1",
  "anthropic": "https://api.anthropic.com/v1",
  "groq": "https://api.groq.com/openai/v1",
  "openrouter": "https://openrouter.ai/api/v1",
  "nvidia": "https://integrate.api.nvidia.com/v1",
}.toTable

proc resolveProviderTech*(cfg_model, cfg_default_provider: string, graph_providers: JsonNode, providerOverride: string = "", modelOverride: string = ""): tuple[model, apiKey, apiBase: string] =
  ## Resolves provider credentials from the world graph with fallback to known base URLs.
  result.model = cfg_model
  if modelOverride != "": result.model = modelOverride

  var providerKey = if providerOverride != "": providerOverride
    elif result.model.contains("/"): result.model.split("/")[0]
    else: cfg_default_provider

  if graph_providers != nil and graph_providers.kind == JObject and graph_providers.hasKey(providerKey):
    let pNode = graph_providers[providerKey]
    result.apiKey = expandEnvVar(pNode{"apiKey"}.getStr(""))
    result.apiBase = expandEnvVar(pNode{"apiBase"}.getStr(""))

  if result.apiBase == "" and PROVIDER_BASE_URLS.hasKey(providerKey):
    result.apiBase = PROVIDER_BASE_URLS[providerKey]
