import std/[asyncdispatch, json, strutils, tables, os]
import curly, webby/httpheaders, regex
import base
import ../bus, ../bus_types, ../config, ../logger, ../services/voice
import ../lib/malebolgia
import ../lib/http_retry

type
  TelegramChannel* = ref object of BaseChannel
    token*: string
    lastUpdateID: int
    transcriber*: GroqTranscriber
    placeholders: Table[string, int] # chatID -> messageID
    stopThinking: Table[string, bool] # chatID -> stopped
    notificationOnly: bool
    curly: Curly
    master: Master

proc markdownToTelegramHTML(text: string): string =
  if text == "": return ""
  # Basic markdown to HTML conversion as in Go logic
  var res = text
  res = res.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
  # Very basic regex based replacements for bold, italic etc.
  res = res.replace(re2"\[([^\]]+)\]\(([^)]+)\)", "<a href=\"$2\">$1</a>")
  res = res.replace(re2"\*\*(.+?)\*\*", "<b>$1</b>")
  res = res.replace(re2"__(.+?)__", "<b>$1</b>")
  res = res.replace(re2"_([^_]+)_", "<i>$1</i>")
  res = res.replace(re2"~~(.+?)~~", "<s>$1</s>")
  res = res.replace(re2"(?m)^[-*]\s+", "• ")
  return res

proc newTelegramChannel*(cfg: TelegramConfig, bus: MessageBus): TelegramChannel =
  let base = newBaseChannel("telegram", bus, cfg.allow_from)
  TelegramChannel(
    bus: base.bus,
    name: base.name,
    allowList: base.allowList,
    running: false,
    token: cfg.token,
    lastUpdateID: 0,
    placeholders: initTable[string, int](),
    stopThinking: initTable[string, bool](),
    notificationOnly: cfg.notification_only,
    curly: newCurly(),
    master: createMaster()
  )

method setTranscriber*(c: TelegramChannel, transcriber: GroqTranscriber) =
  c.transcriber = transcriber

proc safeGetStr(j: JsonNode, key: string, default = ""): string =
  if j.isNil or j.kind != JObject or not j.hasKey(key): return default
  let node = j[key]
  if node.isNil: return default
  if node.kind == JString: return node.getStr()
  return $node

proc apiCall(c: TelegramChannel, method_name: string, payload: JsonNode, retries = 5): Future[JsonNode] {.async.} =
  let url = "https://api.telegram.org/bot$1/$2".format(c.token, method_name)
  let body = $payload
  var headers = emptyHttpHeaders()
  headers["Content-Type"] = "application/json"
  
  proc doRequest(curly: Curly, url, body: string, headers: HttpHeaders): tuple[code: int, body: string] =
    curlyPostWithRetry(curly, url, body, headers, timeout = 30)

  let fv = c.master.spawn doRequest(c.curly, url, body, headers)
  
  var waitMs = 10
  while not fv.isReady:
    await sleepAsync(waitMs)
    waitMs = min(waitMs * 2, 200)  # Exponential backoff: 10→20→40→80→160→200ms

  let (code, respBody) = fv.sync()

  if code == -1:
    errorCF("telegram", "Curly request failed", {"method": method_name, "error": respBody}.toTable)
    return %*{"ok": false, "description": respBody}

  try:
    let json = parseJson(respBody)
    if not json["ok"].getBool():
      errorCF("telegram", "API error", {"method": method_name, "chat_id": payload.safeGetStr("chat_id"), "error": json.getOrDefault("description").getStr()}.toTable)
    else:
      if method_name == "sendMessage":
        infoCF("telegram", "Message delivered to Telegram API", {"chat_id": payload.safeGetStr("chat_id")}.toTable)
    return json
  except Exception as e:
    errorCF("telegram", "JSON parse error", {"method": method_name, "body": respBody, "error": e.msg}.toTable)
    return %*{"ok": false, "description": "JSON parse error: " & e.msg}

proc downloadFile(c: TelegramChannel, fileID: string, ext: string): Future[string] {.async.} =
  let res = await c.apiCall("getFile", %*{"file_id": fileID})
  if not res["ok"].getBool(): return ""
  let filePath = res["result"]["file_path"].getStr()
  let url = "https://api.telegram.org/file/bot$1/$2".format(c.token, filePath)

  proc doDownload(curly: Curly, url: string): tuple[code: int, body: string] =
    try:
      let resp = curly.get(url, timeout = 60)
      return (resp.code, resp.body)
    except Exception as e:
      return (-1, e.msg)

  let fv = c.master.spawn doDownload(c.curly, url)
  var waitMs = 10
  while not fv.isReady:
    await sleepAsync(waitMs)
    waitMs = min(waitMs * 2, 200)

  let (code, body) = fv.sync()
  if code == 200:
    let botID = c.token.split(":")[0]
    let mediaDir = getNimClawDir() / "channels" / "telegram" / "bot-" & botID / "cache" / "media"
    createDir(mediaDir)
    let localPath = mediaDir / (fileID[0..min(15, fileID.len-1)] & ext)
    writeFile(localPath, body)
    return localPath
  
  return ""

