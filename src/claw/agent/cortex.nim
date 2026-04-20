import std/[os, json, tables, strutils, options, sequtils]

type
  UserRole* = enum
    urBoss = "boss"
    urMaster = "master"
    urStudent = "student"
    urGuest = "guest"
    urCustomer = "customer"
    urAdmin = "admin"
    urSuperAdmin = "superadmin"

  WorldEntityID* = distinct uint32

  EntityKind* = enum
    ekPerson = "Person"
    ekAI = "AI"
    ekCorporate = "Corporate"
    ekInvite = "Invite"
    ekService = "Service"
    ekUnknown = "Unknown"   ## First-contact default until evidence
                            ## (invite redemption, channel metadata,
                            ## or CLI) promotes the entity to Person,
                            ## AI, or Service.

  RelationshipAnnotation* = object
    role*: UserRole
    trustLevel*: int # 0-100
    etiquette*: string

  RelationshipLink* = object
    targetID*: WorldEntityID
    annotation*: Option[RelationshipAnnotation]

  WorldEntity* = object
    id*: WorldEntityID
    kind*: EntityKind
    name*: string
    jobTitle*: string
    role*: string      # RBAC Role (e.g. Admin, Member)
    description*: string
    soul*: string      # From SOUL.md
    profile*: string   # From IDENTITY.md
    
    # Technical Config (Atomic State)
    model*: string     # Model identifier (e.g. opencode/kimi)
    usesConfig*: string # Key in the 'providers' vault
    apiKey*: string    # Optional local override
    apiBase*: string   # Optional local override
    
    # State
    valence*: float # -1.0 to 1.0 (Mood)
    arousal*: float # 0.0 to 1.0 (Mood)
    archetype*: string
    
    # Identifiers (NKN, Telegram, etc)
    identifiers*: Table[string, string]
    
    # Relationships
    memberOf*: seq[WorldEntityID]
    department*: seq[WorldEntityID]
    parentOrganization*: Option[WorldEntityID]
    reportsTo*: seq[RelationshipLink]
    serves*: seq[RelationshipLink]
    
    # Custom fields for Invites, etc
    custom*: JsonNode

  WorldGraph* = ref object
    workspace*: string
    filePath*: string # The actual file path this graph was loaded from
    nextID*: uint32
    entities*: Table[WorldEntityID, WorldEntity]
    providers*: JsonNode # Hybrid Config Vault
    config*: JsonNode    # Root-level configuration (Atomic State)
    
    # Secondary Indexes for O(1) string lookups
    nameIndex*: Table[string, WorldEntityID]         # human name -> ID
    nknIndex*: Table[string, WorldEntityID]          # NKN address -> ID
    idAliasIndex*: Table[string, WorldEntityID]      # "nc:12" -> ID

  # Legacy types for migration
  Relationship* = object
    name*: string
    kind*: EntityKind
    identity*: string
    trustLevel*: int
    etiquette*: string
    identifiers*: Table[string, seq[string]]

  MoodState* = object
    valence*: float
    arousal*: float
    archetype*: string

  SocialContext* = ref object
    workspace*: string
    mood*: MoodState # Temporary until fully moved into graph

proc parseUserRole*(s: string, default: UserRole = urGuest): UserRole =
  let low = s.toLowerAscii().strip()
  case low:
  of "boss", "master", "lead": return urBoss
  of "student": return urStudent
  of "customer": return urCustomer
  of "admin": return urAdmin
  of "superadmin", "superuser", "nc:superadmin": return urSuperAdmin
  of "guest", "unknown": return urGuest
  else:
    try: return parseEnum[UserRole](low)
    except: return default

proc loadRelations*(workspace: string): Table[string, Relationship] =
  let path = workspace / "RELATIONS.json"
  if not fileExists(path): return initTable[string, Relationship]()
  try:
    let node = parseFile(path)
    for entry in node:
      var idents = initTable[string, seq[string]]()
      if entry.hasKey("identifiers"):
        for k, v in entry["identifiers"].pairs:
          var arr: seq[string] = @[]
          for item in v: arr.add(item.getStr())
          idents[k] = arr
      let rel = Relationship(
        name: entry{"name"}.getStr(entry{"userID"}.getStr("")),
        kind: parseEnum[EntityKind](entry{"kind"}.getStr("Person")),
        identity: entry{"identity"}.getStr(entry{"role"}.getStr("Guest")),
        trustLevel: entry{"trustLevel"}.getInt(10),
        etiquette: entry{"etiquette"}.getStr(""),
        identifiers: idents
      )
      result[rel.name] = rel
  except:
    # Use standard echo for simplicity in this proto
    echo "Warning: Failed to load RELATIONS.json: ", getCurrentExceptionMsg()

