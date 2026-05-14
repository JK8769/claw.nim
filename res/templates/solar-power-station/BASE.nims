## solar-power-station — L1 domain template
##
## A starter clawfile for any company operating a fleet of solar power
## stations. Vendor-neutral; multi-vendor capable.
##
## After `claw co create <name> --template solar-power-station --as=<name>`:
##   1. Edit this BASE.nims to customize agent personas, channels, etc.
##   2. Set required env vars in `.env` (see vendor/<your-vendor>/README.md)
##   3. Pick your inverter brand(s):
##        skill "sungrow"             # for SunGrow inverters
##        skill "vendor/huawei"       # for Huawei FusionSolar (when shipped)
##        skill "vendor/goodwe"       # for GoodWe (when shipped)
##      Multiple vendors can coexist — the fleet adapter routes per-plant.
##   4. Run `claw co update` to apply changes; `claw gateway` to start.

import claw/clawdsl

org "REPLACE_WITH_YOUR_ORG_NAME":
  description "Solar power station fleet operator"
  # Replace REPLACE_WITH_YOUR_ORG_NAME with your actual organization name
  # before first `co update`. The --as=<name> flag on `co create` does this
  # automatically.

# ── Providers (LLM backends) ──────────────────────────────────
# Configure at least one provider before running gateway. For providers
# in the framework's res/providers.json catalog (deepseek, opencode-go,
# anthropic, openai, ollama, nvidia, groq), apiBase + apiKey auto-fill
# from the catalog — just declare the name + which models you want.
#
# RECOMMENDED FOR THIS TEMPLATE (validated May 2026 via long-task probes
# on a real solar fleet — see commit history for the benchmark methodology):
#
#   provider "opencode-go":
#     models "mimo-v2.5", "mimo-v2.5-pro",
#            "deepseek-v4-pro", "deepseek-v4-flash",
#            "kimi-k2.5"
#
#   provider "deepseek":
#     models "deepseek-v4-flash", "deepseek-v4-pro"
#
# Why OpenCode Go as primary: at the time of writing it's a $0-tier
# proxy for the recommended mimo-v2.5 series (best balance of latency,
# Chinese fluency, and structured-output quality for solar ops). Direct
# `deepseek` access kept as a robust fallback if the proxy is down.
#
# Override only when needed:
#   provider "anthropic":
#     models "claude-sonnet-4.5"
#   # apiBase + ${ANTHROPIC_API_KEY} auto-filled. To pin a different
#   # endpoint or auth, add `apiBase "..."` / `apiKey "..."` explicitly.

# ── Foundation skills (L0, auto-mirrored from framework) ─────
# These ship with claw.nim and apply to every agent. No declaration needed.
# Currently: `tools` (capability-surface management).

# ── Competencies ──────────────────────────────────────────────
# Role disciplines bundling skills + HANDBOOK.md procedural rules.
# Agents `practices` these to inherit the disciplines.
#
# Full HANDBOOK.md content for each lives in
# workspace/competencies/<name>/HANDBOOK.md — declare here, edit there.

competency "solar-operator":
  description "Solar plant operations expertise: equipment taxonomy (plant→inverter→string), units & ranges, data-acquisition discipline via the solar adapter, verification heuristics, domain terminology."

competency "solar-frontdesk":
  description "Customer-facing routing for solar power station ops: classify depth (simple/analytical/advisory), handle simple lookups via the solar adapter, delegate analytical/advisory to the Analyst. Anti-fabrication discipline."
  skills "delegate"

competency "data-analyst":
  description "Data analysis methodology: hypothesis-driven thinking, train/eval/test discipline, model selection, honest reporting, anti-fabrication. Domain-agnostic — pairs with solar-operator."

competency "technical-communication":
  description "Communication discipline for long-running technical tasks: Phase 0 intake, progress checkpoints, plan announcements, structured result formatting, async-tool handoff."

competency "thinker":
  description "The agent's meta-cognitive practice — tends memory + knowledge + heart together. Heartbeat duties: snapshot wiki, surface knowledge promotion candidates, weekly reflection on partner experiences (with stripEntityIdentifiers backstop), monthly journal consolidation, quarterly visibility audit."

competency "workstation-keeper":
  description "Tends the agent's workstation (repos + projects + items) so it stays clean over time. Heartbeat duties: weekly cross-project audit, weekly stale-done cleanup, monthly stale-repo archive review, monthly link-health check. Pairs with the workstation tool — tool primitive on demand; periodic discipline here. Same shape as thinker over the cognitive stores."