proc handleTelegramUpdate(c: TelegramChannel, update: JsonNode) {.async.} =
  if not update.hasKey("message"): return
  let msg = update["message"]
  if not msg.hasKey("from"): return

  let user = msg["from"]
  var senderID = $user["id"].getBiggestInt()
  if user.hasKey("username"):
    senderID = senderID & "|" & user["username"].getStr()

  let chatID = $msg["chat"]["id"].getBiggestInt()

  var content = ""
  if msg.hasKey("text"): content.add(msg["text"].getStr())
  if msg.hasKey("caption"):
    if content != "": content.add("\n")
    content.add(msg["caption"].getStr())

  var mediaPaths: seq[string] = @[]

  if msg.hasKey("photo"):
    let photos = msg["photo"]
    let photo = photos[photos.len - 1]
    let path = await c.downloadFile(photo["file_id"].getStr(), ".jpg")
    if path != "":
      mediaPaths.add(path)
      if content != "": content.add("\n")
      content.add("[image: $1]".format(path))

  if msg.hasKey("voice"):
    let voice = msg["voice"]
    let path = await c.downloadFile(voice["file_id"].getStr(), ".ogg")
    if path != "":
      mediaPaths.add(path)
      var transcribed = "[voice: $1]".format(path)
      if c.transcriber != nil:
        try:
          let res = await c.transcriber.transcribe(path)
          transcribed = "[voice transcription: $1]".format(res.text)
        except: discard
      if content != "": content.add("\n")
      content.add(transcribed)

  if content == "": content = "[empty message]"

  # Chat-kind from Telegram's `chat.type` field.
  #   private    → DM with the bot
  #   group/supergroup/channel → multi-party
  var kind: ChatKind = ckUnknown
  if msg["chat"].hasKey("type"):
    case msg["chat"]["type"].getStr()
    of "private":                             kind = ckDM
    of "group", "supergroup", "channel":      kind = ckGroup
    else:                                     kind = ckUnknown

  c.handleMessage(senderID, chatID, content, mediaPaths,
                   chatKind = kind)

proc poll(c: TelegramChannel) {.async.} =
  while c.running:
    try:
      let res = await c.apiCall("getUpdates", %*{"offset": c.lastUpdateID + 1, "timeout": 30})
      if res["ok"].getBool():
        for update in res["result"]:
          c.lastUpdateID = update["update_id"].getInt()
          discard handleTelegramUpdate(c, update)
    except Exception as e:
      if "Connection was closed" in e.msg:
        debugCF("telegram", "Polling connection reset (expected for long-poll)", {"error": e.msg}.toTable)
      else:
        errorCF("telegram", "Polling error", {"error": e.msg}.toTable)
      await sleepAsync(5000)

method name*(c: TelegramChannel): string = "telegram"

method start*(c: TelegramChannel) {.async.} =
  infoC("telegram", "Starting Telegram bot (raw mode)...")
  let me = await c.apiCall("getMe", %*{})
  if me["ok"].getBool():
    infoCF("telegram", "Telegram bot connected", {"username": me["result"]["username"].getStr()}.toTable)
    c.running = true
    if not c.notificationOnly:
      asyncCheck poll(c)
    else:
      infoC("telegram", "Notification-only mode: polling disabled")

method stop*(c: TelegramChannel) {.async.} =
  c.running = false

method send*(c: TelegramChannel, msg: OutboundMessage) {.async.} =
  if not c.running: return

  if msg.kind == Typing:
    let chatID = msg.chat_id
    # Thinking animation
    discard await c.apiCall("sendChatAction", %*{"chat_id": chatID, "action": "typing"})
    if not c.placeholders.hasKey(chatID):
      let pMsg = await c.apiCall("sendMessage", %*{"chat_id": chatID, "text": "Thinking... 💭"})
      if pMsg["ok"].getBool():
        let pID = pMsg["result"]["message_id"].getInt()
        c.placeholders[chatID] = pID
        c.stopThinking[chatID] = false

        discard (proc() {.async.} =
          let dots = [".", "..", "..."]
          let emotes = ["💭", "🤔", "☁️"]
          var i = 0
          while not c.stopThinking.getOrDefault(chatID, true):
            await sleepAsync(2000)
            if not c.stopThinking.hasKey(chatID) or c.stopThinking[chatID]: break
            i += 1
            let text = "Thinking" & dots[i mod dots.len] & " " & emotes[i mod emotes.len]
            discard await c.apiCall("editMessageText", %*{"chat_id": chatID, "message_id": c.placeholders[chatID], "text": text})
        )()
    return

  c.stopThinking[msg.chat_id] = true
  let htmlContent = markdownToTelegramHTML(msg.content)

  if msg.chat_id in c.placeholders:
    let pID = c.placeholders[msg.chat_id]
    c.placeholders.del(msg.chat_id)
    let editRes = await c.apiCall("editMessageText", %*{
      "chat_id": msg.chat_id,
      "message_id": pID,
      "text": htmlContent,
      "parse_mode": "HTML"
    })
    if editRes["ok"].getBool(): return

  discard await c.apiCall("sendMessage", %*{
    "chat_id": msg.chat_id,
    "text": htmlContent,
    "parse_mode": "HTML"
  })

method isRunning*(c: TelegramChannel): bool = c.running
