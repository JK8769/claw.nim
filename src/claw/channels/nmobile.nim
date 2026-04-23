import std/[asyncdispatch, json, strutils, random, times, tables, os, options, algorithm, httpclient, locks, base64]
import base
import ../crypto_gcm
import ../bus, ../bus_types, ../config, ../logger
import ../agent/cortex as cortex_mod
import ../libnkn/nkn_bridge

type
  PeerInfo = object
    deviceId: string
    profileVersion: string
    deviceToken: string
    lastGreetingAt: float

  NknQueueItem = tuple[clientAddr, src, data: string]

  NMobileChannel* = ref object of BaseChannel
    # Identity — new (seed-centric) fields take priority; legacy fields
    # kept so existing encrypted-wallet deployments still boot until the
    # operator re-auths. See `authNmobileChannel`.
    seed: string                               ## raw 64-char hex if present
    identifiers: seq[(string, string)]         ## (sub-client, agentName) pairs
    walletJson: string                         ## legacy fallback
    password: string                           ## legacy fallback
    identifier: string                         ## legacy single-identifier
    agentIdentifiers: Table[string, string]    ## legacy agent→identifier map
    clientAddrs: seq[string]
    activeClients: Table[string, string]
    # Per-client liveness tracking for the watchdog. Keyed by clientAddr.
    # Single-writer invariant for each map (inbox callback writes
    # lastEventAt; start() writes spawnedAt; watchdog thread reads) —
    # 64-bit aligned float store is safe without a lock.
    clientSpawnedAt: Table[string, float]
    clientLastEventAt: Table[string, float]
    clientIdentifiers: Table[string, string]  ## clientAddr → sub, for respawn
    watchdogThread: Thread[NMobileChannel]
    watchdogRunning: bool
    fcmKey: string
    pushProxy: string
    enableOfflineQueue: bool
    decryptIpfsCache*: bool
    messageTTLHours: int
    numSubClients: int
    originalClient: bool
    telegramPushChatId: Option[string]
    peers: Table[string, PeerInfo]
    seenMessages: Table[string, float] # messageId -> timestamp
    pendingNotifications: Table[string, OutboundMessage] # LLM messageId -> Pending Telegram notification
    lastReadMsgId: string # ID of the last sent message that can be cleared by an empty read receipt
    peersFile: string
    cacheDir: string
    nknAddress: string  # base wallet address (without identifier prefix)
    baseDir: string     # .claw/channels/nmobile/<address>/
    botDeviceId: string
    bridge: NknBridge
    inboxLock: Lock
    inbox: seq[NknQueueItem]

proc genUUID(): string =
  # Simple pseudo-UUID v4
  let h = "0123456789abcdef"
  result = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  for i in 0..<result.len:
    if result[i] == 'x':
      result[i] = h[rand(15)]
    elif result[i] == 'y':
      result[i] = h[8 + rand(3)]

proc safeGetStr(j: JsonNode, key: string, default = ""): string =
  if j.isNil or j.kind != JObject or not j.hasKey(key): return default
  let node = j[key]
  if node.isNil: return default
  # Handle JString vs JNull or others
  if node.kind == JString: return node.getStr()
  return $node # Fallback to string representation for other types

proc shouldRedactOptionKey(key: string): bool =
  let k = key.toLowerAscii()
  if k in [
    "filetype", "filename", "filesize", "fileext", "filemimetype",
    "ipfsip", "ipfshash", "ipfsencrypt", "ipfsencryptalgorithm", "ipfsencryptnoncesize",
    "ipfsthumbnailhash", "ipfsthumbnailip",
    "piece_parent_type", "piece_bytes_length", "piece_total", "piece_parity", "piece_index"
  ]:
    return false
  if k.contains("keybytes") or k.contains("secret") or k.contains("token") or k.contains("password") or k.contains("private") or k.contains("seed"):
    return true
  if k.contains("nonce") and not k.contains("size"):
    return true
  if k.contains("key") and not k.contains("type"):
    return true
  return false

proc sanitizeOptionsForLog(node: JsonNode): JsonNode =
  if node.isNil: return node
  case node.kind
  of JObject:
    result = newJObject()
    for k, v in node.pairs:
      if shouldRedactOptionKey(k):
        result[k] = %"***"
      else:
        result[k] = sanitizeOptionsForLog(v)
  of JArray:
    result = newJArray()
    for v in node.elems:
      result.add sanitizeOptionsForLog(v)
  else:
    result = node

proc optionsToLogString(j: JsonNode): string =
  if j.isNil: return ""
  var s = $sanitizeOptionsForLog(j)
  s = s.replace("\n", "")
  if s.len > 800:
    s = s[0..<800] & "…"
  return s

proc safeFileName(s: string): string =
  var r = s
  for i in 0..<r.len:
    let ch = r[i]
    if not (ch.isAlphaNumeric or ch in {'.', '-', '_'}):
      r[i] = '_'
  if r.len == 0: r = "file"
  if r.len > 120: r = r[0..<120]
  r

proc extCacheDir(c: NMobileChannel, clientAddr: string): string =
  ## Cache dir for an extension: .claw/channels/nmobile/<address>/<ext>/cache/
  ## clientAddr is like "Lexi.NKNSkGf..." — extract the extension prefix.
  if c.baseDir.len > 0:
    let dotPos = clientAddr.find('.')
    let ext = if dotPos > 0: clientAddr[0..<dotPos] else: "_default"
    result = c.baseDir / ext / "cache"
  else:
    result = getNimClawDir() / "channels" / "nmobile" / "cache"

proc perGuestCacheDir(c: NMobileChannel, src: string, clientAddr: string = ""): string =
  c.extCacheDir(clientAddr) / safeFileName(src)

proc mediaCacheDir(c: NMobileChannel, clientAddr: string): string =
  ## Media dir for an extension: .claw/channels/nmobile/<address>/<ext>/cache/media/
  c.extCacheDir(clientAddr) / "media"

proc listFilesWithInfo(dir: string): seq[(string, int64, float)] =
  result = @[]
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    try:
      let st = getFileInfo(path)
      result.add((path, st.size.int64, float(st.lastWriteTime.toUnix)))
    except:
      discard

proc ensureGuestCacheSpace(dir: string, limitBytes, neededBytes: int64) =
  try:
    createDir(dir)
  except:
    discard
  var files = listFilesWithInfo(dir)
  files.sort(proc(a, b: (string, int64, float)): int = cmp(a[2], b[2]))
  var used = int64(0)
  for it in files: used += it[1]
  if neededBytes > limitBytes:
    return
  var i = 0
  while used + neededBytes > limitBytes and i < files.len:
    let p = files[i][0]
    let sz = files[i][1]
    try:
      removeFile(p)
      used -= sz
    except:
      discard
    inc i

