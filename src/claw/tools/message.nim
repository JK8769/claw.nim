import std/[asyncdispatch, json, tables, strutils]
import types, ../agent/cortex

type
  InjectSessionCallback* = proc (sessionKey, role, content: string): Future[void] {.async.}

  MessageTool* = ref object of ContextualTool
    sendCallback*: types.SendCallback
    injectCallback*: InjectSessionCallback

proc newMessageTool*(): MessageTool =
  MessageTool()

method name*(t: MessageTool): string = "message"
method description*(t: MessageTool): string = "Send a message to user on a chat channel. Use this when you want to communicate something."
method parameters*(t: MessageTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "content": {
        "type": "string",
        "description": "The message content to send"
      },
      "to": {
        "type": "string",
        "description": "Optional: Logical identity (nc:N) or Name of the recipient from the graph"
      },
      "channel": {
        "type": "string",
        "description": "Optional: target channel (telegram, whatsapp, feishu, etc.)"
      },
      "chat_id": {
        "type": "string",
        "description": "Optional: target chat/user ID"
      }
    },
    "required": %["content"]
  }.toTable

proc setSendCallback*(t: MessageTool, callback: types.SendCallback) =
  t.sendCallback = callback

proc setInjectCallback*(t: MessageTool, callback: InjectSessionCallback) =
  t.injectCallback = callback

method execute*(t: MessageTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.sessionKey.startsWith("system:"):
    return "Error: Communication tools are disabled for background tasks. Please keep your response internal."

  if not args.hasKey("content"): return "Error: content is required"
  let content = args["content"].getStr()

  var channel = if args.hasKey("channel"): args["channel"].getStr() else: ""
  var chatID = if args.hasKey("chat_id"): args["chat_id"].getStr() else: ""
  let toAlias = if args.hasKey("to"): args["to"].getStr() else: ""

  # Logical Resolution Logic
  if toAlias != "" and t.graph != nil:
    var targetID = parseAlias(toAlias)
    
    if uint32(targetID) == 0:
      # Name Lookup with Priority & Collision Handling
      var agentID = parseAlias(t.recipientID) # t.recipientID is the agent's ID when calling from loop
      var candidates: seq[WorldEntityID] = @[]
      
      # Step 1: Priority check for reportsTo (Boss)
      if uint32(agentID) > 0 and t.graph.entities.hasKey(agentID):
        let agent = t.graph.entities[agentID]
        for link in agent.reportsTo:
          if t.graph.entities.hasKey(link.targetID):
            if t.graph.entities[link.targetID].name == toAlias:
              targetID = link.targetID
              break
      
      # Step 2: Global lookup if no priority match
      if uint32(targetID) == 0:
        for id, ent in t.graph.entities.pairs:
          if ent.name == toAlias:
            candidates.add(id)
        
        if candidates.len == 1:
          targetID = candidates[0]
        elif candidates.len > 1:
          var errorMsg = "Error: Multiple people named '" & toAlias & "' found. Please specify by ID:\n"
          for id in candidates:
            let ent = t.graph.entities[id]
            errorMsg &= "- " & toAlias(id) & " (" & ent.name & ", " & ent.jobTitle & ")\n"
          return errorMsg

    if uint32(targetID) > 0 and t.graph.entities.hasKey(targetID):
      let ent = t.graph.entities[targetID]
      
      # Permission Check: Only allowed to notify reportsTo or specifically allowed contacts
      var isAllowed = false
      var agentID = parseAlias(t.agentID)
      if agentID in t.graph.entities:
        let agent = t.graph.entities[agentID]
        echo "[DEBUG] MessageTool: agentId=", agent.id.toAlias(), " reportsTo.len=", agent.reportsTo.len
        for link in agent.reportsTo:
          echo "[DEBUG]   - reportsTo target: ", link.targetID.toAlias()
          if link.targetID == targetID: isAllowed = true; break
      else:
        echo "[DEBUG] MessageTool: agent not found in graph for agentID=", t.agentID
      
      # Step 3: Allow if the target is the current sender (Self-notification/Direct response)
      if not isAllowed and t.senderID != "":
        # Check both the nc:id alias AND the raw identifiers for the target
        if t.senderID.startsWith("nc:"):
          let currentSenderID = parseAlias(t.senderID)
          if uint32(currentSenderID) > 0 and currentSenderID == targetID:
            isAllowed = true
        else:
          # If senderID is raw (e.g. feishu open_id), check if it's one of the target's identifiers
          for key, val in ent.identifiers.pairs:
            if val.toLowerAscii == t.senderID.toLowerAscii:
              isAllowed = true
              break
      
      if not isAllowed and ent.kind == ekAI:
        isAllowed = true

      if not isAllowed:
        return "Error: You are not authorized to send outbound notifications to " & toAlias & " (" & toAlias(targetID) & "). You can only notify your primary lead(s)."

      # Logic: Search for specific channel identifiers in priority order
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
      
      if channel == "":
        return "Error: No communication identifiers found for entity " & toAlias

  if channel == "": channel = t.channel
  if chatID == "": chatID = t.chatID

  if channel == "" or chatID == "":
    return "Error: No target channel/chat specified"

  if t.sendCallback == nil:
    return "Error: Message sending not configured"

  try:
    let useReply = (channel == t.channel and chatID == t.chatID)
    let repID = if useReply: t.replyToMessageID else: ""
    let apID = if useReply: t.appID else: ""
    await t.sendCallback(channel, chatID, content, t.agentName, repID, apID)
    if t.injectCallback != nil:
      let targetSessionKey = channel & ":" & chatID & ":" & chatID
      if targetSessionKey != t.sessionKey:
        await t.injectCallback(targetSessionKey, "assistant", content)
    return "Message sent successfully to " & toAlias & " via " & channel
  except Exception as e:
    return "Error sending message: " & e.msg
