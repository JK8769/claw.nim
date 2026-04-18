import std/[asyncdispatch, json, tables, strutils, options]
import types
import ../skills/installer

type
  SkillInstallTool* = ref object of Tool
    installer: SkillInstaller

proc newSkillInstallTool*(installer: SkillInstaller): SkillInstallTool =
  SkillInstallTool(installer: installer)

method name*(t: SkillInstallTool): string = "install_skill"

method description*(t: SkillInstallTool): string =
  "Install a skill by name (from skills.json registry or bundled), by GitHub URL, or by 'owner/repo' shorthand. " &
  "If the skill requires environment variables (e.g. API keys), provide them in the env_vars parameter."

method parameters*(t: SkillInstallTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "name": {
        "type": "string",
        "description": "Skill name (e.g. 'anygen', 'nimclaw-web-search') or GitHub URL/shorthand (e.g. 'AnyGenIO/anygen-suite-skill')."
      },
      "env_vars": {
        "type": "object",
        "description": "Environment variables required by the skill (e.g. {\"ANYGEN_API_KEY\": \"sk-xxx\"}). These are stored in the service .env file.",
        "additionalProperties": {"type": "string"}
      },
      "acquisition_method": {
        "type": "string",
        "enum": ["auto", "git", "download"],
        "description": "Optional: how to fetch the skill. Defaults to 'auto' (tries bundled, then git, then download).",
        "default": "auto"
      },
      "sub_path": {
        "type": "string",
        "description": "Optional: subdirectory within the repository to install as the skill."
      }
    },
    "required": %["name"]
  }.toTable

method execute*(t: SkillInstallTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let nameKey = if args.hasKey("name"): "name" else: "repository"  # backward compat
  if not args.hasKey(nameKey):
    return "Error: Missing 'name' parameter."

  let name = args[nameKey].getStr().strip()
  if name.len == 0:
    return "Error: Skill name cannot be empty."

  # Collect env vars from args
  var envVars: seq[(string, string)]
  if args.hasKey("env_vars"):
    let envObj = args["env_vars"]
    if envObj.kind == JObject:
      for k, v in envObj.pairs:
        envVars.add((k, v.getStr()))

  try:
    # Check if this looks like a registry name or a URL/shorthand
    let regOpt = findInRegistry(name)
    if regOpt.isSome or (not name.contains("/") and not name.contains("://")):
      # Registry name or simple name — use unified install
      return await t.installer.installByName(name, envVars)
    else:
      # URL or owner/repo — store env vars then use GitHub install
      for (k, v) in envVars:
        if v.len > 0:
          discard storeEnvVar(k, v)
      let mode = if args.hasKey("acquisition_method"): args["acquisition_method"].getStr() else: "auto"
      let subPath = if args.hasKey("sub_path"): args["sub_path"].getStr() else: ""
      await t.installer.installFromGitHub(name, mode, subPath)
      return "Installed skill from: " & name
  except Exception as e:
    return "Error installing skill: " & e.msg