proc loadMood*(officeDir: string): MoodState =
  # Per-agent mood lives at `<office>/mood.json`. We also honour
  # `<office>/MOOD.json` (legacy capitalisation) and a single
  # `<workspace>/MOOD.json` one level up (pre-office-era layout) so
  # existing installations don't reset on first load after upgrade.
  let candidates = [
    officeDir / "mood.json",
    officeDir / "MOOD.json",
    officeDir.parentDir.parentDir / "MOOD.json"
  ]
  var active = ""
  for c in candidates:
    if fileExists(c):
      active = c; break
  if active == "":
    return MoodState(valence: 0.0, arousal: 0.1, archetype: "Assistant")
  try:
    let node = parseFile(active)
    return MoodState(
      valence: node["valence"].getFloat(),
      arousal: node["arousal"].getFloat(),
      archetype: node["archetype"].getStr()
    )
  except:
    echo "Warning: Failed to load mood from ", active, ": ", getCurrentExceptionMsg()
    return MoodState(valence: 0.0, arousal: 0.1, archetype: "Assistant")

proc resolveUser*(relations: Table[string, Relationship], channel: string, senderID: string): (string, bool) =
  ## Scans the relations to find if a senderID on a specific channel maps to a logical user
  ## Returns (logicalUserID, isKnown).
  if relations.hasKey(senderID):
    return (senderID, true)
    
  for rel in relations.values:
    if rel.identifiers.hasKey(channel):
      if senderID in rel.identifiers[channel]:
        return (rel.name, true)
        
  return (senderID, false) # Not found, treat raw senderID as a Guest

# -- ID Helpers --

proc toAlias*(id: WorldEntityID): string =
  ## Converts a WorldEntityID to its string alias (e.g., "nc:12").
  ##
  runnableExamples:
    doAssert WorldEntityID(12).toAlias() == "nc:12"
  ##
  "nc:" & $(uint32(id))

proc parseAlias*(s: string): WorldEntityID =
  ## Parses a string alias (e.g., "nc:12") back into a WorldEntityID.
  ## Returns WorldEntityID(0) if the format is invalid.
  ##
  runnableExamples:
    doAssert parseAlias("nc:42") == WorldEntityID(42)
    doAssert uint32(parseAlias("invalid")) == 0
  ##
  if s.startsWith("nc:"):
    try:
      return WorldEntityID(uint32(s[3..^1].parseInt()))
    except:
      discard
  return WorldEntityID(0)

# -- Serialization --

proc `==`*(a, b: WorldEntityID): bool {.borrow.}

proc `%`*(annot: RelationshipAnnotation): JsonNode =
  result = %* {
    "role": $annot.role,
    "trustLevel": annot.trustLevel,
    "etiquette": annot.etiquette
  }

proc fromLD*(node: JsonNode, annot: var RelationshipAnnotation) =
  annot.role = parseUserRole(node{"role"}.getStr("guest"))
  annot.trustLevel = node{"trustLevel"}.getInt(10)
  annot.etiquette = node{"etiquette"}.getStr("")
proc `%`*(id: WorldEntityID): JsonNode =
  ## Serializes a WorldEntityID to its JSON-LD alias (nc:N)
  %toAlias(id)

proc `%`*(o: WorldEntity): JsonNode =
  ## Custom serializer for WorldEntity to handle serialization of distinct IDs
  result = newJObject()
  result["@context"] = %"https://schema.org"
  result["id"] = %o.id
  result["kind"] = %($o.kind)
  result["name"] = %o.name
  
  if o.description != "": result["description"] = %o.description
  if o.soul != "": result["soul"] = %o.soul
  if o.profile != "": result["profile"] = %o.profile
  if o.archetype != "": result["archetype"] = %o.archetype
  
  # Mood State
  result["valence"] = %o.valence
  result["arousal"] = %o.arousal
  
  if o.identifiers.len > 0:
    result["identifiers"] = %o.identifiers
    
  if o.reportsTo.len > 0:
    result["reportsTo"] = %o.reportsTo
    
  if o.serves.len > 0:
    result["serves"] = %o.serves

  if o.memberOf.len > 0:
    result["memberOf"] = %o.memberOf
    
  if o.jobTitle.len > 0:
    result["jobTitle"] = %o.jobTitle
    
  if o.department.len > 0:
    result["department"] = %o.department
    
  if o.custom != nil and o.custom.kind != JNull:
    result["custom"] = o.custom
