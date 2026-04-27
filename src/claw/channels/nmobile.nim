import std/[asyncdispatch, json, strutils, random, times, tables, os, options, algorithm, httpclient, locks, base64]
import base
import ../crypto_gcm
import ../bus, ../bus_types, ../config, ../logger
import ../agent/cortex as cortex_mod
import ../libnkn/nkn_bridge
import ../version
import ../billing/company as company_mod
import nimcrypto/hash
import nimcrypto/sha2

type
  PieceBuffer = object
    ## Collects Reed-Solomon-chunked `nknOnePiece` fragments of a single
    ## media message until enough data pieces arrive to reassemble. nmobile
    ## sends `total + parity` pieces per file; we only need the `total`
    ## data pieces (indices 0..total-1) for a simple concat — RS decode of
    ## parity is unnecessary in the common case where the relay delivers
    ## everything. Buffers older than ~60s are dropped by a periodic sweep.
    startedAt: float
    total, parity: int
    bytesLength: int              ## base64-string length of original file
    parentType: string            ## "media" for nmobile images
    fileExt: string               ## sender's hint; we verify via magic bytes
    agentName: string             ## routing target captured at first piece
    clientAddr: string            ## sub-client that received piece 0
    src: string                   ## peer address
    pieces: Table[int, string]    ## piece_index → raw chunk bytes

  PeerInfo = object
    deviceId: string
    profileVersion: string
    deviceToken: string
    displayName: string            ## From peer's `contact`/`contact:profile`
                                    ## card — the name they chose to show
                                    ## in their nMobile app.
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
    pieceBuffers: Table[string, PieceBuffer] # msgId -> accumulator
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
        if v.hasKey("displayName"): info.displayName = v["displayName"].getStr()
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
    # Default on — encrypted IPFS is how nmobile clients transmit
    # photos, and the AES-GCM pipeline is local only (we already have
    # the download + decrypt code; skipping by default meant customers
    # got "I can't see images" for every photo they sent). Operators
    # can still opt out via `decrypt_ipfs_cache: false` in config.
    decryptIpfsCache: (if options.isSome(ncfg.decrypt_ipfs_cache): options.get(ncfg.decrypt_ipfs_cache) else: true),
    messageTTLHours: ncfg.message_ttl_hours,
    numSubClients: ncfg.num_sub_clients,
    originalClient: ncfg.original_client,
    telegramPushChatId: ncfg.telegram_push_chat_id,
    peers: initTable[string, PeerInfo](),
    seenMessages: initTable[string, float](),
    pieceBuffers: initTable[string, PieceBuffer](),
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

# ── Contact-profile advertisement ───────────────────────────────────
# Each sub-client (main-line, lexi.<pub>, atlas.<pub>, …) has its own
# contact card: distinct name, jobTitle, avatar, profile version.
# When a peer first saves our address they pull the card via
# `contact:profile` with requestType=header/full, and we answer here.

proc profileDisplayName(c: NMobileChannel, clientAddr: string): string =
  ## Name advertised on this sub-client's contact card. Agent clients
  ## use the agent's name; the bare-pubkey main-line uses the company
  ## brand resolved from the graph.
  let agentName = c.activeClients.getOrDefault(clientAddr, "")
  if agentName.len > 0: return agentName
  try:
    let g = loadWorld(getNimClawDir() / "workspace")
    if g != nil:
      let brand = resolveBrand(g)
      if brand.len > 0: return brand
  except CatchableError: discard
  result = extractFilename(getNimClawDir())

proc profileSubtitle(c: NMobileChannel, clientAddr: string): string =
  ## Second-line label — usually the agent's jobTitle from the graph.
  ## Populates `last_name` in the card's content block since most nMobile
  ## UIs only render `first_name` prominently, and `last_name` reads as
  ## a subtitle.
  let agentName = c.activeClients.getOrDefault(clientAddr, "")
  if agentName.len == 0: return ""
  try:
    let g = loadWorld(getNimClawDir() / "workspace")
    if g != nil and g.nameIndex.hasKey(agentName):
      let ent = g.entities[g.nameIndex[agentName]]
      if ent.kind == ekAI: return ent.jobTitle
  except CatchableError: discard
  return ""

