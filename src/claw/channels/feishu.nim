import std/[asyncdispatch, json, strutils, tables, os, osproc, strtabs, streams, times, locks, typedthreads, options, unicode]
import unicodedb/[widths, properties]
import base
import ../bus, ../bus_types, ../config, ../logger

type
  FeishuTypingState = object
    reactionID: string
    appID: string

  SubscriberArgs = object
    channel: FeishuChannel
    appID: string
    larkCliBin: string
    configDir: string

  FeishuAppInstance = ref object
    appID: string
    enabled: bool
    subscribeProcess: Process
    subscriberThread: Thread[SubscriberArgs]

  FeishuChannel* = ref object of BaseChannel
    apps: seq[FeishuAppInstance]
    typing: Table[string, FeishuTypingState]
    messageCache*: Table[string, float] # message_id -> timestamp
    cacheLock*: Lock
    larkCliBin: string  # path to lark-cli binary

# --- Markdown table → Feishu post formatting utilities ---

proc splitTableRow(row: string): seq[string] =
  var s = row.strip()
  if s.startsWith("|"): s = s[1 .. ^1]
  if s.endsWith("|"): s = s[0 .. ^2]
  for part in s.split("|"):
    result.add(part.strip())

proc isTableSeparatorRow(row: string): bool =
  let cells = splitTableRow(row)
  if cells.len == 0: return false
  for c in cells:
    if c.len == 0: return false
    for ch in c:
      if ch notin {'-', ':', ' '}:
        return false
  true

proc displayWidth(s: string): int =
  for r in s.runes:
    if combining(r) != 0:
      continue
    case unicodeWidth(r)
    of uwdtWide, uwdtFull: result += 2
    else: result += 1

proc parseLine(line: string): JsonNode =
  ## Parse a single line into Feishu post elements with link and bold support.
  var paragraph = newJArray()
  var i = 0
  var buf = ""

  proc flushBuf(paragraph: JsonNode, buf: var string) =
    if buf.len > 0:
      paragraph.add(%*{"tag": "text", "text": buf})
      buf = ""

  while i < line.len:
    # Bold: **text**
    if i < line.len - 3 and line[i] == '*' and line[i+1] == '*':
      flushBuf(paragraph, buf)
      let start = i + 2
      let endPos = line.find("**", start)
      if endPos > start:
        paragraph.add(%*{"tag": "text", "text": line[start..<endPos], "style": ["bold"]})
        i = endPos + 2
      else:
        buf.add(line[i])
        inc i
    # Markdown link: [text](url)
    elif line[i] == '[':
      let textStart = i + 1
      let textEnd = line.find(']', textStart)
      if textEnd > textStart and textEnd + 1 < line.len and line[textEnd + 1] == '(':
        let urlStart = textEnd + 2
        let urlEnd = line.find(')', urlStart)
        if urlEnd > urlStart:
          flushBuf(paragraph, buf)
          paragraph.add(%*{"tag": "a", "text": line[textStart..<textEnd], "href": line[urlStart..<urlEnd]})
          i = urlEnd + 1
        else:
          buf.add(line[i])
          inc i
      else:
        buf.add(line[i])
        inc i
    # Bare URL: https:// or http://
    elif i < line.len - 7 and (line[i..min(i+6, line.len-1)] == "http://" or (i < line.len - 8 and line[i..min(i+7, line.len-1)] == "https://")):
      flushBuf(paragraph, buf)
      let urlStart = i
      while i < line.len and line[i] notin {' ', '\n', '\r', '\t', ')', '>', ']', '"', '\''}:
        inc i
      let url = line[urlStart..<i]
      var display = url
      if display.startsWith("https://"): display = display[8..^1]
      elif display.startsWith("http://"): display = display[7..^1]
      paragraph.add(%*{"tag": "a", "text": display, "href": url})
    else:
      buf.add(line[i])
      inc i

  flushBuf(paragraph, buf)
  return paragraph

