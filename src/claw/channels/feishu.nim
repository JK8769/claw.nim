import std/[asyncdispatch, json, strutils, tables, os, osproc, strtabs, streams, times, locks, typedthreads, options, unicode, sets, posix, random]
import unicodedb/[widths, properties]
import base
import ../bus, ../bus_types, ../config, ../logger

type
  FeishuTypingState = object
    reactionID: string
    appID: string

  FeishuAppInstance = ref object
    appID: string
    enabled: bool
    agent: string              ## which agent this app routes inbound to
    subscribeProcess: Process
    subscriberThread: Thread[SubscriberArgs]
    spawnedAt: float           ## epoch seconds — lark-cli child start time
    lastEventAt: float         ## epoch seconds — last observed line from stdout.
                                ## Written by the app's reader thread, read by
                                ## the watchdog thread. Single writer + 64-bit
                                ## aligned float store = safe without a lock on
                                ## every supported target.

  SubscriberArgs = object
    channel: FeishuChannel
    app: FeishuAppInstance     ## resolved at spawn so the hot-path stamp
                                ## doesn't re-scan `c.apps` per event
    larkCliBin: string
    configDir: string

  FeishuChannel* = ref object of BaseChannel
    apps: seq[FeishuAppInstance]
    typing: Table[string, FeishuTypingState]
    messageCache*: Table[string, float] # message_id -> timestamp
    cacheLock*: Lock
    larkCliBin: string  # path to lark-cli binary
    watchdogThread: Thread[FeishuChannel]
    watchdogRunning: bool
    # Per-(app, chat) bot display name, auto-discovered from @mentions
    # in that specific chat. Stays in-memory for the gateway process —
    # intentionally not persisted to graph/disk. A bot can appear under
    # different display names in different chats (Feishu lets users
    # rename bots locally), so graph-level persistence would conflate
    # them. Lost on restart; re-populated on the first @mention in
    # each chat after boot.
    botNames: Table[string, string]  # "<app_id>:<chat_id>" → display name
    botNamesLock: Lock

# --- Bot display-name auto-discovery (in-memory, per-chat) ----------
#
# Feishu bots can appear under different display names in different
# chats (Feishu lets users rename bots locally within a chat). So the
# right key is `(app_id, chat_id)`, not just `agent_name`. Cache is
# in-memory on the FeishuChannel; lost on restart and re-populated on
# the first @mention in each chat after boot.
#
# On every outgoing message to the bus, the channel stuffs the current
# cached display name (if any) into `metadata.bot_display_name`. The
# gateway forwards it into ProcessOptions so the agent's system prompt
# for THIS turn knows what name to sign with.

proc chatKey(appID, chatID: string): string = appID & ":" & chatID

const
  BotNamesCap = 4096
    ## Hard ceiling on cached (app,chat) → display-name entries. When
    ## the cache exceeds this (long-running daemon participating in
    ## thousands of chats), we clear it; re-population is cheap (one
    ## @mention per chat after eviction).

proc recordBotDisplayName*(c: FeishuChannel, appID, chatID, displayName: string) =
  ## Cache a bot's display name discovered in this (app, chat) pair.
  ## Idempotent — silently no-ops when the cache already matches.
  if displayName.len == 0 or appID.len == 0 or chatID.len == 0: return
  let key = chatKey(appID, chatID)
  acquire(c.botNamesLock)
  try:
    if c.botNames.getOrDefault(key) == displayName: return
    if c.botNames.len >= BotNamesCap:
      c.botNames.clear()
    c.botNames[key] = displayName
    infoCF("feishu", "Bot display name for chat",
           {"app": appID, "chat": chatID, "name": displayName}.toTable)
  finally:
    release(c.botNamesLock)

proc lookupBotDisplayName*(c: FeishuChannel, appID, chatID: string): string =
  ## Return the cached display name for this (app, chat) or empty.
  if appID.len == 0 or chatID.len == 0: return ""
  let key = chatKey(appID, chatID)
  acquire(c.botNamesLock)
  try: result = c.botNames.getOrDefault(key)
  finally: release(c.botNamesLock)

# --- Chat-description fetch with TTL cache -------------------------

var chatDescCache {.threadvar.}: Table[string, (string, float)]
  ## `<app_id>:<chat_id>` → (description, cachedAtEpoch). 60-second TTL.
  ## Populated on-demand by `fetchChatDescription`; avoids hitting the
  ## Feishu API on every invite. Threadvar because the tool that calls
  ## this runs on the agent-loop's thread pool, not the channel thread.