proc profileAvatarPath(c: NMobileChannel, clientAddr: string): string =
  ## Resolve the avatar file for this sub-client. Agent clients look
  ## under `workspace/offices/<agent>/avatar.{jpg,png,webp}`; the main-
  ## line client looks at `workspace/avatar.*`. Empty if none authored.
  let agentName = c.activeClients.getOrDefault(clientAddr, "")
  let baseDir =
    if agentName.len > 0:
      getNimClawDir() / "workspace" / "offices" / agentName.toLowerAscii
    else:
      getNimClawDir() / "workspace"
  for ext in ["jpg", "jpeg", "png", "webp"]:
    let p = baseDir / ("avatar." & ext)
    if fileExists(p): return p
  return ""

proc profileVersionFor(c: NMobileChannel, clientAddr: string): string =
  ## Deterministic profile version: hash of (name + subtitle + avatar
  ## bytes). Stable across gateway restarts — peers re-pull only when
  ## one of those inputs actually changes. 8-4-4-4-12 shape to look
  ## UUID-ish, though nmobile only compares it for equality.
  var ctx: sha256
  ctx.init()
  ctx.update(c.profileDisplayName(clientAddr))
  ctx.update(c.profileSubtitle(clientAddr))
  let avatarPath = c.profileAvatarPath(clientAddr)
  if avatarPath.len > 0:
    try: ctx.update(readFile(avatarPath))
    except CatchableError: discard
  let hex = $ctx.finish()
  if hex.len >= 32:
    return hex[0..7] & "-" & hex[8..11] & "-" & hex[12..15] & "-" &
           hex[16..19] & "-" & hex[20..31]
  return hex

proc sendContactProfile(c: NMobileChannel, clientAddr, dest,
                        responseType: string, includeContent: bool) =
  ## Emit a `contact:profile` response. `responseType = "header"` carries
  ## just the version (the peer pings with requestType=header on every
  ## message to detect drift); `responseType = "full"` carries the card
  ## content (requested by the peer when it notices a version mismatch).
  ## Keyed on nmobile's getContactProfileResponse{Header,Full} in
  ## lib/schema/message.dart:1238-1267.
  let payload = c.genPayload("contact:profile", "", genUUID())
  payload.delete("content")  # responses don't carry top-level content
  payload["responseType"] = %responseType
  payload["version"] = %c.profileVersionFor(clientAddr)
  if includeContent:
    var content = newJObject()
    let displayName = c.profileDisplayName(clientAddr)
    let subtitle = c.profileSubtitle(clientAddr)
    if displayName.len > 0:
      content["first_name"] = %displayName
      content["last_name"] = %subtitle
      content["name"] = %displayName
    let avatarPath = c.profileAvatarPath(clientAddr)
    if avatarPath.len > 0:
      try:
        let bytes = readFile(avatarPath)
        let ext = avatarPath.splitFile.ext.strip(chars = {'.'})
        content["avatar"] = %*{
          "type": "base64",
          "data": base64.encode(bytes),
          "ext": ext
        }
      except CatchableError: discard
    payload["content"] = content
  let ttl = if c.enableOfflineQueue: c.messageTTLHours * 3600 else: 0
  discard c.bridge.sendNKNMessage(clientAddr, dest, $payload,
                                   maxHoldingSeconds = ttl, noReply = true)
  infoCF("nmobile", "Sent contact:profile response",
         {"dest": dest, "clientAddr": clientAddr,
          "responseType": responseType,
          "displayName": c.profileDisplayName(clientAddr)}.toTable)

# ── nknOnePiece reassembly ──────────────────────────────────────────
# nmobile chunks photos (and other media) with Reed-Solomon FEC:
# total data pieces + parity pieces, any `total` of which reconstruct
# the original. The sender always emits all pieces; we only need to
# wait for the `total` data pieces (indices 0..total-1) and concat —
# no RS decode required in the common case. If data pieces go missing
# and only parity arrives, reassembly fails; we'd need to plumb in a
# Reed-Solomon library for that. Not shipped: for now we wait for all
# data pieces and drop the buffer on timeout.

