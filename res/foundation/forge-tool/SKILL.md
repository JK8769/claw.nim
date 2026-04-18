---
name: forge-tool
version: 1.0.0
description: "Forge a new MCP tool (compiled Nim binary) when no existing tool fits. Use for NEW capabilities. For composing existing tools into a reusable workflow, call the learn_skill tool instead."
operations:
  - forge
  - test
  - promote
requires:
  tools:
    - mcp
    - write_file
    - shell
  deps:
    - package: nim
      manager: system
  env: []
---

# forge-tool — Build Your Own MCP Tools

This skill is about **judgment**: deciding *whether* to forge, *what* to forge, and *how* to group tools. The mechanics (writing boilerplate, hoisting imports, schema derivation) are handled by the `mcp action=forge` tool — you don't need to memorize them.

## When to forge — and when NOT

**Forge when** all of these hold:
- No existing claw tool or MCP server covers the capability
- The need is a **computation / API wrapper / hardware access** — not a sequence of existing tools
- You'll use it more than once (forging costs tokens and compile time; one-shots aren't worth it)
- Your agent has `workstation: true`

**Don't forge for:**
- One-shot computations → use `shell` with `nim e` or `python -c`
- Wrapping an HTTP API → use `http_request` directly
- **Chaining existing tools** → that's a workstation skill, call `learn_skill(...)` instead

## The big design choice: one server, many servers?

Each MCP server is a separate process. Each tool has its own schema visible to the LLM. You're trading two costs:

- **System resources** — each server ≈ 10 MB RAM + process overhead. More servers = more memory.
- **LLM tokens** — each tool schema ≈ 80 tokens in context. Grouping related tools in one server doesn't reduce schemas, but gives the LLM clear domain boundaries so it picks the right tool faster (fewer wrong calls = fewer retry tokens).

**Rule of thumb:** group tools that share a conceptual domain (e.g. all finance calcs in one `finance-calculator` server). Split into separate servers only when:
- Tools have truly independent lifecycles (one can crash without affecting the other)
- Tools have unrelated purposes and shouldn't share state
- One tool has very different dependencies (heavy imports, external state)

## The forge call

Call the `mcp` tool with `action: "forge"`. Two modes:

**`logic_only: true` (recommended)** — you write just the tool logic; forge wraps the server/transport boilerplate:

```
action: forge
name: finance-calculator
logic_only: true
code: |
  import std/math

  mcpTool:
    proc compound_interest(principal: float, rate: float, years: int): float =
      ## Compute compound interest
      ## - principal: base amount
      ## - rate: percent rate (e.g. 5 for 5%)
      ## - years: number of years
      result = principal * pow(1.0 + rate/100.0, years.float)

  mcpTool:
    proc simple_interest(principal: float, rate: float, years: int): float =
      ## Compute simple interest
      ## - principal: base amount
      ## - rate: percent rate
      ## - years: number of years
      result = principal * rate / 100.0 * years.float
```

**`logic_only: false`** — you provide a complete `mcpServer(...)` block. Rarely needed.

Forge handles: compiling with `nim c`, hoisting imports to top level if you put them inside blocks, writing the binary to your workstation, registering the server, and logging invocations.

## What to put in proc doc comments

The forge macro reads the `##` doc comments after each proc's `=` to build the MCP schema the LLM sees. Be specific:

```
proc compound_interest(principal: float, rate: float, years: int): float =
  ## Compute compound interest with annual compounding.
  ## - principal: base amount in dollars
  ## - rate: percent rate (e.g. 5 for 5%, not 0.05)
  ## - years: integer number of years
```

The first `##` line becomes the tool description. Lines starting `## - paramName:` become parameter descriptions. The LLM sees these in its tool list — if you're vague, it'll guess wrong params.

## Lifecycle

- Forged binaries live in `<officeDir>/workstation/mcp/<name>/bin/<name>` — Tier 3 artifact
- Source is kept at `<officeDir>/workstation/mcp/<name>/src/<name>.nim`
- Registration persists across sessions (auto-loaded on gateway startup)
- Purge anytime with `mcp action=purge name=<name>`
- Tools remain scoped to YOUR workstation — other agents can't invoke them
- When confident, request graduation for human review

## Pairing with the learn_skill tool

Common pattern: forge a tool, then teach yourself when to use it.

1. `mcp action=forge` → new MCP server with your compute primitives
2. `learn_skill(...)` → SKILL.md that tells future-you when to reach for those primitives and how to combine them with `reply`

The forge creates *capability*. The `learn_skill` call creates *discoverability*.
