import std/[asyncdispatch, json, tables, strutils, os, base64, httpclient]
import types
import image_info

type
  ImageAnalyzeTool* = ref object of ContextualTool

proc newImageAnalyzeTool*(): ImageAnalyzeTool =
  ImageAnalyzeTool()

method name*(t: ImageAnalyzeTool): string = "image_analyze"

method description*(t: ImageAnalyzeTool): string =
  "Analyze an image using a local vision model (Ollama). " &
  "Use when you see [image: /path] in a message and need to understand image content."

method parameters*(t: ImageAnalyzeTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {
        "type": "string",
        "description": "Path to the image file"
      },
      "prompt": {
        "type": "string",
        "description": "What to analyze (e.g. 'Describe this image', 'Extract all text', 'What objects are visible?')"
      }
    },
    "required": %["path", "prompt"]
  }.toTable

proc findVisionModel(providers: JsonNode): tuple[apiBase: string, model: string] =
  ## Find a vision-capable model from configured providers.
  if providers.kind != JObject: return ("", "")
  for provName, prov in providers.pairs:
    if prov.kind != JObject: continue
    let apiBase = prov{"apiBase"}.getStr("")
    if apiBase == "": continue
    let models = prov{"models"}
    if models == nil or models.kind != JArray: continue
    for m in models:
      if m.kind == JObject:
        let inputs = m{"input"}
        if inputs != nil and inputs.kind == JArray:
          for inp in inputs:
            if inp.getStr("") == "vision":
              return (apiBase, m{"name"}.getStr(""))
  return ("", "")

method execute*(t: ImageAnalyzeTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let path = if args.hasKey("path"): args["path"].getStr() else: ""
  let prompt = if args.hasKey("prompt"): args["prompt"].getStr() else: "Describe this image"

  if path == "": return "Error: Missing 'path' parameter."

  let absPath = if isAbsolute(path): path else: getCurrentDir() / path
  if not fileExists(absPath):
    return "Error: Image file not found: " & path

  # Check file size (max 10MB for vision)
  let size = getFileSize(absPath)
  if size > 10_485_760:
    return "Error: Image too large (" & $(size div 1_048_576) & "MB). Max 10MB."

  # Find a vision-capable model from providers
  let (apiBase, model) = findVisionModel(t.graph.providers)
  if apiBase == "" or model == "":
    return "Error: No vision-capable model configured. " &
           "Add a provider with vision models (e.g. Ollama with gemma4:e2b). " &
           "In the provider config, models need '\"input\": [\"vision\"]' to be discoverable."

  # Check if the provider is reachable
  let client = newAsyncHttpClient()
  try:
    let healthUrl = apiBase.replace("/v1", "")
    let healthResp = await client.get(healthUrl)
    if healthResp.code.int >= 400:
      return "Error: Vision provider not reachable at " & apiBase &
             ". Make sure the service is running."
  except:
    return "Error: Cannot connect to vision provider at " & apiBase &
           ". Is the service running?"
  finally:
    client.close()

  # Read and encode the image
  let imageBytes = readFile(absPath)
  let imageB64 = base64.encode(imageBytes)

  # Detect MIME type
  var bytes = newSeq[byte](min(imageBytes.len, 12))
  for i in 0..<bytes.len: bytes[i] = imageBytes[i].byte
  let format = detectFormat(bytes)
  let mime = case format
    of "png": "image/png"
    of "jpeg": "image/jpeg"
    of "gif": "image/gif"
    of "webp": "image/webp"
    of "bmp": "image/bmp"
    else: "image/png"

  # Call the vision API
  let body = %*{
    "model": model,
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": prompt},
          {"type": "image_url", "image_url": {"url": "data:" & mime & ";base64," & imageB64}}
        ]
      }
    ],
    "max_tokens": 1024
  }

  let apiClient = newAsyncHttpClient()
  try:
    let url = apiBase & "/chat/completions"
    let resp = await apiClient.request(url, httpMethod = HttpPost,
      headers = newHttpHeaders({"Content-Type": "application/json"}),
      body = $body)
    let respBody = await resp.body
    if resp.code.int >= 400:
      return "Error: Vision API returned " & $resp.code.int & ": " & respBody

    let data = parseJson(respBody)
    let content = data{"choices"}{0}{"message"}{"content"}.getStr("")
    if content == "":
      let reasoning = data{"choices"}{0}{"message"}{"reasoning"}.getStr("")
      if reasoning != "":
        return "Model is still thinking. Try again with a simpler prompt."
      return "Error: Empty response from vision model. Raw: " & respBody[0..min(200, respBody.len-1)]
    return content
  except Exception as e:
    return "Error calling vision API: " & e.msg
  finally:
    apiClient.close()
