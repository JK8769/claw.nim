import std/[asyncdispatch, json, tables, osproc, streams, strutils, os, sets]
import ../tools/types
import ../logger

type
  McpClient* = ref object
    process: Process
    idCounter: int
    pendingRequests: Table[int, Future[JsonNode]]
    serverName*: string
    serverVersion*: string
    outputThread: Thread[McpClient]
    outputChannel: Channel[string]
    sandboxPrefix*: seq[string] # Optional: ["sandbox-exec", "-p", "..."]
    namePrefix*: string  # Short alias prefix for tool names (e.g. "pw" for Playwright)

  McpError* = object of CatchableError

proc readerThread(c: McpClient) {.thread.} =
  while c.process.running:
    let line = try:
        if not c.process.outputStream.atEnd():
          c.process.outputStream.readLine()
        else: ""
      except Exception: ""
    
    if line != "":
      c.outputChannel.send(line)
    else:
      if not c.process.running: break
      os.sleep(10)

proc readLoop(c: McpClient) {.async.} =
  while c.process.running:
    let (hasMsg, msg) = c.outputChannel.tryRecv()
    if hasMsg:
      let trimmed = msg.strip()
      if trimmed == "" or not (trimmed.startsWith("{") and trimmed.endsWith("}")):
        continue
        
      try:
        let res = parseJson(trimmed)
        if res.hasKey("id") and (res["id"].kind == JInt or res["id"].kind == JNull):
          let idNode = res["id"]
          if idNode.kind == JInt:
            let id = idNode.getInt()
            if c.pendingRequests.hasKey(id):
              let fut = c.pendingRequests[id]
              c.pendingRequests.del(id)
              if res.hasKey("result"):
                fut.complete(res["result"])
              elif res.hasKey("error"):
                fut.fail(newException(McpError, $res["error"]))
      except Exception as e:
        if trimmed.startsWith("{"):
          errorCF("mcp", "Failed to parse JSON-RPC message", {"line": trimmed, "error": e.msg}.toTable)
    else:
      await sleepAsync(10)

proc sendRequest(c: McpClient, methodStr: string, params: JsonNode): Future[JsonNode] {.async.} =
  let id = c.idCounter
  c.idCounter += 1

  let req = %*{
    "jsonrpc": "2.0",
    "id": id,
    "method": methodStr,
    "params": params
  }
  
  let reqStr = $req & "\n"
  c.process.inputStream.write(reqStr)
  c.process.inputStream.flush()
  
  let fut = newFuture[JsonNode]("mcp.request." & methodStr)
  c.pendingRequests[id] = fut
  return await fut

proc sendNotification(c: McpClient, methodStr: string, params: JsonNode) =
  let req = %*{
    "jsonrpc": "2.0",
    "method": methodStr,
    "params": params
  }
  let reqStr = $req & "\n"
  c.process.inputStream.write(reqStr)
  c.process.inputStream.flush()

proc connectMcpServer*(command: string, args: seq[string], sandbox: seq[string] = @[]): Future[McpClient] {.async.} =
  let client = McpClient(
    idCounter: 0,
    pendingRequests: initTable[int, Future[JsonNode]](),
    sandboxPrefix: sandbox
  )
  client.outputChannel.open()

  let fullCmd = if sandbox.len > 0: sandbox[0] else: command
  let fullArgs = if sandbox.len > 0: sandbox[1..^1] & @[command] & args else: args

  try:
    client.process = startProcess(
      fullCmd,
      args = fullArgs,
      options = {poUsePath, poStdErrToStdOut}
    )
  except Exception as e:
    raise newException(McpError, "Failed to start MCP server process: " & e.msg)

  createThread(client.outputThread, readerThread, client)
  asyncCheck client.readLoop()

  let initParams = %*{
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {"name": "nimclaw", "version": "0.1.0"}
  }

  let initRes = await client.sendRequest("initialize", initParams)
  client.serverName = initRes["serverInfo"]["name"].getStr()
  client.serverVersion = initRes["serverInfo"]["version"].getStr()

  client.sendNotification("notifications/initialized", %*{})
  infoCF("mcp", "Connected to MCP server", {"server": client.serverName, "version": client.serverVersion}.toTable)

  return client

proc connect*(c: McpClient, command: string, args: seq[string] = @[]): Future[void] {.async.} =
  c.process = startProcess(command, args = args, options = {poUsePath, poStdErrToStdOut})
  createThread(c.outputThread, readerThread, c)
  asyncCheck c.readLoop()
  
  let initParams = %*{
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {"name": "nimclaw", "version": "0.1.0"}
  }
  
  let initRes = await c.sendRequest("initialize", initParams)
  c.serverName = initRes["serverInfo"]["name"].getStr()
  c.serverVersion = initRes["serverInfo"]["version"].getStr()
  
  c.sendNotification("notifications/initialized", %*{})
  infoCF("mcp", "Connected to MCP server", {"server": c.serverName, "version": c.serverVersion}.toTable)