const ChatDescCacheCap = 2048
  ## Prevent unbounded growth over long daemon lifetimes. Stale entries
  ## aren't swept on TTL expiry (only overwritten on re-read), so a
  ## chat invited-to once will sit in the cache forever; this cap
  ## keeps memory use bounded. Eviction is drop-all (cheap re-fill).

proc findLarkCli*(): string

proc fetchChatDescription*(appID, chatID: string): string =
  ## Fetch the Feishu group's description field via lark-cli. Caches
  ## per-(app, chat) for 60 seconds so repeated invites in the same
  ## group don't spam the API. Returns empty string on any failure
  ## (missing config dir, network issue, API permission denied, etc.) —
  ## callers treat empty as "no default available".
  if appID.len == 0 or chatID.len == 0: return ""
  let key = appID & ":" & chatID
  let now = epochTime()
  if chatDescCache.hasKey(key):
    let (cached, t) = chatDescCache[key]
    if now - t < 60.0: return cached

  let configDir = getNimClawDir() / "channels" / "feishu" / ("lark-cli-" & appID)
  if not dirExists(configDir): return ""
  let bin = findLarkCli()
  if bin.len == 0: return ""

  var env = newStringTable()
  env["LARKSUITE_CLI_CONFIG_DIR"] = configDir
  for k in ["HOME", "PATH", "USER", "LANG"]:
    let v = getEnv(k)
    if v.len > 0: env[k] = v

  var desc = ""
  try:
    let p = startProcess(bin, args = @[
      "api", "GET", "/open-apis/im/v1/chats/" & chatID
    ], env = env, options = {poUsePath, poStdErrToStdOut})
    discard p.waitForExit(5000)
    let output = readAll(p.outputStream())
    p.close()
    if output.strip.len > 0 and output.strip.startsWith("{"):
      let j = parseJson(output)
      if j.getOrDefault("code").getInt(0) == 0:
        desc = j{"data"}.getOrDefault("description").getStr("")
  except CatchableError: discard

  if chatDescCache.len >= ChatDescCacheCap:
    chatDescCache.clear()
  chatDescCache[key] = (desc, now)
  desc

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

proc hasFencedCodeBlock*(text: string): bool =
  ## True when `text` has at least one line starting with three backticks
  ## (after optional whitespace). Used to decide whether to ship to
  ## Feishu via the rich post-format path (with `tag:code_block` elements
  ## that render as scrollable, copyable code boxes) or the plain
  ## `--markdown` path (simpler but renders fenced blocks as monospaced
  ## text with no copy/scroll affordances).
  for line in text.splitLines():
    if line.strip().startsWith("```"):
      return true
  return false

proc buildPostContent*(text: string): string =
  ## Convert text to Feishu native post JSON format.
  ## Handles: bare URLs, markdown links [text](url), bold **text**,
  ## tables, fenced code blocks, and plain text. URLs become clickable
  ## {"tag": "a"} elements; fenced code blocks become {"tag":
  ## "code_block", "language": ..., "text": ...} which Feishu renders
  ## as a code box with syntax highlighting, vertical scroll, and a
  ## copy button — strictly better than `tag:md`'s monospaced text.
  var rows: seq[JsonNode] = @[]
  let lines = text.split("\n")

  var i = 0
  # Group consecutive non-fenced, non-table lines into a single `tag:md`
  # paragraph so Feishu's md renderer styles bold/italic/inline-code/
  # headers/lists/links across the whole prose chunk. Without this, each
  # line becomes a separate `tag:text` paragraph (parseLine's default)
  # and we lose all markdown styling on prose content.
  var prosePending: seq[string] = @[]

  proc flushProse() =
    if prosePending.len == 0: return
    let prose = prosePending.join("\n")
    if prose.strip.len > 0:
      rows.add(%*[{"tag": "md", "text": prose}])
    prosePending = @[]

  while i < lines.len:
    let line = lines[i]
    let trimmed = line.strip()

    # Fenced code block: ` ```<lang> ... ``` `
    # Promotes to a `tag:code_block` element so Feishu renders it with
    # syntax highlighting (60+ languages supported per the open-platform
    # docs). Note: Feishu IM does NOT add scroll/copy buttons to
    # code_block elements (those are Lark Docs / CardKit features) —
    # large files should be sent as separate `--file` attachments by
    # the framework auto-emit path, not embedded inline here.
    if trimmed.startsWith("```"):
      flushProse()
      let lang = trimmed[3..^1].strip()
      var codeLines: seq[string] = @[]
      inc i
      while i < lines.len:
        let codeLine = lines[i]
        if codeLine.strip().startsWith("```"):
          inc i
          break
        codeLines.add(codeLine)
        inc i
      var elem = %*{"tag": "code_block", "text": codeLines.join("\n")}
      if lang.len > 0:
        elem["language"] = %lang
      rows.add(%*[elem])
      continue

    # Detect table: look for separator row
    if i + 1 < lines.len and line.contains("|") and isTableSeparatorRow(lines[i+1]):
      flushProse()
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

    # Accumulate prose lines so they're flushed together as one
    # `tag:md` paragraph (preserves Feishu's markdown rendering of
    # bold/italic/inline-code/headers/lists/links across multiple lines).
    prosePending.add(line)
    inc i

  flushProse()
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

