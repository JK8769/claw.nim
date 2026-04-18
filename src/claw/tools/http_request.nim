import std/[json, tables, httpclient, strutils, asyncdispatch, uri, httpcore]
import types
import ../net_security

type
  HttpRequestTool* = ref object of Tool

proc newHttpRequestTool*(): HttpRequestTool =
  HttpRequestTool()

method name*(t: HttpRequestTool): string = "http_request"
method description*(t: HttpRequestTool): string = "Make HTTP requests to external APIs. Supports GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS methods. Security: no local/private hosts, SSRF protection."
method parameters*(t: HttpRequestTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "url": {
        "type": "string",
        "description": "HTTP or HTTPS URL to request"
      },
      "method": {
        "type": "string",
        "description": "HTTP method (GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS)",
        "default": "GET"
      },
      "headers": {
        "type": "object",
        "description": "Optional HTTP headers as key-value pairs"
      },
      "body": {
        "type": "string",
        "description": "Optional request body"
      }
    },
    "required": %["url"]
  }.toTable

proc isSensitiveHeader*(name: string): bool =
  let lower = name.toLowerAscii()
  if "authorization" in lower: return true
  if "api-key" in lower: return true
  if "apikey" in lower: return true
  if "token" in lower: return true
  if "secret" in lower: return true
  if "password" in lower: return true
  return false

proc redactHeadersForDisplay*(headers: openArray[tuple[name: string, val: string]]): string =
  if headers.len == 0: return ""
  
  var parts: seq[string] = @[]
  for h in headers:
    if isSensitiveHeader(h.name):
      parts.add("$1: ***REDACTED***" % h.name)
    else:
      parts.add("$1: $2" % [h.name, h.val])
      
  return parts.join("\n")

method execute*(t: HttpRequestTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("url"):
    return "Error: Missing 'url' parameter"
    
  let url = args["url"].getStr()
  
  let u = parseUri(url)
  if not (u.scheme.toLowerAscii() == "http" or u.scheme.toLowerAscii() == "https"):
    return "Error: Only http:// and https:// URLs are allowed"

  let host = extractHost(url)
  if host == "":
    return "Error: Invalid URL, cannot extract host"

  # SSRF Protection
  if isLocalHost(host):
    return "Error: Request to local/private network addresses (SSRF) is blocked for security reasons."

  let mthdStr = if args.hasKey("method"): args["method"].getStr().toUpperAscii() else: "GET"
  let mthd = case mthdStr:
    of "GET": HttpGet
    of "POST": HttpPost
    of "PUT": HttpPut
    of "DELETE": HttpDelete
    of "PATCH": HttpPatch
    of "HEAD": HttpHead
    of "OPTIONS": HttpOptions
    else: HttpGet

  var customHeaders: seq[tuple[name: string, val: string]] = @[]
  var clientHeaders = newHttpHeaders()
  var hasContentType = false
  
  if args.hasKey("headers") and args["headers"].kind == JObject:
    for key, val in args["headers"].pairs:
      if val.kind == JString:
        let vStr = val.getStr()
        customHeaders.add((name: key, val: vStr))
        clientHeaders.add(key, vStr)
        if key.toLowerAscii() == "content-type":
          hasContentType = true
        
  let body = if args.hasKey("body") and args["body"].kind == JString: args["body"].getStr() else: ""
  
  # Auto-sense JSON Content-Type if missing and body looks like JSON
  if body.len > 0 and not hasContentType:
    let stripped = body.strip()
    if (stripped.startsWith("{") and stripped.endsWith("}")) or 
       (stripped.startsWith("[") and stripped.endsWith("]")):
      clientHeaders.add("Content-Type", "application/json")
      customHeaders.add((name: "Content-Type", val: "application/json"))

  let client = newAsyncHttpClient(headers = clientHeaders)
  defer: client.close()
  
  try:
    let response = await client.request(url, httpMethod = mthd, body = body)
    let bodyText = await response.body
    
    let redacted = redactHeadersForDisplay(customHeaders)
    var outText = "Status: $1\n" % $response.code
    if redacted.len > 0:
      outText &= "Request Headers:\n" & redacted & "\n\n"
    else:
      outText &= "\n"
    
    outText &= "Response Body:\n" & bodyText
    return outText
  except Exception as e:
    return "Error: HTTP request failed: " & e.msg
