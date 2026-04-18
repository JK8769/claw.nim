import std/[unittest, json, strutils, options, os, tables]
import ../agent/cortex
import jsony

suite "JSON-LD-star Relationships":
  var workspace = getTempDir() / "nimclaw_test_ld_star"

  setup:
    if dirExists(workspace): removeDir(workspace)
    createDir(workspace)

  teardown:
    if dirExists(workspace): removeDir(workspace)

  test "Serialization and Deserialization of Annotations":
    var graph = WorldGraph(
      workspace: workspace,
      entities: initTable[WorldEntityID, WorldEntity](),
      nameIndex: initTable[string, WorldEntityID](),
      nknIndex: initTable[string, WorldEntityID](),
      nextID: 1,
      providers: newJObject(),
      config: newJObject()
    )
    
    # Create Agent
    let agentId = WorldEntityID(graph.nextID)
    graph.nextID += 1
    graph.entities[agentId] = WorldEntity(
      id: agentId,
      kind: ekAgent,
      name: "TestAgent"
    )
    graph.nameIndex["TestAgent"] = agentId

    # Create User
    let userId = WorldEntityID(graph.nextID)
    graph.nextID += 1
    graph.entities[userId] = WorldEntity(
      id: userId,
      kind: ekPerson,
      name: "TestUser",
      identifiers: { "nkn": "nkn123" }.toTable
    )
    graph.nameIndex["TestUser"] = userId
    graph.nknIndex["nkn123"] = userId

    # Link User to Agent with Annotation
    let annot = RelationshipAnnotation(
      role: urBoss,
      trustLevel: 95,
      etiquette: "Always be formal"
    )
    
    var agent = graph.entities[agentId]
    agent.reportsTo.add(RelationshipLink(
      targetID: userId,
      annotation: some(annot)
    ))
    graph.entities[agentId] = agent

    # Serialize
    let ld = toLD(graph)
    let jsonStr = ld.pretty()
    echo "--- GENERATED JSON ---"
    echo jsonStr
    echo "----------------------"

    check jsonStr.contains("\"@annotation\"")
    check jsonStr.contains("\"trustLevel\": 95")
    check jsonStr.contains("\"role\": \"boss\"")
    check jsonStr.contains("\"etiquette\": \"Always be formal\"")

    # Save to disk
    writeFile(workspace / "BASE.json", jsonStr)

    # Load from disk
    let loadedGraph = loadWorld(workspace)
    
    # Verify Deserialization
    let loadedAgent = loadedGraph.entities[agentId]
    check loadedAgent.reportsTo.len == 1
    let link = loadedAgent.reportsTo[0]
    check link.targetID == userId
    check link.annotation.isSome
    let loadedAnnot = link.annotation.get()
    check loadedAnnot.role == urBoss
    check loadedAnnot.trustLevel == 95
    check loadedAnnot.etiquette == "Always be formal"

  test "User Resolution accurately fetches Context":
    var graph = WorldGraph(
      workspace: workspace,
      entities: initTable[WorldEntityID, WorldEntity](),
      nameIndex: initTable[string, WorldEntityID](),
      nknIndex: initTable[string, WorldEntityID](),
      nextID: 1,
      providers: newJObject(),
      config: newJObject()
    )
    
    let agentId = WorldEntityID(graph.nextID)
    graph.nextID += 1
    graph.entities[agentId] = WorldEntity(id: agentId, kind: ekAgent, name: "TestAgent")
    graph.nameIndex["TestAgent"] = agentId

    let guestId = WorldEntityID(graph.nextID)
    graph.nextID += 1
    graph.entities[guestId] = WorldEntity(id: guestId, kind: ekPerson, name: "GuestUser", identifiers: { "nkn": "guest123" }.toTable)
    graph.nknIndex["guest123"] = guestId
    
    # Agent serves guest (trust: 30)
    var agent = graph.entities[agentId]
    agent.serves.add(RelationshipLink(targetID: guestId, annotation: some(RelationshipAnnotation(role: urGuest, trustLevel: 30))))
    graph.entities[agentId] = agent

    # Resolve
    let (resId, annotOpt) = graph.resolveUserGraph("nkn", "guest123", agentId)
    check resId == guestId
    check annotOpt.isSome
    let a = annotOpt.get()
    check a.trustLevel == 30
    check a.role == urGuest
