## Provider key verification — hit the provider's models endpoint with the
## supplied API key and report outcome. Shared by the `claw provider auth`
## CLI (runs at setup time) and the `provider_auth` agent tool (runs at
## diagnose time).
##
## Never logs or echoes the key. Error messages contain status codes + URLs
## but not the key.

import std/[strutils, json]
import ../lib/curly_with_cancel as curly, webby/httpheaders
import registry

type
  ModelInfo* = object
    id*: string              ## provider's model id (e.g. "llama-3.3-70b-versatile" on Groq)
    canonical*: string       ## canonical model id (e.g. "meta/llama-3.3-70b-instruct"), "" if none
    ownedBy*: string         ## provider's internal owner tag (e.g. "openai")
    created*: int64          ## unix ts, 0 if unknown
    contextLen*: int         ## context window in tokens, 0 if unknown
    inputCostPer1M*: float   ## USD per 1M input tokens, 0 if unknown
    outputCostPer1M*: float  ## USD per 1M output tokens, 0 if unknown
    sizeBytes*: int64        ## disk size (ollama reports this), 0 if unknown
    capabilities*: seq[string] ## ollama reports these via /api/show (vision,tools,...)
    family*: string            ## model family hint (e.g. "gemma4" from ollama's details)

  VerifyOutcome* = enum
    voOk          ## 200 — key accepted, models endpoint responds
    voAuthFailed  ## 401/403 — key rejected
    voRateLimit   ## 429 — temporarily throttled, key likely valid
    voServerError ## 5xx — provider-side issue
    voNetwork     ## network / DNS / timeout
    voSkipped     ## provider is local (ollama), no auth to verify
    voUnknown     ## unexpected response

  VerifyResult* = object
    outcome*: VerifyOutcome
    httpStatus*: int      ## 0 if no response arrived
    modelCount*: int      ## models listed in response (if parseable)
    errMsg*: string       ## short human-readable summary
    provider*: string     ## echo back the provider name for logs

proc buildHeaders(def: ProviderDef, apiKey: string): HttpHeaders =
  result = emptyHttpHeaders()
  if def.authHeader.startsWith("Authorization: Bearer"):
    result["Authorization"] = "Bearer " & apiKey
  elif def.authHeader.toLowerAscii().startsWith("x-api-key"):
    result["x-api-key"] = apiKey
    # Anthropic requires an additional version header
    if def.name == "anthropic":
      result["anthropic-version"] = "2023-06-01"

proc verifyKey*(def: ProviderDef, apiKey: string, timeoutMs: int = 10_000): VerifyResult =
  ## GET <apiBase><verifyPath> with the key in the configured auth header.
  ## Uses curly (libcurl) for modern TLS support — some providers (NVIDIA)
  ## reject Nim's stdlib httpclient TLS defaults.
  result.provider = def.name

  if def.local:
    result.outcome = voSkipped
    result.errMsg = "local provider — no API key required"
    return

  if apiKey.len == 0:
    result.outcome = voAuthFailed
    result.errMsg = "no key supplied"
    return

  let url = def.apiBase & def.verifyPath
  let headers = buildHeaders(def, apiKey)
  let c = newCurly()
  defer: c.close()

  try:
    let resp = c.get(url, headers = headers, timeout = timeoutMs div 1000)
    result.httpStatus = resp.code
    case resp.code
    of 200:
      result.outcome = voOk
      try:
        let j = parseJson(resp.body)
        if j{"data"}.kind == JArray: result.modelCount = j["data"].len
        elif j{"models"}.kind == JArray: result.modelCount = j["models"].len
      except: discard
      result.errMsg = "key accepted"
    of 401, 403:
      result.outcome = voAuthFailed
      result.errMsg = "key rejected by " & def.name & " (HTTP " & $resp.code & ")"
    of 429:
      result.outcome = voRateLimit
      result.errMsg = "rate limited (HTTP 429) — key is likely valid but throttled"
    else:
      if resp.code >= 500:
        result.outcome = voServerError
        result.errMsg = "provider " & def.name & " returned HTTP " & $resp.code
      else:
        result.outcome = voUnknown
        result.errMsg = "unexpected HTTP " & $resp.code
  except CatchableError as e:
    result.outcome = voNetwork
    result.errMsg = "network error: " & e.msg