proc stripMarkdown(s: string): string =
  ## Strip markdown formatting (bold, italic, etc.) for code block rendering
  result = s.replace("**", "").replace("~~", "")

proc padCell(s: string, w: int): string =
  let extra = w - displayWidth(s)
  s & ' '.repeat(max(0, extra))

proc tablesToCodeBlocks*(text: string): string =
  ## Convert markdown pipe tables to aligned code blocks for Feishu.
  ## Feishu markdown doesn't render pipe tables, but code blocks use monospace.
  let lines = text.split("\n")
  var i = 0
  var parts: seq[string]
  while i < lines.len:
    let line = lines[i]
    if i + 1 < lines.len and line.contains("|") and isTableSeparatorRow(lines[i+1]):
      # Parse full table — strip markdown first, then compute widths
      let rawHeader = splitTableRow(line)
      let numCols = rawHeader.len
      var headerCells: seq[string] = @[]
      for c in rawHeader:
        headerCells.add(stripMarkdown(c))

      var dataRows: seq[seq[string]] = @[]
      var j = i + 2
      while j < lines.len and lines[j].contains("|"):
        let rawCells = splitTableRow(lines[j])
        if rawCells.len == 0: break
        var row: seq[string] = @[]
        for ci in 0..<numCols:
          let cell = if ci < rawCells.len: stripMarkdown(rawCells[ci]) else: ""
          row.add(cell)
        dataRows.add(row)
        inc j

      # Compute column widths from cleaned text
      var colWidths = newSeq[int](numCols)
      for ci, c in headerCells:
        colWidths[ci] = max(colWidths[ci], displayWidth(c))
      for row in dataRows:
        for ci, c in row:
          colWidths[ci] = max(colWidths[ci], displayWidth(c))

      var table = "```\n"
      var headerLine = ""
      for ci, c in headerCells:
        if ci > 0: headerLine.add("  ")
        headerLine.add(padCell(c, colWidths[ci]))
      table.add(headerLine & "\n")
      var sepLine = ""
      for ci in 0..<numCols:
        if ci > 0: sepLine.add("  ")
        sepLine.add('-'.repeat(colWidths[ci]))
      table.add(sepLine & "\n")
      for dr in dataRows:
        var dataLine = ""
        for ci, c in dr:
          if ci > 0: dataLine.add("  ")
          dataLine.add(padCell(c, colWidths[ci]))
        table.add(dataLine & "\n")
      table.add("```")
      parts.add(table)
      i = j
    else:
      parts.add(line)
      inc i
  result = parts.join("\n")

proc buildPostContent*(text: string): string =
  ## Convert text to Feishu native post JSON format.
  ## Handles: bare URLs, markdown links [text](url), bold **text**, tables, and plain text.
  ## URLs become clickable {"tag": "a"} elements.
  var rows: seq[JsonNode] = @[]
  let lines = text.split("\n")

  # Table detection and rendering
  var i = 0
  while i < lines.len:
    let line = lines[i]
    # Detect table: look for separator row
    if i + 1 < lines.len and line.contains("|") and isTableSeparatorRow(lines[i+1]):
      let headerCells = splitTableRow(line)
      let numCols = headerCells.len
      var colWidths = newSeq[int](numCols)
      for ci, c in headerCells:
        colWidths[ci] = max(colWidths[ci], displayWidth(c))

      var dataRows: seq[seq[string]] = @[]
      var j = i + 2
      while j < lines.len and lines[j].contains("|"):
        let cells = splitTableRow(lines[j])
        if cells.len == 0: break
        var row: seq[string] = @[]
        for ci in 0..<numCols:
          let cell = if ci < cells.len: cells[ci] else: ""
          row.add(cell)
          colWidths[ci] = max(colWidths[ci], displayWidth(cell))
        dataRows.add(row)
        inc j

      var tableText = ""
      var headerLine = ""
      for ci, c in headerCells:
        if ci > 0: headerLine.add("  ")
        headerLine.add(padCell(c, colWidths[ci]))
      tableText.add(headerLine)

      for dr in dataRows:
        tableText.add("\n")
        var dataLine = ""
        for ci, c in dr:
          if ci > 0: dataLine.add("  ")
          dataLine.add(padCell(c, colWidths[ci]))
        tableText.add(dataLine)

      rows.add(%*[{"tag": "text", "text": tableText & "\n"}])
      i = j
      continue

    rows.add(parseLine(line))
    inc i

  result = $ %*{"zh_cn": {"content": rows}}

