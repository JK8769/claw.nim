import std/[asyncdispatch, json, tables, strutils, uri]
import regex
import ../lib/curl as curly, webby/httpheaders
import ../lib/malebolgia
import types

const userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
const browserHeaders = [
  ("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"),
  ("Accept-Language", "en-US,en;q=0.9"),
  ("Cache-Control", "max-age=0"),
  ("Sec-Ch-Ua", "\"Not(A:Brand\";v=\"24\", \"Chromium\";v=\"122\", \"Google Chrome\";v=\"122\""),
  ("Sec-Ch-Ua-Mobile", "?0"),
  ("Sec-Ch-Ua-Platform", "\"macOS\""),
  ("Sec-Fetch-Dest", "document"),
  ("Sec-Fetch-Mode", "navigate"),
  ("Sec-Fetch-Site", "none"),
  ("Sec-Fetch-User", "?1"),
  ("Upgrade-Insecure-Requests", "1")
]

proc applyBrowserHeaders(headers: var HttpHeaders) =
  headers["User-Agent"] = userAgent
  for (k, v) in browserHeaders:
    headers[k] = v

type
  WebSearchTool* = ref object of Tool
    apiKey*: string
    maxResults*: int
    curly*: Curly
    master*: Master

proc newWebSearchTool*(apiKey: string, maxResults: int, curly: Curly, master: sink Master): WebSearchTool =
  let count = if maxResults <= 0 or maxResults > 10: 5 else: maxResults
  WebSearchTool(apiKey: apiKey, maxResults: count, curly: curly, master: master)

method name*(t: WebSearchTool): string = "web_search"
method description*(t: WebSearchTool): string = "Search the web for current information. Returns titles, URLs, and snippets from search results."
method parameters*(t: WebSearchTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "query": {
        "type": "string",
        "description": "Search query"
      },
      "count": {
        "type": "integer",
        "description": "Number of results (1-10)",
        "minimum": 1,
        "maximum": 10
      }
    },
    "required": %["query"]
  }.toTable

proc extractDuckDuckGoResults*(query: string, maxResults: int, rootVal: JsonNode): string =
  var lines: seq[string] = @[]
  lines.add("Results for: " & query)
  
  var entriesAdded = 0

  proc addResult(title, url, snippet: string) =
    if entriesAdded >= maxResults: return
    if title.len == 0 or url.len == 0: return
    # Avoid duplicates
    for line in lines:
      if url in line: return
    lines.add("$1. $2\n   $3\n   $4".format(entriesAdded + 1, title, url, snippet))
    inc entriesAdded

  # 1. Check top-level Abstract
  let heading = rootVal.getOrDefault("Heading").getStr("")
  let abstractText = rootVal.getOrDefault("AbstractText").getStr("")
  let abstractUrl = rootVal.getOrDefault("AbstractURL").getStr("")
  if abstractText.len > 0:
    addResult(if heading.len > 0: heading else: abstractText, abstractUrl, abstractText)

  # 2. Check Results array (often contains the actual external links)
  if rootVal.hasKey("Results") and rootVal["Results"].kind == JArray:
    for res in rootVal["Results"]:
      let url = res.getOrDefault("FirstURL").getStr("")
      let text = if url.contains("/"): url.split("/")[^1].replace("_", " ") else: "Result"
      addResult(text, url, res.getOrDefault("Text").getStr(""))

  # 3. Process RelatedTopics
  proc processTopics(topics: JsonNode) =
    if topics.kind != JArray: return
    for topic in topics:
      if entriesAdded >= maxResults: break
      if topic.hasKey("Topics"):
        processTopics(topic["Topics"])
      else:
        let text = topic.getOrDefault("Text").getStr("")
        let url = topic.getOrDefault("FirstURL").getStr("")
        if url.len > 0:
          addResult(text, url, text)

  if rootVal.hasKey("RelatedTopics"):
    processTopics(rootVal["RelatedTopics"])

  if entriesAdded == 0:
    return "No web results found."
  
  return lines.join("\n")

proc doWebSearchRequest(c: Curly, url: string, headers: HttpHeaders): tuple[code: int, body: string] =
  try:
    let resp = c.get(url, headers = headers)
    return (resp.code, resp.body)
  except Exception as e:
    return (-1, e.msg)

