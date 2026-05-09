## web — single tool for all HTTP-ish data fetching.
##
## Replaces three split tools: web_search, web_fetch, http_request.
##
## Actions:
##
##   search   — Query the configured search provider (Brave if
##              BRAVE_API_KEY set, DuckDuckGo otherwise). Returns
##              titles, URLs, snippets. (query, count)
##
##   fetch    — GET a URL and extract readable text from HTML/JSON.
##              Convenience for web pages. (url, maxChars)
##
##   request  — Lower-level HTTP client. Supports any method, custom
##              headers, request body. SSRF-protected (blocks
##              local/private hosts). (url, method, headers, body)
##
## Internally delegates to the existing implementations from web.nim
## and http_request.nim — this is a routing facade, not a rewrite.

import std/[asyncdispatch, json, tables]
import ../../lib/curl as curly
import ../../lib/malebolgia
import ../types
import ../spec
import web
import http_request

const ToolSpec* = spec(
  name = "web",
  description = "HTTP-ish data fetching (action=search|fetch|request); SSRF-protected",
  tags = @["web", "search", "http", "data"],
  domain = "web",
  default = true,
  heartbeatSafe = false,
  category = "web",
)

type
  WebTool* = ref object of Tool
    searchTool: WebSearchTool
    fetchTool: WebFetchTool
    httpTool: HttpRequestTool

proc newWebTool*(apiKey: string, maxResults: int, maxChars: int,
                 toolCurly: Curly, master1: sink Master,
                 master2: sink Master): WebTool =
  WebTool(
    searchTool: newWebSearchTool(apiKey, maxResults, toolCurly, master1),
    fetchTool: newWebFetchTool(maxChars, toolCurly, master2),
    httpTool: newHttpRequestTool()
  )

method name*(t: WebTool): string = "web"

method description*(t: WebTool): string =
  "HTTP-ish data fetching.\n\n" &
  "Actions:\n" &
  "  search   — query a search engine (Brave/DuckDuckGo). " &
  "Requires query.\n" &
  "  fetch    — GET a URL and extract readable text. " &
  "Requires url.\n" &
  "  request  — lower-level HTTP request with method/headers/body. " &
  "Requires url. Supports GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS. " &
  "SSRF-protected.\n\n" &
  "Use `fetch` for simple page reads, `request` when you need POST " &
  "or custom headers (APIs)."

method parameters*(t: WebTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["search", "fetch", "request"],
        "description": "Operation to perform"
      },
      "query": {
        "type": "string",
        "description": "search only — search query"
      },
      "count": {
        "type": "integer",
        "description": "search only — number of results (1-10)",
        "minimum": 1, "maximum": 10
      },
      "url": {
        "type": "string",
        "description": "fetch / request — http(s) URL"
      },
      "maxChars": {
        "type": "integer",
        "description": "fetch only — max characters to return",
        "minimum": 100
      },
      "method": {
        "type": "string",
        "description": "request only — HTTP method (default GET)",
        "default": "GET"
      },
      "headers": {
        "type": "object",
        "description": "request only — HTTP headers as key-value pairs"
      },
      "body": {
        "type": "string",
        "description": "request only — request body"
      }
    },
    "required": %*["action"]
  }.toTable

method execute*(t: WebTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (search | fetch | request)"
  let action = args["action"].getStr()
  case action
  of "search":  return await t.searchTool.execute(args)
  of "fetch":   return await t.fetchTool.execute(args)
  of "request": return await t.httpTool.execute(args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: search | fetch | request"