proc tryExtractInteractiveCard*(content: string): Option[string] =
  try:
    let j = parseJson(content)
    if j.kind != JObject: return options.none(string)

    if j.hasKey("nimclaw_feishu") and j["nimclaw_feishu"].kind == JObject:
      let nf = j["nimclaw_feishu"]
      if nf.getOrDefault("msg_type").getStr() != "interactive":
        return options.none(string)
      let card = nf.getOrDefault("card")
      if card.kind != JObject:
        return options.none(string)
      return options.some($card)

    if j.getOrDefault("msg_type").getStr() == "interactive":
      let card = j.getOrDefault("card")
      if card.kind == JObject:
        return options.some($card)
      return options.none(string)

    options.none(string)
  except:
    options.none(string)

proc tryExtractAuthFallback(text: string): Option[(string, string, int)] =
  let s = text.strip()
  if s.len == 0 or not s.startsWith("{"): return options.none((string, string, int))
  try:
    let j = parseJson(s)
    if j.kind != JObject: return options.none((string, string, int))
    let url = j.getOrDefault("verification_uri_complete").getStr(j.getOrDefault("verification_uri").getStr(""))
    let code = j.getOrDefault("user_code").getStr("")
    let expiresIn = j.getOrDefault("expires_in").getInt(0)
    if url.len == 0 and code.len == 0: return options.none((string, string, int))
    options.some((url, code, expiresIn))
  except:
    options.none((string, string, int))

proc collectJsonStrings(node: JsonNode; acc: var seq[string]) =
  if node.isNil: return
  case node.kind
  of JString: acc.add(node.getStr())
  of JObject:
    for _, v in node.getFields(): collectJsonStrings(v, acc)
  of JArray:
    for v in node.getElems(): collectJsonStrings(v, acc)
  else: discard

proc findAuthUrlInCard(node: JsonNode): string =
  if node.isNil: return ""
  if node.kind == JObject:
    if node.hasKey("multi_url") and node["multi_url"].kind == JObject:
      let mu = node["multi_url"]
      let u = mu.getOrDefault("url").getStr(mu.getOrDefault("pc_url").getStr(""))
      if u.len > 0: return u
    if node.hasKey("url") and node["url"].kind == JString:
      let u = node["url"].getStr()
      if u.startsWith("http"): return u
    for _, v in node.getFields():
      let u = findAuthUrlInCard(v)
      if u.len > 0: return u
    return ""
  if node.kind == JArray:
    for v in node.getElems():
      let u = findAuthUrlInCard(v)
      if u.len > 0: return u
    return ""
  ""

proc tryExtractUserCodeFromText(s: string): string =
  let k = "验证码"
  let pos = s.find(k)
  if pos < 0: return ""
  var i = pos + k.len
  while i < s.len:
    if s[i] in {':', ' ', '\t'}:
      inc i
      continue
    if i + 2 < s.len and s[i].ord == 0xEF and s[i + 1].ord == 0xBC and s[i + 2].ord == 0x9A:
      i += 3
      continue
    break
  if i + 1 < s.len and s[i] == '*' and s[i + 1] == '*':
    i += 2
    let j = s.find("**", i)
    if j > i: return s[i ..< j].strip()
    return ""
  var j = i
  while j < s.len and s[j] notin {' ', '\t', '\n', '\r'}: inc j
  if j > i: return s[i ..< j].strip()
  ""