type
  McpTool* = ref object of Tool
    client: McpClient
    mcpName: string
    mcpDescription: string
    mcpParameters: JsonNode

method name*(t: McpTool): string =
  let prefix = if t.client.namePrefix.len > 0: t.client.namePrefix
               else: "mcp_" & t.client.serverName
  let rawName = prefix & "_" & t.mcpName
  return rawName.replace("-", "_")
method description*(t: McpTool): string = t.mcpDescription
method parameters*(t: McpTool): Table[string, JsonNode] =
  # Return proper JSON Schema object with type/properties wrapper
  result = initTable[string, JsonNode]()
  result["type"] = %"object"
  if t.mcpParameters.kind == JObject and t.mcpParameters.hasKey("properties"):
    result["properties"] = t.mcpParameters["properties"]
    if t.mcpParameters.hasKey("required"):
      result["required"] = t.mcpParameters["required"]
  else:
    result["properties"] = newJObject()

method execute*(t: McpTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let params = %*{"name": t.mcpName, "arguments": args}
  let res = await t.client.sendRequest("tools/call", params)
  if res.hasKey("content") and res["content"].kind == JArray:
    var output = ""
    for item in res["content"]:
      if item["type"].getStr() == "text":
        output &= item["text"].getStr()
    return output
  return $res

const
  ServerTagMap: seq[tuple[pattern: string, tags: seq[string]]] = @[
    ("playwright", @["browser", "web", "ui"]),
    ("puppeteer", @["browser", "web", "ui"]),
    ("selenium", @["browser", "web", "ui"]),
    ("git", @["git", "devops", "vcs"]),
    ("github", @["git", "devops", "vcs"]),
    ("slack", @["messaging", "communication"]),
    ("discord", @["messaging", "communication"]),
    ("docker", @["devops", "containers"]),
    ("kubernetes", @["devops", "containers"]),
    ("postgres", @["database", "sql"]),
    ("mysql", @["database", "sql"]),
    ("sqlite", @["database", "sql"]),
    ("redis", @["database", "cache"]),
    ("filesystem", @["filesystem", "data"]),
    ("aws", @["cloud", "devops"]),
    ("gcp", @["cloud", "devops"]),
  ]

  ToolNameTagMap: seq[tuple[keyword: string, tags: seq[string]]] = @[
    ("browser", @["browser", "web"]),
    ("navigate", @["browser", "web", "navigation"]),
    ("click", @["browser", "interaction"]),
    ("type", @["browser", "interaction", "form"]),
    ("screenshot", @["browser", "visual"]),
    ("snapshot", @["browser", "visual"]),
    ("file", @["filesystem"]),
    ("read", @["filesystem", "data"]),
    ("write", @["filesystem", "data"]),
    ("search", @["search", "data"]),
    ("fetch", @["web", "http"]),
    ("api", @["web", "http"]),
    ("cron", @["scheduling", "automation"]),
    ("schedule", @["scheduling", "automation"]),
    ("email", @["messaging", "communication"]),
    ("send", @["messaging"]),
    ("deploy", @["devops"]),
    ("commit", @["git", "devops"]),
  ]

proc autoTagMcp*(serverName: string, toolName: string): seq[string] =
  ## Derive tags from MCP server name and tool name using known mappings.
  var tagSet = initHashSet[string]()
  let serverLow = serverName.toLowerAscii()
  let toolLow = toolName.toLowerAscii()

  # Always include server name as a tag
  tagSet.incl(serverLow)

  # Match server name against known patterns
  for (pattern, tags) in ServerTagMap:
    if pattern in serverLow:
      for t in tags: tagSet.incl(t)

  # Match tool name parts against known keywords
  for (keyword, tags) in ToolNameTagMap:
    if keyword in toolLow:
      for t in tags: tagSet.incl(t)

  for t in tagSet: result.add(t)

proc listTools*(c: McpClient): Future[seq[McpTool]] {.async.} =
  let res = await c.sendRequest("tools/list", %*{})
  result = @[]
  if res.hasKey("tools") and res["tools"].kind == JArray:
    for tJson in res["tools"]:
      let tool = McpTool(
        client: c,
        mcpName: tJson["name"].getStr(),
        mcpDescription: tJson["description"].getStr(),
        mcpParameters: tJson["inputSchema"]
      )
      tool.setTags(autoTagMcp(c.serverName, tJson["name"].getStr()))
      result.add(tool)

proc stop*(c: McpClient) =
  if c.process != nil and c.process.running:
    c.process.terminate()
    c.process.close()
