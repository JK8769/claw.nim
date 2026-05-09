## browser — single tool for browser interaction.
##
## Replaces two split tools: browser_open, playwright.
##
## Actions:
##
##   open      — Launch the system browser to a URL. Allowlisted
##               domains only. Returns immediately. (url)
##
##   automate  — Browser automation via Playwright CLI. Issue navigate,
##               click, type, screenshot, etc. as a single command
##               string. Requires `npx` available at gateway start;
##               otherwise this action returns an error explaining
##               how to enable it. (command)
##
## Internally delegates to the existing BrowserOpenTool and
## PlaywrightTool implementations — this is a routing facade.

import std/[asyncdispatch, json, tables]
import ../types
import ../spec
import browser_open
import playwright

const ToolSpec* = spec(
  name = "browser",
  description = "browser interaction (action=open URL or action=automate via Playwright CLI)",
  tags = @["browser", "web", "ui", "automation"],
  domain = "web",
  default = true,
  heartbeatSafe = false,
  category = "web",
)

type
  BrowserTool* = ref object of Tool
    openTool: BrowserOpenTool
    pwTool: PlaywrightTool       ## may be nil if npx unavailable

proc newBrowserTool*(allowedDomains: seq[string],
                     pwTool: PlaywrightTool = nil): BrowserTool =
  BrowserTool(
    openTool: newBrowserOpenTool(allowedDomains),
    pwTool: pwTool
  )

method name*(t: BrowserTool): string = "browser"

method description*(t: BrowserTool): string =
  "Browser interaction.\n\n" &
  "Actions:\n" &
  "  open      — launch system browser to an allowlisted URL " &
  "(requires url)\n" &
  "  automate  — Playwright CLI for navigate / click / type / " &
  "screenshot / etc. (requires command string; e.g. " &
  "'goto https://example.com', 'snapshot', 'click e5', " &
  "'fill e12 \"text\"'). Use snapshot first to discover element refs."

method parameters*(t: BrowserTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["open", "automate"],
        "description": "Operation to perform"
      },
      "url": {
        "type": "string",
        "description": "open only — https URL to launch"
      },
      "command": {
        "type": "string",
        "description": "automate only — playwright-cli command (e.g. 'goto https://example.com', 'snapshot', 'click e5')"
      }
    },
    "required": %*["action"]
  }.toTable

method execute*(t: BrowserTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (open | automate)"
  let action = args["action"].getStr()
  case action
  of "open":
    return await t.openTool.execute(args)
  of "automate":
    if t.pwTool.isNil:
      return "Error: browser automation unavailable. Playwright CLI " &
             "requires `npx` (Node.js). Install Node, then restart " &
             "the gateway. The `open` action does not require this."
    return await t.pwTool.execute(args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: open | automate"
