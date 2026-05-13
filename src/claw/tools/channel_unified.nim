## channel — vendor-level facts about the comm transports.
##
## Read-only navigator over the running channel manager. Doesn't speak —
## chat / mail are the protocol verbs that carry messages. `channel` tells
## the caller WHICH transports exist and WHAT each one can carry; chat /
## mail consult that to make format-promotion decisions without hardcoding
## "if vendor == feishu" anywhere.
##
##   action=list           — every channel registered + running flag
##   action=capabilities   — feature matrix for one vendor (text length,
##                           markdown, card kind, file/voice/react/edit/
##                           delete/threading, formatting list)
##
## Routing decisions ("how do I reach nc:7?") live in `social` — addresses
## belong to the recipient, not to the transport. This tool is purely about
## transport capabilities.

import std/[json, asyncdispatch, tables, options, strutils]
import ./types
import ./spec
import ./registry
import ./vendor_dispatch
import ../channels/base as channel_base
import ../channels/access

const ToolSpec* = spec(
  name = "channel",
  description = "Channel transport navigator — list enabled vendors and " &
                "their feature matrices (text/card/file/voice/react/edit/" &
                "delete/threading + formatting). Read-only. For routing to " &
                "a specific recipient, use social. For sending, use chat / mail.",
  tags = @["comm", "channel", "transport", "core"],
  searchKeywords = @["channel list", "channel capabilities", "vendor list",
                     "vendor features", "transport", "feishu", "telegram",
                     "discord", "nmobile", "whatsapp", "dingtalk", "qq",
                     "max length", "supports markdown", "supports card",
                     "supports file"],
  domain = "comm",
  default = false, heartbeatSafe = false, category = "messaging",
)

type
  ChannelTool* = ref object of Tool
    reg*: ToolRegistry  ## live registry — scanned per-call to find
                         ## vendor MCP tools (`mcp_<vendor>_<op>`) for
                         ## the docs / sheets / calendar / tasks actions.

proc newChannelTool*(reg: ToolRegistry = nil): ChannelTool =
  ChannelTool(reg: reg)

method name*(t: ChannelTool): string = "channel"

method description*(t: ChannelTool): string =
  "Channel transport navigator AND vendor-feature gateway. Two surface " &
  "areas:\n\n" &
  "READ-ONLY (transport metadata):\n" &
  "  list          — enabled vendors + running status\n" &
  "  capabilities  — feature matrix for one vendor (text length, markdown, " &
                    "card kind, file/voice/react/edit/delete/threading, formatting)\n\n" &
  "VENDOR-FEATURE DISPATCH (request/reply features per vendor — docs, " &
  "sheets, calendar, tasks; routes to mcp_<vendor>_<op> tools):\n" &
  "  docs vendor=feishu op=create|fetch  — Lark Docs / Notion pages / etc.\n" &
  "  sheets vendor=feishu op=read|write  — spreadsheet ops\n" &
  "  calendar vendor=feishu op=create_event|list  — calendar ops\n" &
  "  tasks vendor=feishu op=create|list  — task management\n\n" &
  "For sending messages: use `chat send` (real-time) or `mail send` " &
  "(persistent). For routing to a specific recipient: `social route`."

method parameters*(t: ChannelTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["list", "capabilities",
                 "docs", "sheets", "calendar", "tasks"],
        "description": "Operation to perform. list/capabilities are " &
                       "read-only. docs/sheets/calendar/tasks dispatch " &
                       "to the named vendor's mcp_<vendor>_<action>_<op> tool."
      },
      "vendor": {
        "type": "string",
        "description": "Vendor name (feishu, telegram, discord, nmobile, " &
                       "whatsapp, dingtalk, qq, maixcam, zen). Required for " &
                       "capabilities and for all vendor-feature actions."
      },
      "op": {
        "type": "string",
        "description": "docs/sheets/calendar/tasks — sub-operation (e.g. " &
                       "create, fetch, read, write, list). Maps to the " &
                       "tool name suffix: docs op=create → mcp_<vendor>_docs_create."
      },
      "args": {
        "type": "object",
        "description": "docs/sheets/calendar/tasks — args passed to the " &
                       "vendor's tool. Shape is vendor-specific; consult " &
                       "the vendor skill's README."
      }
    },
    "required": %["action"]
  }.toTable

# ── Action handlers ─────────────────────────────────────────────────

proc capsToJson(caps: channel_base.ChannelCapabilities): JsonNode =
  result = %*{
    "text": {
      "max_length": caps.text.max_length,
      "markdown": caps.text.markdown
    },
    "file": caps.file,
    "voice": caps.voice,
    "react": caps.react,
    "edit": caps.edit,
    "delete": caps.delete,
    "threading": caps.threading,
    "formatting": caps.formatting
  }
  if caps.card.isSome:
    let c = caps.card.get
    result["card"] = %*{"kind": c.kind, "interactive": c.interactive}
  else:
    result["card"] = newJNull()

proc doList(): string =
  let names = listEnabledChannels()
  var rows = newJArray()
  for n in names:
    var row = %*{"name": n, "running": isChannelRunning(n)}
    let cv = getChannelCaps(n)
    if cv.isSome:
      let caps = cv.get
      row["text_max"] = %caps.text.max_length
      row["card"] = if caps.card.isSome: %caps.card.get.kind else: newJNull()
      row["file"] = %caps.file
    rows.add(row)
  return $rows

proc doCapabilities(vendor: string): string =
  if vendor.len == 0:
    return """{"error":"missing_vendor"}"""
  let cv = getChannelCaps(vendor)
  if cv.isNone:
    return """{"error":"vendor_not_enabled","vendor":"""" & vendor & """"}"""
  return $capsToJson(cv.get)

# ── vendor-feature dispatch (docs / sheets / calendar / tasks) ──────

proc doVendorFeature(t: ChannelTool, action: string,
                     args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Routes `channel <feature> vendor=X op=Y args={...}` to the matching
  ## `mcp_<vendor>_<feature>_<op>` tool registered by the vendor's MCP
  ## server. Mirrors the solar-adapter dispatch pattern.
  if t.reg.isNil:
    return """{"error":"channel_tool_not_bound_to_registry"}"""
  if not args.hasKey("vendor") or args["vendor"].getStr().len == 0:
    return """{"error":"missing_vendor","action":"""" & action & """"}"""
  if not args.hasKey("op") or args["op"].getStr().len == 0:
    return """{"error":"missing_op","action":"""" & action & """"}"""
  let vendor = args["vendor"].getStr()
  let op = args["op"].getStr()
  let contractTool = action & "_" & op  # e.g. "docs_create", "sheets_read"
  # Args to forward — extract `args` payload if present, else pass through.
  var fwd: Table[string, JsonNode]
  if args.hasKey("args") and args["args"].kind == JObject:
    for k, v in args["args"]: fwd[k] = v
  else:
    for k, v in args:
      if k notin ["action", "vendor", "op", "args"]: fwd[k] = v
  return await dispatchToVendor(t.reg, vendor, contractTool, fwd)

# ── dispatch ────────────────────────────────────────────────────────

method execute*(t: ChannelTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return """{"error":"missing_action"}"""
  let action = args["action"].getStr().toLowerAscii()
  case action:
  of "list":
    return doList()
  of "capabilities":
    let vendor = if args.hasKey("vendor"): args["vendor"].getStr() else: ""
    return doCapabilities(vendor)
  of "docs", "sheets", "calendar", "tasks":
    return await doVendorFeature(t, action, args)
  else:
    return """{"error":"unknown_action","action":"""" & action & """"}"""
