## solar-power-station — L1 domain template
##
## A starter clawfile for any company operating a fleet of solar power
## stations. Vendor-neutral; multi-vendor capable.
##
## After `claw co create <name> --template solar-power-station --as=<name>`:
##   1. Edit this BASE.nims to customize agent personas, channels, etc.
##   2. Set required env vars in `.env` (see vendor/<your-vendor>/README.md)
##   3. Pick your inverter brand(s):
##        skill "vendor/sungrow"      # for SunGrow inverters
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
# Configure at least one provider before running gateway.
# Use `claw provider auth <name>` to set up API keys, then list them here.
# Example:
#   provider "deepseek":
#     model "deepseek-v4-flash"
#   provider "anthropic":
#     model "claude-sonnet-4.5"

# ── Foundation skills (L0, auto-mirrored from framework) ─────
# These ship with claw.nim and apply to every agent. No declaration needed.
# Currently: `tools` (capability-surface management).

# ── Distribution skills (L2 opt-in) ──────────────────────────
# Optional skills shipped with claw distribution. Uncomment to install:
#   skill "anygen"          # AI-powered content generation (slides, docs, diagrams)
#   skill "doc-parse"       # Document parsing via AnyGen

# ── Inverter vendors (L1 — defined in this template's vendor/) ─
# Pick one or more inverter brands that your fleet uses.
# See vendor/CONTRACT.md for the interface contract and vendor/README.md
# for the list of currently-shipped implementations.
#
# Example single-vendor fleet:
#   skill "vendor/sungrow"
#
# Example multi-vendor fleet:
#   skill "vendor/sungrow"
#   skill "vendor/huawei"

# ── Agents ───────────────────────────────────────────────────
# The template ships with two agents pre-wired: a customer-facing
# Frontdesk and a back-office Analyst, with a delegate flow.
# Customize their names, soul, and channel bindings below.

agent "Frontdesk":
  models "deepseek-v4-flash"
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
  # Frontdesk practices customer-facing disciplines.
  # `solar-frontdesk` (TODO: ship with template) — customer-facing patterns
  # `technical-communication` — delivery discipline (compose with above)
  # practices "solar-frontdesk", "technical-communication"

  reportsTo "Operator":
    role "boss"
    trustLevel 100

agent "Analyst":
  models "deepseek-v4-flash"
  role "Admin"
  identity "Staff"
  jobTitle "Performance Analyst"
  soul """
  I analyse plant performance against baselines, write clear reports,
  and quote numbers not summaries. I never claim a finding without
  evidence. I prefer the explicit playbook over the implicit guess.
  """
  maxDepth 10
  # Analyst practices the analytical disciplines.
  # `solar-operator` — domain knowledge (equipment, units, ranges)
  # `data-analyst` — methodology
  # `technical-communication` — delivery
  # `knowledge-keeper` — reflection
  # practices "solar-operator", "data-analyst",
  #           "technical-communication", "knowledge-keeper"

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
