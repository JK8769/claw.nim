## model_list — agent-side tool for enumerating available models.
##
## Returns the same data the human sees from `claw model list`: canonical
## models that have at least one provider offering with a configured key in
## this company's .env. Includes capability tags so the agent can pick a
## model suited to the task (e.g. "vision", "tool-use", "reasoning").
##
## Read-only. Scoped to the current company.

import std/[asyncdispatch, json, tables, os, strutils, sets, sequtils]
import types
import ../config
import ../providers/[registry as prov_registry, models_catalog]
import ../env_file

type
  ModelListTool* = ref object of Tool

proc newModelListTool*(): ModelListTool = ModelListTool()

method name*(t: ModelListTool): string = "model_list"

method description*(t: ModelListTool): string =
  "List LLM models currently available to this company (canonical models with a configured provider key). Each entry includes vendor, context length, capability tags (tool-use, vision, reasoning, multilingual, audio, code), and the cheapest provider serving it. Use this before picking a model for a task; filter by capability to match the workload. Pass refresh=true to hit each provider's live API and update the cache before listing — use this when you want to detect newly-published models."

method parameters*(t: ModelListTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "capability": {
        "type": "string",
        "description": "Filter to models supporting this capability (tool-use|vision|reasoning|multilingual|audio|code). Optional."
      },
      "vendor": {
        "type": "string",
        "description": "Filter by vendor (meta, anthropic, openai, google, ...). Optional."
      },
      "match": {
        "type": "string",
        "description": "Substring match on model id (case-insensitive). Optional."
      },
      "refresh": {
        "type": "boolean",
        "description": "If true, fetch the latest model catalog from each configured provider's API before listing. Slower (one HTTP call per provider). Use only when you need to detect newly-published models; otherwise cached data is fine."
      }
    },
    "required": %*[]
  }.toTable

method execute*(t: ModelListTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let companyDir = getNimClawDir()
  let capFilter = if args.hasKey("capability"): args["capability"].getStr("").toLowerAscii() else: ""
  let vendorFilter = if args.hasKey("vendor"): args["vendor"].getStr("").toLowerAscii() else: ""
  let matchFilter = if args.hasKey("match"): args["match"].getStr("").toLowerAscii() else: ""
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
    for m in pc.models:
      if m.canonical.len == 0: continue
      offeringsByCanonical.mgetOrPut(m.canonical, @[]).add(
        Offering(provider: provName, inCost: m.inputCostPer1M, outCost: m.outputCostPer1M))

  var arr = newJArray()
  for id, cm in cat.canonical.pairs:
    let offs = offeringsByCanonical.getOrDefault(id, @[])
    if offs.len == 0: continue
    if vendorFilter.len > 0 and cm.vendor.toLowerAscii() != vendorFilter: continue
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
    for m in cat.providers[def.name].models:
      if m.canonical.len > 0: continue
      if matchFilter.len > 0 and matchFilter notin m.id.toLowerAscii(): continue
      if vendorFilter.len > 0 and vendorFilter != def.name.toLowerAscii(): continue
      if capFilter.len > 0:
        var found = false
        for c in m.capabilities:
          if c.toLowerAscii() == capFilter: found = true; break
        if not found: continue
      arr.add(%*{
        "model": def.name & "/" & m.id,
        "vendor": def.name,
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
  return $arr