proc safeObj(n: JsonNode): JsonNode =
  ## Returns an empty JObject when the input isn't an object (JNull,
  ## missing, wrong type) so chained `.getOrDefault(...)` calls don't
  ## blow up. Nim's `getOrDefault` is only safe on JObject.
  if n != nil and n.kind == JObject: n else: newJObject()

proc flattenFeishuEvent*(e: JsonNode): JsonNode =
  ## Normalize lark-cli subscriber output. `--compact` mode gives us a
  ## flat event with top-level fields and drops the `mentions` array.
  ## Without `--compact`, events arrive in Feishu's native webhook shape
  ## — nested under `header` + `event.message` + `event.sender`, with
  ## `mentions` preserved. We want the flat shape plus mentions.
  ##
  ## Wrapped in a try to survive any malformed events — on any parse
  ## issue, fall back to the original so we never crash the subscriber
  ## loop. The caller's downstream code already handles empty/missing
  ## fields defensively.
  if e == nil or e.kind != JObject: return e
  if not (e.hasKey("header") and e.hasKey("event")):
    return e  # already flat or unknown — pass through
  try:
    let header = safeObj(e.getOrDefault("header"))
    let ev = safeObj(e.getOrDefault("event"))
    let message = safeObj(ev.getOrDefault("message"))
    let sender = safeObj(ev.getOrDefault("sender"))
    let senderID = safeObj(sender.getOrDefault("sender_id"))
    result = %* {
      "type": header.getOrDefault("event_type"),
      "app_id": header.getOrDefault("app_id"),
      "message_id": message.getOrDefault("message_id"),
      "chat_id": message.getOrDefault("chat_id"),
      "chat_type": message.getOrDefault("chat_type"),
      "message_type": message.getOrDefault("message_type"),
      "create_time": message.getOrDefault("create_time"),
      "root_id": message.getOrDefault("root_id"),
      "parent_id": message.getOrDefault("parent_id"),
      "thread_id": message.getOrDefault("thread_id"),
      "sender_id": senderID.getOrDefault("open_id"),
      "union_id": senderID.getOrDefault("union_id"),
      "user_id": senderID.getOrDefault("user_id"),
      "mentions": message.getOrDefault("mentions")
    }
    # Resolve the nested content: Feishu sends `content` as a stringified
    # JSON. For TEXT messages it's `{"text":"@_user_1 你好"}` — pull `text`.
    # For POST (rich-text) messages it's a structured doc with rows of
    # nodes (`{"title":"…","content":[[{"tag":"text","text":"…"}, …], …]}`)
    # — we flatten to plain text so the agent gets a readable string
    # instead of "[Non-text message: post]".
    proc flattenPost(node: JsonNode): string =
      ## Walk a Feishu post and concat plain text. Each row → one line.
      ## Common tags: text, a (link), at (mention), img, code_block, media.
      ## Unknown tags fall back to their `text` field if present.
      if node == nil or node.kind != JObject: return
      let title = node.getOrDefault("title").getStr("")
      if title.len > 0:
        result.add(title & "\n")
      let rows = node.getOrDefault("content")
      if rows == nil or rows.kind != JArray: return
      for row in rows:
        if row.kind != JArray: continue
        var line = ""
        for item in row:
          if item.kind != JObject: continue
          let tag = item.getOrDefault("tag").getStr("")
          case tag
          of "text":
            line.add(item.getOrDefault("text").getStr(""))
          of "a":
            let txt = item.getOrDefault("text").getStr("")
            let href = item.getOrDefault("href").getStr("")
            if href.len > 0 and txt != href: line.add(txt & " (" & href & ")")
            elif href.len > 0: line.add(href)
            else: line.add(txt)
          of "at":
            let uname = item.getOrDefault("user_name").getStr("")
            let key = item.getOrDefault("user_id").getStr("")
            if uname.len > 0: line.add("@" & uname)
            elif key.len > 0: line.add("@" & key)
            else: line.add("@(unknown)")
          of "img":
            line.add("[image]")
          of "media":
            line.add("[media]")
          of "code_block":
            line.add("\n```\n" & item.getOrDefault("text").getStr("") & "\n```")
          else:
            let txt = item.getOrDefault("text").getStr("")
            if txt.len > 0: line.add(txt)
        if line.len > 0:
          result.add(line & "\n")
      result = result.strip()

    var resolvedText = ""
    let nestedContent = message.getOrDefault("content").getStr("")
    if nestedContent.len > 0:
      try:
        let parsed = parseJson(nestedContent)
        # Text messages: top-level `text` field
        resolvedText = parsed.getOrDefault("text").getStr("")
        # Post messages: nothing in `text`; flatten the structured content
        if resolvedText.len == 0 and parsed.hasKey("content") and
           parsed["content"].kind == JArray:
          resolvedText = flattenPost(parsed)
      except CatchableError: discard
    let mentions = result["mentions"]
    if mentions != nil and mentions.kind == JArray and resolvedText.len > 0:
      for m in mentions:
        if m.kind != JObject: continue
        let key = m.getOrDefault("key").getStr("")
        let name = m.getOrDefault("name").getStr("")
        if key.len > 0 and name.len > 0 and key in resolvedText:
          resolvedText = resolvedText.replace(key, "@" & name)
    result["content"] = %resolvedText
    # Card events nest differently — surface useful fields if any.
    if ev.hasKey("action"):   result["action"] = ev["action"]
    if ev.hasKey("context"):  result["context"] = ev["context"]
    if ev.hasKey("operator"): result["operator"] = ev["operator"]
  except CatchableError as err:
    errorCF("feishu", "Event flatten failed; passing through raw",
            {"error": err.msg}.toTable)
    return e

