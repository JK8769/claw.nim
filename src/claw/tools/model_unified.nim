## model — the ship (vessel) in the provider/model/capability trio.
##
## A "model" is a specific LLM you can sail on (e.g.
## meta/llama-3.3-70b-instruct, claude-3-5-sonnet-latest). This tool lets
## the agent ask:
##
##   action=list    — every model available to this company, with
##                    capabilities/context/pricing. (PRESERVES the
##                    `model_list` tool's full filter set verbatim:
##                    capability, vendor, match, refresh.)
##   action=info    — show one model's full details (vendor, family,
##                    context_length, max_output_tokens, modality,
##                    capabilities, license, release_date, description,
##                    canonical link / providers offering it, pricing).
##   action=current — show the model the CALLING agent is currently
##                    using as its primary (looked up via the agent's
##                    NamedAgentConfig.models[0]; falls back to cfg
##                    defaults if not explicitly set). Same shape as
##                    `info`.
##
## Replaces the prior `tools/admin/model_list.nim` (folded into `list`)
## plus adds NEW `info` and `current` inspections.
##
## See `provider_unified.nim` for the sea and `capability_unified.nim`
## for the navigator. Registration changes for `agent/loop.nim` and
## `tools/registry/manifest.nim` are documented in
## `capability_unified.nim`.

import std/[asyncdispatch, json, tables, os, strutils, sets, sequtils]
import ./types
import ./spec
import ../config
import ../providers/[registry as prov_registry, models_catalog]
import ../env_file

const ToolSpec* = spec(
  name = "model",
  description = "LLM models (the 'ship' you sail on): list/info/current " &
                "(action=list|info|current). Includes capabilities, " &
                "context, pricing; current = the agent's primary model.",
  tags = @["diagnostics", "providers", "models", "core"],
  searchKeywords = @["llm", "model", "vision", "tool-use", "reasoning",
                      "context", "pricing", "capability", "vendor",
                      "current", "primary", "active"],
  domain = "admin",
  default = true,
  heartbeatSafe = false,
  category = "admin",
)

type
  ModelTool* = ref object of ContextualTool

proc newModelTool*(): ModelTool = ModelTool()

method name*(t: ModelTool): string = "model"

method description*(t: ModelTool): string =
  "LLM model inspection (the 'ship' — what you actually sail on). Each " &
  "model is a specific LLM exposed by one or more providers. Read-only " &
  "and scoped to this company.\n\n" &
  "Actions:\n" &
  "  list    — available models, with vendor/context/capabilities/pricing. " &
                "Filter by capability (tool-use|vision|reasoning|" &
                "multilingual|audio|code), vendor, family, provider, or " &
                "id substring. Pass refresh=true to hit each provider's " &
                "live API before listing (slower).\n" &
  "  info    — one model's full canonical details + which providers serve it\n" &
  "  current — the model the calling agent is using as its primary " &
                "(models[0] from the agent's config), in the same shape " &
                "as `info`. Useful for self-introspection: 'what am I " &
                "running on?'"

method parameters*(t: ModelTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["list", "info", "current"],
        "description": "Operation to perform"
      },
      # ---- list filters (preserved from legacy model_list) ----
      "capability": {
        "type": "string",
        "description": "list only — filter to models supporting this " &
                       "capability (tool-use|vision|reasoning|multilingual" &
                       "|audio|code). Optional."
      },
      "has": {
        "type": "string",
        "description": "list only — alias for `capability` (the navigator " &
                       "uses this name for the same field; both work)."
      },
      "vendor": {
        "type": "string",
        "description": "list only — filter by vendor (meta, anthropic, " &
                       "openai, google, …). Optional."
      },
      "family": {
        "type": "string",
        "description": "list only — filter by model family (e.g. 'gpt-4', " &
                       "'claude-3', 'llama-3'). Matches the canonical " &
                       "`family` field. Optional."
      },
      "provider": {
        "type": "string",
        "description": "list only — filter to models served by this " &
                       "provider. Optional."
      },
      "match": {
        "type": "string",
        "description": "list only — substring match on model id " &
                       "(case-insensitive). Optional."
      },
      "refresh": {
        "type": "boolean",
        "description": "list only — if true, fetch the latest model " &
                       "catalog from each configured provider's API before " &
                       "listing. Slower (one HTTP call per provider). Use " &
                       "only when you need to detect newly-published " &
                       "models; otherwise cached data is fine."
      },
      # ---- info ----
      "id": {
        "type": "string",
        "description": "info only — canonical model id (e.g. " &
                       "'meta/llama-3.3-70b-instruct') or per-provider id " &
                       "(e.g. 'deepseek/deepseek-v4-flash')."
      }
    },
    "required": %["action"]
  }.toTable