proc tryDownloadIpfsToCache*(c: NMobileChannel, src, cid, fileName: string, opts: JsonNode, clientAddr: string = ""): Future[(bool, string, int64)] {.async.} =
  if cid.len == 0:
    return (false, "", 0'i64)
  let limitBytes = 100'i64 * 1024'i64 * 1024'i64
  let cidPrefix = if cid.len > 16: cid[0..<16] else: cid
  let allowDecrypt = (c != nil and c.decryptIpfsCache)
  var decryptKey: seq[byte] = @[]
  var decryptNonceSize = 12
  var wantDecrypt = false
  var isEncrypted = false
  if not opts.isNil and opts.kind == JObject:
    if opts.hasKey("ipfsEncrypt") and opts["ipfsEncrypt"].kind in {JInt, JFloat}:
      isEncrypted = opts["ipfsEncrypt"].getInt() == 1
  if isEncrypted and not allowDecrypt:
    infoCF("nmobile", "IPFS cache skipped (decrypt disabled)", {"src": src, "cidPrefix": cidPrefix}.toTable)
    return (false, "", 0'i64)
  if isEncrypted and allowDecrypt and not opts.isNil and opts.kind == JObject:
    wantDecrypt = true
    if wantDecrypt and opts.hasKey("ipfsEncryptKeyBytes") and opts["ipfsEncryptKeyBytes"].kind == JArray:
      for n in opts["ipfsEncryptKeyBytes"]:
        if n.kind in {JInt, JFloat}:
          decryptKey.add(byte(n.getInt() and 0xFF))
    if wantDecrypt and opts.hasKey("ipfsEncryptNonceSize") and opts["ipfsEncryptNonceSize"].kind in {JInt, JFloat}:
      decryptNonceSize = opts["ipfsEncryptNonceSize"].getInt()
    if decryptKey.len != 16:
      wantDecrypt = false
  var expectedBytes = 0'i64
  if not opts.isNil and opts.kind == JObject and opts.hasKey("fileSize"):
    try:
      expectedBytes = opts["fileSize"].getInt().int64
    except:
      discard
  if expectedBytes > limitBytes:
    infoCF("nmobile", "IPFS cache download too large", {"src": src, "cidPrefix": cidPrefix, "bytes": $expectedBytes}.toTable)
    return (false, "", 0'i64)
  var gateways: seq[string] = @[]
  var ipfsIp = ""
  if not opts.isNil and opts.kind == JObject and opts.hasKey("ipfsIp") and opts["ipfsIp"].kind == JString:
    ipfsIp = opts["ipfsIp"].getStr()
  if ipfsIp.len > 0:
    gateways.add("http://" & ipfsIp & ":80/ipfs/" & cid)
    gateways.add("http://" & ipfsIp & ":80/api/v0/cat?arg=" & cid)
  gateways.add("http://64.225.88.71:80/ipfs/" & cid)
  gateways.add("http://64.225.88.71:80/api/v0/cat?arg=" & cid)
  gateways.add("https://ipfs.io/ipfs/" & cid)
  gateways.add("https://cloudflare-ipfs.com/ipfs/" & cid)

  let dir = c.perGuestCacheDir(src, clientAddr)
  try:
    createDir(dir)
  except:
    discard
  let fn = if fileName.len > 0: safeFileName(fileName) else: cid
  let tmpPath = dir / ($epochTime().int64 & "_" & safeFileName(cid)[0..<min(32, safeFileName(cid).len)] & "_" & fn & ".partial")
  let finalPath = tmpPath[0..<(tmpPath.len - ".partial".len)]
  if fileExists(finalPath):
    return (true, finalPath, getFileSize(finalPath).int64)

  var lastErr = ""
  for url in gateways:
    try:
      infoCF("nmobile", "IPFS cache download start", {"src": src, "cidPrefix": cidPrefix, "url": url}.toTable)
      let client = newAsyncHttpClient()
      client.timeout = 15000
      let resp = if url.contains("/api/v0/cat"):
        await client.post(url, "")
      else:
        await client.get(url)
      if not resp.status.startsWith("200"):
        lastErr = resp.status
        infoCF("nmobile", "IPFS cache download non-200", {"src": src, "cidPrefix": cidPrefix, "status": resp.status, "url": url}.toTable)
        client.close()
        continue
      var cl = ""
      if resp.headers.hasKey("Content-Length"):
        cl = resp.headers["Content-Length"]
      if cl.len > 0:
        try:
          let n = parseInt(cl).int64
          if n > limitBytes:
            infoCF("nmobile", "IPFS cache download too large", {"src": src, "cidPrefix": cidPrefix, "contentLength": $n}.toTable)
            client.close()
            return (false, "", 0'i64)
        except:
          discard
      let body = await resp.body
      client.close()
      let sz = body.len.int64
      if sz > limitBytes:
        infoCF("nmobile", "IPFS cache download too large", {"src": src, "cidPrefix": cidPrefix, "bytes": $sz}.toTable)
        return (false, "", 0'i64)
      var writeData = body
      var writeBytes = sz
      if wantDecrypt:
        try:
          let plainBytes = aes128GcmDecryptNmobile(toBytes(body), decryptKey, decryptNonceSize)
          writeData = toString(plainBytes)
          writeBytes = plainBytes.len.int64
        except Exception as e:
          lastErr = e.msg
          infoCF("nmobile", "IPFS cache decrypt error", {"src": src, "cidPrefix": cidPrefix, "error": lastErr}.toTable)
          continue
      if writeBytes > limitBytes:
        infoCF("nmobile", "IPFS cache write too large", {"src": src, "cidPrefix": cidPrefix, "bytes": $writeBytes}.toTable)
        return (false, "", 0'i64)
      ensureGuestCacheSpace(dir, limitBytes, writeBytes)
      writeFile(tmpPath, writeData)
      moveFile(tmpPath, finalPath)
      infoCF("nmobile", "IPFS cache write success", {"src": src, "cidPrefix": cidPrefix, "bytes": $writeBytes, "path": finalPath, "decrypted": $(wantDecrypt)}.toTable)
      return (true, finalPath, writeBytes)
    except Exception as e:
      lastErr = e.msg
      infoCF("nmobile", "IPFS cache download error", {"src": src, "cidPrefix": cidPrefix, "error": lastErr, "url": url}.toTable)
      try:
        if fileExists(tmpPath): removeFile(tmpPath)
      except:
        discard
      continue
  errorCF("nmobile", "IPFS download failed", {"src": src, "cidPrefix": (if cid.len > 16: cid[0..<16] else: cid), "error": lastErr}.toTable)
  return (false, "", 0'i64)

proc savePeers(c: NMobileChannel) =
  try:
    let j = %*c.peers
    writeFile(c.peersFile, $j)
    debugCF("nmobile", "Saved peers to disk", {"file": c.peersFile}.toTable)
  except:
    errorCF("nmobile", "Failed to save peers", {"error": getCurrentExceptionMsg()}.toTable)

proc loadPeers(c: NMobileChannel) =
  if fileExists(c.peersFile):
    try:
      let j = parseFile(c.peersFile)
      for k, v in j.pairs:
        var info = PeerInfo()
        if v.hasKey("deviceId"): info.deviceId = v["deviceId"].getStr()
        if v.hasKey("profileVersion"): info.profileVersion = v["profileVersion"].getStr()
        if v.hasKey("deviceToken"): info.deviceToken = v["deviceToken"].getStr()
        if v.hasKey("lastGreetingAt"): info.lastGreetingAt = v["lastGreetingAt"].getFloat()
        c.peers[k] = info
      infoCF("nmobile", "Loaded peers from disk", {"count": $c.peers.len}.toTable)
    except:
      errorCF("nmobile", "Failed to load peers", {"error": getCurrentExceptionMsg()}.toTable)

proc newNMobileChannel*(cfg: Config, bus: MessageBus): NMobileChannel =
  let ncfg = cfg.channels.nmobile
  let base = newBaseChannel("nmobile", bus, ncfg.allow_from)
  let appData = getNimClawDir()
  try:
    createDir(appData)
  except:
    discard
  
  # Identity resolution: the DSL `channel "nmobile": identifier` list is
  # the only source of sub-client→agent routing. When it's empty (company
  # hasn't run `claw channel auth nmobile` yet), we default-route every
  # AI agent to a slug of its name, so the channel still comes up for
  # first-boot smoke tests.
  var idPairs: seq[(string, string)] = @[]
  var agentMap = initTable[string, string]()
  if ncfg.identifiers.len > 0:
    for idCfg in ncfg.identifiers:
      let enabled = options.isSome(idCfg.enabled) and options.get(idCfg.enabled)
      let explicit = options.isSome(idCfg.enabled)
      if explicit and not enabled: continue
      if idCfg.identifier.len == 0: continue
      idPairs.add((idCfg.identifier, idCfg.agent))
      if idCfg.agent.len > 0: agentMap[idCfg.agent] = idCfg.identifier
  else:
    for a in cfg.agents.named:
      if a.entity == "Human":
        infoCF("nmobile", "Skipping NKN extension for Human entity",
               {"name": a.name}.toTable)
        continue
      agentMap[a.name] = a.name
      idPairs.add((a.name, a.name))

  result = NMobileChannel(
    bus: base.bus,
    name: base.name,
    allowList: base.allowList,
    running: false,
    seed: expandEnv(ncfg.seed),
    identifiers: idPairs,
    walletJson: block:
      let nmobileDir = appData / "channels" / "nmobile"
      let legacyWallet = nmobileDir / "wallet.json"
      if ncfg.wallet_json.len == 0 and fileExists(legacyWallet):
        readFile(legacyWallet)
      elif fileExists(ncfg.wallet_json):
        readFile(ncfg.wallet_json)
      else:
        ncfg.wallet_json,
    password: expandEnv(ncfg.password),
    identifier: ncfg.identifier,
    agentIdentifiers: agentMap,
    clientAddrs: newSeq[string](),
    activeClients: initTable[string, string](),
    clientSpawnedAt: initTable[string, float](),
    clientLastEventAt: initTable[string, float](),
    clientIdentifiers: initTable[string, string](),
    fcmKey: ncfg.fcm_key,
    pushProxy: ncfg.push_proxy,
    enableOfflineQueue: ncfg.enable_offline_queue,
    decryptIpfsCache: (if options.isSome(ncfg.decrypt_ipfs_cache): options.get(ncfg.decrypt_ipfs_cache) else: false),
    messageTTLHours: ncfg.message_ttl_hours,
    numSubClients: ncfg.num_sub_clients,
    originalClient: ncfg.original_client,
    telegramPushChatId: ncfg.telegram_push_chat_id,
    peers: initTable[string, PeerInfo](),
    seenMessages: initTable[string, float](),
    pendingNotifications: initTable[string, OutboundMessage](),
    peersFile: appData / "channels" / "nmobile" / "peers.json",  # Migrated to per-addr dir in start()
    cacheDir: appData / "channels" / "nmobile" / "cache",  # Migrated to per-addr dir in start()
    botDeviceId: "", # Set later
    inbox: @[]
  )
  initLock(result.inboxLock)
  result.loadPeers()


proc sendPush(c: NMobileChannel, dest: string, info: PeerInfo, msg: string) =
  let title = "New Message"
  let content = msg # In production might want to truncate or obsfuscate
  
  # 1. FCM Direct
  if c.fcmKey.len > 0 and info.deviceToken.startsWith("[FCM]:"):
    let fcmToken = info.deviceToken.replace("[FCM]:", "")
    infoCF("nmobile", "Sending direct FCM push", {"dest": dest, "token": fcmToken}.toTable)
    # Using std/httpclient or similar for async POST to https://fcm.googleapis.com/fcm/send
    # For now, let's log it. In a real impl, we'd use a shared http client.
  
  # 2. Push Proxy (NKN)
  if c.pushProxy.len > 0 and info.deviceToken.len > 0:
    infoCF("nmobile", "Sending push via NKN Proxy", {"proxy": c.pushProxy, "dest": dest}.toTable)
    let pushPayload = %*{
      "token": info.deviceToken,
      "title": title,
      "content": content,
      "last_message_at": getTime().toUnix() * 1000
    }
    discard c.bridge.sendNKNMessage(c.clientAddrs[0], c.pushProxy, $pushPayload, maxHoldingSeconds = 0, noReply = true)

  # 3. Telegram Bridge
  # (Moved to delayed task in send* method for better noise reduction)

proc getBotDeviceId(address: string): string =
  # Generate a stable deviceId from the NKN address
  # nMobile uses UUID-like strings, we can just use a hash or take a chunk of the address
  if address.len > 10:
    # Use "nimclaw-" prefix + last 8 chars of address for uniqueness
    result = "nimclaw-" & address[address.len-8..address.len-1]
  else:
    result = "nimclaw-gateway"

proc genPayload(c: NMobileChannel, contentType, content: string, msgId: string, replyToId = "", options = newJObject()): JsonNode =
  let now = getTime().toUnix() * 1000
  result = %*{
    "id": msgId,
    "timestamp": now,
    "send_timestamp": now,
    "contentType": contentType,
    "content": content,
    "deviceId": c.botDeviceId,
    "isOutbound": false
  }
  if replyToId.len > 0:
    result["targetID"] = %replyToId
  
  # Note: nMobile getText doesn't include topic if empty, but fromReceive expects it if in topic mode.
  # For one-on-one chat, no topic/groupId should be present.
  if options.len > 0:
    result["options"] = options

proc drainInbox(c: NMobileChannel): seq[NknQueueItem] =
  acquire(c.inboxLock)
  result = move(c.inbox)
  c.inbox = @[]
  release(c.inboxLock)

proc poll(c: NMobileChannel) {.async.} =
  infoC("nmobile", "NMobile polling loop started for " & $c.clientAddrs.len & " clients")
  while c.running:
    try:
      let items = c.drainInbox()
      let messageReceived = items.len > 0
      for (clientAddr, src, data) in items:
        let agentName = c.activeClients.getOrDefault(clientAddr, "")
        if src.len > 0:
          # nMobile sends messages as JSON objects. Try to parse it.
          var finalData = data
          try:
            let j = parseJson(data)
            if j.hasKey("id"):
              let msgId = j["id"].getStr()
              let now = getTime().toUnixFloat()
              if c.seenMessages.hasKey(msgId):
                # Skip already processed message
                continue
              
              # Clean up old seen messages periodically
              if c.seenMessages.len > 1000:
                var toDel = newSeq[string]()
                for k, v in c.seenMessages.pairs:
                  if now - v > 3600: toDel.add(k)
                for k in toDel: c.seenMessages.del(k)
              
              c.seenMessages[msgId] = now
   
            let contentType = j.safeGetStr("contentType")
            var deliverToAgent = false
            var ipfsCidForMsg = ""
            var cachedPathForMsg = ""
            var cachedBytesForMsg = 0'i64
            var info = c.peers.getOrDefault(src)
            var infoChanged = false
  
            # (Activity timestamp update moved to specific content types)
  
            if j.hasKey("deviceId"):
              let dId = j["deviceId"].getStr()
              if info.deviceId != dId:
                info.deviceId = dId
                infoChanged = true
            
            if j.hasKey("options") and j["options"].hasKey("profileVersion"):
              let pv = j["options"]["profileVersion"].getStr()
              if info.profileVersion != pv:
                info.profileVersion = pv
                infoChanged = true
  
            case contentType
            of "text":
              finalData = j["content"].getStr()
              infoCF("nmobile", "Text message received", {"src": src, "agent": agentName, "msg": finalData}.toTable)
              
              infoChanged = true
              deliverToAgent = true
              
              # Send Read Receipt (ACK) for text messages
              if j.hasKey("id"):
                let ackId = j["id"].getStr()
                let ackPayload = c.genPayload("receipt", "", genUUID(), replyToId = ackId)
                if info.profileVersion.len > 0:
                  ackPayload["options"] = %*{"profileVersion": info.profileVersion, "push": true}
                else:
                  ackPayload["options"] = %*{"push": true}
                
                debugCF("nmobile", "Sending Receipt", {"dest": src, "targetID": ackId}.toTable)
                let ttl = if c.enableOfflineQueue: c.messageTTLHours * 3600 else: 0
                discard c.bridge.sendNKNMessage(clientAddr, src, $ackPayload, maxHoldingSeconds = ttl, noReply = true)
            
            of "image", "audio", "video", "file", "ipfs", "piece":
              infoChanged = true
              deliverToAgent = true
              let mid = j.safeGetStr("id")
              var fileType = ""
              var fileName = ""
              var ipfsHashPrefix = ""
              var ipfsHashLen = 0
              var ipfsCid = ""
              var optionsLogged = ""
              if contentType == "ipfs" and j.hasKey("content") and j["content"].kind == JString:
                let ipfsHash = j["content"].getStr()
                ipfsCid = ipfsHash
                ipfsHashLen = ipfsHash.len
                ipfsHashPrefix = if ipfsHash.len > 16: ipfsHash[0..<16] else: ipfsHash
              if j.hasKey("options") and j["options"].kind == JObject:
                if j["options"].hasKey("fileType"): fileType = j["options"]["fileType"].getStr()
                if j["options"].hasKey("fileName"): fileName = j["options"]["fileName"].getStr()
                optionsLogged = optionsToLogString(j["options"])
              
              if contentType == "image" or fileType == "image":
                # Image data is base64-encoded in j["content"]
                var imageSaved = false
                if j.hasKey("content") and j["content"].kind == JString:
                  let imageData = j["content"].getStr()
                  if imageData.len > 0:
                    try:
                      let decoded = base64.decode(imageData)
                      if decoded.len > 0:
                        let mediaDir = c.mediaCacheDir(clientAddr)
                        createDir(mediaDir)
                        let ext = if decoded.len >= 3 and decoded[0] == '\xFF' and decoded[1] == '\xD8': ".jpg"
                                  elif decoded.len >= 4 and decoded[0] == '\x89' and decoded[1] == 'P': ".png"
                                  elif decoded.len >= 4 and decoded[0] == 'G' and decoded[1] == 'I': ".gif"
                                  else: ".jpg"
                        let imgFile = mediaDir / safeFileName(mid) & ext
                        writeFile(imgFile, decoded)
                        finalData = "[image: " & imgFile & "]"
                        imageSaved = true
                        infoCF("nmobile", "Image saved", {"src": src, "path": imgFile, "bytes": $decoded.len}.toTable)
                    except:
                      discard
                if not imageSaved:
                  finalData = "User sent an image on NKN/NMobile but it could not be decoded."
              elif contentType == "audio" or fileType == "audio":
                finalData = "User sent an audio message on NKN/NMobile. Media handling is disabled for untrusted guests; please ask them to summarize the audio or resend via Feishu."
              elif contentType == "video" or fileType == "video":
                finalData = "User sent a video on NKN/NMobile. Media handling is disabled for untrusted guests; please ask them to summarize or resend via Feishu."
              elif contentType == "ipfs":
                finalData = "User sent a file via IPFS on NKN/NMobile. Download/decrypt is disabled for untrusted guests; please ask them to send text details or resend via Feishu."
              elif contentType == "piece":
                finalData = "User sent a chunked media message (piece) on NKN/NMobile. Media reconstruction is disabled for untrusted guests; please ask them to resend as text or via Feishu."
              else:
                finalData = "User sent a file on NKN/NMobile. Media handling is disabled for untrusted guests; please ask them to describe it or resend via Feishu."

              if fileName.len > 0:
                finalData.add(" Filename: " & fileName & ".")
              if contentType == "ipfs" and ipfsHashPrefix.len > 0:
                finalData.add(" CID(prefix): " & ipfsHashPrefix & "… (len=" & $ipfsHashLen & ").")
              if contentType == "ipfs" and ipfsCid.len > 0:
                ipfsCidForMsg = ipfsCid
                finalData.add(" Cached: pending.")
                let cacheDir = c.perGuestCacheDir(src, clientAddr)
                try:
                  createDir(cacheDir)
                except:
                  discard
                infoCF("nmobile", "IPFS cache task queued", {"src": src, "cidPrefix": ipfsHashPrefix, "cacheDir": cacheDir}.toTable)

              var autoReply = ""
              autoReply.add("I received your message, but I can't open images/files on NKN/NMobile yet for security reasons. ")
              autoReply.add("Please describe it in text, or resend via Feishu.\n\n")
              autoReply.add("我收到了你发来的图片/文件，但出于安全原因我暂时无法在 NKN/NMobile 上打开。请用文字描述，或通过飞书重新发送。")
              autoReply.add("\n\nDetected type: " & contentType & (if fileType.len > 0: " (" & fileType & ")" else: ""))
              if contentType == "ipfs" and ipfsHashPrefix.len > 0:
                autoReply.add("\nCID(prefix): " & ipfsHashPrefix & "… (len=" & $ipfsHashLen & ")")
              let replyPayload = c.genPayload("text", autoReply, genUUID())
              var replyOptions = newJObject()
              replyOptions["push"] = %true
              if info.profileVersion.len > 0:
                replyOptions["profileVersion"] = %info.profileVersion
              replyPayload["options"] = replyOptions
              let ttl = if c.enableOfflineQueue: c.messageTTLHours * 3600 else: 0
              discard c.bridge.sendNKNMessage(clientAddr, src, $replyPayload, maxHoldingSeconds = ttl, noReply = true)
              finalData.add(" (Note: user was auto-notified about this limitation.)")
              
              if contentType == "ipfs" and ipfsCid.len > 0 and agentName != "":
                let opts = if j.hasKey("options") and j["options"].kind == JObject: j["options"] else: nil
                let src2 = src
                let cid2 = ipfsCid
                let fn2 = fileName
                let agent2 = agentName
                let prefix2 = ipfsHashPrefix
                let len2 = ipfsHashLen
                let clientAddr2 = clientAddr
                asyncCheck((proc() {.async.} =
                  infoCF("nmobile", "IPFS cache task start", {"src": src2, "cidPrefix": prefix2}.toTable)
                  let dl = await c.tryDownloadIpfsToCache(src2, cid2, fn2, opts, clientAddr2)
                  if dl[0] and dl[1].len > 0:
                    var md2 = initTable[string, string]()
                    md2["content_type"] = "ipfs_cached"
                    md2["ipfs_cid"] = cid2
                    md2["ipfs_cache_path"] = dl[1]
                    md2["ipfs_cache_bytes"] = $dl[2]
                    var msg2 = "IPFS file cached. "
                    if fn2.len > 0:
                      msg2.add("Filename: " & fn2 & ". ")
                    msg2.add("CID(prefix): " & prefix2 & "… (len=" & $len2 & "). ")
                    msg2.add("CachePath: " & dl[1] & ". Bytes: " & $dl[2] & ".")
                    c.handleMessage(src2, src2, msg2, metadata = md2, recipientID = agent2)
                  else:
                    infoCF("nmobile", "IPFS cache task finish (not cached)", {"src": src2, "cidPrefix": prefix2}.toTable)
                )())

              var contentLen = 0
              if j.hasKey("content") and j["content"].kind == JString:
                let contentStr = j["content"].getStr()
                contentLen = contentStr.len
              var fields = {"src": src, "agent": agentName, "type": contentType, "fileType": fileType, "fileName": fileName, "id": mid, "contentLen": $contentLen}.toTable
              if contentType == "ipfs":
                fields["ipfsHashPrefix"] = ipfsHashPrefix
                fields["ipfsHashLen"] = $ipfsHashLen
              if optionsLogged.len > 0:
                fields["options"] = optionsLogged
              infoCF("nmobile", "Non-text message received", fields)

              if mid.len > 0:
                let ackPayload = c.genPayload("receipt", "", genUUID(), replyToId = mid)
                if info.profileVersion.len > 0:
                  ackPayload["options"] = %*{"profileVersion": info.profileVersion, "push": true}
                else:
                  ackPayload["options"] = %*{"push": true}
                let ttl = if c.enableOfflineQueue: c.messageTTLHours * 3600 else: 0
                discard c.bridge.sendNKNMessage(clientAddr, src, $ackPayload, maxHoldingSeconds = ttl, noReply = true)
  
            of "device:info":
              if j.hasKey("deviceToken"):
                let dt = j["deviceToken"].getStr()
                if dt.len > 0 and info.deviceToken != dt:
                  info.deviceToken = dt
                  infoChanged = true
                  infoCF("nmobile", "Captured deviceToken from device:info", {"src": src, "token": dt}.toTable)
  
            of "contact:options":
              if j.hasKey("optionType") and j["optionType"].getStr() == "1":
                if j.hasKey("content"):
                  let dt = j["content"].getStr()
                  if dt.len > 0 and info.deviceToken != dt:
                    info.deviceToken = dt
                    infoChanged = true
                    infoCF("nmobile", "Captured deviceToken from contact:options", {"src": src, "token": dt}.toTable)
  
            of "receipt":
              debugCF("nmobile", "Receipt (ACK) received", {"src": src, "targetID": j.safeGetStr("targetID")}.toTable)
              # removed continue
  
            of "read":
              let contentNode = j.getOrDefault("content")
              if not contentNode.isNil and contentNode.kind != JNull:
                if contentNode.kind == JString:
                  let mid = contentNode.getStr()
                  infoCF("nmobile", "Read receipt (CHAT VIEWED) received", {"src": src, "msgId": mid}.toTable)
                  if c.pendingNotifications.hasKey(mid):
                    infoCF("nmobile", "Cancelling pending notification via Read receipt", {"msgId": mid}.toTable)
                    c.pendingNotifications.del(mid)
                elif contentNode.kind == JArray:
                  infoCF("nmobile", "Read receipt (CHAT VIEWED) received", {"src": src, "msgIds": $contentNode}.toTable)
                  for midNode in contentNode:
                    let mid = midNode.getStr()
                    if c.pendingNotifications.hasKey(mid):
                      infoCF("nmobile", "Cancelling pending notification via Read receipt", {"msgId": mid}.toTable)
                      c.pendingNotifications.del(mid)
              else:
                infoCF("nmobile", "Read receipt (CHAT VIEWED) received (empty content)", {"src": src}.toTable)
                if c.lastReadMsgId.len > 0 and c.pendingNotifications.hasKey(c.lastReadMsgId):
                  infoCF("nmobile", "Cancelling pending notification via EMPTY Read receipt", {"msgId": c.lastReadMsgId}.toTable)
                  c.pendingNotifications.del(c.lastReadMsgId)
              # removed continue
  
            of "ping":
              let content = j.safeGetStr("content")
              debugCF("nmobile", "Ping/Pong received", {"src": src, "type": content}.toTable)
              if content == "ping":
                # Respond with pong
                let pongPayload = c.genPayload("ping", "pong", genUUID())
                if info.profileVersion.len > 0:
                  pongPayload["options"] = %*{"profileVersion": info.profileVersion, "push": true}
                else:
                  pongPayload["options"] = %*{"push": true}
                
                let ttl = if c.enableOfflineQueue: c.messageTTLHours * 3600 else: 0
                discard c.bridge.sendNKNMessage(clientAddr, src, $pongPayload, maxHoldingSeconds = ttl, noReply = true)
              # removed continue
  
            else:
              infoChanged = true
              deliverToAgent = true
              let mid = j.safeGetStr("id")
              finalData = "User sent a non-text message on NKN/NMobile (type: " & contentType & "). Media handling is disabled for untrusted guests; please ask them to describe it in text or resend via Feishu."
              var contentLen = 0
              if j.hasKey("content") and j["content"].kind == JString:
                contentLen = j["content"].getStr().len
              var fields = {"src": src, "agent": agentName, "type": contentType, "id": mid, "contentLen": $contentLen}.toTable
              if j.hasKey("options") and j["options"].kind == JObject:
                fields["options"] = optionsToLogString(j["options"])
              infoCF("nmobile", "Non-text message received (unhandled)", fields)
              var autoReply = ""
              autoReply.add("I received your message, but I can't open non-text content on NKN/NMobile yet for security reasons. ")
              autoReply.add("Please describe it in text, or resend via Feishu.\n\n")
              autoReply.add("我收到了你发来的内容，但出于安全原因我暂时无法在 NKN/NMobile 上处理非文字内容。请用文字描述，或通过飞书重新发送。")
              autoReply.add("\n\nDetected type: " & contentType)
              let replyPayload = c.genPayload("text", autoReply, genUUID())
              var replyOptions = newJObject()
              replyOptions["push"] = %true
              if info.profileVersion.len > 0:
                replyOptions["profileVersion"] = %info.profileVersion
              replyPayload["options"] = replyOptions
              let ttl = if c.enableOfflineQueue: c.messageTTLHours * 3600 else: 0
              discard c.bridge.sendNKNMessage(clientAddr, src, $replyPayload, maxHoldingSeconds = ttl, noReply = true)
              finalData.add(" (Note: user was auto-notified about this limitation.)")
              if mid.len > 0:
                let ackPayload = c.genPayload("receipt", "", genUUID(), replyToId = mid)
                if info.profileVersion.len > 0:
                  ackPayload["options"] = %*{"profileVersion": info.profileVersion, "push": true}
                else:
                  ackPayload["options"] = %*{"push": true}
                let ttl = if c.enableOfflineQueue: c.messageTTLHours * 3600 else: 0
                discard c.bridge.sendNKNMessage(clientAddr, src, $ackPayload, maxHoldingSeconds = ttl, noReply = true)
  
            if infoChanged:
              c.peers[src] = info
              c.savePeers()
  
            if deliverToAgent:
              let destLabel = if agentName == "": "main-line (bind / default)" else: agentName
              infoC("nmobile", "Received " & contentType & " from " & src & " for " & destLabel)
              var md = initTable[string, string]()
              md["content_type"] = contentType
              if j.hasKey("id"): md["msg_id"] = j["id"].getStr()
              if j.hasKey("options") and j["options"].kind == JObject:
                if j["options"].hasKey("fileType"): md["file_type"] = j["options"]["fileType"].getStr()
                if j["options"].hasKey("fileName"): md["file_name"] = j["options"]["fileName"].getStr()
              if ipfsCidForMsg.len > 0:
                md["ipfs_cid"] = ipfsCidForMsg
              if cachedPathForMsg.len > 0:
                md["ipfs_cache_path"] = cachedPathForMsg
                md["ipfs_cache_bytes"] = $cachedBytesForMsg
              # Empty agentName = bare-pubkey (main-line) client: gateway's
              # default-recipient path runs the pre-LLM bind intercept, so
              # forward with recipientID="" rather than dropping.
              c.handleMessage(src, src, finalData, metadata = md, recipientID = agentName)
          except Exception as e:
            # Normal binary or plain text, use as-is or log error
            debugCF("nmobile", "Failed to parse JSON message, treating as raw", {"src": src, "error": e.msg}.toTable)
            var content = data
            if data.len > 4000:
              content = "User sent a non-text or oversized message on NKN/NMobile. Media handling is disabled for untrusted guests; please ask them to describe it in text or resend via Feishu."
              let replyPayload = c.genPayload(
                "text",
                "I received your message, but I can't open non-text content on NKN/NMobile yet for security reasons. Please describe it in text, or resend via Feishu.\n\n我收到了你发来的内容，但出于安全原因我暂时无法在 NKN/NMobile 上处理非文字内容。请用文字描述，或通过飞书重新发送。",
                genUUID()
              )
              var replyOptions = newJObject()
              replyOptions["push"] = %true
              replyPayload["options"] = replyOptions
              let ttl = if c.enableOfflineQueue: c.messageTTLHours * 3600 else: 0
              discard c.bridge.sendNKNMessage(clientAddr, src, $replyPayload, maxHoldingSeconds = ttl, noReply = true)
            if agentName == "":
              c.handleMessage(src, src, content)
            else:
              var md = initTable[string, string]()
              md["content_type"] = "raw"
              md["parse_error"] = e.msg
              md["raw_len"] = $data.len
              c.handleMessage(src, src, content, metadata = md, recipientID = agentName)
            
      if not messageReceived:
        # No message from any client, sleep a bit to avoid CPU hogging
        await sleepAsync(500)
    except Exception as e:
      errorCF("nmobile", "Polling exception", {"error": e.msg}.toTable)
      await sleepAsync(2000)

const
  NknClientMaxAgeSec = 14_400   ## 4h blind cycle cap (same as feishu).
  NknClientStaleSec  = 900      ## 15min silent → treat as dead.
  NknWatchdogTickSec = 60       ## Scan cadence.
  NknDefaultNumSubClients = 4   ## nkn-sdk-go refuses NewMultiClient with 0.

proc nkyYellowBook*(cfg: Config, lang = "en"): string =
  ## Build a "phone directory" of agent NKN addresses — printed to a
  ## newly-bound nMobile customer after invite redemption so they can
  ## save each agent directly in their contacts.
  ##
  ## Empty string when no nMobile channel is configured or the seed
  ## isn't available — caller just skips the section.
  let seed = expandEnv(cfg.channels.nmobile.seed)
  if seed.len == 0 or cfg.channels.nmobile.identifiers.len == 0: return ""
  var entries: seq[(string, string)] = @[]
  try:
    let bridge = newNknBridge()
    defer: bridge.stop()
    for idCfg in cfg.channels.nmobile.identifiers:
      if idCfg.agent.len == 0 or idCfg.identifier.len == 0: continue
      let (fullAddr, err) = bridge.getAddressFromSeed(seed, idCfg.identifier)
      if err.len == 0 and fullAddr.len > 0:
        entries.add((idCfg.agent, fullAddr))
  except CatchableError: discard
  if entries.len == 0: return ""
  let zh = lang.startsWith("zh")
  result = if zh:
    "\n\n---\n\n📇 **您可直接联系我们的助理（nMobile 通讯录）**\n\n"
  else:
    "\n\n---\n\n📇 **Direct lines — add to your nMobile contacts**\n\n"
  for (agent, fullAddr) in entries:
    result.add("- **" & agent & "**\n  `" & fullAddr & "`\n")

proc clientWatchdog(c: NMobileChannel) {.thread.} =
  ## SIGKILL+respawn NKN sub-clients whose relay session has gone silently
  ## dead. nkn-cli's MultiClient can lose its relay-node connection without
  ## bubbling an error up — the message pipe stays open but deliveries
  ## stop. Without this, a single network hiccup causes hours of
  ## indistinguishable silence. Polls the shutdown flag every second so
  ## `stop()` returns promptly.
  var tickElapsed = 0
  while c.watchdogRunning and c.running:
    sleep(1000)
    tickElapsed += 1
    if tickElapsed < NknWatchdogTickSec: continue
    tickElapsed = 0
    if c.seed.len == 0: continue  # legacy mode — no respawn path
    let now = epochTime()
    for clientAddr in c.clientAddrs:
      let spawned = c.clientSpawnedAt.getOrDefault(clientAddr, 0.0)
      let lastEvt = c.clientLastEventAt.getOrDefault(clientAddr, 0.0)
      if spawned <= 0: continue
      let age = now - spawned
      let staleness = if lastEvt > 0: now - lastEvt else: 0.0
      var reason = ""
      if age > NknClientMaxAgeSec.float:
        reason = "4h cycle (age=" & $int(age) & "s)"
      elif lastEvt > 0 and staleness > NknClientStaleSec.float:
        reason = "no events " & $int(staleness) & "s (alive " &
                 $int(age) & "s)"
      if reason.len == 0: continue
      let sub = c.clientIdentifiers.getOrDefault(clientAddr, "")
      infoCF("nmobile", "Watchdog cycling client",
             {"address": clientAddr, "reason": reason}.toTable)
      discard c.bridge.closeNKNClient(clientAddr)
      # Re-create with same seed + identifier — nkn-cli derives the same
      # address deterministically, so clientAddr-keyed tables stay valid.
      let (_, err) = c.bridge.createClientFromSeed(c.seed, sub,
                        c.numSubClients, c.originalClient)
      if err.len > 0:
        errorCF("nmobile", "Watchdog respawn failed",
                {"address": clientAddr, "error": err}.toTable)
        continue
      c.clientSpawnedAt[clientAddr] = epochTime()
      c.clientLastEventAt[clientAddr] = 0

method start*(c: NMobileChannel) {.async.} =
  randomize()
  infoC("nmobile", "Starting NMobile channel...")
  try:
    let seedMode = c.seed.len > 0
    if not seedMode and c.walletJson.len == 0:
      errorC("nmobile", "Failed to start NMobile channel: neither seed (NKN_WALLET_SEED) nor wallet_json is configured — run `claw channel auth nmobile`.")
      return

    let onMsg = proc(clientAddr, src, data: string) {.gcsafe.} =
      # Stamp liveness for the watchdog. Single writer (this callback
      # thread), single reader (watchdog thread) — plain float store is
      # safe without a lock, same as feishu's subscriber-liveness path.
      c.clientLastEventAt[clientAddr] = epochTime()
      acquire(c.inboxLock)
      c.inbox.add((clientAddr, src, data))
      release(c.inboxLock)
    c.bridge = newNknBridge(onMsg)

    # Resolve base pubkey early (no client open) to set up per-address dir.
    let nmobileDir = getNimClawDir() / "channels" / "nmobile"
    let (nknAddr, addrErr) =
      if seedMode: c.bridge.getAddressFromSeed(c.seed, "")
      else: c.bridge.getNKNAddress(c.walletJson, c.password, c.identifier)
    if addrErr.len == 0 and nknAddr.len > 0:
      c.nknAddress = nknAddr
      let addrDir = nmobileDir / nknAddr
      c.baseDir = addrDir
      try:
        createDir(addrDir)
        if not seedMode and not fileExists(addrDir / "wallet.json"):
          writeFile(addrDir / "wallet.json", c.walletJson)
        let addrShort = if nknAddr.len > 16: nknAddr[0..<16] else: nknAddr
        let legacyDir = nmobileDir / "nkn-cli-" & addrShort
        if dirExists(legacyDir):
          let legacyPeers = legacyDir / "peers.json"
          if fileExists(legacyPeers) and not fileExists(addrDir / "peers.json"):
            copyFile(legacyPeers, addrDir / "peers.json")
          let legacyWallet = legacyDir / "wallet.json"
          if not seedMode and fileExists(legacyWallet) and
             not fileExists(addrDir / "wallet.json"):
            copyFile(legacyWallet, addrDir / "wallet.json")
          infoCF("nmobile", "Migrated from legacy dir",
                 {"from": "nkn-cli-" & addrShort, "to": nknAddr}.toTable)
        let perAddrPeers = addrDir / "peers.json"
        if not fileExists(perAddrPeers) and fileExists(c.peersFile):
          copyFile(c.peersFile, perAddrPeers)
        c.peersFile = perAddrPeers
        let defaultExt =
          if c.identifiers.len > 0: c.identifiers[0][0]
          elif c.identifier.len > 0: c.identifier
          else: "_default"
        c.cacheDir = addrDir / defaultExt / "cache"
        createDir(c.cacheDir)
        infoCF("nmobile", "Using per-address dir", {"dir": nknAddr}.toTable)
      except:
        discard

    # Build the client list. New DSL → `c.identifiers` (authoritative).
    # Legacy → reconstruct from `c.identifier` + `c.agentIdentifiers`.
    var identifiersToStart: seq[(string, string)] = @[]
    if c.identifiers.len > 0:
      identifiersToStart = c.identifiers
    else:
      if c.identifier.len > 0:
        identifiersToStart.add((c.identifier, ""))
      for name, id in c.agentIdentifiers.pairs:
        identifiersToStart.add((id, name))
      if identifiersToStart.len == 0:
        identifiersToStart.add(("", ""))

    # Spawn per-agent sub-clients AND a bare-pubkey main-line client.
    # The main-line receives bind codes (pre-LLM intercept in gateway)
    # and any customer traffic that addresses the company directly
    # rather than a specific agent extension.
    var toSpawn = identifiersToStart
    if seedMode:
      # Bare pubkey = company main line. Routed with recipient_id=""
      # so gateway's default-recipient path handles it.
      toSpawn.add(("", ""))

    let numSub =
      if c.numSubClients > 0: c.numSubClients else: NknDefaultNumSubClients
    for (id, agent) in toSpawn:
      let (clientAddrRes, err) =
        if seedMode:
          c.bridge.createClientFromSeed(c.seed, id, numSub, c.originalClient)
        else:
          c.bridge.createNKNClient(c.walletJson, c.password, id,
                                    numSub, c.originalClient)
      if err.len > 0:
        errorCF("nmobile", "Failed to create NKN client",
                {"error": err, "identifier": id}.toTable)
        continue
      c.clientAddrs.add(clientAddrRes)
      c.activeClients[clientAddrRes] = agent
      c.clientIdentifiers[clientAddrRes] = id
      c.clientSpawnedAt[clientAddrRes] = epochTime()
      c.clientLastEventAt[clientAddrRes] = 0
      if c.botDeviceId == "":
        c.botDeviceId = getBotDeviceId(clientAddrRes)
      let roleLabel = if id.len == 0: "main-line" else: "agent"
      infoCF("nmobile", "NMobile client connected",
             {"address": clientAddrRes, "deviceId": c.botDeviceId,
              "agent": agent, "role": roleLabel}.toTable)

    if c.clientAddrs.len == 0:
      errorC("nmobile", "Failed to start any NMobile sub-clients")
      return

    c.running = true
    # Liveness watchdog — seed-mode only. Legacy deployments don't get
    # transparent respawn because we don't hold the password in memory
    # across the lifetime of the channel.
    if seedMode:
      c.watchdogRunning = true
      createThread(c.watchdogThread, clientWatchdog, c)
    discard poll(c)
  except Exception as e:
    errorCF("nmobile", "Failed to start NMobile channel",
            {"error": e.msg}.toTable)

method stop*(c: NMobileChannel) {.async.} =
  c.running = false
  if c.watchdogRunning:
    c.watchdogRunning = false
    joinThread(c.watchdogThread)
  for a in c.clientAddrs:
    if a.len > 0:
      discard c.bridge.closeNKNClient(a)
  if c.bridge != nil:
    c.bridge.stop()

method send*(c: NMobileChannel, msg: OutboundMessage) {.async.} =
  if not c.running or c.clientAddrs.len == 0: return
  
  let dest = msg.chat_id
  
  # Route the reply out through the sub-client whose role matches — a
  # DM to lexi.<pub> must leave via lexi.<pub> so the customer's thread
  # stays under the Lexi contact. Bind/default replies have no
  # sender_agent → send from the main-line (bare-pubkey) client so they
  # stay under the "company main line" contact, not whichever sub-client
  # happened to be spawned first.
  var senderAddr = ""
  if msg.sender_agent.len > 0:
    for addr, name in c.activeClients.pairs:
      if name == msg.sender_agent:
        senderAddr = addr; break
  else:
    for addr, name in c.activeClients.pairs:
      if name == "":
        senderAddr = addr; break
  if senderAddr.len == 0: senderAddr = c.clientAddrs[0]

  if msg.kind == Typing:
    # Handle typing/thinking feedback for nMobile
    # Since nMobile doesn't have a status API, we send a quick emoji acknowledgment
    infoC("nmobile", "Sending typing feedback to " & dest)
    let typingMsgId = genUUID()
    let typingPayload = c.genPayload("text", "💭", typingMsgId)
    # Even typing feedback should have some TTL to ensure it shows up if they just backgrounded
    discard c.bridge.sendNKNMessage(senderAddr, dest, $typingPayload, maxHoldingSeconds = 3600, noReply = true)
    return

  var data = msg.content
  if data.len > 0:
    # Force nMobile to use Markdown renderer even if mentions are present
    # Wrapped in a comment to hide it from the user
    data &= "\n\n<!-- &status=approve -->"
  infoC("nmobile", "Sending message to " & dest)
  
  let msgId = genUUID()
  let info = c.peers.getOrDefault(dest)
  
  # Prepare options
  let options = newJObject()
  options["push"] = %true
  if info.profileVersion.len > 0:
    options["profileVersion"] = %info.profileVersion

  let payload = c.genPayload("text", data, msgId, options = options)
  
  # Diagnostic Log
  debugCF("nmobile", "OUTBOUND PAYLOAD", {"dest": dest, "msgId": msgId, "json": $payload}.toTable)

  # Force a robust TTL (default to 24h if not configured or set to 0)
  var ttl = if c.enableOfflineQueue and c.messageTTLHours > 0: 
              c.messageTTLHours * 3600 
            else: 
              86400 # 24 hours default
  
  infoCF("nmobile", "Sending message via NKN", {"dest": dest, "msgId": msgId, "ttl": $ttl}.toTable)
  let (_, err) = c.bridge.sendNKNMessage(senderAddr, dest, $payload, ttl, noReply = false)
  
  if err.len > 0:
    errorCF("nmobile", "Send error", {"dest": dest, "error": err}.toTable)
  else:
    infoCF("nmobile", "Message sent successfully", {"dest": dest, "msgId": msgId}.toTable)
    # 1. Immediate Native Push (FCM/Proxy)
    let latestInfo = c.peers.getOrDefault(dest)
    c.sendPush(dest, latestInfo, data)

    # 2. Delayed Telegram Notification (Cancellable by Read Receipt)
    if c.telegramPushChatId.isSome:
      let tChatId = c.telegramPushChatId.get
      let pushMsg = "🔔 *nMobile Notification*\nYour NimClaw response is ready! 🦞"
      let pendingMsg = OutboundMessage(
        channel: "telegram", 
        chat_id: tChatId, 
        content: pushMsg
      )
      c.pendingNotifications[msgId] = pendingMsg
      c.lastReadMsgId = msgId # Store for empty read receipts
      
      let channel = c
      let mid = msgId
      asyncCheck (proc() {.async.} =
        await sleepAsync(5000) # 5 seconds window for user to view chat
        if channel.pendingNotifications.hasKey(mid):
          let pMsg = channel.pendingNotifications.getOrDefault(mid)
          if pMsg.chat_id.len > 0:
            infoCF("nmobile", "Telegram notification SENT (no read receipt within 5s)", {"msgId": mid}.toTable)
            channel.bus.publishOutbound(pMsg)
          channel.pendingNotifications.del(mid)
        else:
          infoCF("nmobile", "Telegram notification SUPPRESSED (read receipt received)", {"msgId": mid}.toTable)
      )()

method isRunning*(c: NMobileChannel): bool = c.running