proc startSubscriberProcess(larkCliBin, configDir: string): Process =
  let env = buildLarkEnv(configDir)
  result = startProcess(
    larkCliBin,
    # Dropped `--compact`: it strips the `mentions` array we need for
    # auto-discovering bot display names. We flatten the nested event
    # ourselves via `flattenFeishuEvent` — see that proc for details.
    args = ["event", "+subscribe",
            "--event-types", "im.message.receive_v1,card.action.trigger",
            "--quiet"],
    env = env,
    options = {poUsePath}
  )

const
  SubscriberMaxAgeSec = 14_400     ## 4h blind-cycle cap.
  SubscriberStaleSec  = 3_600      ## 1h without stdout = treat as dead.
                                    ## Was 15min, but legitimately quiet
                                    ## apps (a tenant where nobody DMs
                                    ## the bot for an hour) hit that
                                    ## threshold harmlessly. 1h is still
                                    ## tight enough to detect actual
                                    ## socket failures.
  ReadPollIntervalMs  = 5_000      ## Reader's poll() timeout — wakes the
                                    ## syscall periodically so staleness
                                    ## and shutdown checks can run.

proc subscriberWatchdog(c: FeishuChannel) {.thread.} =
  ## Liveness checks moved INTO each eventReader thread (they self-poll
  ## via posix.poll with a periodic timeout, so they self-detect
  ## staleness without an external watchdog racing on the pipe FD —
  ## that race was the root cause of the zombie-subscriber bug we
  ## hit in production: SIGTERM the process from the watchdog thread
  ## while the reader thread was blocked in fgets, and the reader
  ## stayed parked forever).
  ##
  ## Kept around for shutdown signalling (stop() flips the flag and
  ## joins) and as a hook for future per-app health metrics.
  while c.watchdogRunning and c.running:
    sleep(1000)

