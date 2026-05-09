---
name: tools
version: 1.0.0
description: "Manage your capability surface: discover hidden tools by intent, delegate to peers, forge new MCP tools when nothing fits, capture reusable workflows as skills. The umbrella skill for everything tool-related."
operations:
  - find
  - delegate
  - forge
  - learn
requires:
  tools:
    - find_tools
    - mcp
    - delegate
    - skill
    - write_file
    - shell
  deps:
    - package: nim
      manager: system
  env: []
---

# tools — Manage Your Capability Surface

This skill is about the agent's relationship to its tools. Five faces:

- **What you have** — knowing your active surface
- **What's hidden** — discovering tools by intent (find_tools)
- **What a peer has** — delegating instead of authoring
- **What doesn't exist yet** — forging new MCP tools
- **What's worth saving** — capturing workflows as skills

The mistake to avoid: bouncing through random tool calls or burning iterations on guesses. Every "I need to do X" starts with a deliberate decision tree.

## The decision tree, in order

1. **Memory check.** `memory action=recall scope=all query="..."` — you might already remember how you did this. Cheapest, cited.
2. **Active list.** Scan your current tool list. Don't search for what's already in front of you.
3. **Hidden discovery.** `find_tools query="..."` — most tools are hidden by default to save context. Search by **INTENT**, not tool name; the framework's `searchKeywords` field maps task vocabulary to tool names (e.g., "remind" → `scheduler`, "modify" → `edit_file`).
4. **Peer delegation.** `delegate agent=X prompt="..."` — if a peer agent has the capability and you don't, ask them. Cheaper than forging; respects trust boundaries.
5. **Forge new.** `mcp action=forge ...` — create a new MCP tool. Heavy: writes Nim, compiles, registers a server, adds tokens to your context. Reserve for genuinely new capabilities you'll use ≥3 times.
6. **Capture as skill.** `skill action=learn ...` — when an ad-hoc workflow has been useful 3+ times, the workflow itself deserves a SKILL.md. Forge creates *capability*; learn creates *discoverability*.

## Searching by intent — task-vocabulary → tool

You don't always know the right tool name. Search by what you want to DO:

| Intent | Try keywords | Likely match |
|---|---|---|
| modify a file | `modify`, `change`, `update`, `rewrite` | `edit_file` |
| remember something | `remember`, `save`, `note`, `store` | `memory` action=store |
| recall past events | `history`, `past`, `recall`, `earlier` | `memory` action=recall scope=all |
| remind me later | `remind`, `later`, `timer`, `delay` | `scheduler` |
| fetch a webpage | `fetch`, `download`, `url`, `http` | `web` action=fetch |
| search the internet | `search`, `google`, `lookup` | `web` action=search |
| open a website | `browser`, `open`, `site` | `browser` action=open |
| interact with a page | `click`, `automate`, `navigate`, `form` | `browser` action=automate |
| run a shell command | `shell`, `bash`, `run`, `execute` | `exec` |
| commit code | `commit`, `push`, `branch`, `diff` | `git` |
| extract from JSON | `json`, `parse`, `filter`, `query` | `json_query` |
| describe an image | `describe image`, `vision`, `ocr` | `image_analyze` |
| verify a claim | `verify`, `prove`, `evidence` | `memory` action=verify or `workstation` action=verify_project |

If nothing matches: **broaden before narrowing.** Swap synonyms, drop terms, try a different intent angle. If `find_tools` still returns no useful results, the capability genuinely doesn't exist — proceed to delegate or forge.

## When to forge — and when NOT

**Forge when** all of these hold:
- No existing claw tool or MCP server covers the capability (verified via `find_tools`, not assumed)
- The need is a **computation / API wrapper / hardware access** — not a sequence of existing tools
- You'll use it ≥3 times (forging costs tokens and compile time; one-shots aren't worth it)
- Your agent has `workstation: true`

**Don't forge for:**
- One-shot computations → use `exec` with `nim e` or `python -c`
- Wrapping an HTTP API → use `web action=request` directly
- **Chaining existing tools** → that's a workstation skill, call `skill action=learn` instead

## When to delegate (vs forge yourself)

**Delegate when:**
- A specific peer agent already has the capability
- The task crosses your role boundary (e.g., admin operations from a non-admin agent)
- The peer's domain expertise materially helps (e.g., Lexi for solar, Devon for code)