proc tryExtractAuthFallbackFromCard(cardJson: string): Option[(string, string, int)] =
  let s = cardJson.strip()
  if s.len == 0 or not s.startsWith("{"): return options.none((string, string, int))
  try:
    let j = parseJson(s)
    if j.kind != JObject: return options.none((string, string, int))
    let url = findAuthUrlInCard(j)
    var texts: seq[string] = @[]
    collectJsonStrings(j, texts)
    var code = ""
    for t in texts:
      code = tryExtractUserCodeFromText(t)
      if code.len > 0: break
    if code.len == 0: return options.none((string, string, int))
    options.some((url, code, 0))
  except:
    options.none((string, string, int))

# --- Message cache persistence ---

proc getCachePath(c: FeishuChannel): string =
  getNimClawDir() / "channels" / "feishu" / "cache.json"

proc saveCache(c: FeishuChannel) =
  let path = c.getCachePath()
  try:
    createDir(parentDir(path))
    let j = %c.messageCache
    writeFile(path, $j)
  except: discard

proc loadCache(c: FeishuChannel) =
  let path = c.getCachePath()
  if fileExists(path):
    try:
      let j = parseFile(path)
      acquire(c.cacheLock)
      for k, v in j.getFields:
        c.messageCache[k] = v.getFloat()
      release(c.cacheLock)
      infoCF("feishu", "Loaded persistent message cache", {"entries": $c.messageCache.len}.toTable)
    except: discard

proc pruneCache(c: FeishuChannel) =
  let now = epochTime()
  const maxAge = 3600.0 * 24.0
  var toDel: seq[string] = @[]
  acquire(c.cacheLock)
  for k, v in c.messageCache.pairs:
    if now - v > maxAge: toDel.add k
  for k in toDel: c.messageCache.del k
  release(c.cacheLock)
  if toDel.len > 0:
    infoCF("feishu", "Pruned message cache", {"deleted": $toDel.len}.toTable)
    c.saveCache()

# --- lark-cli environment helper ---