proc dispatchFeishuLine(line: string, c: FeishuChannel, app: FeishuAppInstance) =
  ## Process one JSON event line: parse → classify → publish to bus.
  ## Extracted from the old readEvents body so the new poll-based reader
  ## can call it per parsed line. Each `continue` in the original loop
  ## becomes a `return` here — same effect, single-line scope.
  let appID = app.appID
  try:
    let evt = flattenFeishuEvent(parseJson(line))
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
        return

      infoCF("feishu", "Card action received", {"chat": chatID, "sender": senderID, "action": actionValue}.toTable)

      let content = "[Card button clicked: " & actionValue & "]"
      var metadata = {"message_id": messageID, "app_id": appID, "event_type": "card.action.trigger", "action_value": actionValue}.toTable
      c.handleMessage(senderID, chatID, content, @[], metadata)
      return

    if evtType != "im.message.receive_v1":
      debugCF("feishu", "Non-IM event received", {"type": evtType}.toTable)
      return

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
        return

    # Ignore stale messages (>5 min old)
    if createTimeStr.len > 0:
      let createTime = createTimeStr.parseBiggestInt
      let nowMs = (epochTime() * 1000).int64
      if createTime > 0 and (nowMs - createTime) > 300_000:
        debugCF("feishu", "Ignoring stale message", {"msg_id": messageID, "age_s": $((nowMs - createTime) div 1000)}.toTable)
        return

    let rootID = evt.getOrDefault("root_id").getStr()
    let parentID = evt.getOrDefault("parent_id").getStr()
    let threadID = evt.getOrDefault("thread_id").getStr()
    infoCF("feishu", "Processing message", {"msg_id": messageID, "sender": senderID, "chat": chatID, "type": messageType, "root_id": rootID, "parent_id": parentID, "thread_id": threadID}.toTable)

    # Per-app agent routing. Resolved here (earlier than strictly
    # needed for publishing) so the text-mention resolver below can
    # substitute a bot's display name with the agent's config name.
    var routeTo = ""
    for a in c.apps:
      if a.appID == appID:
        routeTo = a.agent
        break

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
    elif messageType == "post":
      # `flattenFeishuEvent` already extracted the post's text from its
      # structured rows into `content` — keep that as the message body
      # rather than overwriting with "[Non-text message: post]". If the
      # extraction returned empty (unusual post shape), fall through to
      # the catch-all below to surface the gap visibly.
      if finalContent.len == 0:
        finalContent = "[Non-text message: post (extraction returned empty)]"
    elif messageType == "text":
      # Mentions auto-discovery. flattenFeishuEvent already placed
      # `mentions` as a sibling field on the event with placeholders
      # resolved. Scan for any bot mention (empty `user_id`) and
      # cache the bot's display name for this (app, chat) pair.
      # Defensively typed — SIGSEGV on malformed JSON subtrees would
      # bypass try/except, so every step validates kind.
      try:
        let mentions = evt.getOrDefault("mentions")
        if mentions != nil and mentions.kind == JArray:
          for m in mentions:
            if m == nil or m.kind != JObject: continue
            let displayName = m.getOrDefault("name").getStr("").strip()
            let mIdObj = m.getOrDefault("id")
            let mUserId =
              if mIdObj != nil and mIdObj.kind == JObject:
                mIdObj.getOrDefault("user_id").getStr("")
              else: ""
            let isBot = mUserId.len == 0
            if isBot and displayName.len > 0 and routeTo.len > 0:
              c.recordBotDisplayName(appID, chatID, displayName)
              break  # one bot per message is the 99% case
      except CatchableError: discard
    elif messageType != "text":
      finalContent = "[Non-text message: " & messageType & "]"

    var metadata = {"message_id": messageID, "app_id": appID}.toTable
    # Pass the resolved mentions array through as JSON in metadata so
    # downstream (context builder → agent LLM → create_customer_invite
    # tool) can see who was @mentioned alongside the bot. Powers the
    # group-chat invite UX where operators @mention the customer.
    try:
      let m = evt.getOrDefault("mentions")
      if m != nil and m.kind == JArray and m.len > 0:
        metadata["mentions"] = $m
    except CatchableError: discard
    # Tenant-scoped cross-app identifiers: `union_id` is stable across
    # all apps published by the same Feishu tenant; `user_id` is the
    # tenant's internal employee ID (only present for corporate users
    # in the same org). Either lets the binding/resolver recognize
    # the same human on a different app without a second bind.
    let unionID = evt.getOrDefault("union_id").getStr()
    if unionID.len > 0: metadata["union_id"] = unionID
    let userID = evt.getOrDefault("user_id").getStr()
    if userID.len > 0: metadata["user_id"] = userID
    if rootID.len > 0:
      metadata["root_id"] = rootID
    if parentID.len > 0:
      metadata["parent_id"] = parentID
    if threadID.len > 0:
      metadata["thread_id"] = threadID

    # Detect DM vs group from Feishu's chat_id namespace.
    # ou_ = user/open-id (DM); oc_ = open-chat-id (group).
    # Event payload also carries `chat_type` ("p2p" | "group") — honour
    # that when present, fall back to prefix heuristic otherwise.
    var kind: ChatKind = ckUnknown
    let eventChatType = evt.getOrDefault("chat_type").getStr()
    case eventChatType
    of "p2p":   kind = ckDM
    of "group": kind = ckGroup
    else:
      if chatID.startsWith("ou_"):   kind = ckDM
      elif chatID.startsWith("oc_"): kind = ckGroup

    # Bot display name — group-chat only. In a 1:1 DM the customer
    # is talking directly to one bot, so the bot's "display name"
    # doesn't need to compete with other participants or personas;
    # just use the internal config name. Group chats have multiple
    # members who may see the bot under a chat-local nickname, so
    # the agent should sign as that name there.
    if kind == ckGroup:
      let botName = c.lookupBotDisplayName(appID, chatID)
      if botName.len > 0:
        metadata["bot_display_name"] = botName

    # `routeTo` was computed above (before content pre-processing)
    # so the mention resolver could use it. Empty → gateway uses its
    # default (Lexi).
    c.handleMessage(senderID, chatID, finalContent, mediaPaths, metadata,
                     recipientID = routeTo, chatKind = kind)
  except Exception as e:
    errorCF("feishu", "Event parse error", {"error": e.msg}.toTable)

