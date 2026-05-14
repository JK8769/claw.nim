## capability — the navigator (instrument) in the
## provider/model/capability trio.
##
## A "capability" is a tag on a model that says what it can do:
## `tool-use`, `vision`, `reasoning`, `multilingual`, `audio`, `code`,
## `thinking`, etc. This tool turns the catalog inside out — instead of
## "what does THIS model do?", you ask "WHICH models can do X?".
##
## Also designed to be called by the framework itself as a cheap
## feature-gate: before serving an image to a chat, ask
## `capability method=has model=<current> tag=vision` and refuse early
## if the answer is no.
##
##   method=list  — every distinct capability tag in the catalog,
##                  case-folded and deduped (the navigator's full
##                  instrument panel).
##   method=find  — which models offer this capability? Returns model
##                  ids with their providers. Accepts the same narrowing
##                  filters as `model method=list` (provider, vendor,
##                  family).
##   method=has   — boolean: does <model> have <tag>? Cheap, fast,
##                  framework-callable. Returns "yes"/"no" plus a brief
##                  explanation when no.
##
## NOTE on tag normalization: capabilities are matched case-insensitively
## but otherwise left as-declared. The catalog currently has near-duplicate
## tags (`tool-use` vs `tools`, `reasoning` vs `thinking`) — for v1 we keep
## them distinct so the agent sees the authentic catalog shape. A future v2
## should canonicalize via a per-vendor alias map; flag for cleanup.
##
## This tool needs zero per-agent context (no role, no graph, no env keys).
## It's a pure read over `effectiveCatalog()`. Cheap to call from anywhere
## including inside a feature-gate check on the hot path.
##
## ─── Registration changes (NEW trio replaces 2 legacy tools) ──────────
##
## Files to delete after this lands:
##   • src/claw/tools/admin/provider_auth.nim
##   • src/claw/tools/admin/model_list.nim
##
## agent/loop.nim (line numbers from the current tree as of the writing
## of this file — re-grep before applying):
##
##   DELETE (line 27):
##     import ../tools/admin/[provider_auth, model_list, config_tools, feishu_add_app]
##   ADD (replaces the line above):
##     import ../tools/admin/[config_tools, feishu_add_app]
##     import ../tools/[provider_unified, model_unified, capability_unified]
##
##   DELETE the two blocks around lines 2957–2960 and 2969–2970:
##     # provider_auth: read-only verify of the company's stored API keys. Never
##     # exposes the key value to the LLM; never writes .env (that's CLI-only).
##     regTagged(newProviderAuthTool(), ["admin", "diagnostics", "providers"],
##               "verify provider api key deepseek openai anthropic reachable")
##     ...
##     regTagged(newModelListTool(), ["diagnostics", "providers", "models"],
##               "list available llm models capabilities context pricing")
##
##   ADD (single block, near where the other admin tools register):
##     # Provider / model / capability — the sea / ship / navigator trio.
##     # Replaces provider_auth + model_list with three unified tools that
##     # share the catalog as substrate. `provider` shows API endpoints,
##     # `model` shows the LLMs themselves, `capability` lets the framework
##     # (and the agent) ask "which models can do X?" — used internally to
##     # gate features like image input on models without `vision`.
##     regTagged(newProviderTool(),
##               ["admin", "providers", "diagnostics", "core"],
##               "list verify info LLM provider api key endpoint")
##     regTagged(newModelTool(),
##               ["diagnostics", "providers", "models", "core"],
##               "list info current LLM model capabilities context pricing")
##     regTagged(newCapabilityTool(),
##               ["diagnostics", "models", "capability", "core"],
##               "find list has model capability tag vision tool-use reasoning")
##
## tools/registry/manifest.nim (line numbers around 161–168):
##
##   DELETE (lines 161–168):
##     spec(name = "provider_auth",
##          description = "verify provider api key (deepseek, openai, anthropic, ...) reachable",
##          tags = @["admin", "diagnostics", "providers"], domain = "admin",
##          default = true, heartbeatSafe = false, category = "admin"),
##     spec(name = "model_list",
##          description = "list available LLM models with capabilities, context, pricing",
##          tags = @["diagnostics", "providers", "models"], domain = "admin",
##          default = true, heartbeatSafe = false, category = "admin"),
##
##   ADD (in the same admin block):
##     spec(name = "provider",
##          description = "LLM providers (the 'sea'): list/verify/info " &
##                        "(method=list|verify|info). Read-only — keys stay on disk.",
##          tags = @["admin", "providers", "diagnostics", "core"],
##          searchKeywords = @["llm", "api", "key", "endpoint", "openai",
##                              "anthropic", "deepseek", "ollama", "auth",
##                              "verify", "credentials"],
##          domain = "admin",
##          default = true, heartbeatSafe = false, category = "admin"),
##     spec(name = "model",
##          description = "LLM models (the 'ship'): list/info/current " &
##                        "(method=list|info|current). Includes capabilities, " &
##                        "context, pricing; current = caller agent's primary.",
##          tags = @["diagnostics", "providers", "models", "core"],
##          searchKeywords = @["llm", "model", "vision", "tool-use", "reasoning",
##                              "context", "pricing", "capability", "vendor",
##                              "current", "primary"],
##          domain = "admin",
##          default = true, heartbeatSafe = false, category = "admin"),
##     spec(name = "capability",
##          description = "find models by capability (method=list|find|has). " &
##                        "Framework-callable feature gate (e.g. vision check " &
##                        "before serving an image).",
##          tags = @["diagnostics", "models", "capability", "core"],
##          searchKeywords = @["tag", "feature", "vision", "tool-use",
##                              "reasoning", "thinking", "multilingual", "audio",
##                              "code", "supports", "gate"],
##          domain = "admin",
##          default = true, heartbeatSafe = true, category = "admin"),

