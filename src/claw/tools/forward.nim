import std/[asyncdispatch, json, tables, strutils, os, times, unicode]
import types
import ../agent/cortex

proc clampInt(x, lo, hi: int): int =
  if x < lo: return lo
  if x > hi: return hi
  return x

type
  ForwardLink = object
    channel: string
    chatID: string
    senderID: string
    updatedAt: float

  ForwardState = object
    lastExternalByViaInternal: Table[string, ForwardLink] # "via|internal" -> external
    forwardTimesByKey: Table[string, seq[float]]          # "via|outsider|direction" -> timestamps (epoch seconds)

  ForwardTool* = ref object of ContextualTool
    officeDir: string
    sendCallback*: types.SendCallback

proc newForwardTool*(officeDir: string): ForwardTool =
  ForwardTool(officeDir: officeDir)

proc setSendCallback*(t: ForwardTool, callback: types.SendCallback) =
  t.sendCallback = callback

proc statePath(t: ForwardTool): string =
  t.officeDir / "forward.json"

proc loadState(t: ForwardTool): ForwardState =
  result.lastExternalByViaInternal = initTable[string, ForwardLink]()
  result.forwardTimesByKey = initTable[string, seq[float]]()
  let path = t.statePath()
  if not fileExists(path): return
  try:
    let j = parseFile(path)
    if j.kind != JObject: return
    if j.hasKey("lastExternalByViaInternal") and j["lastExternalByViaInternal"].kind == JObject:
      for k, v in j["lastExternalByViaInternal"].pairs:
        if v.kind == JObject:
          var link: ForwardLink
          link.channel = v.getOrDefault("channel").getStr()
          link.chatID = v.getOrDefault("chat_id").getStr()
          link.senderID = v.getOrDefault("sender_id").getStr()
          link.updatedAt = v.getOrDefault("updated_at").getFloat(0.0)
          result.lastExternalByViaInternal[k] = link
    if j.hasKey("forwardTimesByKey") and j["forwardTimesByKey"].kind == JObject:
      for k, v in j["forwardTimesByKey"].pairs:
        if v.kind == JArray:
          var ts: seq[float] = @[]
          for it in v.items:
            ts.add(it.getFloat(0.0))
          result.forwardTimesByKey[k] = ts
  except:
    discard

proc saveState(t: ForwardTool, st: ForwardState) =
  let path = t.statePath()
  try:
    let dir = parentDir(path)
    createDir(dir)
    var j = newJObject()
    var m = newJObject()
    for k, link in st.lastExternalByViaInternal.pairs:
      m[k] = %*{
        "channel": link.channel,
        "chat_id": link.chatID,
        "sender_id": link.senderID,
        "updated_at": link.updatedAt
      }
    j["lastExternalByViaInternal"] = m
    var ft = newJObject()
    for k, ts in st.forwardTimesByKey.pairs:
      var arr = newJArray()
      for x in ts:
        arr.add(%x)
      ft[k] = arr
    j["forwardTimesByKey"] = ft
    writeFile(path, $j)
  except:
    discard

proc resolveInternalTarget(t: ForwardTool, idOrName: string): (string, string, string) =
  if t.graph == nil: return ("", "", "Error: No graph loaded")
  var targetID = parseAlias(idOrName)
  if uint32(targetID) == 0:
    if t.graph.nameIndex.hasKey(idOrName):
      targetID = t.graph.nameIndex[idOrName]
  if uint32(targetID) == 0: return ("", "", "Error: Unknown internal id: " & idOrName)
  if not t.graph.entities.hasKey(targetID): return ("", "", "Error: Unknown internal id: " & idOrName)
  let ent = t.graph.entities[targetID]
  var channel = ""
  var chatID = ""
  if ent.identifiers.hasKey("feishu"):
    channel = "feishu"
    chatID = ent.identifiers["feishu"]
  elif ent.identifiers.hasKey("nmobile"):
    channel = "nmobile"
    chatID = ent.identifiers["nmobile"]
  elif ent.identifiers.hasKey("nkn"):
    channel = "nkn"
    chatID = ent.identifiers["nkn"]
  elif ent.identifiers.hasKey("email"):
    channel = "email"
    chatID = ent.identifiers["email"]
  elif ent.identifiers.len > 0:
    for k, v in ent.identifiers.pairs:
      channel = k
      chatID = v
      break
  if channel == "" or chatID == "":
    return ("", "", "Error: No communication identifiers found for internal id: " & idOrName)
  return (channel, chatID, "")

