import std/[os, json, tables, options]
import nimclaw/[config, agent/cortex, agent/context]

proc main() =
  let nimclawDir = "/Users/owaf/Work/Agents/nimclaw/.nimclaw"
  let workspace = nimclawDir / "workspace"
  let officeDir = workspace / "offices" / "lexi"
  
  echo "--- Testing loadWorld for lexi office ---"
  echo "Office Dir: ", officeDir
  let graph = loadWorld(officeDir)
  echo "Found BASE.json at: ", graph.filePath
  echo "Entities in graph: ", graph.entities.len
  
  if graph.entities.hasKey(WorldEntityID(3)):
    let jerry = graph.entities[WorldEntityID(3)]
    echo "Jerry (nc:3) found!"
    echo "  Identifiers: ", jerry.identifiers
  else:
    echo "ERROR: Jerry (nc:3) NOT found in office graph!"

  echo "\n--- Testing resolveUserGraph ---"
  let senderID = "ou_b785f570411fcf8398abf8a5c75d0670"
  let (resID, annot) = graph.resolveUserGraph("feishu", senderID, WorldEntityID(2))
  echo "Resolved ID: ", uint32(resID)
  if annot.isSome:
    echo "Relationship confirmed!"
  else:
    echo "STILL NO RELATIONSHIP!"

main()