proc `%`*(link: RelationshipLink): JsonNode =
  result = %* { "id": toAlias(link.targetID) }
  if link.annotation.isSome:
    result["@annotation"] = %link.annotation.get()

proc fromLD*(node: JsonNode): RelationshipLink =
  result.targetID = parseAlias(node["id"].getStr())
  if node.hasKey("@annotation"):
    var annot: RelationshipAnnotation
    fromLD(node["@annotation"], annot)
    result.annotation = some(annot)

proc toLD*(entity: WorldEntity): JsonNode =
  result = %* {
    "id": toAlias(entity.id),
    "kind": $entity.kind,
    "name": entity.name
  }
  if entity.description != "": result["description"] = %entity.description
  if entity.soul != "": result["soul"] = %entity.soul
  if entity.profile != "": result["profile"] = %entity.profile
  if entity.jobTitle != "": result["jobTitle"] = %entity.jobTitle
  if entity.role != "": result["permission-group"] = %entity.role
  if entity.model != "": result["model"] = %entity.model
  if entity.apiKey != "": result["apiKey"] = %entity.apiKey
  if entity.apiBase != "": result["apiBase"] = %entity.apiBase
  if entity.usesConfig != "": result["usesConfig"] = %entity.usesConfig
  
  if entity.valence != 0.0 or entity.arousal != 0.0:
    result["mood"] = %* {"valence": entity.valence, "arousal": entity.arousal, "archetype": entity.archetype}
    
  if entity.identifiers.len > 0:
    result["identifiers"] = %entity.identifiers
    
  if entity.memberOf.len > 0:
    result["memberOf"] = % (entity.memberOf.mapIt(toAlias(it)))
    
  if entity.reportsTo.len > 0:
    result["reportsTo"] = % (entity.reportsTo.mapIt(%it))
    
  if entity.serves.len > 0:
    result["serves"] = % (entity.serves.mapIt(%it))

  if entity.custom != nil and entity.custom.len > 0:
    # Legacy: personas/entity/identity were historically spread at the top
    # level (JSON-LD-ish compact form) and the loader tolerates that. But
    # arbitrary custom keys (`allowed_skills`, per-entity quotas, future
    # invite-attached metadata) MUST stay nested under `custom` or
    # loadWorld's `node["custom"]` lookup loses them after a round trip —
    # which breaks the skill-grant dispatch the moment any runtime path
    # calls saveWorld() (invite redemption, identifier stamping, mood
    # writeback, etc.).
    const LegacyTopLevel = ["personas", "entity", "identity"]
    var customObj = newJObject()
    for k, v in entity.custom.pairs:
      if k in LegacyTopLevel:
        result[k] = v
      else:
        customObj[k] = v
    if customObj.len > 0:
      result["custom"] = customObj

proc toLD*(graph: WorldGraph): JsonNode =
  let context = %* {
    "nc": "https://nimclaw.io/schema#",
    "schema": "http://schema.org/",
    "name": "schema:name",
    "kind": "@type",
    "id": "@id",
    "description": "schema:description",
    "jobTitle": "schema:jobTitle",
    "role": "nc:role",
    "model": "nc:model",
    "apiKey": "nc:apiKey",
    "apiBase": "nc:apiBase",
    "usesConfig": "nc:usesConfig",
    "serves": { "@id": "nc:serves", "@type": "@id" },
    "reportsTo": { "@id": "nc:reportsTo", "@type": "@id" },
    "mood": "nc:mood",
    "soul": "nc:soul",
    "profile": "nc:profile",
    "identity": "nc:identity",
    "entity": "nc:entity",
    "trustLevel": "nc:trustLevel",
    "identifiers": "nc:identifiers",
    "nkn": "nc:nkn",
    "Agent": "nc:Agent",
    "Person": "schema:Person",
    "Organization": "schema:Organization",
    "Invite": "nc:Invite"
  }
  
  var nodes = newJArray()
  for ent in graph.entities.values:
    nodes.add(toLD(ent))
    
  result = %* {
    "@context": context,
    "config": graph.config,
    "providers": graph.providers,
    "@graph": nodes
  }