proc isInternalAgent(t: ForwardTool, viaID: WorldEntityID): bool =
  if t.graph == nil: return false
  if uint32(viaID) == 0: return false
  if not t.graph.entities.hasKey(viaID): return false
  return t.graph.entities[viaID].kind == ekAI

proc resolveInternalID(t: ForwardTool, idOrName: string): WorldEntityID =
  if t.graph == nil: return WorldEntityID(0)
  let direct = parseAlias(idOrName)
  if uint32(direct) != 0 and t.graph.entities.hasKey(direct):
    return direct
  if t.graph.nameIndex.hasKey(idOrName):
    return t.graph.nameIndex[idOrName]
  let low = idOrName.toLowerAscii()
  for k, v in t.graph.nameIndex.pairs:
    if k.toLowerAscii() == low:
      return v
  return WorldEntityID(0)

proc isReportsToTarget(t: ForwardTool, viaID, targetID: WorldEntityID): bool =
  if t.graph == nil: return false
  if not t.graph.entities.hasKey(viaID): return false
  let ent = t.graph.entities[viaID]
  for rel in ent.reportsTo:
    if rel.targetID == targetID:
      return true
  return false

proc relationsPath(t: ForwardTool): string =
  t.officeDir / "RELATIONS.json"

proc trustLevelFor(t: ForwardTool, channel, outsiderID: string): int =
  let path = t.relationsPath()
  if not fileExists(path): return 10
  try:
    let j = parseFile(path)
    if j.kind != JArray: return 10
    for it in j.items:
      if it.kind != JObject: continue
      let trust = it.getOrDefault("trustLevel").getInt(10)
      if it.hasKey("identifiers") and it["identifiers"].kind == JObject:
        let ids = it["identifiers"]
        if ids.hasKey(channel) and ids[channel].kind == JArray:
          for v in ids[channel].items:
            if v.getStr().toLowerAscii == outsiderID.toLowerAscii:
              return trust
      let name = it.getOrDefault("name").getStr()
      if name.toLowerAscii == outsiderID.toLowerAscii:
        return trust
  except:
    discard
  return 10

proc rateParams(trust: int): (int, int) =
  let perMin = clampInt(1 + (trust div 20), 1, 10)
  let perHour = perMin * 20
  return (perMin, perHour)

proc checkAndRecordRateLimit(t: ForwardTool, st: var ForwardState, key: string, trust: int): (bool, string) =
  let nowT = epochTime()
  let (maxPerMin, maxPerHour) = rateParams(trust)
  var ts = st.forwardTimesByKey.getOrDefault(key, @[])
  var kept: seq[float] = @[]
  for x in ts:
    if nowT - x <= 3600.0:
      kept.add(x)
  ts = kept
  var cMin = 0
  var cHour = ts.len
  var oldestMin = nowT
  for x in ts:
    if nowT - x <= 60.0:
      cMin.inc
      if x < oldestMin: oldestMin = x
  if cMin >= maxPerMin:
    let retryIn = int(max(0.0, (oldestMin + 60.0) - nowT))
    return (false, "Error: forward rate-limited (trust=" & $trust & ", " & $cMin & "/" & $maxPerMin & " per minute). Retry in " & $retryIn & "s.")
  if cHour >= maxPerHour:
    let oldestHour = ts[0]
    let retryIn = int(max(0.0, (oldestHour + 3600.0) - nowT))
    return (false, "Error: forward rate-limited (trust=" & $trust & ", " & $cHour & "/" & $maxPerHour & " per hour). Retry in " & $retryIn & "s.")
  ts.add(nowT)
  st.forwardTimesByKey[key] = ts
  return (true, "ok")

method name*(t: ForwardTool): string = "forward"

method description*(t: ForwardTool): string =
  "Forward a message between an internal user and an external user through an internal agent. This tool maintains a small routing memory so an agent can reply back to the last guest."

method parameters*(t: ForwardTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "content": {
        "type": "string",
        "description": "The message content to forward"
      },
      "note": {
        "type": "string",
        "description": "Optional: a short triage note from the internal agent (intent, risk, recommendation). Included only when forwarding to internal."
      },
      "from": {
        "type": "string",
        "description": "Sender ID. Use nc:N for internal entities."
      },
      "to": {
        "type": "string",
        "description": "Recipient ID. Use nc:N for internal entities, or 'guest' to target the last guest for that internal user."
      },
      "via": {
        "type": "string",
        "description": "Internal agent ID (nc:N) that is performing the forward. If omitted, defaults to the current agent."
      }
    },
    "required": %["from", "content"]
  }.toTable

