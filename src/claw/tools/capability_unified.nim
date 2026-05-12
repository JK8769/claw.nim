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
## `capability action=has model=<current> tag=vision` and refuse early
## if the answer is no.
##
##   action=list  — every distinct capability tag in the catalog,
##                  case-folded and deduped (the navigator's full
##                  instrument panel).
##   action=find  — which models offer this capability? Returns model
##                  ids with their providers. Accepts the same narrowing
##                  filters as `model action=list` (provider, vendor,
##                  family).
##   action=has   — boolean: does <model> have <tag>? Cheap, fast,
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
##                        "(action=list|verify|info). Read-only — keys stay on disk.",
##          tags = @["admin", "providers", "diagnostics", "core"],
##          searchKeywords = @["llm", "api", "key", "endpoint", "openai",
##                              "anthropic", "deepseek", "ollama", "auth",
##                              "verify", "credentials"],
##          domain = "admin",
##          default = true, heartbeatSafe = false, category = "admin"),
##     spec(name = "model",
##          description = "LLM models (the 'ship'): list/info/current " &
##                        "(action=list|info|current). Includes capabilities, " &
##                        "context, pricing; current = caller agent's primary.",
##          tags = @["diagnostics", "providers", "models", "core"],
##          searchKeywords = @["llm", "model", "vision", "tool-use", "reasoning",
##                              "context", "pricing", "capability", "vendor",
##                              "current", "primary"],
##          domain = "admin",
##          default = true, heartbeatSafe = false, category = "admin"),
##     spec(name = "capability",
##          description = "find models by capability (action=list|find|has). " &
##                        "Framework-callable feature gate (e.g. vision check " &
##                        "before serving an image).",
##          tags = @["diagnostics", "models", "capability", "core"],
##          searchKeywords = @["tag", "feature", "vision", "tool-use",
##                              "reasoning", "thinking", "multilingual", "audio",
##                              "code", "supports", "gate"],
##          domain = "admin",
##          default = true, heartbeatSafe = true, category = "admin"),

import std/[asyncdispatch, json, tables, os, strutils, sets, algorithm]
import ./types
import ./spec
import ../config
import ../providers/[registry as prov_registry, models_catalog]
import ../env_file

const ToolSpec* = spec(
  name = "capability",
  description = "Find models by capability (action=list|find|has). " &
                "Framework-callable feature gate.",
  tags = @["diagnostics", "models", "capability", "core"],
  searchKeywords = @["tag", "feature", "vision", "tool-use", "reasoning",
                      "thinking", "multilingual", "audio", "code", "supports",
                      "gate", "navigator"],
  domain = "admin",
  default = true,
  heartbeatSafe = true,  # pure catalog read, no side effects, safe for
                          # heartbeat ticks (e.g. an autonomous tick that
                          # wants to check what the agent's model can do
                          # before planning).
  category = "admin",
)

type
  CapabilityTool* = ref object of Tool

proc newCapabilityTool*(): CapabilityTool = CapabilityTool()

method name*(t: CapabilityTool): string = "capability"

method description*(t: CapabilityTool): string =
  "Find LLM models by capability (the 'navigator' — your instrument for " &
  "picking a ship by what it can do). Tags include: tool-use, vision, " &
  "reasoning, thinking, multilingual, audio, code. Also usable by the " &
  "framework itself as a feature gate (e.g. 'does the current model " &
  "support vision before we serve an image?').\n\n" &
  "Actions:\n" &
  "  list — every distinct capability tag in the catalog (sorted)\n" &
  "  find — which models have <tag>? Returns ids + providers. Filter " &
              "by provider/vendor/family to narrow.\n" &
  "  has  — boolean check: does <model> have <tag>? Cheap. Returns " &
              "'yes' or 'no' with brief explanation."

method parameters*(t: CapabilityTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["list", "find", "has"],
        "description": "Operation to perform"
      },
      "tag": {
        "type": "string",
        "description": "find/has only — capability tag to look for " &
                       "(case-insensitive). Examples: 'tool-use', 'vision', " &
                       "'reasoning', 'multilingual', 'audio', 'code'."
      },
      "model": {
        "type": "string",
        "description": "has only — model id to check (canonical id or " &
                       "provider-scoped 'provider/model_id')."
      },
      "provider": {
        "type": "string",
        "description": "find only — narrow results to one provider. Optional."
      },
      "vendor": {
        "type": "string",
        "description": "find only — narrow results to one vendor. Optional."
      },
      "family": {
        "type": "string",
        "description": "find only — narrow results to one model family " &
                       "(e.g. 'claude-3', 'llama-3'). Optional."
      }
    },
    "required": %["action"]
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
           "' (after filters). Use `capability action=list` to see " &
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

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

method execute*(t: CapabilityTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (list | find | has)"
  let action = args["action"].getStr()
  case action
  of "list": return doList(t)
  of "find": return doFind(t, args)
  of "has":  return doHas(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: list | find | has"