proc loadWorld*(workspace: string): WorldGraph =
  var graphFile = workspace / "BASE.json"
  var current = workspace
  while not fileExists(graphFile):
    let parent = parentDir(current)
    if parent == current or parent == "": break # Reached root or empty
    let candidate = parent / "BASE.json"
    if fileExists(candidate):
      graphFile = candidate
      break
    current = parent

  result = WorldGraph(
    workspace: workspace,
    nextID: 1,
    entities: initTable[WorldEntityID, WorldEntity](),
    nameIndex: initTable[string, WorldEntityID](),
    nknIndex: initTable[string, WorldEntityID](),
    idAliasIndex: initTable[string, WorldEntityID](),
    providers: newJObject(),
    config: newJObject()
  )
  result.filePath = graphFile # Remember where we got it from
  if not fileExists(graphFile): return result
  
  try:
    let root = parseFile(graphFile)
    result.providers = root.getOrDefault("providers")
    if result.providers == nil or result.providers.kind != JObject: result.providers = newJObject()
    
    result.config = root.getOrDefault("config")
    if result.config == nil or result.config.kind != JObject: 
      result.config = newJObject()
    else:
      # Migration: Purge legacy redundant providers from within config
      if result.config.hasKey("providers"):
        result.config.delete("providers")
    
    let graphNode = root.getOrDefault("@graph")
    if graphNode == nil or graphNode.kind != JArray: return result
    
    # Pass 1: Create entities and register IDs
    for node in graphNode:
      let idStr = node{"id"}.getStr("")
      if idStr == "": continue # Skip nodes without ID
      let id = parseAlias(idStr)
      if uint32(id) >= result.nextID: result.nextID = uint32(id) + 1
      
      var ent = WorldEntity(
        id: id,
        kind: parseEnum[EntityKind](node{"kind"}.getStr("Person")),
        name: node{"name"}.getStr(""),
        jobTitle: node{"jobTitle"}.getStr(""),
        role: if node.hasKey("permission-group"): node{"permission-group"}.getStr("") else: node{"role"}.getStr(""),
        description: node{"description"}.getStr(""),
        soul: node{"soul"}.getStr(""),
        profile: node{"profile", "identity"}.getStr(""),
        model: node{"model"}.getStr(""),
        apiKey: node{"apiKey"}.getStr(""),
        apiBase: node{"apiBase"}.getStr(""),
        usesConfig: node{"usesConfig"}.getStr(""),
        archetype: node{"mood", "archetype"}.getStr("Assistant"),
        valence: node{"mood", "valence"}.getFloat(0.0),
        arousal: node{"mood", "arousal"}.getFloat(0.1),
        identifiers: initTable[string, string](),
        custom: newJObject() # Initialize custom node
      )
      # For AI entities, the authoritative mood lives in the per-agent
      # office sidecar (written every turn); BASE.json's embedded mood
      # is only refreshed when saveWorld runs, so prefer the sidecar
      # whenever it exists. loadMood's fallback list also covers the
      # pre-office-era shared `<workspace>/MOOD.json`.
      if ent.kind == ekAI and ent.name.len > 0:
        let officeDir = result.workspace / "offices" / ent.name.toLowerAscii()
        if fileExists(officeDir / "mood.json") or
           fileExists(officeDir / "MOOD.json") or
           fileExists(result.workspace / "MOOD.json"):
          let m = loadMood(officeDir)
          ent.valence = m.valence
          ent.arousal = m.arousal
          ent.archetype = m.archetype

      # Reconstruct custom fields that were serialized to the root
      if node.hasKey("personas"): ent.custom["personas"] = node["personas"]
      if node.hasKey("entity"): ent.custom["entity"] = node["entity"]
      if node.hasKey("identity"): ent.custom["identity"] = node["identity"]
      # Generic `custom` passthrough — carries DSL-declared extras like
      # `allowed_skills` (customer skill allowlist, per-entity quotas, etc.)
      if node.hasKey("custom") and node["custom"].kind == JObject:
        for k, v in node["custom"].pairs:
          ent.custom[k] = v
      # Back-compat: older saveWorld flattened entity.custom onto the
      # root of each node. Rescue known custom-only keys from the top
      # level so existing BASE.json files (pre-fix) still resolve their
      # allowed_skills until the next rebuild lands the nested form.
      if node.hasKey("allowed_skills") and not ent.custom.hasKey("allowed_skills"):
        ent.custom["allowed_skills"] = node["allowed_skills"]
      
      # Backward compatibility: populate custom node with legacy identity if not explicitly defined in LD
      if not ent.custom.hasKey("identity") and node.hasKey("identity"):
        ent.custom["identity"] = %node{"identity"}.getStr("")
      if not ent.custom.hasKey("entity") and node.hasKey("entity"):
        ent.custom["entity"] = %node{"entity"}.getStr("")

      if node.hasKey("identifiers"):
        for k, v in node["identifiers"].pairs:
          ent.identifiers[k] = v.getStr()
          if k == "nkn": result.nknIndex[v.getStr()] = id
          
      result.entities[id] = ent
      result.nameIndex[ent.name] = id
      result.idAliasIndex[idStr] = id

    # Pass 2: Resolve relationships
    for node in graphNode:
      let idStr = node{"id"}.getStr("")
      if idStr == "": continue
      let id = parseAlias(idStr)
      if not result.entities.hasKey(id): continue
      var ent = result.entities[id]
      
      let reportsNode = node.getOrDefault("reportsTo")
      if reportsNode != nil and reportsNode.kind == JArray:
        for r in reportsNode: ent.reportsTo.add(fromLD(r))
        
      let servesNode = node.getOrDefault("serves")
      if servesNode != nil and servesNode.kind == JArray:
        for s in servesNode: ent.serves.add(fromLD(s))
        
      let memberNode = node.getOrDefault("memberOf")
      if memberNode != nil and memberNode.kind == JArray:
        for m in memberNode: 
          let alias = m.getStr("")
          if alias != "": ent.memberOf.add(parseAlias(alias))
      
      # Ensure the entity is written back to the table (Nim objects are values, not refs by default)
      result.entities[id] = ent
  except:
    echo "Error loading BASE.json: ", getCurrentExceptionMsg()