proc extractDuckDuckGoHTML(body: string, maxResults: int): string =
  var lines: seq[string] = @[]
  var entriesAdded = 0
  
  # Very simple HTML scraping for html.duckduckgo.com
  var pos = 0
  while entriesAdded < maxResults:
    let titleStart = body.find("result__title", pos)
    if titleStart == -1: break
    
    let aStart = body.find("<a", titleStart)
    if aStart == -1: break
    let hrefStart = body.find("href=\"", aStart)
    if hrefStart == -1: break
    let hrefEnd = body.find("\"", hrefStart + 6)
    if hrefEnd == -1: break
    var url = body[hrefStart + 6 ..< hrefEnd]
    if url.startsWith("//"): url = "https:" & url
    elif url.startsWith("/"): url = "https://duckduckgo.com" & url
    
    let contentStart = body.find(">", hrefEnd)
    if contentStart == -1: break
    let contentEnd = body.find("</a>", contentStart)
    if contentEnd == -1: break
    let title = body[contentStart + 1 ..< contentEnd].replace(re2"<[^>]*>", "").strip()
    
    # Snippet
    let snippetStart = body.find("result__snippet", contentEnd)
    var snippet = ""
    if snippetStart != -1:
      let sContentStart = body.find(">", snippetStart)
      if sContentStart != -1:
        let sContentEnd = body.find("</a>", sContentStart)
        if sContentEnd != -1:
          snippet = body[sContentStart + 1 ..< sContentEnd].replace(re2"<[^>]*>", "").strip()
    
    if url.len > 0 and title.len > 0:
      lines.add("$1. $2\n   $3\n   $4".format(entriesAdded + 1, title, url, snippet))
      inc entriesAdded
    
    pos = if snippetStart != -1: snippetStart else: contentEnd
    
  if entriesAdded == 0:
    return "No web results found."
  return lines.join("\n")

proc doWebHTMLSearch(c: Curly, query: string, headers: HttpHeaders): tuple[code: int, body: string] =
  # Try the standard /html/ path which is sometimes less restricted than html.
  let url = "https://duckduckgo.com/html/?q=" & encodeUrl(query)
  try:
    let resp = c.get(url, headers = headers)
    return (resp.code, resp.body)
  except Exception as e:
    return (-1, e.msg)