# ---------------------------------------------------------------------------
# list — PRESERVED verbatim from admin/model_list.nim, plus `provider=` and
#         `family=` filters which the legacy tool didn't have explicit
#         params for. (The original implicitly excluded `provider`/`family`
#         filtering — this tool adds them while keeping the original
#         filter behavior unchanged.)
# ---------------------------------------------------------------------------

proc doList(t: ModelTool, args: Table[string, JsonNode]): string =
  let companyDir = getNimClawDir()
  # Accept either `capability` (legacy) or `has` (navigator-aligned).
  let capFilter =
    if args.hasKey("capability"): args["capability"].getStr("").toLowerAscii()
    elif args.hasKey("has"): args["has"].getStr("").toLowerAscii()
    else: ""
  let vendorFilter =
    if args.hasKey("vendor"): args["vendor"].getStr("").toLowerAscii() else: ""
  let familyFilter =
    if args.hasKey("family"): args["family"].getStr("").toLowerAscii() else: ""
  let providerFilter =
    if args.hasKey("provider"): args["provider"].getStr("").toLowerAscii() else: ""
  let matchFilter =
    if args.hasKey("match"): args["match"].getStr("").toLowerAscii() else: ""
  let wantRefresh = args.hasKey("refresh") and args["refresh"].getBool(false)

  # Providers with a key (or local) for this company
  var configured = initHashSet[string]()
  var configuredDefs: seq[prov_registry.ProviderDef] = @[]
  for p in prov_registry.effectiveProviders():
    if p.local or readEnvValue(companyDir / ".env", p.envKey).len > 0:
      configured.incl(p.name)
      configuredDefs.add(p)

  # Optional live refresh — hit each configured provider's models API and
  # write results into the company cache before reading. Compute a delta so
  # the agent can surface newly-published models (including ones without a
  # canonical entry yet in res/models.json).
  var refreshNote = ""
  type NewModel = object
    provider, id, canonical: string
  var newModels: seq[NewModel] = @[]
  if wantRefresh:
    # Snapshot pre-refresh IDs per configured provider
    let preCat = models_catalog.effectiveCatalog()
    var preIds = initTable[string, HashSet[string]]()
    for def in configuredDefs:
      var s = initHashSet[string]()
      if preCat.providers.hasKey(def.name):
        for m in preCat.providers[def.name].models: s.incl(m.id)
      preIds[def.name] = s

    var parts: seq[string]
    for def in configuredDefs:
      let key = if def.local: "" else: readEnvValue(companyDir / ".env", def.envKey)
      if not def.local and key.len == 0: continue
      let n = models_catalog.refreshProvider(def, key)
      parts.add(def.name & "=" & $n)
    refreshNote = "refreshed: " & parts.join(", ")

    # Post-refresh: compute newly-seen IDs per provider
    let postCat = models_catalog.effectiveCatalog()
    for def in configuredDefs:
      if not postCat.providers.hasKey(def.name): continue
      for m in postCat.providers[def.name].models:
        if m.id notin preIds[def.name]:
          newModels.add(NewModel(provider: def.name, id: m.id, canonical: m.canonical))

  let cat = models_catalog.effectiveCatalog()

  type Offering = object
    provider: string
    inCost, outCost: float
  var offeringsByCanonical = initTable[string, seq[Offering]]()
  for provName, pc in cat.providers.pairs:
    if provName notin configured: continue
    if providerFilter.len > 0 and provName.toLowerAscii() != providerFilter: continue
    for m in pc.models:
      if m.canonical.len == 0: continue
      offeringsByCanonical.mgetOrPut(m.canonical, @[]).add(
        Offering(provider: provName, inCost: m.inputCostPer1M, outCost: m.outputCostPer1M))

  var arr = newJArray()
  for id, cm in cat.canonical.pairs:
    let offs = offeringsByCanonical.getOrDefault(id, @[])
    if offs.len == 0: continue
    if vendorFilter.len > 0 and cm.vendor.toLowerAscii() != vendorFilter: continue
    if familyFilter.len > 0 and cm.family.toLowerAscii() != familyFilter: continue
    if matchFilter.len > 0 and matchFilter notin id.toLowerAscii(): continue
    if capFilter.len > 0:
      var found = false
      for c in cm.capabilities:
        if c.toLowerAscii() == capFilter: found = true; break
      if not found: continue

    # Cheapest priced offering, else first available
    var cheapest = offs[0]
    var bestCost = float.high
    for o in offs:
      let c = o.inCost + o.outCost
      if c > 0 and c < bestCost:
        bestCost = c
        cheapest = o

    var provsJson = newJArray()
    for o in offs: provsJson.add(%o.provider)

    arr.add(%*{
      "model": id,
      "vendor": cm.vendor,
      "family": cm.family,
      "context_length": cm.contextLength,
      "capabilities": cm.capabilities,
      "providers": provsJson,
      "cheapest_via": cheapest.provider,
      "input_cost_per_1m_usd": cheapest.inCost,
      "output_cost_per_1m_usd": cheapest.outCost,
      "local": false
    })

  # Uncanonical provider models (local ollama models with dynamic per-host
  # lists + cloud providers like OpenCode Go whose ids aren't in canonical).
  for def in configuredDefs:
    if not cat.providers.hasKey(def.name): continue
    if providerFilter.len > 0 and def.name.toLowerAscii() != providerFilter: continue
    for m in cat.providers[def.name].models:
      if m.canonical.len > 0: continue
      if matchFilter.len > 0 and matchFilter notin m.id.toLowerAscii(): continue
      if vendorFilter.len > 0 and vendorFilter != def.name.toLowerAscii(): continue
      if familyFilter.len > 0 and m.family.toLowerAscii() != familyFilter: continue
      if capFilter.len > 0:
        var found = false
        for c in m.capabilities:
          if c.toLowerAscii() == capFilter: found = true; break
        if not found: continue
      arr.add(%*{
        "model": def.name & "/" & m.id,
        "vendor": def.name,
        "family": m.family,
        "context_length": m.contextLen,
        "capabilities": %m.capabilities,
        "providers": %*[def.name],
        "cheapest_via": def.name,
        "input_cost_per_1m_usd": m.inputCostPer1M,
        "output_cost_per_1m_usd": m.outputCostPer1M,
        "local": def.local,
        "uncanonical": true
      })

  # Build the new_models delta payload (only meaningful when refresh ran)
  var newArr = newJArray()
  for nm in newModels:
    newArr.add(%*{
      "provider": nm.provider,
      "id": nm.id,
      "canonical": (if nm.canonical.len > 0: %nm.canonical else: newJNull()),
      "has_canonical_entry": nm.canonical.len > 0
    })

  if arr.len == 0:
    var msg = "No models match (configured providers: " &
              toSeq(configured).join(", ") & "). Try without filters or pass refresh=true."
    if refreshNote.len > 0: msg.add(" (" & refreshNote & ")")
    return msg

  # When refresh ran, wrap the array in an object so the agent sees the
  # refresh outcome, the available models, and any newly-seen provider
  # models (including ones not yet linked to a canonical entry — those
  # need a PR to res/models.json before they show up in the main list).
  if refreshNote.len > 0:
    return $(%*{
      "refresh": refreshNote,
      "new_models": newArr,
      "new_models_note": (if newModels.len == 0: "no new models since last refresh"
                          else: $newModels.len & " newly-seen provider model(s); " &
                                "entries without canonical links need a PR to res/models.json to appear in `models`"),
      "models": arr
    })
  $arr