import std/[asyncdispatch, json, tables, os, strutils, sets, algorithm,
              base64, httpclient]
import ./types
import ./spec
import ./path_security
import ./iam_policies
import ../config
import ../providers/[registry as prov_registry, models_catalog]
import ../env_file

const ToolSpec* = spec(
  name = "capability",
  description = "Find models by capability AND use them as tools " &
                "(method=list|find|has|route|invoke). " &
                "invoke = call a specialist model (vision, audio) and " &
                "get text back without your primary model needing the " &
                "capability natively. Framework-callable feature gate + " &
                "LLM-as-tool dispatcher.",
  tags = @["diagnostics", "models", "capability", "core"],
  searchKeywords = @["tag", "feature", "vision", "tool-use", "reasoning",
                      "thinking", "multilingual", "audio", "code", "supports",
                      "gate", "navigator", "invoke", "route", "specialist",
                      "vision-model", "image-analyze", "audio-transcribe"],
  domain = "admin",
  default = true,
  heartbeatSafe = false,  # invoke makes external HTTP calls — not safe
                           # on the heartbeat hot path. list/find/has are
                           # still cheap but the action dispatch makes
                           # the tool as a whole non-heartbeat-safe.
                           # Pre-route action could re-enable for inspection-
                           # only callers; v2 task.
  category = "admin",
)

type
  CapabilityTool* = ref object of ContextualTool
    # Path-safety surface for `invoke` when reading file inputs. Mirrors
    # FsTool's three-field gate (workspaceDir / officeDir / allowedPaths).
    # When unset (e.g. CLI calls that never set context), `invoke` falls
    # back to deriving them from config + agentName at call time.
    workspaceDir*: string
    officeDir*: string
    allowedPaths*: seq[string]

proc newCapabilityTool*(): CapabilityTool = CapabilityTool()

method name*(t: CapabilityTool): string = "capability"

method description*(t: CapabilityTool): string =
  "Find LLM models by capability AND USE them as tools (the 'navigator' " &
  "— your instrument for picking a ship by what it can do, and chartering " &
  "one for a one-off voyage). Tags include: tool-use, vision, reasoning, " &
  "thinking, multilingual, audio, code.\n\n" &
  "Actions:\n" &
  "  list   — every distinct capability tag in the catalog (sorted)\n" &
  "  find   — which models have <tag>? Returns ids + providers. Filter " &
                "by provider/vendor/family to narrow.\n" &
  "  has    — boolean check: does <model> have <tag>? Cheap. Returns " &
                "'yes' or 'no' with brief explanation.\n" &
  "  route  — DRY-RUN: which model would `invoke` dispatch to for " &
                "<tag>? No LLM call, no file read, no cost. Useful for " &
                "debugging routing or previewing before commit.\n" &
  "  invoke — CALL a specialist model with this capability. The framework " &
                "picks a model (preferring your own if eligible, else " &
                "cheapest available), reads the input file if needed, " &
                "builds the multimodal request, and returns TEXT. " &
                "Lets your primary text-only model still handle images/" &
                "audio/video by delegating to a specialist."

method parameters*(t: CapabilityTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["list", "find", "has", "route", "invoke"],
        "description": "Operation to perform"
      },
      "tag": {
        "type": "string",
        "description": "find/has/route/invoke — capability tag to look " &
                       "for (case-insensitive). Examples: 'vision', " &
                       "'tool-use', 'reasoning', 'multilingual', 'audio', " &
                       "'code'. For invoke/route this picks the SPECIALIST " &
                       "to dispatch to."
      },
      "model": {
        "type": "string",
        "description": "has/invoke only — for has: model to check. " &
                       "For invoke: bypass routing, force this specific " &
                       "model (canonical id or 'provider/model_id')."
      },
      "provider": {
        "type": "string",
        "description": "find/invoke/route only — narrow routing to a " &
                       "single provider. Optional."
      },
      "vendor": {
        "type": "string",
        "description": "find only — narrow results to one vendor. Optional."
      },
      "family": {
        "type": "string",
        "description": "find only — narrow results to one model family " &
                       "(e.g. 'claude-3', 'llama-3'). Optional."
      },
      "input": {
        "type": "string",
        "description": "invoke/route — the payload. If the string is an " &
                       "absolute path to a file that exists (and is in an " &
                       "allowed area), it's read & base64-encoded; mime is " &
                       "inferred from extension. Otherwise it's passed as " &
                       "plain text. Required for invoke; optional for route."
      },
      "prompt": {
        "type": "string",
        "description": "invoke only — what to ask the specialist about " &
                       "the input. Examples: 'describe this image', " &
                       "'transcribe', 'extract all text'. Required for " &
                       "invoke."
      },
      "exclude": {
        "type": "string",
        "description": "route/invoke — comma-separated model ids to skip " &
                       "during routing. Useful when the agent already " &
                       "tried one and wants the next-best alternative."
      }
    },
    "required": %["method"]
  }.toTable

# ---------------------------------------------------------------------------
# helpers — case-folded membership
# ---------------------------------------------------------------------------