method execute*(t: WebSearchTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("query"): return "Error: query is required"
  let query = args["query"].getStr()
  var count = t.maxResults
  if args.hasKey("count"):
    count = args["count"].getInt()
    if count <= 0 or count > 10: count = t.maxResults

  # Mock provider extraction - ideally passed in from agent config
  # For now, if no API key is set, we fallback to duckduckgo as a free option
  let activeProvider = if t.apiKey == "": "duckduckgo" else: "brave"

  var headers = emptyHttpHeaders()
  applyBrowserHeaders(headers)

  if activeProvider == "duckduckgo":
    let searchURL = "https://api.duckduckgo.com/?q=$1&format=json&no_html=1&skip_disambig=1".format(encodeUrl(query))
    
    let fv = t.master.spawn doWebSearchRequest(t.curly, searchURL, headers)

    while not fv.isReady:
      await sleepAsync(10)
    
    let (code, body) = fv.sync()
    if code == -1:
      return "Error: duckduckgo search failed: " & body
    
    try:
      let jsonResp = parseJson(body)
      let results = extractDuckDuckGoResults(query, count, jsonResp)
      if results != "No web results found.":
        return results
      
      # Fallback to HTML scraping
      let fvHtml = t.master.spawn doWebHTMLSearch(t.curly, query, headers)
      while not fvHtml.isReady:
        await sleepAsync(10)
      let (codeHtml, bodyHtml) = fvHtml.sync()
      if codeHtml == 200:
        return extractDuckDuckGoHTML(bodyHtml, count)
      return results
    except Exception as e:
      # If JSON fails, it might be the HTML version already or an error
      let fvHtml = t.master.spawn doWebHTMLSearch(t.curly, query, headers)
      while not fvHtml.isReady:
        await sleepAsync(10)
      let (codeHtml, bodyHtml) = fvHtml.sync()
      if codeHtml == 200:
        return extractDuckDuckGoHTML(bodyHtml, count)
      return "Error: failed to search duckduckgo: " & e.msg

  elif activeProvider == "brave":
    if t.apiKey == "" or t.apiKey.startsWith("${"): return "Error: BRAVE_API_KEY not configured. Run: nimclaw service auth set BRAVE_API_KEY"
    headers["Accept"] = "application/json"
    headers["X-Subscription-Token"] = t.apiKey
    let searchURL = "https://api.search.brave.com/res/v1/web/search?q=$1&count=$2".format(encodeUrl(query), count)

    let fv = t.master.spawn doWebSearchRequest(t.curly, searchURL, headers)

    while not fv.isReady:
      await sleepAsync(10)
    
    let (code, body) = fv.sync()
    if code == -1:
      return "Error: brave search failed: " & body

    try:
      let jsonResp = parseJson(body)

      if not jsonResp.hasKey("web") or not jsonResp["web"].hasKey("results"):
        return "No results for: " & query

      let results = jsonResp["web"]["results"]
      if results.len == 0:
        return "No results for: " & query

      var lines: seq[string] = @[]
      lines.add("Results for: " & query)
      for i in 0 ..< min(results.len, count):
        let item = results[i]
        lines.add("$1. $2\n   $3".format(i + 1, item["title"].getStr(), item["url"].getStr()))
        if item.hasKey("description"):
          lines.add("   " & item["description"].getStr())

      return lines.join("\n")
    except Exception as e:
      return "Error: failed to parse brave JSON: " & e.msg
  else:
    return "Error: unknown search provider"

type
  WebFetchTool* = ref object of Tool
    maxChars*: int
    curly*: Curly
    master*: Master

proc newWebFetchTool*(maxChars: int, curly: Curly, master: sink Master): WebFetchTool =
  let count = if maxChars <= 0: 50000 else: maxChars
  WebFetchTool(maxChars: count, curly: curly, master: master)

proc doWebFetchRequest(c: Curly, url: string, headers: HttpHeaders): tuple[code: int, body: string, contentType: string] =
  try:
    let resp = c.get(url, headers = headers)
    var ct = ""
    # HttpHeaders is a distinct seq[(string, string)] in webby
    for header in seq[(string, string)](resp.headers):
      if header[0].toLowerAscii == "content-type":
        ct = header[1]
        break
    return (resp.code, resp.body, ct)
  except Exception as e:
    return (-1, e.msg, "")

method name*(t: WebFetchTool): string = "web_fetch"
method description*(t: WebFetchTool): string = "Fetch a URL and extract readable content (HTML to text). Use this to get weather info, news, articles, or any web content."
method parameters*(t: WebFetchTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "url": {
        "type": "string",
        "description": "URL to fetch"
      },
      "maxChars": {
        "type": "integer",
        "description": "Maximum characters to extract",
        "minimum": 100
      }
    },
    "required": %["url"]
  }.toTable

proc extractText(html: string): string =
  result = html
  result = result.replace(re2"(?s)<script[\s\S]*?<\/script>", "")
  result = result.replace(re2"(?s)<style[\s\S]*?<\/style>", "")
  result = result.replace(re2"<[^>]+>", "")
  result = result.replace(re2"\s+", " ")
  result = result.strip()

method execute*(t: WebFetchTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("url"): return "Error: url is required"
  let urlStr = args["url"].getStr()

  let u = parseUri(urlStr)
  if u.scheme != "http" and u.scheme != "https":
    return "Error: only http/https URLs are allowed"

  var maxChars = t.maxChars
  if args.hasKey("maxChars"):
    let mc = args["maxChars"].getInt()
    if mc > 100: maxChars = mc

  var headers = emptyHttpHeaders()
  applyBrowserHeaders(headers)

  let fv = t.master.spawn doWebFetchRequest(t.curly, urlStr, headers)

  while not fv.isReady:
    await sleepAsync(10)
  
  let (code, body, contentType) = fv.sync()
  if code == -1:
    return "Error: fetch failed: " & body

  var text = ""
  var extractor = ""

  if contentType.contains("application/json"):
    text = body # Could format it if we wanted
    extractor = "json"
  elif contentType.contains("text/html") or body.startsWith("<!DOCTYPE") or body.toLowerAscii.startsWith("<html"):
    text = extractText(body)
    extractor = "text"
  else:
    text = body
    extractor = "raw"

  let truncated = text.len > maxChars
  if truncated:
    text = text[0 ..< maxChars]

  let resObj = %*{
    "url": urlStr,
    "status": code,
    "extractor": extractor,
    "truncated": truncated,
    "length": text.len,
    "text": text
  }
  return resObj.pretty()