method execute*(t: ForwardTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sessionKey.startsWith("system:"):
    return "Error: forward is disabled for background tasks."

  if t.sendCallback == nil:
    return "Error: Forward callback not configured"

  var content = args.getOrDefault("content").getStr()
  var note = args.getOrDefault("note").getStr()
  var fromID = args.getOrDefault("from").getStr()
  var toID = args.getOrDefault("to").getStr()
  var viaID = args.getOrDefault("via").getStr()

  if fromID == "" and t.logicalUserID != "":
    fromID = t.logicalUserID

  if viaID == "" and t.agentID != "":
    viaID = t.agentID

  if fromID == "":
    return "Error: from is required"
  if viaID == "":
    return "Error: via is required"

  var st = t.loadState()

  var viaEntID = t.resolveInternalID(viaID)
  if uint32(viaEntID) == 0 and t.agentID != "":
    viaID = t.agentID
    viaEntID = t.resolveInternalID(viaID)
  if uint32(viaEntID) == 0:
    return "Error: via must be a valid internal agent id"

  if t.agentID != "":
    let ctxVia = t.resolveInternalID(t.agentID)
    if uint32(ctxVia) != 0 and viaEntID != ctxVia:
      return "Error: via must match the current internal agent id"

  if not t.isInternalAgent(viaEntID):
    return "Error: via must be a valid internal agent id"

  let viaKey = toAlias(viaEntID)

  var fromEntID = t.resolveInternalID(fromID)
  if uint32(fromEntID) == 0 and t.logicalUserID != "" and t.logicalUserID.startsWith("nc:"):
    fromID = t.logicalUserID
    fromEntID = t.resolveInternalID(fromID)
  let fromIsInternal = uint32(fromEntID) != 0
  if toID == "" and fromIsInternal:
    toID = "guest"

  let toLower = toID.toLowerAscii()
  if fromIsInternal and (toLower == "him" or toLower == "her" or toLower == "them" or toLower == "the_guest" or toLower == "the guest" or toLower == "guest" or toID == "他" or toID == "她" or toID == "他们" or toID == "客人"):
    toID = "guest"
  let toIsGuestAlias = toID.toLowerAscii() in ["guest", "last_guest", "last"]
  let toEntID = if toIsGuestAlias: WorldEntityID(0) else: t.resolveInternalID(toID)

  let toIsInternal = (not toIsGuestAlias) and uint32(toEntID) != 0
  let toIsOutsider = (not toIsInternal)
  let fromIsOutsider = (not fromIsInternal)

  if content == "" and note != "" and fromIsInternal and toID.toLowerAscii in ["guest", "last_guest", "last"]:
    content = note
    note = ""

  if content == "" or toID == "":
    return "Error: content and to are required"

  if toIsInternal:
    if not t.isReportsToTarget(viaEntID, toEntID):
      return "Error: to must be in via's reportsTo"
    if not fromIsOutsider:
      return "Error: when forwarding to via's reportsTo, from must be an outsider id"

    let trust = t.trustLevelFor(t.channel, fromID)
    let rateKey = viaKey & "|" & fromID & "|out_to_reportsTo"
    let (ok, msg) = t.checkAndRecordRateLimit(st, rateKey, trust)
    if not ok: return msg

    let (channel, chatID, err) = t.resolveInternalTarget(toID)
    if err != "": return err
    var guestName = ""
    let path = t.relationsPath()
    if fileExists(path):
      try:
        let j = parseFile(path)
        if j.kind == JArray:
          block found:
            for it in j.items:
              if it.kind != JObject: continue
              if it.hasKey("identifiers") and it["identifiers"].kind == JObject:
                let ids = it["identifiers"]
                if ids.hasKey(t.channel) and ids[t.channel].kind == JArray:
                  for v in ids[t.channel].items:
                    if v.getStr().toLowerAscii == fromID.toLowerAscii:
                      guestName = it.getOrDefault("name").getStr()
                      break found
      except:
        discard

    let viaName =
      if t.graph != nil and t.graph.entities.hasKey(viaEntID): t.graph.entities[viaEntID].name
      else: "Agent"
    let toName =
      if t.graph != nil and t.graph.entities.hasKey(toEntID): t.graph.entities[toEntID].name
      else: "Lead"

    let trustLabel =
      if trust >= 80: "High"
      elif trust >= 40: "Medium"
      else: "Low"

    var forwarded = ""
    forwarded.add("Forwarded by " & viaName & " to " & toName & "\n")
    forwarded.add("From: " & (if guestName != "": guestName else: "Guest") & " on " & t.channel & "\n")
    forwarded.add("Guest ID: " & fromID & "\n")
    forwarded.add("Trust: " & $trust & "/100 (" & trustLabel & ")\n")
    if note != "":
      forwarded.add("\nLexi summary:\n" & note.strip() & "\n")
    forwarded.add("\nMessage:\n" & content.strip() & "\n")
    forwarded.add("\nNext step:\nJust reply in plain language, e.g. \"tell him ...\" / \"reply him ...\" / \"跟他说...\" / \"回复他...\". " & viaName & " will route it back to this guest.")

    await t.sendCallback(channel, chatID, forwarded, t.agentName, "", "")

    if t.channel != "" and t.chatID != "":
      let key = viaKey & "|" & toAlias(toEntID) & "|" & t.channel
      let legacyKey = viaKey & "|" & toAlias(toEntID)
      st.lastExternalByViaInternal[key] = ForwardLink(
        channel: t.channel,
        chatID: t.chatID,
        senderID: fromID,
        updatedAt: epochTime()
      )
      st.lastExternalByViaInternal[legacyKey] = st.lastExternalByViaInternal[key]
      t.saveState(st)

    return "Forwarded successfully (trust=" & $trust & ", guest=" & fromID & ")"

  if toIsOutsider:
    if not fromIsInternal:
      return "Error: when forwarding to outsider, from must be an internal id"
    if not t.isReportsToTarget(viaEntID, fromEntID):
      return "Error: from must be in via's reportsTo"

    let key = viaKey & "|" & toAlias(fromEntID) & "|" & t.channel
    let legacyKey = viaKey & "|" & toAlias(fromEntID)
    var link: ForwardLink
    var found = false
    if st.lastExternalByViaInternal.hasKey(key):
      link = st.lastExternalByViaInternal[key]
      found = true
    elif st.lastExternalByViaInternal.hasKey(legacyKey):
      link = st.lastExternalByViaInternal[legacyKey]
      found = true
    else:
      var bestT = 0.0
      for k, v in st.lastExternalByViaInternal.pairs:
        if not k.startsWith(viaKey & "|"): continue
        if v.channel != "" and v.channel == t.channel and v.updatedAt > bestT:
          bestT = v.updatedAt
          link = v
          found = true
      if not found:
        for k, v in st.lastExternalByViaInternal.pairs:
          if not k.startsWith(viaKey & "|"): continue
          if v.updatedAt > bestT:
            bestT = v.updatedAt
            link = v
            found = true
      if not found:
        return "Error: No known guest route for this agent yet"
    if link.channel == "" or link.chatID == "":
      return "Error: Stored guest route is incomplete"

    if not toIsGuestAlias:
      if toID.toLowerAscii != link.senderID.toLowerAscii and toID.toLowerAscii != link.chatID.toLowerAscii:
        return "Error: to must match the last known guest for this (via, from) pair"

    let trust = t.trustLevelFor(link.channel, link.senderID)
    let rateKey = viaKey & "|" & link.senderID & "|reportsTo_to_out"
    let (ok, msg) = t.checkAndRecordRateLimit(st, rateKey, trust)
    if not ok: return msg

    let viaName =
      if t.graph != nil and t.graph.entities.hasKey(viaEntID): t.graph.entities[viaEntID].name
      else: "Agent"
    let fromName =
      if t.graph != nil and t.graph.entities.hasKey(fromEntID): t.graph.entities[fromEntID].name
      else: "Boss"

    var hasCjk = false
    for ch in content.runes:
      if ch.int >= 0x4E00 and ch.int <= 0x9FFF:
        hasCjk = true
        break

    let outboundText =
      if hasCjk:
        fromName & "让我回复你说: " & content.strip()
      else:
        fromName & " asked me (" & viaName & ") to reply: " & content.strip()

    var destID = link.chatID
    if link.channel == "feishu" and link.senderID.startsWith("ou_"):
      destID = link.senderID

    await t.sendCallback(link.channel, destID, outboundText, t.agentName, "", "")
    return "Forwarded successfully (trust=" & $trust & ")"

  return "Error: invalid forward routing"