const PieceBufferTtlSec = 60.0

proc extFromMagic(bytes: string): string =
  if bytes.len >= 3 and bytes[0].uint8 == 0xFF and bytes[1].uint8 == 0xD8 and
     bytes[2].uint8 == 0xFF: return ".jpg"
  if bytes.len >= 8 and bytes[0].uint8 == 0x89 and bytes[1].uint8 == 0x50 and
     bytes[2].uint8 == 0x4E and bytes[3].uint8 == 0x47: return ".png"
  if bytes.len >= 6 and bytes[0].uint8 == 0x47 and bytes[1].uint8 == 0x49 and
     bytes[2].uint8 == 0x46: return ".gif"
  if bytes.len >= 12 and bytes[0].uint8 == 0x52 and bytes[1].uint8 == 0x49 and
     bytes[2].uint8 == 0x46 and bytes[3].uint8 == 0x46: return ".webp"
  return ""

proc sweepPieceBuffers(c: NMobileChannel) =
  ## Drop half-assembled buffers once they've aged past the TTL. Called
  ## cheaply on every inbound piece rather than on a dedicated timer.
  let now = epochTime()
  var stale: seq[string] = @[]
  for k, buf in c.pieceBuffers.pairs:
    if now - buf.startedAt > PieceBufferTtlSec: stale.add(k)
  for k in stale:
    let buf = c.pieceBuffers[k]
    infoCF("nmobile", "Dropped stale piece buffer",
           {"msgId": k, "pieces": $buf.pieces.len, "needed": $buf.total,
            "ageSec": $int(now - buf.startedAt)}.toTable)
    c.pieceBuffers.del(k)

