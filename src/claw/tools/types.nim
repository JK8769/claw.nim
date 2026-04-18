import std/[json, tables, asyncdispatch]

import ../agent/cortex

type
  ToolContext* = object
    channel*: string
    chatID*: string
    sessionKey*: string
    senderID*: string
    recipientID*: string
    role*: string
    agentName*: string
    agentID*: string
    logicalUserID*: string
    appID*: string
    replyToMessageID*: string
    graph*: WorldGraph
    entity*: string
    identity*: string

  Tool* = ref object of RootObj
    toolTags*: seq[string]  ## Tags for discovery, ordered by importance (first = primary)
    searchHint*: string     ## Curated 3-10 word phrase for find_tools discovery

method name*(t: Tool): string {.base.} = ""
method description*(t: Tool): string {.base.} = ""
method parameters*(t: Tool): Table[string, JsonNode] {.base.} = initTable[string, JsonNode]()
method execute*(t: Tool, args: Table[string, JsonNode]): Future[string] {.base, async.} = return ""

proc tags*(t: Tool): seq[string] = t.toolTags
proc setTags*(t: Tool, tags: seq[string]) = t.toolTags = tags
proc setSearchHint*(t: Tool, hint: string) = t.searchHint = hint

type
  ContextualTool* = ref object of Tool
    channel*: string
    chatID*: string
    sessionKey*: string
    senderID*: string
    recipientID*: string
    role*: string
    agentName*: string
    agentID*: string
    logicalUserID*: string
    graph*: WorldGraph
    appID*: string
    replyToMessageID*: string

  SendCallback* = proc(channel, chatID, content, senderAgent, replyToMessageID, appID: string, metadata: Table[string, string] = initTable[string, string]()): Future[void]

method setContext*(t: ContextualTool, ctx: ToolContext) {.base.} =
  t.channel = ctx.channel
  t.chatID = ctx.chatID
  t.sessionKey = ctx.sessionKey
  t.senderID = ctx.senderID
  t.recipientID = ctx.recipientID
  t.role = ctx.role
  t.agentName = ctx.agentName
  t.agentID = ctx.agentID
  t.logicalUserID = ctx.logicalUserID
  t.graph = ctx.graph
  t.appID = ctx.appID
  t.replyToMessageID = ctx.replyToMessageID