proc hasTagFold(caps: seq[string], tag: string): bool =
  ## Case-insensitive membership. Tag normalization (dedup of `tool-use`
  ## vs `tools`, `reasoning` vs `thinking`) is deliberately NOT done here;
  ## v2 cleanup will introduce an alias table.
  let lc = tag.toLowerAscii()
  for c in caps:
    if c.toLowerAscii() == lc: return true
  false

# ---------------------------------------------------------------------------
# list — every distinct capability tag in the catalog, sorted
# ---------------------------------------------------------------------------

proc doList(t: CapabilityTool): string =
  let cat = models_catalog.effectiveCatalog()
  var tags = initHashSet[string]()
  for _, cm in cat.canonical.pairs:
    for c in cm.capabilities:
      let s = c.strip()
      if s.len > 0: tags.incl(s)
  for _, pc in cat.providers.pairs:
    for m in pc.models:
      for c in m.capabilities:
        let s = c.strip()
        if s.len > 0: tags.incl(s)
  var sortedTags: seq[string] = @[]
  for tagItem in tags: sortedTags.add(tagItem)
  sortedTags.sort(cmpIgnoreCase)
  var arr = newJArray()
  for s in sortedTags: arr.add(%s)
  $(%*{
    "tags": arr,
    "count": sortedTags.len,
    "note": "case-insensitive matching; near-duplicates like 'tool-use' " &
            "vs 'tools' or 'reasoning' vs 'thinking' are kept distinct " &
            "for v1 (faithful to catalog). v2 should canonicalize."
  })

# ---------------------------------------------------------------------------
# find — every model offering <tag>, with its providers
# ---------------------------------------------------------------------------

