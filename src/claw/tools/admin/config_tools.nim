import std/[asyncdispatch, json, tables, strutils]
import ../types
import ../spec
import ../../config

const ToolSpec* = spec(
  name = "set_api_key",
  description = "configure API keys and secrets",
  tags = @["admin", "config"],
  domain = "admin",
  default = false,
  heartbeatSafe = false,
  category = "admin",
)

type
  SetApiKeyTool* = ref object of Tool
    configPath: string

proc newSetApiKeyTool*(configPath: string): SetApiKeyTool =
  SetApiKeyTool(configPath: configPath)

method name*(t: SetApiKeyTool): string = "set_api_key"

method description*(t: SetApiKeyTool): string =
  "Set or update an API key for a global provider. This saves the key to the secure corporate vault (.env)."

method parameters*(t: SetApiKeyTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "provider": {
        "type": "string",
        "description": "The provider name (e.g., 'openai', 'deepseek', 'anthropic')"
      },
      "api_key": {
        "type": "string",
        "description": "The API key to save"
      }
    },
    "required": %["provider", "api_key"]
  }.toTable

method execute*(t: SetApiKeyTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("provider") or not args.hasKey("api_key"):
    return "Error: provider and api_key are required"

  let provider = args["provider"].getStr().toUpperAscii().strip()
  let apiKey = args["api_key"].getStr().strip()

  if provider == "" or apiKey == "":
    return "Error: provider and api_key cannot be empty"

  let envVar = case provider:
               of "OPENAI": "OPENAI_API_KEY"
               of "ANTHROPIC": "ANTHROPIC_API_KEY"
               of "GEMINI": "GEMINI_API_KEY"
               of "DEEPSEEK": "DEEPSEEK_API_KEY"
               of "OPENROUTER": "OPENROUTER_API_KEY"
               of "GROQ": "GROQ_API_KEY"
               of "OPENCODE": "NIMCLAW_OPENCODE_API_KEY"
               else: provider & "_API_KEY"

  try:
    let envPath = expandHome("~/.claw/.env")
    let line = "\n" & envVar & "=" & apiKey & "\n"
    
    # Append to .env (Simple implementation)
    var f: File
    if open(f, envPath, fmAppend):
      f.write(line)
      f.close()
      return "Successfully saved API key for " & provider & " to the Corporate Vault (.env). Please restart the system for changes to take effect."
    else:
      return "Error: Could not open the Corporate Vault (.env) for writing."
  except Exception as e:
    return "Error saving API key to Vault: " & e.msg