# ── Solar adapter (L1 — vendor-neutral facade) ───────────────
# Exposes the `solar` tool that fans out across installed inverter
# vendors and routes per-plant queries automatically. Agents that
# practice solar-operator or solar-frontdesk should
# `uses "solar-adapter"` to acquire it.
skill "solar-adapter"

# ── Workflow skills (L1, ship with this template) ───────────
# Four vendor-neutral workflows over the `solar` tool. All are
# `loading: lazy` — they stub in agents' catalog by default and
# inline only when explicitly loaded via `skill action=load`.
skill "daily-yield-sync"
skill "monthly-report"
skill "customer-onboarding"
skill "alarm-response"

# ── Equipment vendors (one or more) ──────────────────────────
# Each equipment vendor is its own skill living at
# vendor/equipment/<name>/ in this template (resolver scans
# templates' vendor/<class>/ for bare-name skills). The solar
# adapter routes per-plant queries to the right vendor automatically.
# Multiple vendors can coexist. The shipped `sungrow` is a
# contract-conformant STUB returning mock data — replace its
# src/sungrow.nim with a real implementation (see
# vendor/equipment/sungrow/README.md) for production.
skill "sungrow"

# Example multi-vendor fleet:
#   skill "sungrow"
#   skill "huawei"   # (when added to vendor/equipment/huawei/)
#   skill "goodwe"   # (when added to vendor/equipment/goodwe/)

# ── Distribution skills (L2 opt-in) ──────────────────────────
# Optional skills shipped with claw distribution. Uncomment to install:
#   skill "anygen"          # AI-powered content generation (slides, docs, diagrams)
#   skill "doc-parse"       # Document parsing via AnyGen

# ── Agents ───────────────────────────────────────────────────
# The template ships with two agents pre-wired: a customer-facing
# Frontdesk and a back-office Analyst, with a delegate flow.
# Customize their names, soul, and channel bindings below.

agent "Frontdesk":
  # Validated via probe + live in-loop test on a real solar fleet:
  # mimo-v2.5 is fast (~17s for a multi-step task), $0 via opencode-go
  # at current tier, perfect Chinese fluency. mimo-v2.5-pro as fallback
  # for harder customer questions that benefit from structured output.
  # Operators on deepseek-only can substitute "deepseek-v4-flash" here.
  models "mimo-v2.5", "mimo-v2.5-pro"
  role "Staff"
  identity "Staff"
  jobTitle "Customer Support"
  soul """
  I meet every customer where they are: calm, clear, specific.
  I handle simple lookups directly; I escalate to the Analyst the
  moment a question turns into analysis. I never guess numbers —
  if a reading isn't in the graph, I ask or defer.
  """
  maxDepth 8
  uses "solar-adapter"
  # Frontdesk practices customer-facing disciplines.
  practices "solar-frontdesk", "technical-communication"

  reportsTo "Operator":
    role "boss"
    trustLevel 100

agent "Analyst":
  # Validated via probe + live in-loop test: mimo-v2.5-pro is the
  # standout for analytical workloads — produces structured markdown
  # tables with deviation calculations natively, identifies anomalies
  # with domain-correct reasoning, $0 via opencode-go at current tier.
  # deepseek-v4-flash as fallback for long-doc analysis (1M ctx canonical).
  # Operators on deepseek-only can swap to "deepseek-v4-flash", "deepseek-v4-pro".
  models "mimo-v2.5-pro", "deepseek-v4-flash"
  role "Admin"
  identity "Staff"
  jobTitle "Performance Analyst"
  soul """
  I analyse plant performance against baselines, write clear reports,
  and quote numbers not summaries. I never claim a finding without
  evidence. I prefer the explicit playbook over the implicit guess.
  """
  maxDepth 10
  uses "solar-adapter"
  # Analyst practices the analytical disciplines.
  practices "solar-operator", "data-analyst",
            "technical-communication", "thinker",
            "workstation-keeper"

  reportsTo "Operator":
    role "boss"
    trustLevel 100

# ── Channels (added by `claw channel auth <name>`) ───────────
# Once you've authed channels, declare them here:
#   channel "feishu":
#     app "<your-app-id>", "Frontdesk"
#   channel "telegram":
#     app "<your-bot-id>", "Frontdesk"

# ── Updates (Phase 9 auto-update from upstream claw) ─────────
# updates:
#   enabled false              # opt in when you trust the upgrade flow
#   branch "main"
#   check_interval_hours 4
#   auto_apply false
#   notify_agent "Analyst"

# Generate the company workspace.
build(currentSourcePath())