proc readEvents(p: Process, c: FeishuChannel, app: FeishuAppInstance): string =
  ## Read events from the subscriber. Returns reason for exit:
  ##   "eof"      — process closed its stdout (died, normal restart)
  ##   "shutdown" — channel-wide stop signalled
  ##   "stale"    — no events for SubscriberStaleSec — suspect dead socket
  ##   "max_age"  — exceeded SubscriberMaxAgeSec — preventive recycle
  ##   "error"    — unrecoverable read/poll error
  ##
  ## Uses posix poll(2) + read(2) directly instead of stream readLine
  ## because readLine on a FileStream doesn't notice process death from
  ## another thread (observed in production: zombie subscriber, EOF
  ## never propagates, reader parked forever). With explicit poll the
  ## reader self-monitors staleness on every timeout — no separate
  ## watchdog needed, no race on the pipe FD.
  let appID = app.appID
  let fd = p.outputHandle.cint
  var rbuf = newString(8192)
  var lineBuf = ""
  var pfd: TPollfd
  pfd.fd = fd
  pfd.events = POLLIN
  while c.running:
    pfd.revents = 0
    let ready = poll(addr pfd, 1, ReadPollIntervalMs.cint)
    if ready < 0:
      if errno.cint == EINTR: continue
      errorCF("feishu", "poll() error",
              {"app_id": appID, "errno": $errno.int}.toTable)
      return "error"
    if ready == 0:
      # Timeout — self-check staleness/age before polling again.
      let now = epochTime()
      let age = now - app.spawnedAt
      if age > SubscriberMaxAgeSec.float:
        return "max_age"
      if app.lastEventAt > 0 and (now - app.lastEventAt) > SubscriberStaleSec.float:
        return "stale"
      continue
    if (pfd.revents and POLLIN) == 0:
      # POLLERR / POLLHUP / POLLNVAL — pipe is gone.
      return "eof"
    let n = posix.read(fd, addr rbuf[0], rbuf.len.cint)
    if n == 0: return "eof"
    if n < 0:
      if errno.cint == EINTR: continue
      errorCF("feishu", "read() error",
              {"app_id": appID, "errno": $errno.int}.toTable)
      return "error"
    lineBuf.add(rbuf.substr(0, n.int - 1))
    while true:
      let nl = lineBuf.find('\n')
      if nl < 0: break
      var line = lineBuf[0 ..< nl]
      lineBuf = lineBuf[nl + 1 .. ^1]
      if line.len > 0 and line[^1] == '\r': line.setLen(line.len - 1)
      if line.len == 0 or not line.startsWith("{"): continue
      app.lastEventAt = epochTime()
      dispatchFeishuLine(line, c, app)
  return "shutdown"

proc subscriberPidPath(configDir: string): string =
  configDir / "locks" / "subscriber.pid"

proc processAlive(pid: int): bool =
  pid > 0 and kill(Pid(pid), 0) == 0

proc reapOrphanSubscriber(configDir, appID: string) =
  ## Kill a lark-cli subscriber left running by a previous gateway.
  ## Feishu load-balances events across all connected subscribers for
  ## one app_id — a leftover orphan steals half the @mentions from the
  ## new gateway, so we SIGTERM, poll briefly, SIGKILL if still alive.
  let path = subscriberPidPath(configDir)
  if not fileExists(path): return
  var pid = 0
  try: pid = parseInt(readFile(path).strip()) except CatchableError: discard
  if pid > 0 and pid != getCurrentProcessId() and processAlive(pid):
    discard kill(Pid(pid), SIGTERM)
    # Poll for up to 200ms before escalating — lark-cli usually exits
    # in <50ms on SIGTERM, the budget is for the slow case.
    for _ in 0 ..< 20:
      if not processAlive(pid): break
      sleep(10)
    if processAlive(pid):
      discard kill(Pid(pid), SIGKILL)
    infoCF("feishu", "Reaped orphan subscriber",
           {"app_id": appID, "pid": $pid}.toTable)
  try: removeFile(path) except CatchableError: discard

proc writeSubscriberPid(configDir: string, pid: int) =
  let path = subscriberPidPath(configDir)
  try:
    createDir(path.parentDir)
    writeFile(path, $pid)
  except CatchableError: discard