**Don't delegate when:**
- The peer is overloaded or AFK (sync delegate blocks; deferred queues to next heartbeat)
- The capability is a one-step trivial call YOU could make
- You'd be doing this 100x a day — that's a forge candidate

## When to learn (capture as skill, vs just remembering)

**Learn when:**
- You've executed the same tool sequence 3+ times
- You'll execute it again, and getting it right matters (e.g., a deployment workflow)
- The pattern has clear triggers ("when user asks X, do Y, Z, W")
- The pattern is reusable across sessions

**Don't learn when:**
- It's a one-off or rare combination
- The "skill" is really just a memory entry — use `memory action=store` instead
- You can't articulate clear triggers — wait until the pattern crystallizes

## Forge mechanics: one server, many servers?

Each MCP server is a separate process. Each tool has its own schema visible to the LLM. Two costs you trade:

- **System resources** — each server ≈ 10 MB RAM + process overhead.
- **LLM tokens** — each tool schema ≈ 80 tokens. Grouping related tools in one server doesn't reduce schemas, but gives the LLM clear domain boundaries → fewer wrong calls → fewer retry tokens.

**Rule of thumb:** group tools that share a conceptual domain (e.g. all finance calcs in one `finance-calculator` server). Split into separate servers only when:
- Tools have truly independent lifecycles (one can crash without affecting the other)
- Tools have unrelated purposes and shouldn't share state
- One has very different dependencies (heavy imports, external state)

## The forge call

`mcp action=forge` has two modes:

**`logic_only: true` (recommended)** — you write tool logic; forge wraps the server/transport boilerplate:

```
action: forge
name: finance-calculator
logic_only: true
code: |
  import std/math

  mcpTool:
    proc compound_interest(principal: float, rate: float, years: int): float =
      ## Compute compound interest with annual compounding.
      ## - principal: base amount in dollars
      ## - rate: percent rate (e.g. 5 for 5%, not 0.05)
      ## - years: integer number of years
      result = principal * pow(1.0 + rate/100.0, years.float)

  mcpTool:
    proc simple_interest(principal: float, rate: float, years: int): float =
      ## Compute simple interest
      ## - principal: base amount
      ## - rate: percent rate
      ## - years: integer number of years
      result = principal * rate / 100.0 * years.float
```

**`logic_only: false`** — you provide a complete `mcpServer(...)` block. Rarely needed.

Forge handles: compiling with `nim c`, hoisting imports to top level if you put them inside blocks, writing the binary, registering the server, and logging invocations.

## What to put in proc doc comments (forge schema)

The forge macro reads `##` doc comments after each proc's `=` to build the MCP schema the LLM sees. Be specific:

```
proc compound_interest(principal: float, rate: float, years: int): float =
  ## Compute compound interest with annual compounding.
  ## - principal: base amount in dollars
  ## - rate: percent rate (e.g. 5 for 5%, not 0.05)
  ## - years: integer number of years
```

The first `##` line becomes the tool description. Lines starting `## - paramName:` become parameter descriptions. The LLM sees these in its tool list — vague comments → wrong-param guesses.

## Forged tool lifecycle

- Forged binaries live in `<officeDir>/workstation/mcp/<name>/bin/<name>` — Tier 3 artifact
- Source kept at `<officeDir>/workstation/mcp/<name>/src/<name>.nim`
- Registration persists across sessions (auto-loaded on gateway startup)
- Purge anytime with `mcp action=purge name=<name>`
- Tools remain scoped to YOUR workstation — other agents can't invoke them
- When confident, request graduation for human review

## Common pattern: forge → learn

Forge a tool, then teach yourself when to use it.

1. `mcp action=forge` → new MCP server with your compute primitives
2. `skill action=learn` → SKILL.md that tells future-you when to reach for those primitives and how to combine them with `reply` / `mail` / etc.

The forge creates *capability*. The learn creates *discoverability*.

## Anti-patterns

- **Don't forge for tools that already exist via composition.** Run `find_tools` first.
- **Don't search for tools you already have active.** Check your tool list.
- **Don't delegate when the peer doesn't have the capability either.** Ask them what they have first.
- **Don't learn-as-skill for one-off workflows.** Wait for the 3rd repetition.
- **Don't fall back to `exec` when a structured tool already does the job.** `git`, `web`, `mcp` etc. carry safety wrappers `exec` skips.
- **Don't blindly call random tools to "see what they do."** `find_tools` returns descriptions without burning iterations.

Practiced over time, the decision tree above becomes invisible — but writing it out keeps the discipline visible while it's still being learned.
