## LLM provider registry.
##
## Providers ship with claw as `res/providers.json` (see nimble `installDirs`
## for how it's laid out after install). Per-company additions/overrides go
## to `<companyDir>/providers.json` and layer on top by name.
##
## Lookup priority at runtime:
##   1. `<companyDir>/providers.json`  — company-specific additions/overrides
##   2. `res/providers.json` shipped with claw — the default catalog
##   3. Hardcoded fallback below — last resort when the distribution's
##      res/ is missing (e.g. unpackaged dev tree w/o the file)
##
## The file is loaded once and cached.

import std/[os, strutils, json, tables]

type
  ProviderDef* = object
    name*: string
    envKey*: string
    apiBase*: string
    authHeader*: string
    verifyPath*: string
    defaultModel*: string
    local*: bool

# ─── Hardcoded fallback ─────────────────────────────────────────
# Used only if res/providers.json can't be located. Kept intentionally
# small — maintained copies of a handful of major providers so a damaged
# or missing distribution still boots something usable.

const FallbackProviders* = [
  ProviderDef(name: "deepseek",  envKey: "DEEPSEEK_API_KEY",
              apiBase: "https://api.deepseek.com/v1",
              authHeader: "Authorization: Bearer",
              verifyPath: "/models",
              defaultModel: "deepseek-chat"),
  ProviderDef(name: "openai",    envKey: "OPENAI_API_KEY",
              apiBase: "https://api.openai.com/v1",
              authHeader: "Authorization: Bearer",
              verifyPath: "/models",
              defaultModel: "gpt-4o-mini"),
  ProviderDef(name: "anthropic", envKey: "ANTHROPIC_API_KEY",
              apiBase: "https://api.anthropic.com/v1",
              authHeader: "x-api-key",
              verifyPath: "/models",
              defaultModel: "claude-3-5-sonnet-latest"),
  ProviderDef(name: "ollama",    envKey: "",
              apiBase: "http://localhost:11434/v1",
              authHeader: "",
              verifyPath: "/models",
              defaultModel: "llama3.2", local: true),
]

# ─── Path resolution for the shipped res/providers.json ─────────

proc findDistributionResource*(relativePath: string): string =
  ## Locate a file shipped in the claw distribution. Tries several paths
  ## so it works in: dev (running from the repo), nimble-installed (bin +
  ## sibling share dirs), symlinked binaries, AND NimScript evaluation
  ## (which the `claw co update` rebuild path uses to run BASE.nims).
  # 1. CWD-relative (dev: running from repo root). Works in both compiled
  #    and NimScript contexts.
  let cwd = getCurrentDir() / relativePath
  if fileExists(cwd): return cwd
  # 2. Walk up from this source file (`src/claw/providers/registry.nim`)
  #    to find the framework root, then check the res/ sibling. Works in
  #    BOTH compiled (returns build-time source path) AND NimScript
  #    (returns the actual interpreted source path — useful when the
  #    DSL is evaluated as a subprocess inside `claw co update`).
  let sourceFile = currentSourcePath()
  if sourceFile.len > 0:
    # registry.nim sits at <root>/src/claw/providers/registry.nim → up 4
    let frameworkRoot = sourceFile.parentDir.parentDir.parentDir.parentDir
    let viaSource = frameworkRoot / relativePath
    if fileExists(viaSource): return viaSource
  # 3. Next to the binary (compiled context only — NimScript has no `getAppDir`).
  when not defined(nimscript) and not defined(js):
    let appDir = getAppDir()
    for candidate in [
      appDir / relativePath,                 # e.g. pkgs/claw-X.Y.Z/res/providers.json
      appDir.parentDir / relativePath,       # parent dir
      appDir / ".." / relativePath,
    ]:
      if fileExists(candidate): return candidate
  # 4. Nimble-specific: ~/.nimble/pkgs/<name>*/res/providers.json
  let nimblePkgs = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble") / "pkgs2"
  if dirExists(nimblePkgs):
    for kind, path in walkDir(nimblePkgs):
      if kind == pcDir:
        let base = path.lastPathPart
        if base.startsWith("claw-") or base.startsWith("nimclaw-"):
          let candidate = path / relativePath
          if fileExists(candidate): return candidate
  # Not found
  return ""

# ─── JSON parsing ───────────────────────────────────────────────

proc parseProvider(j: JsonNode): ProviderDef =
  result.name = j{"name"}.getStr("")
  result.envKey = j{"envKey"}.getStr("")
  result.apiBase = j{"apiBase"}.getStr("")
  result.authHeader = j{"authHeader"}.getStr("Authorization: Bearer")
  result.verifyPath = j{"verifyPath"}.getStr("/v1/models")
  result.defaultModel = j{"defaultModel"}.getStr("")
  result.local = j{"local"}.getBool(false)