proc verifyViaChat*(def: ProviderDef, apiKey, modelId: string,
                    timeoutMs: int = 15_000): VerifyResult =
  ## Alternative verify for providers that don't expose a working GET /models
  ## (e.g. OpenCode Go at /zen/go/v1): POST a minimal chat-completion and
  ## treat the response code as the signal. HTTP 200 / 400 / a credits-style
  ## error all mean auth passed. Caller picks `modelId` from res/models.json —
  ## `models_catalog.getProviderModels(def.name)` is the canonical source.
  result.provider = def.name
  if def.local:
    result.outcome = voSkipped
    result.errMsg = "local provider — no API key required"
    return
  if apiKey.len == 0:
    result.outcome = voAuthFailed
    result.errMsg = "no key supplied"
    return
  if modelId.len == 0:
    result.outcome = voUnknown
    result.errMsg = "no probe model available in res/models.json for " & def.name
    return

  let url = def.apiBase & "/chat/completions"
  var headers = buildHeaders(def, apiKey)
  headers["Content-Type"] = "application/json"
  let body = $(%*{
    "model": modelId,
    "messages": [{"role": "user", "content": "ping"}],
    "max_tokens": 1
  })
  let c = newCurly()
  defer: c.close()

  try:
    let resp = c.post(url, headers = headers, body = body,
                      timeout = timeoutMs div 1000)
    result.httpStatus = resp.code
    # Some providers (OpenCode Zen) signal "out of credits" with HTTP 401 plus
    # a structured error body — the key is actually valid. Peek at the body
    # before classifying.
    var errType, errMsg = ""
    try:
      let j = parseJson(resp.body)
      errType = j{"error"}{"type"}.getStr("")
      errMsg = j{"error"}{"message"}.getStr("")
    except: discard
    let looksLikeCredits = errType.toLowerAscii().contains("credit") or
                           errMsg.toLowerAscii().contains("balance") or
                           errMsg.toLowerAscii().contains("quota")

    case resp.code
    of 200:
      result.outcome = voOk
      result.errMsg = "key accepted (chat probe: " & modelId & ")"
    of 400:
      # Request-shape issue (bad model name, missing param) — auth still passed.
      result.outcome = voOk
      result.errMsg = "key accepted (HTTP 400 on " & modelId & ": " & errMsg & ")"
    of 401, 403:
      if looksLikeCredits:
        result.outcome = voOk
        result.errMsg = "key accepted (provider: " & errMsg & ")"
      else:
        result.outcome = voAuthFailed
        result.errMsg = "key rejected by " & def.name & " (HTTP " & $resp.code &
                        (if errMsg.len > 0: ": " & errMsg else: "") & ")"
    of 404:
      # Model not in this tier's catalog — caller should retry with a different
      # probe model. Leaves outcome ambiguous rather than asserting auth status.
      result.outcome = voUnknown
      result.errMsg = "model '" & modelId & "' not available on " & def.name &
                      " — pick another from res/models.json"
    of 429:
      result.outcome = voRateLimit
      result.errMsg = "rate limited (HTTP 429)"
    else:
      if resp.code >= 500:
        result.outcome = voServerError
        result.errMsg = "provider " & def.name & " returned HTTP " & $resp.code
      else:
        result.outcome = voUnknown
        result.errMsg = "unexpected HTTP " & $resp.code &
                        (if errMsg.len > 0: ": " & errMsg else: "")
  except CatchableError as e:
    result.outcome = voNetwork
    result.errMsg = "network error: " & e.msg

