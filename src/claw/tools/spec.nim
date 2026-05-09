## Tool spec — single source of truth for tool metadata.
##
## Every tool source file declares a `const ToolSpec*: ToolSpec = ToolSpec(...)`
## near the top. This const carries everything the framework needs to know
## about the tool: name, description, tags, default-status, heartbeat-safety,
## domain, category. Reading any tool source = reading its full metadata.
##
## The framework's central manifest module (`tools/registry/manifest.nim`)
## imports every tool module and aggregates these consts into `AllTools`.
## Derived sets — `defaultToolNames()`, `heartbeatSafeToolNames()` — are
## computed from the consts, not maintained by hand.
##
## Conventions:
##
##   - `name` MUST match what `method name*(t: T): string` returns at
##     runtime. Boot-time validation enforces this; a unit test rounds it
##     trip per tool. Mismatches mean either the const or the method is
##     wrong — fix the source.
##
##   - `domain` MUST match the subdirectory the tool lives in (e.g. a tool
##     in `src/claw/tools/agent/foo.nim` has `domain: "agent"`).
##     Denormalized for fast filtering by `claw tools list --domain ...`.
##
##   - `default: true` means the tool is auto-granted to every agent at
##     `claw co update` time. Mirrors what was previously hand-listed in
##     `clawdsl.nim::defaultTools`. Per-agent `tool_grants.json` overlays
##     can add or revoke individually.
##
##   - `heartbeatSafe: true` means the tool is in the allowlist of tools
##     callable during heartbeat ticks (low-trust system sender). Mirrors
##     `tools/registry.nim::HeartbeatAllowedTools`.
##
##   - `tags` are categorization markers used by `find_tools` discovery
##     and search-hint match. Order doesn't matter; use 1-4 short words.
##
##   - `category` is a human-readable grouping for `claw tools list` UI
##     ("self-management", "comm", "system", etc.). Less granular than
##     `domain`. Optional but recommended for legibility.
##
##   - `version` is reserved for future compat checks. Always "1.0.0" for
##     framework tools shipped today; bump if a tool's interface changes
##     in a way that breaks existing skills' `requires.tools` declarations.

type
  ToolSpec* = object
    name*: string             ## canonical tool name; must equal `method name*(t)`
    description*: string      ## one-line description; LLM sees this in tool listings
    tags*: seq[string]        ## categorical (e.g. ["filesystem", "core"]); drives
                              ## `claw tools list --domain` filtering and grouping
    searchKeywords*: seq[string]  ## free-form synonyms / task vocabulary that
                              ## might NOT appear in name/description/tags but
                              ## matches user intent. E.g. edit_file's keywords
                              ## include "modify", "change", "update", "rewrite"
                              ## so an agent searching with task-language finds it.
                              ## Distinct from `tags` (categorical structure) —
                              ## think of these as the search-ranking surface.
    domain*: string           ## subdirectory under src/claw/tools/ (denormalized)
    default*: bool            ## auto-grant to every agent at config-resolve time
    heartbeatSafe*: bool      ## allowed during heartbeat ticks (system sender)
    externalAllowed*: bool    ## guest/customer trust floor — callable by external
                              ## (low-trust) callers without an explicit grant.
                              ## Drives both `ExternalAllowedTools` (runtime gate)
                              ## and the default `Guest` role grant in clawdsl
                              ## resolver. Keep this conservative: only tools
                              ## with no privileged side effects.
    category*: string         ## human-readable bucket (self-management, comm, ...)
    version*: string          ## reserved for compat checks; "1.0.0" for current

# Shorthand for the common case — most fields default cleanly.
proc spec*(
    name: string,
    description: string,
    tags: seq[string] = @[],
    searchKeywords: seq[string] = @[],
    domain: string = "",
    default = false,
    heartbeatSafe = false,
    externalAllowed = false,
    category: string = "",
    version: string = "1.0.0"): ToolSpec =
  ## Helper for declaring a `ToolSpec` const in a tool source file.
  ## Every framework tool should declare:
  ##
  ##   const ToolSpec* = spec(
  ##     name = "foo",
  ##     description = "...",
  ##     domain = "agent",
  ##     default = true,
  ##     heartbeatSafe = true,
  ##     category = "self-management",
  ##     tags = @["agent", "core"]
  ##   )
  ToolSpec(
    name: name,
    description: description,
    tags: tags,
    searchKeywords: searchKeywords,
    domain: domain,
    default: default,
    heartbeatSafe: heartbeatSafe,
    externalAllowed: externalAllowed,
    category: category,
    version: version
  )
