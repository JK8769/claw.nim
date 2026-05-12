## Models catalog — single source of truth.
##
## One file: `res/models.json` shipped with claw. Contains both the canonical
## model facts (hand-curated, PR-edited) and the per-provider offering lists.
## `claw model refresh` hits each configured provider's live API and writes
## the updated provider sections back into this same file — so the catalog
## stays in sync with live provider state without a per-company cache.

import std/[os, strutils, json, tables, times]
import auth, registry

type
  CanonicalModel* = object
    ## One real model in the world (e.g. "meta/llama-3.3-70b-instruct").
    ## Provider offerings link here via their `canonical` field.
    id*: string               ## canonical id (vendor-scoped)
    vendor*: string
    family*: string
    paramsB*: int             ## parameter count in billions (0 if unknown)
    contextLength*: int       ## input limit
    maxOutputTokens*: int     ## per-request output cap (provider-enforced;
                              ## sending more triggers 400 from many APIs)
    modality*: string         ## "text" | "multimodal"
    capabilities*: seq[string]
    license*: string
    releaseDate*: string      ## ISO date
    description*: string
    deprecated*: bool

  ProviderCatalog* = object
    updated*: string          ## ISO date of last refresh (informational)
    models*: seq[ModelInfo]

  ModelsCatalog* = object
    canonical*: Table[string, CanonicalModel]   ## keyed by canonical id
    providers*: Table[string, ProviderCatalog]  ## keyed by provider name

# ─── JSON parsing ───────────────────────────────────────────────

proc jsonToModel(e: JsonNode): ModelInfo =
  # Note: e{key} returns nil if the key is missing. `.kind` on nil crashes;
  # `.getStr()`/`.getInt()`/`.getFloat()` with defaults are safe.
  result.id = e{"id"}.getStr("")
  if result.id.len == 0: result.id = e{"name"}.getStr("")
  result.canonical = e{"model"}.getStr("")  # link to canonical catalog
  result.ownedBy = e{"owned_by"}.getStr("")
  let created = e{"created"}
  if created != nil and created.kind == JInt: result.created = created.getInt()
  let ctx = e{"context_length"}
  if ctx != nil and ctx.kind == JInt: result.contextLen = ctx.getInt()
  result.inputCostPer1M = e{"input_cost_per_1m_usd"}.getFloat(0.0)
  result.outputCostPer1M = e{"output_cost_per_1m_usd"}.getFloat(0.0)
  let sz = e{"size_bytes"}
  if sz != nil and sz.kind == JInt: result.sizeBytes = sz.getInt()
  let caps = e{"capabilities"}
  if caps != nil and caps.kind == JArray:
    for c in caps: result.capabilities.add(c.getStr(""))
  result.family = e{"family"}.getStr("")

proc jsonToCanonical(id: string, e: JsonNode): CanonicalModel =
  result.id = id
  result.vendor = e{"vendor"}.getStr("")
  result.family = e{"family"}.getStr("")
  let pb = e{"params_b"}
  if pb != nil and pb.kind == JInt: result.paramsB = pb.getInt()
  let ctx = e{"context_length"}
  if ctx != nil and ctx.kind == JInt: result.contextLength = ctx.getInt()
  let mout = e{"max_output_tokens"}
  if mout != nil and mout.kind == JInt: result.maxOutputTokens = mout.getInt()
  result.modality = e{"modality"}.getStr("")
  let caps = e{"capabilities"}
  if caps != nil and caps.kind == JArray:
    for c in caps: result.capabilities.add(c.getStr(""))
  result.license = e{"license"}.getStr("")
  result.releaseDate = e{"release_date"}.getStr("")
  result.description = e{"description"}.getStr("")
  result.deprecated = e{"deprecated"}.getBool(false)

proc modelToJson(m: ModelInfo): JsonNode =
  result = newJObject()
  result["id"] = %m.id
  if m.canonical.len > 0: result["model"] = %m.canonical
  if m.ownedBy.len > 0: result["owned_by"] = %m.ownedBy
  if m.created > 0: result["created"] = %m.created
  if m.contextLen > 0: result["context_length"] = %m.contextLen
  if m.inputCostPer1M > 0: result["input_cost_per_1m_usd"] = %m.inputCostPer1M
  if m.outputCostPer1M > 0: result["output_cost_per_1m_usd"] = %m.outputCostPer1M
  if m.sizeBytes > 0: result["size_bytes"] = %m.sizeBytes
  if m.capabilities.len > 0: result["capabilities"] = %m.capabilities
  if m.family.len > 0: result["family"] = %m.family

proc loadCatalog*(path: string): ModelsCatalog =
  ## Parse the two-section models.json (canonical + providers).
  ## Back-compat: legacy files without `canonical:` still load (canonical empty).
  result.canonical = initTable[string, CanonicalModel]()
  result.providers = initTable[string, ProviderCatalog]()
  if not fileExists(path): return
  try:
    let j = parseJson(readFile(path))
    # Canonical section (optional for backward compat)
    let canon = j{"canonical"}
    if canon != nil and canon.kind == JObject:
      for id, entry in canon.pairs:
        result.canonical[id] = jsonToCanonical(id, entry)
    # Providers section
    let provs = j{"providers"}
    if provs != nil and provs.kind == JObject:
      for name, blob in provs.pairs:
        var pc = ProviderCatalog(updated: blob{"updated"}.getStr(""))
        let models = blob{"models"}
        if models != nil and models.kind == JArray:
          for m in models: pc.models.add(jsonToModel(m))
        result.providers[name] = pc
  except: discard