proc parseModelEntry(e: JsonNode): ModelInfo =
  ## Best-effort extraction of common fields from a provider's model entry.
  ## Different providers return different shapes; we pick whatever matches.
  # ID: most providers use "id", Ollama uses "name"
  result.id = e{"id"}.getStr("")
  if result.id.len == 0: result.id = e{"name"}.getStr("")
  if result.id.len == 0: result.id = e{"model"}.getStr("")

  result.ownedBy = e{"owned_by"}.getStr("")

  # Created: may be unix int, ISO string, or Ollama's "modified_at" (ISO)
  let createdNode = e{"created"}
  if createdNode != nil:
    if createdNode.kind == JInt:
      result.created = createdNode.getInt()
    elif createdNode.kind == JString:
      try: result.created = parseInt(createdNode.getStr("0")) except: discard

  # Context length: OpenRouter-style "context_length", or sometimes "max_tokens"
  for key in ["context_length", "context_window", "max_context_length"]:
    let n = e{key}
    if n != nil and n.kind == JInt:
      result.contextLen = n.getInt()
      break

  # Pricing: OpenRouter shape {"pricing": {"prompt": "0.0000008", "completion": "0.0000024"}}
  let pricing = e{"pricing"}
  if pricing != nil and pricing.kind == JObject:
    let promptCost = pricing{"prompt"}
    if promptCost != nil:
      let s = (if promptCost.kind == JString: promptCost.getStr("0")
               else: $promptCost.getFloat(0.0))
      try: result.inputCostPer1M = parseFloat(s) * 1_000_000 except: discard
    let completionCost = pricing{"completion"}
    if completionCost != nil:
      let s = (if completionCost.kind == JString: completionCost.getStr("0")
               else: $completionCost.getFloat(0.0))
      try: result.outputCostPer1M = parseFloat(s) * 1_000_000 except: discard

  # Ollama: size field
  let sizeNode = e{"size"}
  if sizeNode != nil and sizeNode.kind == JInt:
    result.sizeBytes = sizeNode.getInt()

proc enrichOllama*(def: ProviderDef, models: var seq[ModelInfo], timeoutMs: int = 5_000) =
  ## Ollama-specific: pull each model's capabilities + family from /api/show.
  ## `/v1/models` (OpenAI-compat) doesn't return that richer metadata, so we
  ## hit the native `/api/show` endpoint per model.
  ##
  ## Derives the native host from the OpenAI-compat apiBase by stripping the
  ## trailing `/v1` (ollama's apiBase is e.g. `http://localhost:11434/v1`).
  var nativeBase = def.apiBase
  if nativeBase.endsWith("/v1"): nativeBase = nativeBase[0 ..< nativeBase.len - 3]
  let showUrl = nativeBase & "/api/show"
  let c = newCurly()
  defer: c.close()
  var headers = emptyHttpHeaders()
  headers["Content-Type"] = "application/json"
  for i in 0 ..< models.len:
    let body = $(%*{"name": models[i].id})
    try:
      let resp = c.post(showUrl, headers = headers, body = body,
                        timeout = timeoutMs div 1000)
      if resp.code != 200: continue
      let j = parseJson(resp.body)
      let caps = j{"capabilities"}
      if caps != nil and caps.kind == JArray:
        for c in caps: models[i].capabilities.add(c.getStr(""))
      let details = j{"details"}
      if details != nil and details.kind == JObject:
        models[i].family = details{"family"}.getStr("")
    except: discard

proc listModels*(def: ProviderDef, apiKey: string, timeoutMs: int = 15_000): seq[ModelInfo] =
  ## Fetch the provider's model list. Handles OpenAI-compatible `/v1/models`
  ## ({"data": [...]}), Ollama's `/api/tags` ({"models": [...]}), and falls
  ## back to any top-level array. Uses curly for consistent TLS behavior.
  let url = def.apiBase & def.verifyPath
  let headers = buildHeaders(def, apiKey)
  let c = newCurly()
  defer: c.close()

  try:
    let resp = c.get(url, headers = headers, timeout = timeoutMs div 1000)
    if resp.code != 200: return @[]
    let j = parseJson(resp.body)
    var arr: JsonNode = nil
    for key in ["data", "models"]:
      let candidate = j{key}
      if candidate != nil and candidate.kind == JArray:
        arr = candidate
        break
    if arr == nil and j.kind == JArray: arr = j
    if arr == nil: return @[]
    for entry in arr:
      let m = parseModelEntry(entry)
      if m.id.len > 0: result.add(m)
  except:
    return @[]