proc loadProvidersFile*(path: string): seq[ProviderDef] =
  ## Parse a providers JSON file into a seq of defs. Returns empty on error.
  if not fileExists(path): return @[]
  try:
    let j = parseJson(readFile(path))
    let arr = j{"providers"}
    if arr == nil or arr.kind != JArray: return @[]
    for entry in arr:
      let p = parseProvider(entry)
      if p.name.len > 0: result.add(p)
  except: discard

# Write side is compiled-binary only — the DSL evaluation path (NimScript)
# never writes the registry, only reads it, and NimScript's VM doesn't allow
# `createDir`. Guarding here lets clawdsl.nim `import providers/registry`
# without dragging in unsupported procs.
when not defined(nimscript) and not defined(js):
  proc providerToJson(p: ProviderDef): JsonNode =
    result = newJObject()
    result["name"] = %p.name
    if p.envKey.len > 0: result["envKey"] = %p.envKey
    if p.apiBase.len > 0: result["apiBase"] = %p.apiBase
    if p.authHeader.len > 0: result["authHeader"] = %p.authHeader
    if p.verifyPath.len > 0: result["verifyPath"] = %p.verifyPath
    if p.defaultModel.len > 0: result["defaultModel"] = %p.defaultModel
    if p.local: result["local"] = %true

  proc saveProvidersFile*(path: string, providers: seq[ProviderDef]) =
    ## Write the full provider list to the given JSON file (res/ or company).
    ## Uses schema_version 1, matching the distribution format.
    let parent = path.parentDir
    if parent.len > 0 and not dirExists(parent): createDir(parent)
    var arr = newJArray()
    for p in providers: arr.add(providerToJson(p))
    let wrapper = %*{"schema_version": 1, "providers": arr}
    writeFile(path, pretty(wrapper, 2))

# ─── Cached distribution (res/) providers ───────────────────────

var cachedBuiltin: seq[ProviderDef]
var cachedBuiltinLoaded = false

proc invalidateBuiltinCache*() =
  ## Force the next builtinProviders() call to re-read from disk.
  ## Called after writing to res/providers.json.
  cachedBuiltinLoaded = false
  cachedBuiltin = @[]

proc builtinProvidersPath*(): string =
  findDistributionResource("res" / "providers.json")

proc builtinProviders*(): seq[ProviderDef] =
  ## The distribution-shipped provider catalog.
  if cachedBuiltinLoaded: return cachedBuiltin
  let resPath = findDistributionResource("res" / "providers.json")
  if resPath.len > 0:
    cachedBuiltin = loadProvidersFile(resPath)
  if cachedBuiltin.len == 0:
    # Distribution file missing or unparseable — fall back to compiled-in
    for p in FallbackProviders: cachedBuiltin.add(p)
  cachedBuiltinLoaded = true
  return cachedBuiltin

# ─── Lookups ────────────────────────────────────────────────────
#
# Providers are a global catalog — one list shared across all companies on
# this install. Per-company `.env` files still hold per-company API keys,
# but the provider DEFINITIONS (endpoint URLs, auth styles) are the same
# everywhere. Stored in res/providers.json as the single source of truth.

proc effectiveProviders*(): seq[ProviderDef] =
  ## The full provider catalog. Same as builtinProviders — kept for call-site
  ## readability (the name reads better than "builtinProviders" at usage).
  builtinProviders()

proc normalizeName(s: string): string =
  ## Provider name lookup normalization: lowercase + space→hyphen.
  ## Lets `"opencode-go"` (slug form, as operators commonly type) match
  ## `"OpenCode Go"` (display form, as it appears in providers.json).
  ## Same rule the DSL uses (see `normalizeProviderKey` in clawdsl.nim).
  result = newStringOfCap(s.len)
  for c in s:
    if c == ' ': result.add('-')
    else: result.add(c.toLowerAscii())

proc findProvider*(name: string): (ProviderDef, bool) =
  ## Case-insensitive lookup. Also normalizes spaces↔hyphens so the
  ## same provider can be addressed as `OpenCode Go` (display name in
  ## providers.json) or `opencode-go` (the slug operators commonly type).
  let lc = normalizeName(name)
  for p in effectiveProviders():
    if normalizeName(p.name) == lc: return (p, true)
  return (ProviderDef(), false)

proc providerNames*(): seq[string] =
  ## For help text, search, completion.
  for p in effectiveProviders(): result.add(p.name)
