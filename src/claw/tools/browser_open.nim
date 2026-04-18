import std/[json, tables, strutils, browsers, asyncdispatch]
import types

type
  BrowserOpenTool* = ref object of Tool
    allowedDomains*: seq[string]

proc newBrowserOpenTool*(allowedDomains: seq[string]): BrowserOpenTool =
  BrowserOpenTool(allowedDomains: allowedDomains)

method name*(t: BrowserOpenTool): string = "browser_open"

method description*(t: BrowserOpenTool): string = "Open an approved HTTPS URL in the default browser. Only allowlisted domains are permitted."

method parameters*(t: BrowserOpenTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "url": {"type": "string", "description": "HTTPS URL to open in browser"}
    },
    "required": %*["url"]
  }.toTable

proc isLocalOrPrivate*(host: string): bool =
  if host == "localhost": return true
  if host.endsWith(".localhost"): return true
  if host.endsWith(".local"): return true
  if host == "::1": return true

  if host.startsWith("10."): return true
  if host.startsWith("127."): return true
  if host.startsWith("192.168."): return true
  if host.startsWith("169.254."): return true

  return false

proc hostMatchesAllowlist*(host: string, allowed: seq[string]): bool =
  for domain in allowed:
    if host == domain: return true
    if host.len > domain.len:
      let prefixLen = host.len - domain.len
      if host[prefixLen..^1] == domain and host[prefixLen - 1] == '.':
        return true
  return false

method execute*(t: BrowserOpenTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let url = if args.hasKey("url"): args["url"].getStr() else: ""
  if url == "": return "Missing 'url' parameter"

  if not url.startsWith("https://"):
    return "Only https:// URLs are allowed"

  let rest = url["https://".len..^1]
  let hostEnd = rest.find({'/', '?', '#'})
  let authority = if hostEnd != -1: rest[0..<hostEnd] else: rest

  if authority.len == 0:
    return "URL must include a host"

  let colon = authority.find(':')
  let host = if colon != -1: authority[0..<colon] else: authority

  if isLocalOrPrivate(host):
    return "Blocked local/private host"

  if t.allowedDomains.len == 0:
    return "No allowed_domains configured for browser_open"

  if not hostMatchesAllowlist(host, t.allowedDomains):
    return "Host is not in browser allowed_domains"

  when not defined(testing):
    try:
      openDefaultBrowser(url)
    except Exception as e:
      return "Browser command failed: " & e.msg

  return "Opened in browser: " & url
