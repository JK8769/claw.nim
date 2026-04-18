# SunGrow.nims — solar/storage fleet monitoring company.
#
# This company is configured around the Sungrow iSolarCloud API.
# Its operator agent (Lexi) has access to:
#   - sungrow skill (bundled Tier 2) — query plants, devices, real-time & history
#   - forge-tool                     — to author custom analytics/report tools
#   - learn_skill tool (automatic)   — to capture repeated workflows as SKILL.md
#   - doc-parse                      — to ingest data sheets / service reports
#   - anygen                         — to generate dashboards and reports
#
# Setup:
#   1. claw create templates/clawfiles/SunGrow.nims
#   2. Compile the sungrow MCP server:
#        nim c -d:ssl -d:release --threads:on --mm:orc \
#          --path:src/claw --path:src \
#          -o:$HOME/.nimclaw-SunGrow/workspace/lab/mcp/sungrow/bin/sungrow \
#          skills/sungrow/src/sungrow.nim
#   3. Fill ~/.nimclaw-SunGrow/.env with your iSolarCloud credentials
#   4. NIMCLAW_DIR=~/.nimclaw-SunGrow claw gateway --debug
#
# After that you can edit ~/.nimclaw-SunGrow/BASE.nims (this file copied there
# by 'claw create') and re-run 'claw create' to rebuild without re-specifying
# the template path.

import claw/clawdsl

# ── Organization ──────────────────────────────────────
org "SunGrow":
  description "Solar and energy-storage fleet monitoring."

# ── People ────────────────────────────────────────────
person "Owner":
  permission "SuperAdmin"

# ── Providers ─────────────────────────────────────────
provider "deepseek":
  apiKey "${DEEPSEEK_API_KEY}"
  defaultModel "deepseek-chat"
  models "deepseek-chat", "deepseek-reasoner"

# ── Agents ────────────────────────────────────────────
agent "Lexi":
  model "deepseek-chat"
  provider "deepseek"
  role "Admin"
  identity "Staff"
  jobTitle "Solar Ops Analyst"
  profile "Secretary"
  maxDepth 10
  uses "sungrow", "doc-parse", "anygen", "forge-tool"
  workstation true

  reportsTo "Owner":
    role "boss"
    trustLevel 100
    etiquette "Primary lead. Prefers concise reports with kWh and SOC numbers stated clearly."

# ── Company Rules ─────────────────────────────────────
defaults:
  maxTokens 4096
  temperature 0.5        # lower than MyCompany — analytics prefers deterministic output
  maxToolIterations 20

security:
  policy "rate_limit",
    "Sungrow iSolarCloud recommends >=5 minutes between realtime queries for the same device. Do not poll in loops."
  policy "no_control",
    "This company is READ-ONLY. Never attempt parameter writes, grid control, or firmware operations via the Sungrow API."

gateway:
  host "127.0.0.1"
  port 18791           # differs from MyCompany so both can run in parallel

# ── Skills (Tier 2 Company Lab) ───────────────────────
# Only Tier 2 opt-ins need declaration. Tier 1 base skill `forge-tool`
# is universal — reference via `uses "..."` on an agent, no company-level
# `skill "..."` line needed. The learn_skill TOOL is automatic for any
# agent with `workstation: true`.
# Skills. Adjust the refs below once you have sungrow/doc-parse in git
# (or use `claw:` refs to another company that owns them).
#   skill "sungrow",   "github:<you>/claw-sungrow-skill"
#   skill "doc-parse", "github:<you>/claw-doc-parse-skill"
skill "anygen", "github:AnyGenIO/anygen-suite-skill/anygen-suite"
build(currentSourcePath())
