import std/[os, json, tables, options]
import nimclaw/[config, agent/cortex, agent/context]

proc main() =
  let nimclawDir = "/Users/owaf/Work/Agents/nimclaw/.nimclaw"
  let workspace = nimclawDir / "workspace"
  
  # 1. Mimic gateway loading
  echo "--- Step 1: Loading World Graph ---"
  let graph = loadWorld(workspace)
  echo "Graph file: ", graph.filePath
  echo "Entities count: ", graph.entities.len
  
  if graph.entities.hasKey(WorldEntityID(3)):
    let jerry = graph.entities[WorldEntityID(3)]
    echo "Jerry (nc:3) found!"
    echo "  Name: ", jerry.name
    echo "  Role: ", jerry.role
    echo "  Identifiers: ", jerry.identifiers
    echo "  ReportsTo len: ", jerry.reportsTo.len
  else:
    echo "ERROR: Jerry (nc:3) NOT found in graph!"

  if graph.nameIndex.hasKey("Lexi"):
    let lexiID = graph.nameIndex["Lexi"]
    let lexi = graph.entities[lexiID]
    echo "Lexi found (ID: ", uint32(lexiID), ")"
    echo "  ReportsTo len: ", lexi.reportsTo.len
    for link in lexi.reportsTo:
      echo "    Reports to: ", uint32(link.targetID)
  else:
    echo "ERROR: Lexi NOT found in graph!"

  # 2. Test resolution
  echo "\n--- Step 2: Testing Resolution ---"
  let senderID = "ou_b785f570411fcf8398abf8a5c75d0670" # Jerry's OpenID
  let channel = "feishu"
  let agentID = WorldEntityID(2) # Lexi
  
  let (resID, annot) = graph.resolveUserGraph(channel, senderID, agentID)
  echo "Resolved ID: ", uint32(resID)
  if annot.isSome:
    echo "Relationship found: Role=", $annot.get().role, " Trust=", annot.get().trustLevel
  else:
    echo "No specific relationship found."

  # 3. Test Social Section
  echo "\n--- Step 3: Testing Social Section ---"
  let cb = newContextBuilder(workspace, nimclawDir)
  let sb = cb.buildSocialSection(senderID, "nc:2", "feishu")
  echo "Social Section Sample:"
  echo sb

main()