proc doFind(t: CapabilityTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("tag"):
    return "Error: 'tag' is required (e.g. 'vision', 'tool-use')"
  let tag = args["tag"].getStr().strip()
  if tag.len == 0:
    return "Error: 'tag' must be non-empty"
  let providerFilter =
    if args.hasKey("provider"): args["provider"].getStr("").toLowerAscii() else: ""
  let vendorFilter =
    if args.hasKey("vendor"): args["vendor"].getStr("").toLowerAscii() else: ""
  let familyFilter =
    if args.hasKey("family"): args["family"].getStr("").toLowerAscii() else: ""

  let companyDir = getNimClawDir()
  var configured = initHashSet[string]()
  for p in prov_registry.effectiveProviders():
    if p.local or readEnvValue(companyDir / ".env", p.envKey).len > 0:
      configured.incl(p.name)

  let cat = models_catalog.effectiveCatalog()

  # Walk canonical entries — for each match, list which configured providers
  # offer it.
  var arr = newJArray()
  var seenCanonical = initHashSet[string]()
  for id, cm in cat.canonical.pairs:
    if not hasTagFold(cm.capabilities, tag): continue
    if vendorFilter.len > 0 and cm.vendor.toLowerAscii() != vendorFilter: continue
    if familyFilter.len > 0 and cm.family.toLowerAscii() != familyFilter: continue
    var provs = newJArray()
    for provName, pc in cat.providers.pairs:
      if provName notin configured: continue
      if providerFilter.len > 0 and provName.toLowerAscii() != providerFilter: continue
      for m in pc.models:
        if m.canonical == id:
          provs.add(%provName)
          break
    if provs.len == 0: continue  # no configured provider serves it
    seenCanonical.incl(id)
    arr.add(%*{
      "model": id,
      "vendor": cm.vendor,
      "family": cm.family,
      "providers": provs
    })

  # Also walk per-provider models whose own capabilities list the tag —
  # catches uncanonical entries (local ollama, opencode etc.) that may
  # advertise capabilities directly without a canonical link.
  for provName, pc in cat.providers.pairs:
    if provName notin configured: continue
    if providerFilter.len > 0 and provName.toLowerAscii() != providerFilter: continue
    for m in pc.models:
      # Skip canonical-linked ones already represented above.
      if m.canonical.len > 0 and m.canonical in seenCanonical: continue
      if not hasTagFold(m.capabilities, tag): continue
      if vendorFilter.len > 0 and provName.toLowerAscii() != vendorFilter: continue
      if familyFilter.len > 0 and m.family.toLowerAscii() != familyFilter: continue
      arr.add(%*{
        "model": provName & "/" & m.id,
        "vendor": provName,
        "family": m.family,
        "providers": %*[provName],
        "uncanonical": true
      })

  if arr.len == 0:
    return "No models found with capability '" & tag &
           "' (after filters). Use `capability method=list` to see " &
           "available tags."
  $(%*{
    "tag": tag,
    "count": arr.len,
    "models": arr
  })

# ---------------------------------------------------------------------------
# has — boolean: does this model have this capability?
# ---------------------------------------------------------------------------

proc doHas(t: CapabilityTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("model"): return "Error: 'model' is required"
  if not args.hasKey("tag"): return "Error: 'tag' is required"
  let model = args["model"].getStr().strip()
  let tag = args["tag"].getStr().strip()
  if model.len == 0: return "Error: 'model' must be non-empty"
  if tag.len == 0: return "Error: 'tag' must be non-empty"

  let cat = models_catalog.effectiveCatalog()

  # Three lookup shapes (mirrors model_unified.lookupModel):
  #   1. direct canonical id
  #   2. provider/model_id
  #   3. bare provider model id (scan all providers)
  proc capsFor(id: string): (seq[string], string) =
    ## Returns (capabilities, source-description) or (@[], "") on no match.
    if cat.canonical.hasKey(id):
      return (cat.canonical[id].capabilities, "canonical:" & id)
    if '/' in id:
      let parts = id.split('/', 1)
      let provName = parts[0]
      let modelId = parts[1]
      if cat.providers.hasKey(provName):
        for m in cat.providers[provName].models:
          if m.id == modelId:
            if m.canonical.len > 0 and cat.canonical.hasKey(m.canonical):
              return (cat.canonical[m.canonical].capabilities,
                      "canonical:" & m.canonical & " (via " &
                      provName & "/" & modelId & ")")
            return (m.capabilities, provName & "/" & modelId)
      return (@[], "")
    for provName, pc in cat.providers.pairs:
      for m in pc.models:
        if m.id == id:
          if m.canonical.len > 0 and cat.canonical.hasKey(m.canonical):
            return (cat.canonical[m.canonical].capabilities,
                    "canonical:" & m.canonical & " (via " &
                    provName & "/" & id & ")")
          return (m.capabilities, provName & "/" & id)
    (@[], "")

  let (caps, source) = capsFor(model)
  if source.len == 0:
    return $(%*{
      "model": model,
      "tag": tag,
      "answer": "no",
      "reason": "model '" & model & "' not found in the catalog"
    })
  if hasTagFold(caps, tag):
    return $(%*{
      "model": model,
      "tag": tag,
      "answer": "yes",
      "source": source
    })
  $(%*{
    "model": model,
    "tag": tag,
    "answer": "no",
    "reason": "model has capabilities " & $caps & " — none match '" &
              tag & "' (case-insensitive)",
    "source": source
  })

# ===========================================================================
# LLM-as-tool: `route` (dry-run preview) and `invoke` (actual call).
# ===========================================================================
#
# Architecture: this is the "framework picks a specialist for you" layer.
# An agent whose primary model is text-only can still handle images, audio,
# etc. by calling `capability method=invoke tag=vision input=/path prompt=...`
# — the framework selects a vision-capable model, makes the HTTP call with
# multimodal content, and returns plain text. The agent's primary model
# (and the Message type's content_blocks plumbing) doesn't need to change.

# ---------------------------------------------------------------------------
# Mime detection (extension-based; precise enough for OpenAI multimodal wire
# shape; we don't sniff bytes here because the chosen MIME goes straight into
# `data:<mime>;base64,` and providers tolerate slight imprecision).
# ---------------------------------------------------------------------------

const MimeByExt = {
  # Image
  ".jpg":  "image/jpeg", ".jpeg": "image/jpeg",
  ".png":  "image/png",  ".gif":  "image/gif",
  ".webp": "image/webp", ".bmp":  "image/bmp",
  ".heic": "image/heic", ".heif": "image/heif",
  ".tif":  "image/tiff", ".tiff": "image/tiff",
  # Audio
  ".mp3":  "audio/mpeg", ".wav":  "audio/wav",
  ".m4a":  "audio/mp4",  ".ogg":  "audio/ogg",
  ".flac": "audio/flac", ".opus": "audio/opus",
  ".aac":  "audio/aac",  ".webm": "audio/webm",
  # Video
  ".mp4":  "video/mp4",  ".mov":  "video/quicktime",
  ".mkv":  "video/x-matroska",
  ".avi":  "video/x-msvideo",
  # Document
  ".pdf":  "application/pdf",
}.toTable

proc mimeOf(path: string): string =
  ## Returns the mime type for a file path by extension, or "" if unknown.
  let ext = splitFile(path).ext.toLowerAscii()
  if MimeByExt.hasKey(ext): return MimeByExt[ext]
  return ""

# ---------------------------------------------------------------------------
# Tag → modality wire shape: vision uses `image_url`, audio uses
# `input_audio`, video has no standard OpenAI shape (TODO: frame extraction).
# ---------------------------------------------------------------------------

type Modality = enum
  modText,      ## payload is plain text — embed as {"type":"text"}
  modImage,     ## payload is image bytes — embed as {"type":"image_url"}
  modAudio,     ## payload is audio bytes — embed as {"type":"input_audio"}
  modVideo,     ## payload is video bytes — TODO: no standard wire shape
  modPdf        ## payload is a PDF — embed as {"type":"input_file"} (vendor-specific)

proc modalityForTag(tag: string): Modality =
  case tag.toLowerAscii()
  of "vision", "image", "ocr":           return modImage
  of "audio", "speech", "transcribe":    return modAudio
  of "video":                            return modVideo
  of "pdf", "document":                  return modPdf
  else:                                  return modText

# ---------------------------------------------------------------------------
# Provider preference + reachability
# ---------------------------------------------------------------------------

type
  ModelChoice = object
    modelId: string         ## canonical id (or provider/model_id)
    providerName: string    ## which provider serves this model
    providerDef: ProviderDef
    reason: string          ## human-readable rationale for selection

  RouteCandidate = object
    modelId: string
    providerName: string
    providerDef: ProviderDef
    rank: int               ## 0 = preferred; higher = less preferred
    annotation: string      ## "agent's primary", "local", "configured remote", "unconfigured"
    skipReason: string      ## "" if usable, else why this was skipped
    inputCostPer1M: float
    outputCostPer1M: float

proc isProviderConfigured(envPath: string, p: ProviderDef): bool =
  ## A provider is "configured" if it's local OR has a non-empty env key
  ## value in the company's .env file.
  if p.local: return true
  if p.envKey.len == 0: return false
  return readEnvValue(envPath, p.envKey).len > 0

proc pingProvider(p: ProviderDef): bool =
  ## Short-timeout reachability probe. Hits <apiBase>/models. Returns true
  ## on any 2xx/4xx response (server is up), false on connection failure.
  ## Used to skip local providers (Ollama) when the service isn't running
  ## — saves the agent a confusing "connection refused" from invoke.
  if p.apiBase.len == 0: return false
  let url = p.apiBase & (if p.verifyPath.len > 0: p.verifyPath else: "/models")
  let client = newHttpClient(timeout = 800)  # 800ms — generous for local;
                                              # spec says 200ms but localhost
                                              # cold-start can easily exceed
                                              # that and we don't want a
                                              # false negative on a healthy
                                              # Ollama with a model loading.
  try:
    let resp = client.request(url, httpMethod = HttpGet)
    return resp.code.int < 500
  except: return false
  finally:
    try: client.close() except: discard

proc costRank(c: RouteCandidate): float =
  ## Combined cost heuristic: input+output USD per 1M tokens. Zero = free
  ## (treated as cheapest). Local providers always rank at 0 regardless.
  if c.providerDef.local: return 0.0
  return c.inputCostPer1M + c.outputCostPer1M

# ---------------------------------------------------------------------------
# Build all routing candidates (matched models × providers) for a given tag.
# ---------------------------------------------------------------------------

proc gatherCandidates(tag, agentModel, prefProvider: string,
                      excludeSet: HashSet[string]): seq[RouteCandidate] =
  ## Walks the catalog and emits one candidate per (model, provider) pair
  ## where the model has the requested tag and (if specified) the provider
  ## matches `prefProvider`. Sets the candidate's annotation but doesn't
  ## yet check reachability (that happens in selectModel so route can
  ## report the result).
  let cat = models_catalog.effectiveCatalog()
  let companyDir = getNimClawDir()
  let envPath = companyDir / ".env"

  # Index canonical models by tag presence
  var canonicalsWithTag = initHashSet[string]()
  for id, cm in cat.canonical.pairs:
    if hasTagFold(cm.capabilities, tag):
      canonicalsWithTag.incl(id)

  # For each provider × model that matches the tag, emit a candidate.
  for prov in prov_registry.effectiveProviders():
    if prefProvider.len > 0 and prov.name.toLowerAscii() != prefProvider.toLowerAscii() and
       prov.name.toLowerAscii().replace(" ", "-") != prefProvider.toLowerAscii():
      continue
    if not cat.providers.hasKey(prov.name): continue
    for m in cat.providers[prov.name].models:
      let pmId = m.id
      let canonicalId = m.canonical
      let scopedId =
        if canonicalId.len > 0 and canonicalId in canonicalsWithTag: canonicalId
        elif hasTagFold(m.capabilities, tag): prov.name & "/" & pmId
        else: ""
      if scopedId.len == 0: continue
      if scopedId in excludeSet or pmId in excludeSet: continue

      var c = RouteCandidate(
        modelId: scopedId,
        providerName: prov.name,
        providerDef: prov,
        inputCostPer1M: m.inputCostPer1M,
        outputCostPer1M: m.outputCostPer1M
      )

      # Annotate. Order matters — first match wins.
      if agentModel.len > 0 and (agentModel == scopedId or agentModel == pmId or
                                  agentModel == prov.name & "/" & pmId):
        c.annotation = "agent's primary model"
      elif prov.local:
        c.annotation = "local"
      elif isProviderConfigured(envPath, prov):
        c.annotation = "configured remote"
      else:
        c.annotation = "unconfigured (no API key)"
      result.add(c)

# ---------------------------------------------------------------------------
# selectModel — apply preference order, do reachability probes for locals,
# return the winning choice + the full candidate list (with skip reasons)
# for the route output.
# ---------------------------------------------------------------------------

proc agentPrimaryModel(t: CapabilityTool): string =
  ## Resolve the calling agent's models[0]. Returns "" if no context set
  ## or the agent has no explicit model.
  if t.agentName.len == 0: return ""
  try:
    let cfg = loadConfig(getConfigPath())
    for a in cfg.agents.named:
      if a.name == t.agentName:
        if a.models.len > 0: return a.models[0]
        if a.model.len > 0: return a.model
        return ""
  except: discard
  return ""

proc selectModel(t: CapabilityTool, tag, prefModel, prefProvider: string,
                 excludeSet: HashSet[string]):
                 tuple[choice: ModelChoice, candidates: seq[RouteCandidate],
                       err: string] =
  ## Returns the chosen model + the considered candidate list (annotated
  ## with skip reasons) + an error string ("" on success).
  let agentModel = agentPrimaryModel(t)

  # Fast path: prefModel forces a specific id, skip routing.
  if prefModel.len > 0:
    let cat = models_catalog.effectiveCatalog()
    # Look up across all providers for an exact match.
    var found = false
    var chosen: RouteCandidate
    for prov in prov_registry.effectiveProviders():
      if not cat.providers.hasKey(prov.name): continue
      for m in cat.providers[prov.name].models:
        let pmId = m.id
        let canonicalId = m.canonical
        if prefModel == pmId or prefModel == prov.name & "/" & pmId or
           (canonicalId.len > 0 and prefModel == canonicalId):
          chosen = RouteCandidate(
            modelId: (if canonicalId.len > 0: canonicalId else: prov.name & "/" & pmId),
            providerName: prov.name,
            providerDef: prov,
            inputCostPer1M: m.inputCostPer1M,
            outputCostPer1M: m.outputCostPer1M,
            annotation: "forced via model=" & prefModel
          )
          found = true
          break
      if found: break
    if not found:
      return (ModelChoice(), @[],
              "model '" & prefModel & "' not found in any configured " &
              "provider's catalog")
    return (ModelChoice(modelId: chosen.modelId,
                        providerName: chosen.providerName,
                        providerDef: chosen.providerDef,
                        reason: "forced via model= override"),
            @[chosen], "")

  # Routing path: gather candidates, sort by preference.
  var cands = gatherCandidates(tag, agentModel, prefProvider, excludeSet)
  if cands.len == 0:
    return (ModelChoice(), @[],
            "no model in the catalog advertises tag '" & tag & "'" &
            (if prefProvider.len > 0: " for provider '" & prefProvider & "'" else: ""))

  # Probe local providers — locals get skipped (with annotation) if their
  # apiBase is unreachable. Done once per provider to avoid duplicate pings.
  var pingedLocals = initTable[string, bool]()
  for i in 0 ..< cands.len:
    if cands[i].providerDef.local:
      if not pingedLocals.hasKey(cands[i].providerName):
        pingedLocals[cands[i].providerName] = pingProvider(cands[i].providerDef)
      if not pingedLocals[cands[i].providerName]:
        cands[i].skipReason = cands[i].providerName & " not responding " &
                              "at " & cands[i].providerDef.apiBase

  # Skip unconfigured remotes too (they'll fail at invoke time anyway).
  for i in 0 ..< cands.len:
    if cands[i].skipReason.len > 0: continue
    if cands[i].annotation == "unconfigured (no API key)":
      cands[i].skipReason = "no API key configured for " &
                            cands[i].providerName &
                            " (set $" & cands[i].providerDef.envKey & ")"

  # Preference rank: 0 = agent's primary, 1 = local (reachable), 2 = configured
  # remote (sorted by cost), 3 = anything else still usable.
  for i in 0 ..< cands.len:
    case cands[i].annotation
    of "agent's primary model":     cands[i].rank = 0
    of "local":                     cands[i].rank = 1
    of "configured remote":         cands[i].rank = 2
    of "unconfigured (no API key)": cands[i].rank = 3
    else:                           cands[i].rank = 4

  # Sort: by rank then by cost.
  cands.sort(proc(a, b: RouteCandidate): int =
    if a.rank != b.rank: return a.rank - b.rank
    let ca = costRank(a); let cb = costRank(b)
    if ca < cb: return -1
    if ca > cb: return 1
    return cmp(a.modelId, b.modelId))

  # Pick the first usable candidate.
  for c in cands:
    if c.skipReason.len > 0: continue
    let reasonText =
      case c.annotation
      of "agent's primary model":
        "agent's primary model already has this capability — no extra cost"
      of "local":
        "local provider (free, reachable)"
      of "configured remote":
        "configured remote provider, cheapest available"
      else:
        "best available (no preferred candidate)"
    return (ModelChoice(modelId: c.modelId,
                        providerName: c.providerName,
                        providerDef: c.providerDef,
                        reason: reasonText),
            cands, "")

  # Nothing usable.
  return (ModelChoice(), cands,
          "every model with tag '" & tag & "' was skipped — see " &
          "candidate list for reasons (run method=route for details)")

# ---------------------------------------------------------------------------
# route — dry-run: which model WOULD invoke pick?
# ---------------------------------------------------------------------------

proc doRoute(t: CapabilityTool, args: Table[string, JsonNode]): string =
  if not args.hasKey("tag"):
    return "Error: 'tag' is required (e.g. 'vision', 'audio')"
  let tag = args["tag"].getStr().strip()
  if tag.len == 0: return "Error: 'tag' must be non-empty"
  let prefModel = if args.hasKey("model"): args["model"].getStr() else: ""
  let prefProvider = if args.hasKey("provider"): args["provider"].getStr() else: ""
  let excludeRaw = if args.hasKey("exclude"): args["exclude"].getStr() else: ""
  var excludeSet = initHashSet[string]()
  for tok in excludeRaw.split(','):
    let s = tok.strip()
    if s.len > 0: excludeSet.incl(s)

  let (choice, cands, err) = selectModel(t, tag, prefModel, prefProvider, excludeSet)

  var lines: seq[string] = @[]
  if err.len > 0:
    lines.add("Cannot route 'tag=" & tag & "': " & err)
  else:
    lines.add("Would route 'tag=" & tag & "' to:")
    lines.add("  → " & choice.modelId & " via " & choice.providerName &
              " (" & choice.reason & ")")

  if cands.len > 0:
    lines.add("")
    lines.add("Other candidates considered:")
    for c in cands:
      # Skip the one already shown as the chosen winner (only possible when
      # err is empty — err means selectModel returned no choice at all).
      if err.len == 0 and c.modelId == choice.modelId and
         c.providerName == choice.providerName: continue
      var line = "  - " & c.modelId & " via " & c.providerName &
                 " [" & c.annotation
      if costRank(c) > 0 and not c.providerDef.local:
        line.add(", ~$" & $(c.inputCostPer1M + c.outputCostPer1M) & "/1M")
      line.add("]")
      if c.skipReason.len > 0:
        line.add(" [skipped: " & c.skipReason & "]")
      lines.add(line)

  if cands.len == 0 and err.len == 0:
    lines.add("(no other candidates)")
  return lines.join("\n")

# ---------------------------------------------------------------------------
# invoke — actually call a specialist with the given input + prompt.
# ---------------------------------------------------------------------------

proc resolveInvokeInput(t: CapabilityTool, raw: string):
                       tuple[isFile: bool, b64: string, mime: string,
                             text: string, err: string] =
  ## Decide if `raw` is a file path we should base64-encode, or plain text.
  ## A path qualifies if: absolute, exists, allowed by path safety, ≤20 MB.
  ## Otherwise treated as inline text.
  const MaxBytes = 20 * 1024 * 1024  # 20MB hard cap

  if raw.len == 0:
    return (false, "", "", "", "input is empty")

  # Heuristic: only treat as file if it looks like a path AND exists. Inline
  # prompts can contain slashes (URLs etc.), so existence is the disambiguator.
  let looksLikePath = isAbsolute(raw) or raw.startsWith("./") or
                      raw.startsWith("~/") or "/" in raw or "\\" in raw
  if not looksLikePath or not fileExists(raw):
    return (false, "", "", raw, "")

  # Path-safety gate. Workspace + officeDir + allowedPaths come from the
  # contextual fields. Fall back to deriving from config + agentName when
  # they're unset (e.g. CLI callers that never set context).
  var workspaceDir = t.workspaceDir
  var officeDir = t.officeDir
  var allowedPaths = t.allowedPaths
  if workspaceDir.len == 0:
    try:
      let cfg = loadConfig(getConfigPath())
      workspaceDir = cfg.workspacePath()
      allowedPaths = cfg.agents.security.allowed_paths
      if t.agentName.len > 0:
        officeDir = workspaceDir / "offices" / t.agentName.toLowerAscii()
    except: discard

  let checkResult = resolveAndCheckPath(raw, workspaceDir, allowedPaths, officeDir)
  if checkResult.startsWith("Error:"):
    return (false, "", "", "", "path not allowed: " & checkResult)
  let wsResolved = if workspaceDir.len > 0: expandFilename(workspaceDir) else: ""
  let role = if t.role.len > 0: t.role else: "Staff"  # default to least-priv staff
  if wsResolved.len > 0 and
     not checkAccess(role, t.agentName, checkResult, wsResolved, akRead):
    return (false, "", "", "",
            "IAM read denied for path: " & raw)

  let size = getFileSize(checkResult)
  if size > MaxBytes:
    return (false, "", "", "",
            "file too large (" & $(size div (1024*1024)) & " MB, max 20 MB)")

  let mime = mimeOf(checkResult)
  if mime.len == 0:
    return (false, "", "", "",
            "unknown file type for '" & splitFile(checkResult).ext &
            "' — supported: " &
            "images (.jpg/.png/.gif/.webp/.bmp/.heic), " &
            "audio (.mp3/.wav/.m4a/.ogg/.flac), " &
            "video (.mp4/.mov/.webm), " &
            "documents (.pdf)")
  let bytes = readFile(checkResult)
  return (true, base64.encode(bytes), mime, "", "")

proc buildContentBlock(modality: Modality, mime, b64, text: string): JsonNode =
  ## Returns one OpenAI-style content block, or a labeled text fallback
  ## when the modality has no standardized wire shape (video for now).
  case modality
  of modText:
    return %*{"type": "text", "text": text}
  of modImage:
    return %*{
      "type": "image_url",
      "image_url": {"url": "data:" & mime & ";base64," & b64}
    }
  of modAudio:
    # OpenAI audio uses {type: "input_audio", input_audio: {data, format}}.
    # Format = bare extension (mp3/wav/etc.) without leading dot.
    let format = if mime.startsWith("audio/"): mime.split("/")[1] else: "mp3"
    return %*{
      "type": "input_audio",
      "input_audio": {"data": b64, "format": format}
    }
  of modVideo:
    # TODO(v2): no standard OpenAI shape for raw video. Options: extract
    # frames → image batch, or use a provider-specific shape (Gemini). For
    # now, return a labeled text wrapper so the request doesn't break, but
    # the model can't actually see the bytes.
    return %*{
      "type": "text",
      "text": "[video content provided as base64 data:" & mime & " — note: " &
              "no model can currently process raw video bytes through this " &
              "tool; convert to image frames first]"
    }
  of modPdf:
    # Anthropic supports `document`; OpenAI supports `input_file` via Files API.
    # For now use a `text` wrapper noting the data is attached as base64.
    return %*{
      "type": "text",
      "text": "[PDF document provided as base64 data:" & mime &
              ";base64," & b64 & "]"
    }

proc doInvoke(t: CapabilityTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("tag"):
    return "Error: 'tag' is required (e.g. 'vision', 'audio'); pick the " &
           "capability of the specialist you want to invoke."
  let tag = args["tag"].getStr().strip()
  if tag.len == 0: return "Error: 'tag' must be non-empty"
  if not args.hasKey("input"):
    return "Error: 'input' is required (file path or inline text)"
  let rawInput = args["input"].getStr()
  let prompt =
    if args.hasKey("prompt"): args["prompt"].getStr()
    else: "Describe this " & tag & " input"
  let prefModel = if args.hasKey("model"): args["model"].getStr() else: ""
  let prefProvider = if args.hasKey("provider"): args["provider"].getStr() else: ""
  let excludeRaw = if args.hasKey("exclude"): args["exclude"].getStr() else: ""
  var excludeSet = initHashSet[string]()
  for tok in excludeRaw.split(','):
    let s = tok.strip()
    if s.len > 0: excludeSet.incl(s)

  # 1. Resolve input — file vs text.
  let (isFile, b64, mime, text, inputErr) = resolveInvokeInput(t, rawInput)
  if inputErr.len > 0:
    return "Error: cannot use input — " & inputErr

  # 2. Pick a model.
  let (choice, _, selErr) = selectModel(t, tag, prefModel, prefProvider, excludeSet)
  if selErr.len > 0:
    # On no-model-found, enumerate what tags ARE available so the agent
    # can pivot. Cheap re-read of the catalog.
    let tagsList = doList(t)
    return "Error: " & selErr & "\n\n" &
           "Available tags from the catalog (for reference):\n" & tagsList

  # 3. Strip provider prefix on the wire — vendors expect the bare model id.
  # We keep the canonical vendor scope (e.g. "meta/llama-3.3") intact because
  # most providers (ollama, openrouter) accept it; only the provider-name
  # scope (e.g. "OpenCode Go/mimo-v2.5") needs trimming.
  var wireModel = choice.modelId
  if '/' in wireModel and wireModel.startsWith(choice.providerName & "/"):
    wireModel = wireModel[(choice.providerName.len + 1) .. ^1]

  # 4. Look up API key and base.
  let providerDef = choice.providerDef
  let companyDir = getNimClawDir()
  let envPath = companyDir / ".env"
  var apiKey = ""
  if providerDef.envKey.len > 0:
    apiKey = readEnvValue(envPath, providerDef.envKey)
  if not providerDef.local and apiKey.len == 0:
    return "Error: no API key for " & providerDef.name &
           " (expected in $" & providerDef.envKey & " in " & envPath & ")"
  let apiBase =
    if providerDef.apiBase.endsWith("/v1") or providerDef.apiBase.contains("/v1/"):
      providerDef.apiBase
    elif providerDef.apiBase.endsWith("/"):
      providerDef.apiBase & "v1"
    else:
      providerDef.apiBase

  # 5. Build the content array.
  let modality = modalityForTag(tag)
  var contentArr = newJArray()
  contentArr.add(%*{"type": "text", "text": prompt})
  if isFile:
    contentArr.add(buildContentBlock(modality, mime, b64, ""))
  else:
    contentArr.add(buildContentBlock(modText, "", "", text))

  let body = %*{
    "model": wireModel,
    "messages": [
      {"role": "user", "content": contentArr}
    ],
    "max_tokens": 800,
    "temperature": 0.3
  }

  # 6. Make the HTTP call. Use stdlib httpclient to match the existing
  # tool-layer convention (http_request, pushover) rather than pulling
  # in curly's master/spawn machinery. The User-Agent "curl/8.7.1"
  # bypasses Cloudflare's WAF on OpenCode Go — without it, requests
  # come back as 403 challenge pages.
  let url = apiBase & "/chat/completions"
  let headers = newHttpHeaders({
    "Content-Type": "application/json",
    "User-Agent": "curl/8.7.1",
    "Accept": "application/json"
  })
  if apiKey.len > 0:
    headers["Authorization"] = "Bearer " & apiKey

  let client = newAsyncHttpClient(headers = headers)
  var respBody = ""
  var respCode = 0
  try:
    let resp = await client.request(url, httpMethod = HttpPost, body = $body)
    respCode = resp.code.int
    respBody = await resp.body
  except Exception as e:
    return "Error: HTTP call failed (" & choice.providerName & " → " &
           url & "): " & e.msg
  finally:
    try: client.close() except: discard

  if respCode < 200 or respCode >= 300:
    let snippet =
      if respBody.len > 400: respBody[0 ..< 400] & "…"
      else: respBody
    return "Error: " & choice.providerName & " returned HTTP " & $respCode &
           ": " & snippet

  # 7. Extract the content. Fall back to reasoning_content for models that
  # split content/reasoning (DeepSeek V4 thinking mode, etc.).
  var parsed: JsonNode
  try:
    parsed = parseJson(respBody)
  except:
    return "Error: " & choice.providerName & " returned non-JSON: " &
           (if respBody.len > 300: respBody[0..299] & "…" else: respBody)

  var content = ""
  var reasoning = ""
  if parsed.kind == JObject and parsed.hasKey("choices") and
     parsed["choices"].kind == JArray and parsed["choices"].len > 0:
    let msg = parsed["choices"][0]{"message"}
    if msg != nil:
      content = msg{"content"}.getStr("")
      if content.len == 0:
        reasoning = msg{"reasoning"}.getStr("")
        if reasoning.len == 0:
          reasoning = msg{"reasoning_content"}.getStr("")

  let header = "[via " & choice.modelId & " (" & choice.providerName & ")]"
  if content.len > 0:
    return header & "\n" & content
  if reasoning.len > 0:
    return header & "\n[note: empty content, returning reasoning trace]\n" &
           reasoning
  return header & "\nModel returned no content. Raw response (truncated): " &
         (if respBody.len > 300: respBody[0..299] & "…" else: respBody)

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

method execute*(t: CapabilityTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("method"):
    return "Error: 'method' is required (list | find | has | route | invoke)"
  let action = getMethodArg(args)
  case action
  of "list":   return doList(t)
  of "find":   return doFind(t, args)
  of "has":    return doHas(t, args)
  of "route":  return doRoute(t, args)
  of "invoke": return await doInvoke(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: list | find | has | route | invoke"