proc eventReader(args: SubscriberArgs) {.thread.} =
  ## Reads events from lark-cli subscriber. Auto-restarts on crash with backoff.
  let c = args.channel
  let app = args.app
  let appID = app.appID
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

    # Stamp our PID so the next gateway startup can reap us if we
    # outlive our parent (SIGTERM races, hung joinThread, etc.).
    writeSubscriberPid(args.configDir, p.processID)

    # Stamp spawn time for watchdog 4h cycle; reset lastEventAt so
    # the watchdog doesn't flag a fresh subprocess as stale before
    # it's had a chance to receive anything.
    app.subscribeProcess = p
    app.spawnedAt = epochTime()
    app.lastEventAt = 0

    infoCF("feishu", "Subscriber connected", {"app_id": appID}.toTable)
    backoff = 1  # reset on successful connect

    let exitReason = readEvents(p, c, app)

    # Reader returned. If it returned because the reader self-detected
    # staleness (no events / max age), the lark-cli process is still
    # alive and we have to kill it. SIGKILL not SIGTERM: SIGTERM gave
    # lark-cli a chance to do graceful shutdown but its stdout pipe
    # didn't reliably close before the parent Nim FileStream noticed,
    # leading to the parked-reader zombie we just escaped from.
    if exitReason in ["stale", "max_age"]:
      infoCF("feishu", "Recycling subscriber", {"app_id": appID, "reason": exitReason}.toTable)
      try: p.kill() except CatchableError: discard
    let exitCode = try: p.waitForExit(2000) except: -1
    try: p.close() except: discard

    if not c.running: break
    warnCF("feishu", "Subscriber down, restarting",
           {"app_id": appID, "reason": exitReason,
            "exit_code": $exitCode, "backoff_s": $backoff}.toTable)
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
      enabled: (if options.isSome(appCfg.enabled): options.get(appCfg.enabled) else: true),
      agent: appCfg.agent
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

    # lark-cli config must exist. Two ways to bootstrap:
    #   (a) operator ran `claw channel auth feishu <APP_ID> <SECRET>` once
    #       (manual path; lark-cli config lives at
    #        <companyDir>/channels/feishu/lark-cli-<APP_ID>/config.json)
    #   (b) auto-bootstrap from env var `FEISHU_APP_SECRET__<APP_ID>` (or
    #       uppercase variant) in this deployment's .env. Makes migrations
    #       turnkey: copy .env to a new deployment, restart gateway, channels
    #       come up automatically. Saves a manual `channel auth` step per app.
    let configDir = getNimClawDir() / "channels" / "feishu" / "lark-cli-" & app.appID
    if not fileExists(configDir / "config.json"):
      # Try env-var bootstrap. Look up exact-case first, then uppercase
      # variant (some operators uppercase everything in .env per shell
      # convention; either should work).
      var secret = getEnv("FEISHU_APP_SECRET__" & app.appID, "")
      if secret.len == 0:
        secret = getEnv("FEISHU_APP_SECRET__" & app.appID.toUpperAscii(), "")
      if secret.len > 0:
        infoCF("feishu", "Bootstrapping lark-cli from env var FEISHU_APP_SECRET__<app_id>",
               {"app_id": app.appID}.toTable)
        if initLarkCliConfig(c.larkCliBin, app.appID, secret):
          # initLarkCliConfig logged success; continue with channel start
          discard
        else:
          errorCF("feishu", "Env-var-driven lark-cli init failed; check secret value",
                  {"app_id": app.appID}.toTable)
          continue
      else:
        errorCF("feishu", "lark-cli not configured for app. Either: run `claw channel auth feishu <APP_ID> <APP_SECRET>`, OR set `FEISHU_APP_SECRET__" & app.appID & "=<secret>` in .env and restart",
                {"app_id": app.appID}.toTable)
        continue
      # After bootstrap, the config should now exist
      if not fileExists(configDir / "config.json"):
        errorCF("feishu", "lark-cli config still missing after env-var bootstrap; init may have silently failed",
                {"app_id": app.appID}.toTable)
        continue

    # Kill any orphan subscriber from a previous gateway that didn't
    # terminate its lark-cli child (SIGTERM races, hung joinThread).
    # Must run BEFORE clearing locks so the orphan sees its lock
    # disappear and doesn't fight the new subscriber for it.
    reapOrphanSubscriber(configDir, app.appID)

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
    let subArgs = SubscriberArgs(channel: c, app: app, larkCliBin: c.larkCliBin, configDir: configDir)
    createThread(app.subscriberThread, eventReader, subArgs)

  # Liveness watchdog — cycles subscribers when Feishu's event stream
  # goes silently stale. Without this, a dead socket leaves the gateway
  # accepting no inbound messages for hours while the subprocess sits
  # blocked in readLine.
  c.watchdogRunning = true
  createThread(c.watchdogThread, subscriberWatchdog, c)

  infoC("feishu", "Feishu event subscribers started")