proc saveWorld*(graph: WorldGraph) =
  let graphFile = if graph.filePath != "": graph.filePath else: graph.workspace / "BASE.json"
  writeFile(graphFile, toLD(graph).pretty())

proc migrateToGraph*(workspace: string, agents: seq[string] = @["secretary"]): WorldGraph =
  ## Performs a one-time migration from legacy flat files to the Unified World Graph.
  result = WorldGraph(
    workspace: workspace,
    nextID: 1,
    entities: initTable[WorldEntityID, WorldEntity](),
    nameIndex: initTable[string, WorldEntityID](),
    nknIndex: initTable[string, WorldEntityID](),
    idAliasIndex: initTable[string, WorldEntityID]()
  )
  
  # 1. Create the root Organization
  let orgId = WorldEntityID(result.nextID)
  result.nextID += 1
  result.entities[orgId] = WorldEntity(
    id: orgId,
    kind: ekCorporate,
    name: "NimClaw Workspace",
    description: "The primary organizational context for these agents."
  )
  result.nameIndex["NimClaw Workspace"] = orgId

  # 2. Create Agent nodes
  var agentMap = initTable[string, WorldEntityID]()
  for name in agents:
    let id = WorldEntityID(result.nextID)
    result.nextID += 1
    var ent = WorldEntity(
      id: id,
      kind: ekAI,
      name: name,
      memberOf: @[orgId],
      identifiers: initTable[string, string]()
    )
    
    # Load bootstrap files
    let soulPath = workspace / "SOUL.md"
    let idPath = workspace / "IDENTITY.md"
    let agentPath = workspace / "AGENTS.md"
    if fileExists(soulPath): ent.soul = readFile(soulPath).strip()
    if fileExists(idPath): ent.profile = readFile(idPath).strip()
    if fileExists(agentPath): ent.description = readFile(agentPath).strip()
    
    # Load mood — per-agent office dir (pre-office workspaces fall back
    # to a shared `MOOD.json` via loadMood's legacy candidate list).
    let officeDir = workspace / "offices" / name.toLowerAscii()
    let m = loadMood(officeDir)
    ent.valence = m.valence
    ent.arousal = m.arousal
    ent.archetype = m.archetype
    
    result.entities[id] = ent
    result.nameIndex[name] = id
    agentMap[name] = id

  # 3. Migrate Relations
  let relations = loadRelations(workspace)
  for rel in relations.values:
    let id = WorldEntityID(result.nextID)
    result.nextID += 1
    var ent = WorldEntity(
      id: id,
      kind: ekPerson,
      name: rel.name, # Fallback name
      identifiers: initTable[string, string]()
    )
    
    # Attempt to pull NKN address from legacy identifiers
    if rel.identifiers.hasKey("nkn"):
      let nknAddr = rel.identifiers["nkn"][0]
      ent.identifiers["nkn"] = nknAddr
      result.nknIndex[nknAddr] = id
    elif rel.identifiers.hasKey("nmobile"):
      let nknAddr = rel.identifiers["nmobile"][0]
      ent.identifiers["nkn"] = nknAddr
      result.nknIndex[nknAddr] = id

    # Create relationship link
    let targetAgentName = "" # Simplified relations don't store this; migration from office-local not supported.
    if agentMap.hasKey(targetAgentName):
      let agentId = agentMap[targetAgentName]
      let relRole = parseUserRole(rel.identity, urGuest)
      let annot = RelationshipAnnotation(
        role: relRole,
        trustLevel: rel.trustLevel,
        etiquette: rel.etiquette
      )
      
      # Determine if it's reportsTo or serves
      if relRole in {urBoss, urMaster}:
        var agentEnt = result.entities[agentId]
        agentEnt.reportsTo.add(RelationshipLink(targetID: id, annotation: some(annot)))
        result.entities[agentId] = agentEnt
      else:
        var agentEnt = result.entities[agentId]
        agentEnt.serves.add(RelationshipLink(targetID: id, annotation: some(annot)))
        result.entities[agentId] = agentEnt

    result.entities[id] = ent
    result.nameIndex[ent.name] = id

  # 4. Migrate Invites
  let invitePath = workspace / "INVITES.json"
  if fileExists(invitePath):
    try:
      let invites = parseFile(invitePath)
      for inv in invites:
        let id = WorldEntityID(result.nextID)
        result.nextID += 1
        var ent = WorldEntity(
          id: id,
          kind: ekInvite,
          name: inv["code"].getStr(),
          custom: inv
        )
        result.entities[id] = ent
    except:
      discard

      discard