proc tryAssemblePiece(c: NMobileChannel, msgId: string): bool =
  ## Return true when enough data pieces (indices 0..total-1) have
  ## arrived and the media has been reassembled + handed to the agent.
  ## Buffer is consumed on success.
  if not c.pieceBuffers.hasKey(msgId): return false
  let buf = c.pieceBuffers[msgId]
  # Need every data-index present; parity pieces are ignored in this
  # non-RS path because a single missing data piece would require
  # Reed-Solomon recovery which we haven't wired up.
  for i in 0 ..< buf.total:
    if not buf.pieces.hasKey(i): return false
  var base64Data = newStringOfCap(buf.bytesLength + 16)
  for i in 0 ..< buf.total:
    base64Data.add(buf.pieces[i])
  # Trim to the exact length the sender declared — RS padding may
  # occasionally produce a last-piece overshoot of a few bytes.
  if base64Data.len > buf.bytesLength:
    base64Data.setLen(buf.bytesLength)
  var fileBytes = ""
  try:
    fileBytes = base64.decode(base64Data)
  except CatchableError as err:
    errorCF("nmobile", "Piece reassembly: base64 decode failed",
            {"msgId": msgId, "error": err.msg}.toTable)
    c.pieceBuffers.del(msgId)
    return true  # consumed, even though failed — avoid retrying
  var ext = extFromMagic(fileBytes)
  if ext.len == 0 and buf.fileExt.len > 0:
    ext = "." & buf.fileExt.strip(chars = {'.'})
  let isImage = ext in [".jpg", ".jpeg", ".png", ".gif", ".webp"]
  let mediaDir = c.mediaCacheDir(buf.clientAddr)
  try: createDir(mediaDir)
  except CatchableError: discard
  let outPath = mediaDir / safeFileName(msgId) & ext
  try:
    writeFile(outPath, fileBytes)
  except CatchableError as err:
    errorCF("nmobile", "Piece reassembly: write failed",
            {"msgId": msgId, "path": outPath, "error": err.msg}.toTable)
    c.pieceBuffers.del(msgId)
    return true
  infoCF("nmobile", "Piece reassembly success",
         {"msgId": msgId, "path": outPath,
          "bytes": $fileBytes.len, "isImage": $isImage,
          "pieces": $buf.total}.toTable)
  var md = initTable[string, string]()
  md["content_type"] = if isImage: "piece_image" else: "piece_file"
  md["msg_id"] = msgId
  md["cache_path"] = outPath
  md["cache_bytes"] = $fileBytes.len
  let agentMsg =
    if isImage: "[image: " & outPath & "]"
    else: "User sent a file via nMobile. Path: " & outPath & ". Bytes: " &
          $fileBytes.len & "."
  c.handleMessage(buf.src, buf.src, agentMsg, metadata = md,
                   recipientID = buf.agentName)
  c.pieceBuffers.del(msgId)
  return true

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
            let msgId = j{"id"}.getStr()
            let incomingType = j{"contentType"}.getStr()
            # `nknOnePiece` fragments of a single logical media message
            # all share the same outer `id` — dedupe by id would drop
            # every piece after the first and break reassembly. Rely on
            # nkn-sdk-go's MultiClient msgCache (NKN-transport layer
            # MessageID) for these; they're already deduped there.
            if msgId.len > 0 and incomingType != "nknOnePiece":
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
            of "text", "textExtension":
              # textExtension is plain text + options (burn-after,
              # profileVersion). nmobile promotes outbound text to
              # textExtension when options are attached; we treat both
              # identically on receive. See nmobile
              # lib/schema/message.dart:145 (isText covers both).
              finalData = j["content"].getStr()
              var textFields = {"src": src, "agent": agentName, "msg": finalData,
                                "kind": contentType}.toTable
              if info.displayName.len > 0: textFields["from"] = info.displayName
              infoCF("nmobile", "Text message received", textFields)
              
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

              # An IPFS image we can decrypt will arrive via the async
              # cache task and be delivered to the agent as [image:
              # <path>]; sending a "can't open" decline first would
              # confuse the thread. Skip the autoreply in that case.
              let willDecryptIpfs = contentType == "ipfs" and c.decryptIpfsCache and
                                     ipfsCid.len > 0 and
                                     j.hasKey("options") and j["options"].kind == JObject and
                                     j["options"].hasKey("ipfsEncrypt") and
                                     j["options"]["ipfsEncrypt"].kind in {JInt, JFloat} and
                                     j["options"]["ipfsEncrypt"].getInt() == 1 and
                                     j["options"].hasKey("ipfsEncryptKeyBytes") and
                                     j["options"]["ipfsEncryptKeyBytes"].kind == JArray and
                                     j["options"]["ipfsEncryptKeyBytes"].len == 16
              if willDecryptIpfs:
                # Async cache task will deliver [image: <path>] to the
                # agent when it completes. Skip the synchronous
                # placeholder delivery so the agent sees one clean
                # message instead of "User sent a file... (pending)"
                # followed by the real image.
                deliverToAgent = false
              if not willDecryptIpfs:
                var autoReply = ""
                autoReply.add("I received your message, but I can't open images/files on NKN/NMobile yet for security reasons. ")
                autoReply.add("Please describe it in text, or resend via Feishu.\n\n")
                autoReply.add("我收到了你发来的图片/文件，但出于安全原因我暂时无法在 NKN/NMobile 上打开。请用文字描述，或通过飞书重新发送。")
                autoReply.add("\n\nDetected type: " & contentType & (if fileType.len > 0: " (" & fileType & ")" else: ""))
                if contentType == "ipfs" and ipfsHashPrefix.len > 0:
                  autoReply.add("\nCID(prefix): " & ipfsHashPrefix & "… (len=" & $ipfsHashLen & ")")
                let replyPayload = c.genPayload("textExtension", autoReply, genUUID())
                var replyOptions = newJObject()
                replyOptions["push"] = %true
                replyOptions["isMarkdown"] = %true
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
                let isImageHint = (fileType == "image")
                asyncCheck((proc() {.async.} =
                  infoCF("nmobile", "IPFS cache task start", {"src": src2, "cidPrefix": prefix2}.toTable)
                  let dl = await c.tryDownloadIpfsToCache(src2, cid2, fn2, opts, clientAddr2)
                  if dl[0] and dl[1].len > 0:
                    # Detect actual image content by magic bytes in case
                    # the sender mis-labels or the fileType hint is
                    # missing. Rename with the right extension so the
                    # agent can open the cache file directly.
                    var finalPath = dl[1]
                    var isImage = isImageHint
                    var ext = ""
                    try:
                      let f = open(finalPath, fmRead)
                      var head: array[8, byte]
                      let n = f.readBytes(head, 0, 8)
                      f.close()
                      if n >= 3 and head[0] == 0xFF and head[1] == 0xD8 and head[2] == 0xFF:
                        ext = ".jpg"; isImage = true
                      elif n >= 8 and head[0] == 0x89 and head[1] == 0x50 and
                           head[2] == 0x4E and head[3] == 0x47:
                        ext = ".png"; isImage = true
                      elif n >= 6 and head[0] == 0x47 and head[1] == 0x49 and
                           head[2] == 0x46:
                        ext = ".gif"; isImage = true
                      elif n >= 12 and head[0] == 0x52 and head[1] == 0x49 and
                           head[2] == 0x46 and head[3] == 0x46:
                        ext = ".webp"; isImage = true
                    except CatchableError: discard
                    if ext.len > 0 and not finalPath.endsWith(ext):
                      let newPath = finalPath & ext
                      try:
                        moveFile(finalPath, newPath)
                        finalPath = newPath
                      except CatchableError: discard
                    var md2 = initTable[string, string]()
                    md2["content_type"] = if isImage: "ipfs_image" else: "ipfs_cached"
                    md2["ipfs_cid"] = cid2
                    md2["ipfs_cache_path"] = finalPath
                    md2["ipfs_cache_bytes"] = $dl[2]
                    let msg2 =
                      if isImage:
                        # Same marker shape as the inline-image path so
                        # the agent's image-aware tools can pick it up.
                        "[image: " & finalPath & "]"
                      else:
                        var s = "IPFS file cached. "
                        if fn2.len > 0: s.add("Filename: " & fn2 & ". ")
                        s.add("CID(prefix): " & prefix2 & "… (len=" & $len2 & "). ")
                        s.add("Path: " & finalPath & ". Bytes: " & $dl[2] & ".")
                        s
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

            of "contact", "contact:profile":
              # Dual-purpose message type: `requestType` present → peer
              # is asking for OUR card; `responseType` present → peer
              # is sending THEIR card. See nmobile's
              # getContactProfileRequest / getContactProfileResponse*
              # at lib/schema/message.dart:1228-1267.
              let requestType = j.getOrDefault("requestType").getStr()
              if requestType.len > 0:
                # Header request is a drift check (peer only wants our
                # version); full request means "send me the card".
                let includeContent = requestType == "full"
                c.sendContactProfile(clientAddr, src,
                                      responseType = requestType,
                                      includeContent = includeContent)
              else:
                # This is a response (or a legacy `contact` push) —
                # treat as the peer advertising their own card.
                if j.hasKey("version") and j["version"].kind == JString:
                  let pv = j["version"].getStr()
                  if pv.len > 0 and info.profileVersion != pv:
                    info.profileVersion = pv
                    infoChanged = true
                if j.hasKey("content") and j["content"].kind == JObject:
                  let content = j["content"]
                  var newName = ""
                  if content.hasKey("name") and content["name"].kind == JString:
                    newName = content["name"].getStr()
                  elif content.hasKey("first_name") and content["first_name"].kind == JString:
                    newName = content["first_name"].getStr()
                    if content.hasKey("last_name") and content["last_name"].kind == JString:
                      let ln = content["last_name"].getStr()
                      if ln.len > 0: newName.add(" " & ln)
                  newName = newName.strip()
                  if newName.len > 0 and info.displayName != newName:
                    info.displayName = newName
                    infoChanged = true
                    infoCF("nmobile", "Captured peer displayName",
                           {"src": src, "displayName": newName,
                            "contentType": contentType}.toTable)
                debugCF("nmobile", "Contact response absorbed",
                        {"src": src, "type": contentType,
                         "id": j.safeGetStr("id")}.toTable)

            of "device:request":
              # Peer asking for our device info so their state machine
              # can finish the new-contact handshake. We're a gateway
              # (no FCM handle), so respond with an empty deviceToken —
              # nmobile's chat_in.dart:555-599 accepts the handshake and
              # just skips the push-to-us path, which is what we want.
              # See nmobile's `getDeviceInfoResponse` at
              # lib/schema/message.dart:1297-1308.
              let reqId = j.safeGetStr("id")
              let diPayload = c.genPayload("device:info", "", genUUID())
              diPayload["appName"] = %"nimclaw"
              diPayload["appVersion"] = %versionString()
              diPayload["platform"] = %"gateway"
              diPayload["platformVersion"] = %(hostOS & " " & hostCPU)
              diPayload["deviceToken"] = %""  # headless — no FCM target
              var diOpts = newJObject()
              diOpts["push"] = %true
              if info.profileVersion.len > 0:
                diOpts["profileVersion"] = %info.profileVersion
              diPayload["options"] = diOpts
              let ttl = if c.enableOfflineQueue: c.messageTTLHours * 3600 else: 0
              discard c.bridge.sendNKNMessage(clientAddr, src, $diPayload,
                                              maxHoldingSeconds = ttl, noReply = true)
              debugCF("nmobile", "Replied to device:request with headless device:info",
                      {"src": src, "reqId": reqId}.toTable)

            of "event:contactOptions":
              # Peer's contact settings changed event — nothing for us
              # to act on. Absorb silently.
              debugCF("nmobile", "Protocol handshake absorbed",
                      {"src": src, "type": contentType,
                       "id": j.safeGetStr("id")}.toTable)

            of "msgStatus":
              # Delivery-state resync. After a peer reconnects following
              # a gap, it sends `requestType: "ask"` with a list of
              # past msgIds asking which we received. If we ignore it
              # (or fall to the unhandled branch), the LLM gets woken up
              # to apologise about non-text content. Worse, replying
              # `0` (unknown) for everything would prompt nmobile to
              # resend days-old chat content as if fresh. So reply
              # `310` (read) for every msgId — declares the
              # conversation in-sync and stops the resync request loop.
              # See nmobile chat_in.dart:980-1015 for the protocol.
              let content =
                if j.hasKey("content") and j["content"].kind == JObject: j["content"]
                else: newJObject()
              let requestType = content{"requestType"}.getStr()
              if requestType == "ask":
                let messageIds = content{"messageIds"}
                var statusList = newJArray()
                if messageIds != nil and messageIds.kind == JArray:
                  for m in messageIds:
                    if m.kind == JString:
                      statusList.add(%(m.getStr() & ":310"))
                if statusList.len > 0:
                  let replyPayload = c.genPayload("msgStatus", "", genUUID())
                  replyPayload.delete("content")
                  replyPayload["content"] = %*{
                    "requestType": "reply",
                    "messageIds": statusList
                  }
                  var opts = newJObject()
                  opts["push"] = %true
                  if info.profileVersion.len > 0:
                    opts["profileVersion"] = %info.profileVersion
                  replyPayload["options"] = opts
                  let ttl = if c.enableOfflineQueue: c.messageTTLHours * 3600 else: 0
                  discard c.bridge.sendNKNMessage(clientAddr, src, $replyPayload,
                                                   maxHoldingSeconds = ttl,
                                                   noReply = true)
                  infoCF("nmobile", "msgStatus ack: declared all-read",
                         {"src": src, "count": $statusList.len}.toTable)
              else:
                debugCF("nmobile", "msgStatus reply absorbed",
                        {"src": src, "requestType": requestType,
                         "id": j.safeGetStr("id")}.toTable)

            of "nknOnePiece":
              # Reed-Solomon-chunked media (most commonly a photo).
              # Accumulate pieces keyed by `id`; deliver the reassembled
              # file once all data pieces arrive. Don't send the decline
              # autoreply and don't wake the agent for individual pieces
              # — the sender already committed to the upload and seeing
              # "I can't open this" mid-stream caused nmobile to abort
              # the send before later pieces arrived.
              c.sweepPieceBuffers()
              let mid = j.safeGetStr("id")
              let opts = if j.hasKey("options") and j["options"].kind == JObject: j["options"]
                         else: newJObject()
              let pieceIndex = opts{"piece_index"}.getInt(-1)
              let pieceTotal = opts{"piece_total"}.getInt(0)
              let pieceParity = opts{"piece_parity"}.getInt(0)
              let pieceBytesLen = opts{"piece_bytes_length"}.getInt(0)
              if mid.len == 0 or pieceIndex < 0 or pieceTotal <= 0:
                errorCF("nmobile", "nknOnePiece: missing required options",
                        {"src": src, "msgId": mid,
                         "options": $opts}.toTable)
              else:
                # Decode this piece's base64 content into the buffer.
                var content = ""
                if j.hasKey("content") and j["content"].kind == JString:
                  try: content = base64.decode(j["content"].getStr())
                  except CatchableError as err:
                    errorCF("nmobile", "nknOnePiece: piece base64 decode failed",
                            {"src": src, "msgId": mid,
                             "index": $pieceIndex, "error": err.msg}.toTable)
                if not c.pieceBuffers.hasKey(mid):
                  c.pieceBuffers[mid] = PieceBuffer(
                    startedAt: epochTime(),
                    total: pieceTotal,
                    parity: pieceParity,
                    bytesLength: pieceBytesLen,
                    parentType: opts{"piece_parent_type"}.getStr(),
                    fileExt: opts{"fileExt"}.getStr(),
                    agentName: agentName,
                    clientAddr: clientAddr,
                    src: src,
                    pieces: initTable[int, string]()
                  )
                # Use withValue-style pattern: fetch the buffer, modify,
                # write back — Nim's `Table` values are copies on access.
                var buf = c.pieceBuffers[mid]
                buf.pieces[pieceIndex] = content
                c.pieceBuffers[mid] = buf
                infoCF("nmobile", "nknOnePiece received",
                       {"src": src, "msgId": mid, "agent": agentName,
                        "index": $pieceIndex, "total": $pieceTotal,
                        "parity": $pieceParity,
                        "have": $(buf.pieces.len)}.toTable)
                # Ack the piece so the sender doesn't retransmit.
                let ackPayload = c.genPayload("receipt", "", genUUID(),
                                              replyToId = mid)
                var ackOpts = newJObject()
                ackOpts["push"] = %true
                if info.profileVersion.len > 0:
                  ackOpts["profileVersion"] = %info.profileVersion
                ackPayload["options"] = ackOpts
                let ttl = if c.enableOfflineQueue: c.messageTTLHours * 3600 else: 0
                discard c.bridge.sendNKNMessage(clientAddr, src, $ackPayload,
                                                 maxHoldingSeconds = ttl,
                                                 noReply = true)
                discard c.tryAssemblePiece(mid)

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
              let fromLabel =
                if info.displayName.len > 0: info.displayName & " (" & src & ")"
                else: src
              infoC("nmobile", "Received " & contentType & " from " & fromLabel & " for " & destLabel)
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
  # nMobile has no real typing-indicator API; a 💭 emoji "pre-message"
  # just clutters the thread, so drop Typing kinds outright.
  if msg.kind == Typing: return

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
  debugCF("nmobile", "Outbound routing",
          {"sender_agent": msg.sender_agent, "senderAddr": senderAddr,
           "dest": msg.chat_id}.toTable)

  let data = msg.content
  infoC("nmobile", "Sending message to " & dest)

  let msgId = genUUID()
  let info = c.peers.getOrDefault(dest)

  # textExtension is the proper wire type for text carrying options
  # (markdown flag, profileVersion, push, burn-after-read). nmobile and
  # dchat both auto-promote plain `text` → `textExtension` whenever
  # options are attached (chat-service.ts:549-553, message.dart:145),
  # so matching them here means phones render markdown and show proper
  # delivery indicators without the old `<!-- &status=approve -->`
  # HTML-comment trick.
  let options = newJObject()
  options["push"] = %true
  options["isMarkdown"] = %true
  if info.profileVersion.len > 0:
    options["profileVersion"] = %info.profileVersion

  let payload = c.genPayload("textExtension", data, msgId, options = options)
  
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
