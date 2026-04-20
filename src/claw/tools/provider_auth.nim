## provider_auth — agent-side tool for verifying a company's stored API keys.
##
## Security model:
##   - This tool VERIFIES only; it cannot SET or OVERWRITE keys.
##   - The key itself is read from the company's .env by the TOOL (server-side).
##     The agent never sees the key string — not in params, not in results.
##   - Keys stay in <companyDir>/.env and never cross into another company.
##
## Why an agent needs this: "Is the Anthropic key still valid?" is a
## diagnostic the agent should answer for the user without the user having
## to drop to a terminal.
##
## To SET a key, the human operator must run `claw provider auth <name>`
## at the CLI. Tool access is deliberately read-only.

import std/[asyncdispatch, json, tables, os, strutils]
import types
import ../config
import ../providers/[registry as prov_registry, auth as prov_auth, models_catalog]
import ../env_file

type
  ProviderAuthTool* = ref object of Tool

proc newProviderAuthTool*(): ProviderAuthTool =
  ProviderAuthTool()

method name*(t: ProviderAuthTool): string = "provider_auth"

method description*(t: ProviderAuthTool): string =
  "Verify that the API key for an LLM provider (deepseek, openai, anthropic, etc.) is valid and reachable. Returns pass/fail plus model count. Read-only — cannot set or change keys; ask a human operator to run `claw provider auth <name>` at the CLI for that. Scoped to this company only; never exposes the key value."

method parameters*(t: ProviderAuthTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "name": {
        "type": "string",
        "description": "Provider name (e.g. 'deepseek', 'openai', 'anthropic'). Use the same name as in ClawDSL/BASE.nims."
      }
    },
    "required": %*["name"]
  }.toTable

method execute*(t: ProviderAuthTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("name"):
    return "Error: 'name' is required"
  let name = args["name"].getStr().strip()
  let companyDir = getNimClawDir()
  let (def, found) = prov_registry.findProvider(name)
  if not found:
    return "Error: unknown provider '" & name & "'. Known: " &
           prov_registry.providerNames().join(", ")

  # Scoping is implicit: getNimClawDir() returns THIS company's dir.
  # Cross-company key access is impossible by construction.
  let envPath = companyDir / ".env"

  var storedKey = ""
  if not def.local:
    storedKey = readEnvValue(envPath, def.envKey)
    if storedKey.len == 0:
      return "✗ " & def.envKey & " is not set in " & envPath &
             ". A human operator must run `claw provider auth " & name & "` at the CLI to add it."

  let vr = models_catalog.verifyProviderKey(def, storedKey)

  # Build a result that exposes outcome + metadata but NEVER the key value.
  var status = ""
  case vr.outcome
  of prov_auth.voOk:
    status = "✓ " & name & " key is valid"
    if vr.modelCount > 0:
      status.add(" (" & $vr.modelCount & " models available)")
  of prov_auth.voSkipped:
    status = "✓ " & name & " is local (no key) — endpoint reachable"
  of prov_auth.voAuthFailed:
    status = "✗ " & name & " key rejected: " & vr.errMsg &
             ". A human operator must run `claw provider auth " & name & "` to set a new one."
  of prov_auth.voRateLimit:
    status = "⚠ " & name & " returned 429 (rate limit). Key is probably valid but throttled."
  of prov_auth.voNetwork:
    status = "✗ " & name & " not reachable: " & vr.errMsg
  of prov_auth.voServerError:
    status = "⚠ " & name & " server error: " & vr.errMsg & ". Key state unknown."
  of prov_auth.voUnknown:
    status = "? " & name & " returned unexpected response: " & vr.errMsg
  return status
