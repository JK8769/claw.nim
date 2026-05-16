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

import std/[asyncdispatch, json, tables, strutils]
import ../types
import ../spec
import browser_open
import playwright

const ToolSpec* = spec(
  name = "browser",
  description = "browser interaction (method=open URL or method=automate via Playwright CLI)",
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
  "  open      — launch SYSTEM browser to an allowlisted URL " &
  "(requires url; visible to the user; needs BROWSER_ALLOWED_DOMAINS " &
  "env var to be configured).\n" &
  "  automate  — HEADLESS browser automation via Playwright CLI " &
  "(separate path from `open`). Issue Playwright commands like " &
  "'goto https://example.com', 'snapshot', 'click e5', 'fill e12 \"text\"'. " &
  "The Playwright context auto-initializes on first call — you do NOT " &
  "need to run `open` first to use `automate`. Workflow: " &
  "1) `command='goto <url>'` to navigate; " &
  "2) `command='snapshot'` to dump the rendered page text + element refs; " &
  "3) interact via `click`/`fill` referring to those refs."

method parameters*(t: BrowserTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
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
    "required": %*["method"]
  }.toTable

method execute*(t: BrowserTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("method"):
    return "Error: 'method' is required (open | automate)"
  let action = getMethodArg(args)
  case action
  of "open":
    return await t.openTool.execute(args)
  of "automate":
    if t.pwTool.isNil:
      return "Error: browser automation unavailable. Playwright CLI " &
             "requires `npx` (Node.js). Install Node, then restart " &
             "the gateway. The `open` action does not require this."
    # Auto-init: Playwright CLI is stateful. The FIRST `automate` call on
    # a cold context returns: "The browser 'default' is not open, please
    # run open first". Detect that and transparently retry — call
    # `open` (the Playwright open subcommand, NOT the system-browser
    # `method=open` path) to bootstrap the context, then re-issue the
    # original command. Costs one extra round-trip on the first hit per
    # session; subsequent calls reuse the context.
    let firstResult = await t.pwTool.execute(args)
    if "is not open" in firstResult and "please run open" in firstResult:
      var openArgs = initTable[string, JsonNode]()
      openArgs["command"] = %"open --browser chromium"
      let openResult = await t.pwTool.execute(openArgs)
      if openResult.startsWith("Error"):
        return "Error: auto-init failed when bootstrapping the Playwright " &
               "context. open subcommand returned:\n" & openResult & "\n\n" &
               "Original command's error was:\n" & firstResult
      return await t.pwTool.execute(args)
    return firstResult
  else:
    return "Error: Unknown action '" & action &
           "'. Use: open | automate"