proc saveCatalog*(path: string, cat: ModelsCatalog) =
  ## Write both sections. Canonical omitted if empty.
  let parent = path.parentDir
  if parent.len > 0 and not dirExists(parent): createDir(parent)
  let wrapper = newJObject()
  wrapper["schema_version"] = %2
  if cat.canonical.len > 0:
    var canonObj = newJObject()
    for id, cm in cat.canonical.pairs:
      var entry = newJObject()
      if cm.vendor.len > 0: entry["vendor"] = %cm.vendor
      if cm.family.len > 0: entry["family"] = %cm.family
      if cm.paramsB > 0: entry["params_b"] = %cm.paramsB
      if cm.contextLength > 0: entry["context_length"] = %cm.contextLength
      if cm.modality.len > 0: entry["modality"] = %cm.modality
      if cm.capabilities.len > 0: entry["capabilities"] = %cm.capabilities
      if cm.license.len > 0: entry["license"] = %cm.license
      if cm.releaseDate.len > 0: entry["release_date"] = %cm.releaseDate
      if cm.description.len > 0: entry["description"] = %cm.description
      if cm.deprecated: entry["deprecated"] = %true
      canonObj[id] = entry
    wrapper["canonical"] = canonObj
  var provsObj = newJObject()
  for name, pc in cat.providers.pairs:
    var modelsArr = newJArray()
    for m in pc.models: modelsArr.add(modelToJson(m))
    provsObj[name] = %*{
      "updated": pc.updated,
      "models": modelsArr
    }
  wrapper["providers"] = provsObj
  writeFile(path, pretty(wrapper, 2))

# ─── Resolution ─────────────────────────────────────────────────

proc catalogPath*(): string =
  ## Path to the single res/models.json — the only catalog.
  findDistributionResource("res" / "models.json")

proc effectiveCatalog*(): ModelsCatalog =
  ## Load the canonical catalog. Single source of truth.
  let path = catalogPath()
  if path.len > 0: result = loadCatalog(path)
  else:
    result.canonical = initTable[string, CanonicalModel]()
    result.providers = initTable[string, ProviderCatalog]()

proc getProviderModels*(providerName: string): seq[ModelInfo] =
  let cat = effectiveCatalog()
  if cat.providers.hasKey(providerName): return cat.providers[providerName].models

proc findCanonical*(canonicalId: string): (CanonicalModel, bool) =
  let cat = effectiveCatalog()
  if cat.canonical.hasKey(canonicalId):
    return (cat.canonical[canonicalId], true)
  return (CanonicalModel(), false)

proc probeModelFor*(providerName: string): string =
  ## First model id from res/models.json for this provider, or "" if none.
  ## Used by `verifyProviderKey` below to pick a known-good model when the
  ## provider has no /models listing endpoint.
  for m in getProviderModels(providerName):
    if m.id.len > 0: return m.id

proc verifyProviderKey*(def: ProviderDef, apiKey: string): auth.VerifyResult =
  ## Robust verify: try GET <verifyPath> first (fast, cheap). If that returns
  ## voUnknown (e.g. 404 — some provider tiers don't expose /models), fall back
  ## to a minimal chat-completion probe with a model from the shipped catalog.
  ## Every caller (CLI auth, `provider list --verify`, the agent's
  ## `provider action=verify` tool) gets the same behavior this way.
  result = auth.verifyKey(def, apiKey)
  if result.outcome != auth.voUnknown: return
  let probe = probeModelFor(def.name)
  if probe.len == 0: return
  result = auth.verifyViaChat(def, apiKey, probe)

# ─── Refresh: hit the live API, write back to res/models.json ───
#
# Refresh merges: the provider's live model list replaces its entry, but we
# preserve any canonical links + pricing data already in the file so a refresh
# doesn't wipe out hand-curated facts.

proc refreshProvider*(def: ProviderDef, apiKey: string): int =
  ## Fetches live model list for the given provider and writes it back to
  ## res/models.json. Preserves canonical links + pricing on matching ids.
  ## For ollama (local), enriches each model with capabilities/family from
  ## the native /api/show endpoint. Returns number of models written.
  var live = auth.listModels(def, apiKey)
  if live.len == 0: return 0
  if def.name == "ollama": auth.enrichOllama(def, live)
  let path = catalogPath()
  if path.len == 0: return 0
  var cat = loadCatalog(path)
  # Preserve existing enrichments (canonical link, pricing) by id
  var prevById = initTable[string, ModelInfo]()
  if cat.providers.hasKey(def.name):
    for m in cat.providers[def.name].models: prevById[m.id] = m
  var merged: seq[ModelInfo]
  for m in live:
    var eff = m
    if prevById.hasKey(m.id):
      let p = prevById[m.id]
      if eff.canonical.len == 0: eff.canonical = p.canonical
      if eff.inputCostPer1M == 0: eff.inputCostPer1M = p.inputCostPer1M
      if eff.outputCostPer1M == 0: eff.outputCostPer1M = p.outputCostPer1M
    merged.add(eff)
  cat.providers[def.name] = ProviderCatalog(
    updated: now().format("yyyy-MM-dd"),
    models: merged
  )
  saveCatalog(path, cat)
  return merged.len