# ---------------------------------------------------------------------------
# info — one model's full canonical details + offering providers
# ---------------------------------------------------------------------------

proc canonicalJson(cm: CanonicalModel, cat: ModelsCatalog,
                   configured: HashSet[string]): JsonNode =
  ## Render one canonical model + which configured providers serve it.
  result = %*{
    "model": cm.id,
    "vendor": cm.vendor,
    "family": cm.family,
    "params_b": cm.paramsB,
    "context_length": cm.contextLength,
    "max_output_tokens": cm.maxOutputTokens,
    "modality": cm.modality,
    "capabilities": cm.capabilities,
    "license": cm.license,
    "release_date": cm.releaseDate,
    "description": cm.description,
    "deprecated": cm.deprecated
  }
  # Which configured providers offer this canonical id + pricing per offering.
  var providersArr = newJArray()
  for provName, pc in cat.providers.pairs:
    if provName notin configured: continue
    for m in pc.models:
      if m.canonical == cm.id:
        providersArr.add(%*{
          "provider": provName,
          "provider_model_id": m.id,
          "input_cost_per_1m_usd": m.inputCostPer1M,
          "output_cost_per_1m_usd": m.outputCostPer1M
        })
  result["providers"] = providersArr

proc lookupModel(id: string): JsonNode =
  ## Resolve `id` against the catalog. Supports three shapes:
  ##   • canonical id (e.g. 'meta/llama-3.3-70b-instruct')
  ##   • provider-scoped id (e.g. 'deepseek/deepseek-v4-flash') — the part
  ##     after the slash is the provider's model id; we look it up and
  ##     follow its canonical link if present.
  ##   • bare provider model id (e.g. 'deepseek-v4-flash') — scan all
  ##     providers for a match.
  ## Returns nil if not found.
  let companyDir = getNimClawDir()
  let cat = models_catalog.effectiveCatalog()
  var configured = initHashSet[string]()
  for p in prov_registry.effectiveProviders():
    if p.local or readEnvValue(companyDir / ".env", p.envKey).len > 0:
      configured.incl(p.name)

  # 1. Direct canonical hit.
  if cat.canonical.hasKey(id):
    return canonicalJson(cat.canonical[id], cat, configured)

  # 2. Provider-scoped (foo/bar).
  if '/' in id:
    let parts = id.split('/', 1)
    let provName = parts[0]
    let modelId = parts[1]
    if cat.providers.hasKey(provName):
      for m in cat.providers[provName].models:
        if m.id == modelId:
          # If it links to canonical, return the canonical view.
          if m.canonical.len > 0 and cat.canonical.hasKey(m.canonical):
            var view = canonicalJson(cat.canonical[m.canonical], cat, configured)
            view["matched_via"] = %*{"provider": provName, "model_id": modelId}
            return view
          # Uncanonical — return the per-provider details directly.
          return %*{
            "model": provName & "/" & m.id,
            "vendor": provName,
            "family": m.family,
            "context_length": m.contextLen,
            "capabilities": m.capabilities,
            "providers": %*[
              %*{
                "provider": provName,
                "provider_model_id": m.id,
                "input_cost_per_1m_usd": m.inputCostPer1M,
                "output_cost_per_1m_usd": m.outputCostPer1M
              }
            ],
            "uncanonical": true
          }
    return nil

  # 3. Bare provider model id — scan every provider for an exact match.
  for provName, pc in cat.providers.pairs:
    for m in pc.models:
      if m.id == id:
        if m.canonical.len > 0 and cat.canonical.hasKey(m.canonical):
          var view = canonicalJson(cat.canonical[m.canonical], cat, configured)
          view["matched_via"] = %*{"provider": provName, "model_id": id}
          return view
        return %*{
          "model": provName & "/" & m.id,
          "vendor": provName,
          "family": m.family,
          "context_length": m.contextLen,
          "capabilities": m.capabilities,
          "providers": %*[
            %*{
              "provider": provName,
              "provider_model_id": m.id,
              "input_cost_per_1m_usd": m.inputCostPer1M,
              "output_cost_per_1m_usd": m.outputCostPer1M
            }
          ],
          "uncanonical": true
        }
  nil

