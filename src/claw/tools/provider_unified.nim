## provider — the sea (substrate) in the provider/model/capability trio.
##
## An LLM "provider" is one of the API endpoints you've connected this
## company to (deepseek, openai, anthropic, ollama, …). This tool lets the
## agent (and operators chatting through it) ask:
##
##   action=list   — which providers does this company know about, and
##                   which have a key configured? Returns each provider's
##                   apiBase, models-offered count, masked key status.
##   action=verify — does provider X's stored key still work? (PRESERVES
##                   the `provider_auth` tool's logic verbatim — keys are
##                   read from <companyDir>/.env by the tool, NEVER passed
##                   in from the LLM and NEVER returned to it.)
##   action=info   — show one provider's full def (apiBase, envKey,
##                   authHeader, verifyPath, defaultModel, local flag, and
##                   the per-provider catalog of models offered).
##
## Replaces the prior `tools/admin/provider_auth.nim` (now folded into
## `verify`) plus adds two NEW read-only inspections (`list`, `info`).
##
## See `model_unified.nim` for the ship (the model you sail on) and
## `capability_unified.nim` for the navigator (find ships by what they do).
##
## Registration changes needed in `agent/loop.nim` and
## `tools/registry/manifest.nim` are documented at the bottom of each new
## file; see `capability_unified.nim` for the consolidated diff guide.

import std/[asyncdispatch, json, tables, os, strutils]
import ./types
import ./spec
import ../config
import ../providers/[registry as prov_registry, auth as prov_auth, models_catalog]
import ../env_file

const ToolSpec* = spec(
  name = "provider",
  description = "LLM providers (the 'sea' you sail on): list/verify/info " &
                "(action=list|verify|info). Read-only — keys stay on disk.",
  tags = @["admin", "providers", "diagnostics", "core"],
  searchKeywords = @["llm", "api", "key", "endpoint", "openai", "anthropic",
                      "deepseek", "ollama", "auth", "verify", "credentials",
                      "reachable", "available"],
  domain = "admin",
  default = true,
  heartbeatSafe = false,
  category = "admin",
)

type
  ProviderTool* = ref object of Tool

proc newProviderTool*(): ProviderTool = ProviderTool()

method name*(t: ProviderTool): string = "provider"

method description*(t: ProviderTool): string =
  "LLM provider inspection (the 'sea' — the substrate you sail on). Each " &
  "provider is one API endpoint this company can call (deepseek, openai, " &
  "anthropic, ollama, …). Read-only: cannot set or change keys (ask a " &
  "human operator to run `claw provider auth <name>` at the CLI for that). " &
  "Scoped to this company only; the key value is never exposed to the LLM.\n\n" &
  "Actions:\n" &
  "  list   — every provider this install knows about, with masked key " &
                "status and model count\n" &
  "  verify — does provider X's stored key still authenticate? Returns " &
                "pass/fail plus model count\n" &
  "  info   — one provider's full definition (apiBase, envKey, authHeader, " &
                "verifyPath, defaultModel, local flag, models offered)"

method parameters*(t: ProviderTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["list", "verify", "info"],
        "description": "Operation to perform"
      },
      "name": {
        "type": "string",
        "description": "verify/info only — provider name (e.g. 'deepseek', " &
                       "'openai', 'anthropic'). Use the same name as in " &
                       "ClawDSL/BASE.nims."
      }
    },
    "required": %["action"]
  }.toTable

# ---------------------------------------------------------------------------
# list — every known provider + masked key status + model count
# ---------------------------------------------------------------------------

proc doList(t: ProviderTool): string =
  let companyDir = getNimClawDir()
  let envPath = companyDir / ".env"
  let cat = models_catalog.effectiveCatalog()
  var arr = newJArray()
  for p in prov_registry.effectiveProviders():
    var keyStatus = ""
    if p.local:
      keyStatus = "local (no key)"
    else:
      let stored = readEnvValue(envPath, p.envKey)
      keyStatus = if stored.len > 0: "set" else: "missing"
    var modelCount = 0
    if cat.providers.hasKey(p.name):
      modelCount = cat.providers[p.name].models.len
    arr.add(%*{
      "name": p.name,
      "apiBase": p.apiBase,
      "envKey": p.envKey,
      "local": p.local,
      "key_status": keyStatus,
      "models_offered": modelCount,
      "default_model": p.defaultModel
    })
  $arr

# ---------------------------------------------------------------------------
# verify — preserved verbatim from provider_auth.nim
# ---------------------------------------------------------------------------

proc doVerify(t: ProviderTool, args: Table[string, JsonNode]): string =
  ## PRESERVES logic from admin/provider_auth.nim verbatim.
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
  status

# ---------------------------------------------------------------------------
# info — one provider's full definition + offered models
# ---------------------------------------------------------------------------

proc doInfo(t: ProviderTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("name"):
    return "Error: 'name' is required"
  let name = args["name"].getStr().strip()
  let (def, found) = prov_registry.findProvider(name)
  if not found:
    return "Error: unknown provider '" & name & "'. Known: " &
           prov_registry.providerNames().join(", ")
  let companyDir = getNimClawDir()
  let envPath = companyDir / ".env"
  let keyStatus =
    if def.local: "local (no key)"
    elif readEnvValue(envPath, def.envKey).len > 0: "set"
    else: "missing"

  # Pull the provider's offered models from the catalog.
  let cat = models_catalog.effectiveCatalog()
  var modelsArr = newJArray()
  if cat.providers.hasKey(def.name):
    for m in cat.providers[def.name].models:
      var entry = %*{
        "id": m.id,
        "context_length": m.contextLen,
        "input_cost_per_1m_usd": m.inputCostPer1M,
        "output_cost_per_1m_usd": m.outputCostPer1M
      }
      if m.canonical.len > 0: entry["canonical"] = %m.canonical
      if m.capabilities.len > 0: entry["capabilities"] = %m.capabilities
      if m.family.len > 0: entry["family"] = %m.family
      modelsArr.add(entry)

  $(%*{
    "name": def.name,
    "apiBase": def.apiBase,
    "envKey": def.envKey,
    "authHeader": def.authHeader,
    "verifyPath": def.verifyPath,
    "defaultModel": def.defaultModel,
    "local": def.local,
    "key_status": keyStatus,
    "models": modelsArr
  })

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

method execute*(t: ProviderTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (list | verify | info)"
  let action = args["action"].getStr()
  case action
  of "list":   return doList(t)
  of "verify": return doVerify(t, args)
  of "info":   return doInfo(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: list | verify | info"
