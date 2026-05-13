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

proc newChannelTool*(): ChannelTool = ChannelTool()

method name*(t: ChannelTool): string = "channel"

method description*(t: ChannelTool): string =
  "Channel transport navigator — what vendors are running and what each " &
  "can carry. Read-only.\n\n" &
  "Actions:\n" &
  "  list          — enabled vendors + running status\n" &
  "  capabilities  — feature matrix for one vendor (text length, markdown, " &
                    "card kind, file/voice/react/edit/delete/threading, formatting)\n\n" &
  "For sending: use `chat send` (real-time) or `mail send` (persistent). " &
  "For routing to a specific recipient: use `social route to=nc:X`."

method parameters*(t: ChannelTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["list", "capabilities"],
        "description": "Operation to perform"
      },
      "vendor": {
        "type": "string",
        "description": "capabilities — vendor name (feishu, telegram, " &
                       "discord, nmobile, whatsapp, dingtalk, qq, maixcam, zen)"
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
  else:
    return """{"error":"unknown_action","action":"""" & action & """"}"""