proc doInfo(t: ModelTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("id"):
    return "Error: 'id' is required (e.g. 'meta/llama-3.3-70b-instruct' " &
           "or 'deepseek/deepseek-v4-flash')"
  let id = args["id"].getStr().strip()
  let view = lookupModel(id)
  if view == nil:
    return "Error: model '" & id & "' not found in the catalog. Use " &
           "`model action=list` to see what's available."
  $view

# ---------------------------------------------------------------------------
# current — what's the CALLING agent's primary model?
# ---------------------------------------------------------------------------
#
# Tools don't get a direct AgentLoop reference, but ContextualTool carries
# `agentName`. We look up that agent's NamedAgentConfig (loaded from BASE
# via getConfigPath), read models[0], and return its full info.
#
# Fallback chain (matches the gateway's actual model-pick at startup):
#   1. agent's `models[0]` if non-empty
#   2. agent's `model` field (DEPRECATED but still respected by readers)
#   3. cfg-level default chain (not yet exposed here — would need a
#      `defaultModel` accessor on AgentsDefaultsConfig; for now return a
#      hint that the agent inherits company defaults)

proc doCurrent(t: ModelTool): string =
  if t.agentName.len == 0:
    return "Error: caller agent name not set in tool context — " &
           "cannot resolve current model."
  let cfg = loadConfig(getConfigPath())
  var modelId = ""
  var found = false
  for a in cfg.agents.named:
    if a.name == t.agentName:
      found = true
      if a.models.len > 0:
        modelId = a.models[0]
      elif a.model.len > 0:
        modelId = a.model
      break
  if not found:
    return "Error: agent '" & t.agentName & "' not found in config."
  if modelId.len == 0:
    return $(%*{
      "agent": t.agentName,
      "model": newJNull(),
      "note": "agent has no explicit model set; gateway resolves it from " &
              "the company default chain at startup. Use `model " &
              "action=list` to see what's available."
    })
  let view = lookupModel(modelId)
  if view == nil:
    return $(%*{
      "agent": t.agentName,
      "model": modelId,
      "note": "agent's configured model is not in the catalog (could be a " &
              "private/local model). No canonical details available."
    })
  # Annotate the lookup with the calling agent's name for clarity.
  var annotated = view
  annotated["agent"] = %t.agentName
  $annotated

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

method execute*(t: ModelTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (list | info | current)"
  let action = args["action"].getStr()
  case action
  of "list":    return doList(t, args)
  of "info":    return doInfo(t, args)
  of "current": return doCurrent(t)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: list | info | current"