method stop*(c: FeishuChannel) {.async.} =
  c.running = false
  c.watchdogRunning = false
  # Watchdog polls the flag every second so this join returns within
  # ~1s worst case.
  joinThread(c.watchdogThread)
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
    # Remove the PID file only after the process actually died — otherwise
    # a half-shutdown that orphans the child would leave no PID trace for
    # the next gateway to reap. The file is idempotent to delete on clean
    # restart since the recorded PID will no longer exist.
    let configDir = getNimClawDir() / "channels" / "feishu" / ("lark-cli-" & app.appID)
    try: removeFile(subscriberPidPath(configDir)) except CatchableError: discard
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

  # lark-cli's `--file` / `--image` / `--video` / `--audio` flags
  # require the path to be RELATIVE and within the current working
  # directory ("--file: --file must be a relative path within the
  # current directory, got <absolute path>"). The framework hands
  # absolute paths everywhere — fix the impedance mismatch by
  # rewriting any absolute path to a `./<basename>` plus a working
  # directory we set on the lark-cli subprocess via startProcess's
  # workingDir parameter.
  #
  # When the path's basename has non-ASCII chars, lark-cli's
  # filename URL-encoding ALSO mangles the uploaded filename
  # (`荣鑫一期.pdf` → `%XX` garbage). Sidestep by copying to a temp
  # path with an ASCII-safe name; the original file stays put.
  proc isAsciiLeaf(p: string): bool =
    for c in lastPathPart(p):
      if c.ord >= 128: return false
    true
  proc prepareUpload(rawPath: string): tuple[workDir, relPath: string] =
    ## Returns the working dir and `./<basename>` form lark-cli wants.
    ## If `rawPath`'s leaf has non-ASCII, copies to a temp ASCII path
    ## first and uses that.
    var p = rawPath
    if not isAsciiLeaf(p):
      let (_, _, ext) = splitFile(p)
      let stamp = $getTime().toUnix() & "_" & $rand(100000)
      let safeName = "feishu_upload_" & stamp & ext
      let tmp = getTempDir() / safeName
      try:
        copyFile(p, tmp)
        p = tmp
        infoCF("feishu", "Renamed non-ASCII upload",
               {"original": rawPath, "temp": tmp}.toTable)
      except CatchableError as e:
        warnCF("feishu", "Non-ASCII rename failed; passing original",
               {"path": rawPath, "error": e.msg}.toTable)
    (parentDir(p), "./" & lastPathPart(p))

  # Track workingDir for the lark-cli subprocess. Empty means inherit
  # parent's CWD (correct for text/markdown/card sends).
  var uploadWorkDir = ""

  # Choose content format: image > file > card > markdown > post
  if imageVal.len > 0:
    let (wd, rel) = prepareUpload(imageVal)
    uploadWorkDir = wd
    args.add("--image")
    args.add(rel)
    if msg.content.len > 0:
      # Send text as a separate follow-up (lark-cli image doesn't support caption)
      discard
  elif fileVal.len > 0:
    let (wd, rel) = prepareUpload(fileVal)
    uploadWorkDir = wd
    args.add("--file")
    args.add(rel)
  elif options.isSome(cardOpt):
    args.add("--msg-type")
    args.add("interactive")
    args.add("--content")
    args.add(options.get(cardOpt))
  else:
    # tablesToCodeBlocks promotes pipe tables to fenced code blocks
    # (Feishu's md tag doesn't render pipe tables; monospaced code
    # blocks do). Then check if any code blocks remain — if so, ship
    # via post-format with explicit `tag:code_block` elements so
    # Feishu's IM client gives them the rich code-box UI (scroll +
    # copy + syntax highlighting). Without this branch, lark-cli's
    # `--markdown` flag would wrap everything in `tag:md` which leaves
    # fenced blocks as plain monospaced text.
    let prepared = tablesToCodeBlocks(msg.content)
    if hasFencedCodeBlock(prepared):
      args.add("--msg-type")
      args.add("post")
      args.add("--content")
      args.add(buildPostContent(prepared))
    else:
      args.add("--markdown")
      args.add(prepared)

  args.add("--as")
  args.add("bot")

  infoCF("feishu", "Sending via lark-cli",
         {"cmd": args.join(" "), "chat": msg.chat_id,
          "workdir": uploadWorkDir}.toTable)

  try:
    let p = startProcess(c.larkCliBin, args = args, env = env,
                         workingDir = uploadWorkDir,
                         options = {poUsePath})
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
