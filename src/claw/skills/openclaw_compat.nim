import std/[json]
import skill_types

type
  OpenClawManifest* = object
    id*: string
    kind*: string
    description*: string
    configSchema*: JsonNode

proc parseOpenClawManifest*(content: string): SkillMetadata =
  ## Parses an openclaw.plugin.json file into SkillMetadata.
  let j = parseJson(content)
  result = SkillMetadata(
    name: j.getOrDefault("id").getStr(),
    description: j.getOrDefault("description").getStr()
  )
  
  if result.description == "" and j.hasKey("configSchema"):
    let schema = j["configSchema"]
    if schema.hasKey("description"):
      result.description = schema["description"].getStr()

  if result.name == "":
    result.name = "unknown-plugin"