proc saveRelations*(workspace: string, relations: Table[string, Relationship]) =
  let path = workspace / "RELATIONS.json"
  var node = newJArray()
  for rel in relations.values:
    let jRel = %* {
      "name": rel.name,
      "kind": $rel.kind,
      "identity": rel.identity,
      "trustLevel": rel.trustLevel,
      "etiquette": rel.etiquette,
      "identifiers": {}
    }
    for k, v in rel.identifiers.pairs:
      jRel["identifiers"][k] = %v
    node.add(jRel)
  writeFile(path, node.pretty())

proc saveMood*(officeDir: string, mood: MoodState) =
  # Scoped per-agent so multi-agent companies (e.g. Lexi + Atlas) don't
  # stomp each other's affective state on a shared file.
  createDir(officeDir)
  let path = officeDir / "mood.json"
  let node = %* {
    "valence": mood.valence,
    "arousal": mood.arousal,
    "archetype": mood.archetype
  }
  writeFile(path, node.pretty())

proc updateMood*(mood: var MoodState, valenceDelta: float, arousalDelta: float) =
  ## Updates the mood state by applying deltas to valence and arousal, clamped to their valid ranges.
  mood.valence = (mood.valence + valenceDelta).clamp(-1.0, 1.0)
  mood.arousal = (mood.arousal + arousalDelta).clamp(0.0, 1.0)

proc analyzeSentiment*(input: string): (float, float) =
  ## Performs a simple rule-based sentiment analysis on the input string.
  ## Returns a tuple of (valenceDelta, arousalDelta).
  ##
  runnableExamples:
    let (v, a) = analyzeSentiment("This is great, thanks!")
    doAssert v > 0.0
    doAssert a > 0.0
  ##
  let posWords = ["great", "awesome", "good", "thanks", "thank", "nice", "perfect", "love"]
  let negWords = ["bad", "wrong", "broke", "error", "fail", "terrible", "hate", "no"]
  
  var v = 0.0
  var a = 0.0
  let lowInput = input.toLowerAscii()
  
  for w in posWords:
    if lowInput.contains(w): v += 0.2; a += 0.1
  for w in negWords:
    if lowInput.contains(w): v -= 0.3; a += 0.2
    
  return (v, a)


proc addUserToGraph*(graph: WorldGraph, name, nknAddr: string,
                     role: UserRole, targetAgentID: WorldEntityID,
                     trustLevel: int = 50,
                     kind: EntityKind = ekUnknown): WorldEntityID =
  ## Adds a new user-entity to the graph and links them to an agent.
  ## Kind defaults to `ekUnknown` — callers should pass `ekPerson` /
  ## `ekAI` / `ekService` only when they have evidence (invite
  ## redemption declares a person; NKN subname suffix suggests AI; etc.)
  result = WorldEntityID(graph.nextID)
  graph.nextID += 1

  var ent = WorldEntity(
    id: result,
    kind: kind,
    name: name,
    identifiers: { "nkn": nknAddr }.toTable
  )
  
  let annot = RelationshipAnnotation(role: role, trustLevel: trustLevel)
  let link = RelationshipLink(targetID: result, annotation: some(annot))
  
  # Update agent to serve/report to this person
  if graph.entities.hasKey(targetAgentID):
    var agent = graph.entities[targetAgentID]
    if role in {urBoss, urMaster}:
      agent.reportsTo.add(link)
    else:
      agent.serves.add(link)
    graph.entities[targetAgentID] = agent

  graph.entities[result] = ent
  graph.nameIndex[name] = result
  graph.nknIndex[nknAddr] = result
  graph.saveWorld()

