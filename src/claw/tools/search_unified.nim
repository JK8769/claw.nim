## search — single tool for finding pages by query (the "navigator").
##
## Sea / ship / navigator for the internet stack:
##   web    (the sea)       — HTTP-ish data fetching: GET URLs, raw requests
##   browser(the ship)      — stateful Chromium for JS/login/interaction
##   search (the navigator) — discover pages via search engines; returns
##                            ranked results (title + url + snippet)
##
## Backend: Brave Search API when BRAVE_API_KEY is configured;
## DuckDuckGo as the always-available fallback. The actual machinery
## lives in `web.nim::WebSearchTool` — this is the standalone surface
## that lets agents call `search query=...` directly instead of
## `web action=search query=...`. Same dispatch path; cleaner naming.

import std/[asyncdispatch, json, tables]
import ../lib/curl as curly
import ../lib/malebolgia
import ./types
import ./spec
import ./web/web

const ToolSpec* = spec(
  name = "search",
  description = "Search the web for current information — returns titles, URLs, " &
                "and snippets from search results (the 'navigator' of the " &
                "internet trio). Brave when key set, DuckDuckGo fallback.",
  tags = @["web", "search", "discovery", "core"],
  searchKeywords = @["query", "google", "bing", "duckduckgo", "brave",
                      "ddg", "find on web", "lookup", "research"],
  domain = "web",
  default = true,
  heartbeatSafe = false,
  category = "web",
)

type
  SearchTool* = ref object of Tool
    inner: WebSearchTool

proc newSearchTool*(apiKey: string, maxResults: int,
                    toolCurly: Curly, master: sink Master): SearchTool =
  ## Constructor mirrors WebSearchTool's. The inner tool carries the
  ## actual Brave/DuckDuckGo logic; we just rebrand it as `search`.
  SearchTool(inner: newWebSearchTool(apiKey, maxResults, toolCurly, master))

method name*(t: SearchTool): string = "search"

method description*(t: SearchTool): string =
  "Search the web for current information. Returns ranked results: " &
  "title, URL, snippet for each. Uses Brave Search when BRAVE_API_KEY " &
  "is set; falls back to DuckDuckGo otherwise.\n\n" &
  "When to use:\n" &
  "  • Researching a topic or looking up current information\n" &
  "  • Finding documentation, articles, or references\n" &
  "  • Discovery (you don't know the URL yet)\n\n" &
  "Use `web action=fetch url=...` to retrieve a specific URL's content. " &
  "Use `browser` for JS-rendered pages, logins, or multi-step interaction."

method parameters*(t: SearchTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "query": {
        "type": "string",
        "description": "Search query (natural language or keywords)"
      },
      "count": {
        "type": "integer",
        "description": "Number of results (1-10). Default: provider's max (typically 5).",
        "minimum": 1,
        "maximum": 10
      }
    },
    "required": %["query"]
  }.toTable

method execute*(t: SearchTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Delegate to the inner WebSearchTool. All logic preserved verbatim —
  ## this tool is purely a rename + first-class-surface promotion.
  return await t.inner.execute(args)