proc buildLarkEnv(configDir: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, val in envPairs():
    result[key] = val
  result["LARKSUITE_CLI_CONFIG_DIR"] = configDir

# --- lark-cli bridge reader ---

proc startSubscriberProcess(larkCliBin, configDir: string): Process =
  let env = buildLarkEnv(configDir)
  result = startProcess(
    larkCliBin,
    args = ["event", "+subscribe", "--event-types", "im.message.receive_v1,card.action.trigger", "--compact", "--quiet"],
    env = env,
    options = {poUsePath}
  )

proc readEvents(p: Process, c: FeishuChannel, appID: string) =
  ## Read events from a single subscriber process until it dies or channel stops.
  let s = p.outputStream()
  var line = ""
  while c.running and not s.atEnd():
    try:
      if not s.readLine(line): continue
      if line.len == 0 or not line.startsWith("{"): continue

      let evt = parseJson(line)
      let evtType = evt.getOrDefault("type").getStr()

      if evtType == "card.action.trigger":
        let action = evt.getOrDefault("action")
        let context = evt.getOrDefault("context")
        let operator = evt.getOrDefault("operator")
        let chatID = context.getOrDefault("open_chat_id").getStr()
        let messageID = context.getOrDefault("open_message_id").getStr()
        let senderID = operator.getOrDefault("open_id").getStr()
        let actionValue = if action.kind == JObject: $action.getOrDefault("value") else: ""

        if chatID.len == 0:
          debugCF("feishu", "Card action without chat_id, skipping", {"event_id": evt.getOrDefault("event_id").getStr()}.toTable)
          continue

        infoCF("feishu", "Card action received", {"chat": chatID, "sender": senderID, "action": actionValue}.toTable)

        let content = "[Card button clicked: " & actionValue & "]"
        var metadata = {"message_id": messageID, "app_id": appID, "event_type": "card.action.trigger", "action_value": actionValue}.toTable
        c.handleMessage(senderID, chatID, content, @[], metadata)
        continue

      if evtType != "im.message.receive_v1":
        debugCF("feishu", "Non-IM event received", {"type": evtType}.toTable)
        continue

      let messageID = evt.getOrDefault("message_id").getStr()
      let chatID = evt.getOrDefault("chat_id").getStr()
      let senderID = evt.getOrDefault("sender_id").getStr()
      let messageType = evt.getOrDefault("message_type").getStr("text")
      let content = evt.getOrDefault("content").getStr()
      let createTimeStr = evt.getOrDefault("create_time").getStr()

      # Dedup by message_id
      if messageID.len > 0:
        let isDuplicate = block:
          acquire(c.cacheLock)
          try:
            if c.messageCache.hasKey(messageID):
              true
            else:
              c.messageCache[messageID] = epochTime()
              c.saveCache()
              false
          finally:
            release(c.cacheLock)
        if isDuplicate:
          debugCF("feishu", "Discarding duplicate", {"msg_id": messageID}.toTable)
          continue

      # Ignore stale messages (>5 min old)
      if createTimeStr.len > 0:
        let createTime = createTimeStr.parseBiggestInt
        let nowMs = (epochTime() * 1000).int64
        if createTime > 0 and (nowMs - createTime) > 300_000:
          debugCF("feishu", "Ignoring stale message", {"msg_id": messageID, "age_s": $((nowMs - createTime) div 1000)}.toTable)
          continue

      let rootID = evt.getOrDefault("root_id").getStr()
      let parentID = evt.getOrDefault("parent_id").getStr()
      let threadID = evt.getOrDefault("thread_id").getStr()
      infoCF("feishu", "Processing message", {"msg_id": messageID, "sender": senderID, "chat": chatID, "type": messageType, "root_id": rootID, "parent_id": parentID, "thread_id": threadID}.toTable)

      var finalContent = content
      var mediaPaths: seq[string] = @[]

      if messageType == "image":
        # Parse image_key from content JSON: {"image_key":"img_v3_xxx"}
        var imageKey = ""
        try:
          let contentJson = parseJson(content)
          imageKey = contentJson{"image_key"}.getStr("")
        except: discard

        if imageKey.len > 0 and messageID.len > 0:
          let mediaDir = getNimClawDir() / "channels" / "feishu" / "lark-cli-" & appID / "cache" / "media"
          try:
            createDir(mediaDir)
            let outputPath = mediaDir / imageKey & ".jpg"
            let configDir = getNimClawDir() / "channels" / "feishu" / "lark-cli-" & appID
            let env = buildLarkEnv(configDir)
            let dlProc = startProcess(c.larkCliBin,
              args = ["im", "+messages-resources-download",
                      "--message-id", messageID,
                      "--file-key", imageKey,
                      "--type", "image",
                      "--output", outputPath],
              env = env, options = {poUsePath})
            let code = dlProc.waitForExit(30000)
            dlProc.close()
            if code == 0 and fileExists(outputPath):
              mediaPaths.add(outputPath)
              finalContent = "[image: " & outputPath & "]"
              infoCF("feishu", "Downloaded image", {"file_key": imageKey, "path": outputPath}.toTable)
            else:
              finalContent = "[image: download failed for " & imageKey & "]"
              warnCF("feishu", "Image download failed", {"file_key": imageKey, "exit_code": $code}.toTable)
          except Exception as e:
            finalContent = "[image: download error: " & e.msg & "]"
            errorCF("feishu", "Image download error", {"file_key": imageKey, "error": e.msg}.toTable)
        else:
          finalContent = "[image: missing image_key or message_id]"

      elif messageType == "audio":
        finalContent = "[audio: " & messageID & "]"
      elif messageType == "file":
        finalContent = "[file: " & messageID & "]"
      elif messageType != "text":
        finalContent = "[Non-text message: " & messageType & "]"

      var metadata = {"message_id": messageID, "app_id": appID}.toTable
      if rootID.len > 0:
        metadata["root_id"] = rootID
      if parentID.len > 0:
        metadata["parent_id"] = parentID
      if threadID.len > 0:
        metadata["thread_id"] = threadID

      c.handleMessage(senderID, chatID, finalContent, mediaPaths, metadata)
    except Exception as e:
      errorCF("feishu", "Event parse error", {"error": e.msg}.toTable)

proc eventReader(args: SubscriberArgs) {.thread.} =
  ## Reads events from lark-cli subscriber. Auto-restarts on crash with backoff.
  let c = args.channel
  let appID = args.appID
  var backoff = 1  # seconds

  while c.running:
    var p: Process
    try:
      p = startSubscriberProcess(args.larkCliBin, args.configDir)
    except Exception as e:
      errorCF("feishu", "Failed to start subscriber", {"app_id": appID, "error": e.msg}.toTable)
      if not c.running: break
      sleep(backoff * 1000)
      backoff = min(backoff * 2, 30)
      continue

    # Update the app's process reference for clean shutdown
    for app in c.apps:
      if app.appID == appID:
        app.subscribeProcess = p
        break

    infoCF("feishu", "Subscriber connected", {"app_id": appID}.toTable)
    backoff = 1  # reset on successful connect

    readEvents(p, c, appID)

    # Process ended — clean up
    let exitCode = try: p.waitForExit(100) except: -1
    try: p.close() except: discard

    if not c.running: break
    warnCF("feishu", "Subscriber died, restarting", {"app_id": appID, "exit_code": $exitCode, "backoff_s": $backoff}.toTable)
    sleep(backoff * 1000)
    backoff = min(backoff * 2, 30)

# --- lark-cli binary discovery ---

proc findLarkCli*(): string =
  # Check thirdparty build, then PATH
  let thirdparty = currentSourcePath().parentDir().parentDir().parentDir().parentDir() / "channels" / "bin" / "lark-cli"
  if fileExists(thirdparty): return thirdparty
  let onPath = findExe("lark-cli")
  if onPath.len > 0: return onPath
  return ""

proc initLarkCliConfig*(bin, appID, appSecret: string): bool =
  ## Initialize lark-cli config non-interactively for an app.
  let configDir = getNimClawDir() / "channels" / "feishu" / "lark-cli-" & appID
  try:
    createDir(configDir)
  except: discard
  let env = buildLarkEnv(configDir)
  try:
    let p = startProcess(bin, args = ["config", "init", "--app-id", appID, "--app-secret-stdin", "--brand", "feishu"],
                         env = env, options = {poUsePath})
    p.inputStream.writeLine(appSecret)
    p.inputStream.close()
    let code = p.waitForExit(10000)
    p.close()
    if code == 0:
      infoCF("feishu", "lark-cli config initialized", {"app_id": appID}.toTable)
      return true
    else:
      errorCF("feishu", "lark-cli config init failed", {"app_id": appID, "code": $code}.toTable)
  except Exception as e:
    errorCF("feishu", "lark-cli config init error", {"error": e.msg}.toTable)

# --- Channel constructor ---

proc newFeishuChannel*(cfg: FeishuConfig, bus: MessageBus): FeishuChannel =
  let base = newBaseChannel("feishu", bus, cfg.allow_from)
  result = FeishuChannel(
    bus: base.bus,
    name: base.name,
    allowList: base.allowList,
    running: false,
    apps: @[],
    typing: initTable[string, FeishuTypingState](),
    messageCache: initTable[string, float](),
    larkCliBin: findLarkCli()
  )
  for appCfg in cfg.apps:
    result.apps.add(FeishuAppInstance(
      appID: appCfg.app_id,
      enabled: (if options.isSome(appCfg.enabled): options.get(appCfg.enabled) else: true)
    ))
  initLock(result.cacheLock)
  result.loadCache()
  result.pruneCache()

method name*(c: FeishuChannel): string = "feishu"

method start*(c: FeishuChannel) {.async.} =
  if c.apps.len == 0: return
  if c.running:
    infoC("feishu", "Feishu channel already running, skipping start")
    return

  if c.larkCliBin.len == 0:
    errorC("feishu", "lark-cli binary not found. Build with: nimble build_lark")
    return

  infoC("feishu", "Starting Feishu channel via lark-cli...")
  c.running = true

  for app in c.apps:
    if not app.enabled:
      infoCF("feishu", "Feishu app disabled", {"app_id": app.appID}.toTable)
      continue

    # lark-cli config must exist (created by: nimclaw channel add feishu)
    let configDir = getNimClawDir() / "channels" / "feishu" / "lark-cli-" & app.appID
    if not fileExists(configDir / "config.json"):
      errorCF("feishu", "lark-cli not configured for app. Run: nimclaw channel add feishu <APP_ID> <APP_SECRET>", {"app_id": app.appID}.toTable)
      continue

    # Clear stale lock files from previous unclean shutdown
    let locksDir = configDir / "locks"
    try:
      for f in walkDir(locksDir, relative = true):
        if f.path.endsWith(".lock"):
          try:
            removeFile(locksDir / f.path)
            infoCF("feishu", "Cleared stale lock", {"file": f.path}.toTable)
          except: discard
    except OSError: discard

    infoCF("feishu", "Starting lark-cli event subscriber", {"app_id": app.appID}.toTable)
    let subArgs = SubscriberArgs(channel: c, appID: app.appID, larkCliBin: c.larkCliBin, configDir: configDir)
    createThread(app.subscriberThread, eventReader, subArgs)

  infoC("feishu", "Feishu event subscribers started")

method stop*(c: FeishuChannel) {.async.} =
  c.running = false
  for app in c.apps:
    if app.subscribeProcess != nil:
      infoCF("feishu", "Stopping lark-cli subscriber", {"app_id": app.appID}.toTable)
      try:
        app.subscribeProcess.terminate()
        discard app.subscribeProcess.waitForExit(3000)
        if app.subscribeProcess.running:
          app.subscribeProcess.kill()
        app.subscribeProcess.close()
      except: discard
    joinThread(app.subscriberThread)

method send*(c: FeishuChannel, msg: OutboundMessage) {.async.} =
  if not c.running or c.apps.len == 0: return
  if c.larkCliBin.len == 0: return

  let replyID = msg.reply_to_message_id
  let typingKey = msg.chat_id & ":" & replyID

  # Resolve which app to use
  var effectiveAppID = msg.app_id
  if effectiveAppID.len == 0 and c.typing.hasKey(typingKey):
    effectiveAppID = c.typing[typingKey].appID

  var app: FeishuAppInstance = nil
  if effectiveAppID.len > 0:
    for a in c.apps:
      if a.appID == effectiveAppID:
        app = a
        break
    if app != nil and not app.enabled: return
  if app.isNil:
    for a in c.apps:
      if a.enabled:
        app = a
        break
  if app.isNil: return

  let configDir = getNimClawDir() / "channels" / "feishu" / "lark-cli-" & app.appID
  let env = buildLarkEnv(configDir)

  # Handle typing indicator (reaction-based) via REST API since lark-cli doesn't have a reaction shortcut
  if msg.kind == Typing:
    if replyID.len == 0: return
    if not c.typing.hasKey(typingKey):
      # Use lark-cli api for reactions
      try:
        let reactionData = $ %*{"reaction_type": {"emoji_type": "Typing"}}
        let p = startProcess(c.larkCliBin,
          args = ["api", "POST", "/open-apis/im/v1/messages/" & replyID & "/reactions",
                  "--data", reactionData, "--as", "bot", "--format", "data"],
          env = env, options = {poUsePath})
        let output = p.outputStream.readAll()
        let code = p.waitForExit(10000)
        p.close()
        if code == 0:
          try:
            let res = parseJson(output)
            let rid = res.getOrDefault("reaction_id").getStr()
            if rid.len > 0:
              c.typing[typingKey] = FeishuTypingState(reactionID: rid, appID: app.appID)
          except: discard
      except Exception as e:
        errorCF("feishu", "Typing reaction error", {"error": e.msg}.toTable)
    return

  # Clear typing indicator before sending
  if replyID.len > 0 and c.typing.hasKey(typingKey):
    let t = c.typing[typingKey]
    c.typing.del(typingKey)
    try:
      let p = startProcess(c.larkCliBin,
        args = ["api", "DELETE", "/open-apis/im/v1/messages/" & replyID & "/reactions/" & t.reactionID,
                "--as", "bot"],
        env = env, options = {poUsePath})
      discard p.waitForExit(5000)
      p.close()
    except: discard

  # Build send/reply command
  let cardOpt = tryExtractInteractiveCard(msg.content)
  let format = msg.metadata.getOrDefault("format", "")
  let imageVal = msg.metadata.getOrDefault("image", "")
  let fileVal = msg.metadata.getOrDefault("file", "")
  let replyInThread = msg.metadata.getOrDefault("reply_in_thread", "") == "true"
  var args: seq[string] = @[]

  if replyID.len > 0:
    args = @["im", "+messages-reply", "--message-id", replyID]
    if replyInThread:
      args.add("--reply-in-thread")
  else:
    let idType = if msg.chat_id.startsWith("ou_"): "--user-id" else: "--chat-id"
    args = @["im", "+messages-send", idType, msg.chat_id]

  # Choose content format: image > file > card > markdown > post
  if imageVal.len > 0:
    args.add("--image")
    args.add(imageVal)
    if msg.content.len > 0:
      # Send text as a separate follow-up (lark-cli image doesn't support caption)
      discard
  elif fileVal.len > 0:
    args.add("--file")
    args.add(fileVal)
  elif options.isSome(cardOpt):
    args.add("--msg-type")
    args.add("interactive")
    args.add("--content")
    args.add(options.get(cardOpt))
  else:
    # tablesToCodeBlocks is a no-op when there are no pipe tables
    args.add("--markdown")
    args.add(tablesToCodeBlocks(msg.content))

  args.add("--as")
  args.add("bot")

  infoCF("feishu", "Sending via lark-cli", {"cmd": args.join(" "), "chat": msg.chat_id}.toTable)

  try:
    let p = startProcess(c.larkCliBin, args = args, env = env, options = {poUsePath})
    let output = p.outputStream.readAll()
    let errOutput = p.errorStream.readAll()
    let code = p.waitForExit(30000)
    p.close()

    if code != 0:
      errorCF("feishu", "Send failed", {"code": $code, "stderr": errOutput, "stdout": output}.toTable)
    else:
      infoCF("feishu", "Send ok", {"chat": msg.chat_id}.toTable)

      # Check for interactive card upgrade placeholder fallback
      if options.isSome(cardOpt):
        try:
          let res = parseJson(output)
          let msgId = res.getOrDefault("message_id").getStr()
          if msgId.len > 0:
            var fbOpt = tryExtractAuthFallback(msg.content)
            if options.isNone(fbOpt):
              fbOpt = tryExtractAuthFallbackFromCard(options.get(cardOpt))
            if options.isSome(fbOpt):
              let (u, userCode, expiresIn) = options.get(fbOpt)
              var fb = "如未看到授权卡片按钮，可使用以下信息完成授权：\n\n"
              if u.len > 0: fb &= "授权链接：" & u & "\n"
              if userCode.len > 0: fb &= "验证码：**" & userCode & "**\n"
              if expiresIn > 0: fb &= "有效期：" & $(max(expiresIn div 60, 1)) & " 分钟\n"
              var fbArgs = @["im", "+messages-send"]
              let idType = if msg.chat_id.startsWith("ou_"): "--user-id" else: "--chat-id"
              fbArgs.add(idType)
              fbArgs.add(msg.chat_id)
              fbArgs.add("--text")
              fbArgs.add(fb)
              fbArgs.add("--as")
              fbArgs.add("bot")
              let fbP = startProcess(c.larkCliBin, args = fbArgs, env = env, options = {poUsePath})
              discard fbP.waitForExit(10000)
              fbP.close()
        except: discard
  except Exception as e:
    errorCF("feishu", "Send error", {"error": e.msg}.toTable)

method isRunning*(c: FeishuChannel): bool = c.running