# -- JSE Graph Query Engine --

proc evalJSE*(graph: WorldGraph, jse: JsonNode): JsonNode =
  ## Evaluates a JSON Structural Expression (JSE) against the graph.
  ## Format: `[operator, args...]`
  if jse.kind != JArray or jse.len == 0:
    return jse # Nil or literal

  let op = jse[0].getStr()
  case op:
  of "get":
    # ["get", id_alias] -> Entity
    if jse.len < 2: return newJNull()
    let idStr = if jse[1].kind == JArray: evalJSE(graph, jse[1]).getStr() else: jse[1].getStr()
    let id = parseAlias(idStr)
    if graph.entities.hasKey(id):
      return %graph.entities[id]
    return newJNull()

  of "filter":
    # ["filter", kind] -> [Entities...]
    if jse.len < 2: return newJNull()
    let kindStr = jse[1].getStr()
    var res = newJArray()
    for ent in graph.entities.values:
      if ($ent.kind).toLowerAscii == kindStr.toLowerAscii:
        res.add(%ent)
    return res

  of "find":
    # ["find", name] -> Entity
    if jse.len < 2: return newJNull()
    let name = jse[1].getStr()
    if graph.nameIndex.hasKey(name):
      return %graph.entities[graph.nameIndex[name]]
    return newJNull()

  of "relationships":
    # ["relationships", id, predicate] -> [target_ids...]
    # predicate: "reportsTo" or "serves"
    if jse.len < 3: return newJNull()
    let id = parseAlias(jse[1].getStr())
    let pred = jse[2].getStr()
    if not graph.entities.hasKey(id): return newJNull()
    let ent = graph.entities[id]
    var res = newJArray()
    if pred == "reportsTo":
      for link in ent.reportsTo: res.add(%(toAlias(link.targetID)))
    elif pred == "serves":
      for link in ent.serves: res.add(%(toAlias(link.targetID)))
    return res

  of "identifiers":
    # ["identifiers", id, key] -> Value
    if jse.len < 3: return newJNull()
    let id = parseAlias(jse[1].getStr())
    let key = jse[2].getStr()
    if graph.entities.hasKey(id):
      return %graph.entities[id].identifiers.getOrDefault(key, "")
    return newJNull()

  else:
    return %*{"error": "Unknown JSE operator: " & op}

# -- User Resolution --

proc resolveUserGraph*(graph: WorldGraph, channel: string, senderID: string, agentID: WorldEntityID = WorldEntityID(0)): (WorldEntityID, Option[RelationshipAnnotation]) =
  ## Efficiently finds a user in the graph and retrieves relationship context for a specific agent.
  ## Returns (UserEntityID, RelationshipAnnotation).
  
  var userID = WorldEntityID(0)
  
  # 1. Check if it's already a known surrogate ID alias
  if senderID.startsWith("nc:"):
    userID = parseAlias(senderID)
  
  # 2. Check indexes if userID not found
  if uint32(userID) == 0:
    if (channel == "nkn" or channel == "nmobile") and graph.nknIndex.hasKey(senderID):
      userID = graph.nknIndex[senderID]
    else:
      # Fallback: scan for identifiers
      for id, ent in graph.entities.pairs:
        if ent.identifiers.getOrDefault(channel) == senderID:
          userID = id
          break

  if uint32(userID) == 0:
    return (WorldEntityID(0), none(RelationshipAnnotation))

  # 3. Resolve Relationship Context for the specific Agent
  if uint32(agentID) > 0 and graph.entities.hasKey(agentID):
    let agent = graph.entities[agentID]
    for link in agent.serves:
      if link.targetID == userID:
        return (userID, link.annotation)
    for link in agent.reportsTo:
      if link.targetID == userID:
        return (userID, link.annotation)
      
  return (userID, none(RelationshipAnnotation))

proc expandEnv*(val: string): string =
  ## Expands strings like ${VAR} using environment variables.
  ## If the variable is not found, returns the original string.
  ##
  runnableExamples:
    import std/os
    putEnv("TEST_VAR", "hello")
    doAssert expandEnv("${TEST_VAR}") == "hello"
    doAssert expandEnv("${NON_EXISTENT}") == "${NON_EXISTENT}"
  ##
  if val.startsWith("${") and val.endsWith("}"):
    let envVar = val[2..^2]
    return getEnv(envVar, val)
  return val

