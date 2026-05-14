## web — single tool for HTTP-ish data fetching (the "sea").
##
## Sea / ship / navigator for the internet stack:
##   web    (the sea)       — HTTP-ish data fetching: GET URLs, raw requests
##   browser(the ship)      — stateful Chromium for JS/login/interaction
##   search (the navigator) — discover pages via search engines
##
## Actions:
##
##   fetch    — GET a URL and extract readable text from HTML/JSON.
##              Convenience for web pages. (url, maxChars)
##
##   request  — Lower-level HTTP client. Supports any method, custom
##              headers, request body. SSRF-protected (blocks
##              local/private hosts). (url, method, headers, body)
##
## For search engine queries use the standalone `search` tool —
## extracted out of `web` so the action surface is purely transport.
## For JS-rendered pages, login flows, or multi-step interaction,
## use `browser` instead (heavier, stateful).
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
  description = "HTTP fetching (method=fetch|request); SSRF-protected. " &
                "For search engines use the standalone `search` tool.",
  tags = @["web", "http", "data"],
  domain = "web",
  default = true,
  heartbeatSafe = false,
  category = "web",
)

type
  WebTool* = ref object of Tool
    fetchTool: WebFetchTool
    httpTool: HttpRequestTool

proc newWebTool*(maxChars: int, toolCurly: Curly, master: sink Master): WebTool =
  ## Constructor — no longer takes a search-engine apiKey or maxResults
  ## (those moved to the standalone `search` tool's constructor).
  WebTool(
    fetchTool: newWebFetchTool(maxChars, toolCurly, master),
    httpTool: newHttpRequestTool()
  )

method name*(t: WebTool): string = "web"

method description*(t: WebTool): string =
  "HTTP fetching (the 'sea' of the internet trio).\n\n" &
  "Actions:\n" &
  "  fetch    — GET a URL and extract readable text. Requires url.\n" &
  "  request  — lower-level HTTP request with method/headers/body. " &
  "Requires url. Supports GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS. " &
  "SSRF-protected.\n\n" &
  "Use `fetch` for simple page reads, `request` when you need POST " &
  "or custom headers (APIs).\n\n" &
  "For SEARCH ENGINE queries: use the standalone `search` tool.\n" &
  "For JS-rendered/interactive pages: use `browser`."

method parameters*(t: WebTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["fetch", "request"],
        "description": "Operation to perform"
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
    "required": %*["method"]
  }.toTable

method execute*(t: WebTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("method"):
    return "Error: 'method' is required (fetch | request). " &
           "For search engine queries use the standalone `search` tool."
  let action = getMethodArg(args)
  case action
  of "fetch":   return await t.fetchTool.execute(args)
  of "request": return await t.httpTool.execute(args)
  of "search":
    return "Error: `web method=search` was moved to the standalone " &
           "`search` tool. Call `search query=...` instead."
  else:
    return "Error: Unknown action '" & action &
           "'. Use: fetch | request"