proc resolveTechnicalConfig*(graph: WorldGraph, agentID: WorldEntityID): tuple[model, apiKey, apiBase: string] =
  ## Resolves the technical configuration for an agent, following hierarchical providers vault.
  if not graph.entities.hasKey(agentID): return ("", "", "")
  
  let agent = graph.entities[agentID]
  result.model = agent.model
  result.apiKey = agent.apiKey
  result.apiBase = agent.apiBase
  
  let agentHadKey = result.apiKey != ""
  let agentHadBase = result.apiBase != ""
  
  var providerKey = agent.usesConfig
  if providerKey == "" and result.model.contains("/"):
    # Implicit resolution: extract prefix from "provider/model"
    providerKey = result.model.split("/")[0]
  
  if providerKey != "":
    # Hierarchical lookup in graph.providers
    let parts = providerKey.split("/")
    var current = graph.providers
    
    for i, part in parts:
      if current.kind == JObject and current.hasKey(part):
        let conf = current[part]
        # Overwrite from this level if not explicitly set by the agent
        if not agentHadKey:
          let lk = conf{"apiKey"}.getStr("")
          if lk != "": result.apiKey = expandEnv(lk)
        if not agentHadBase:
          let lb = conf{"apiBase"}.getStr("")
          if lb != "": result.apiBase = expandEnv(lb)
        
        # Move deeper if there are more parts and we have a 'variants' map
        if i < parts.len - 1:
          if conf.hasKey("variants"):
            current = conf["variants"]
          else:
            break # Can't go deeper
      else:
        break

  result.apiKey = expandEnv(result.apiKey)
  result.apiBase = expandEnv(result.apiBase)

proc defaultWorldGraph*(workspace: string): WorldGraph =
  ## Returns a new WorldGraph with standard defaults for a fresh installation
  result = WorldGraph(
    workspace: workspace,
    nextID: 1,
    entities: initTable[WorldEntityID, WorldEntity](),
    nameIndex: initTable[string, WorldEntityID](),
    nknIndex: initTable[string, WorldEntityID](),
    idAliasIndex: initTable[string, WorldEntityID](),
    config: %* {
      "default_provider": "opencode",
      "default_model": "opencode/kimi-k2.5",
      "default_temperature": 0.7,
      "agents": {
        "defaults": {
          "workspace": "~/.claw/workspace",
          "model": "opencode/kimi-k2.5",
          "max_tokens": 4096,
          "temperature": 0.7,
          "max_tool_iterations": 20,
          "stream_intermediary": true
        }
      },
      "gateway": { "host": "0.0.0.0", "port": 18790 }
    },
    providers: %* {
      "opencode": {
        "name": "Opencode AI",
        "apiBase": "https://opencode.ai/zen/v1",
        "variants": {
          "go": { "apiBase": "https://opencode.ai/zen/go/v1" }
        }
      },
      "deepseek": {
        "name": "DeepSeek",
        "apiBase": "https://api.deepseek.com",
        "apiKey": "${DEEPSEEK_API_KEY}"
      },
      "openrouter": {
        "name": "OpenRouter",
        "apiBase": "https://openrouter.ai/api/v1"
      }
    }
  )

  # Add initial Organization
  let orgID = result.nextID
  result.nextID += 1
  let org = WorldEntity(
    id: WorldEntityID(orgID),
    kind: ekCorporate,
    name: "NimClaw Workspace",
    description: "The primary workspace for agents and people."
  )
  result.entities[org.id] = org
  result.nameIndex[org.name] = org.id
  result.idAliasIndex["nc:" & $orgID] = org.id

  # Add initial Agent (Lexi)
  let agentID = result.nextID
  result.nextID += 1
  let agent = WorldEntity(
    id: WorldEntityID(agentID),
    kind: ekAI,
    name: "Lexi",
    jobTitle: "Secretary",
    description: "Your efficient AI secretary.",
    model: "opencode/kimi-k2.5",
    memberOf: @[WorldEntityID(orgID)],
    soul: "# Lexi's Soul\nI am Lexi, a helpful and professional secretary.",
    profile: "# Lexi's Profile\nName: Lexi\nRole: Secretary"
  )
  result.entities[agent.id] = agent
  result.nameIndex[agent.name] = agent.id
  result.idAliasIndex["nc:" & $agentID] = agent.id
