# SunGrow.nims — solar/storage fleet monitoring company.
#
# Two-agent architecture:
#   - Atlas (Customer Support)  — customer-facing front desk; classifies intent,
#                                 answers simple "current state" lookups, delegates
#                                 analytical work to Lexi.
#   - Lexi  (Secretary / Analyst) — deep analysis: baselines, CAGR anomalies,
#                                   performance ratios, report generation via anygen.
#
# Core skills referenced below:
#   - sungrow    — query plants, devices, real-time & history; solar_report_* pipeline
#                  (solar_report_build orchestrator + primitives)
#   - doc-parse  — ingest data sheets / service reports
#   - anygen     — AI generation of slides, docs, diagrams, websites
#
# Setup:
#   1. claw create templates/clawfiles/SunGrow.nims
#   2. Compile the sungrow MCP server:
#        nim c -d:ssl -d:release --threads:on --mm:orc \
#          --path:src/claw --path:src \
#          -o:$HOME/.nimclaw-SunGrow/workspace/skills/sungrow/bin/sungrow \
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
  # `brand` is the customer-facing service name (shown in welcome
  # messages, status text, etc.). The `org` name above stays as the
  # internal codename — drives NIMCLAW_DIR, BASE files, git repo.
  brand "SolarIQ"
  # `support` points at a Person (declared below) whose identifiers
  # get rendered in welcome + billing-gate messages as "Contact Jerry
  # on Feishu". Customers see this when they hit a daily limit, trial
  # expiry, grace warning, or suspension.
  support "Jerry"
  description "Solar and energy-storage fleet monitoring."

# ── People ────────────────────────────────────────────
# The SuperAdmin. Channel bindings (feishu, nkn, …) are added automatically
# by `claw channel auth <channel>` / `redeem_invite` flows — don't add them
# here by hand.
person "Owner":
  permission "SuperAdmin"

# ── Providers ─────────────────────────────────────────
# Keep deepseek as a zero-friction fallback. opencode-go is preferred for
# production: glm-5.1 handles Chinese analytical prose well; mimo-v2-pro is
# a strong customer-facing model for Atlas.
provider "deepseek":
  apiKey "${DEEPSEEK_API_KEY}"
  defaultModel "deepseek-v4-flash"
  models "deepseek-v4-flash", "deepseek-v4-pro"

provider "opencode-go":
  apiBase "https://opencode.ai/zen/go/v1"
  apiKey "${OPENCODE_GO_API_KEY}"
  defaultModel "kimi-k2.5"
  models "kimi-k2.5", "mimo-v2-pro", "mimo-v2-omni",
         "minimax-m2.5", "minimax-m2.7",
         "qwen3.5-plus", "qwen3.6-plus",
         "glm-5", "glm-5.1"

# ── Competencies (role bundles — skill requirements + handbook pointer) ─
# A competency groups the skills an agent needs plus a handbook that teaches
# the "when to reach for which tool" decision tree. Reference from an agent
# via `practices "<name>"`.
competency "solar-frontdesk":
  description "Customer-facing routing: classify depth, handle simple sungrow lookups directly, delegate analytical/advisory queries to the solar analyst."
  skills "sungrow", "delegate"
  source "solar-frontdesk.md"

competency "solar-analysis":
  description "Deep solar performance analysis: baselines, anomaly detection, performance ratios, and operator-facing recommendations."
  skills "sungrow"
  source "solar-analysis.md"

# ── Agents ────────────────────────────────────────────
agent "Lexi":
  # Primary glm-5.1 (opencode-go), automatic cross-provider fallback to
  # deepseek-v4-flash if opencode-go is down or your key isn't set.
  # The framework looks up which provider serves each model name in
  # the providers list above.
  models "glm-5.1", "deepseek-v4-flash"
  role "Admin"
  identity "Staff"
  jobTitle "Secretary"
  profile "Secretary"
  maxDepth 10
  # Skill-level change on sungrow: raw sungrow_* tools are hidden from MCP
  # exposure. Lexi sees only the solar_* analyst surface + local history
  # store + solar_report_* pipeline — ~15 focused tools instead of 33.
  # No deny-list needed here.
  uses "sungrow", "doc-parse", "anygen"
  practices "solar-analysis"

  reportsTo "Owner":
    role "boss"
    trustLevel 100
    etiquette "Primary lead. Prefers concise reports with kWh and SOC numbers stated clearly."

agent "Atlas":
  # Same cross-provider fallback ladder as Lexi but with mimo-v2-pro
  # as Atlas's preferred primary (lighter customer-facing surface).
  models "mimo-v2-pro", "deepseek-v4-flash"
  role "Staff"
  identity "Staff"
  jobTitle "Customer Support"
  profile "Secretary"
  maxDepth 8
  uses "sungrow", "doc-parse", "delegate"
  practices "solar-frontdesk"
  # Atlas is customer-facing front desk — needs "current state" tools only.
  # Historical analysis + stats are Lexi's job; Atlas delegates those via
  # the `delegate` tool. Restricting to the now-tools + string-health keeps
  # him focused: 5 analyst tools instead of 15. forge-tool is also removed
  # (front desk never forges custom tools).
  deny "mcp_sungrow_solar_plant_history",
       "mcp_sungrow_solar_device_history",
       "mcp_sungrow_solar_optimizer_now",
       "mcp_sungrow_solar_optimizer_history",
       "mcp_sungrow_solar_environment_now",
       "mcp_sungrow_solar_environment_history",
       "mcp_sungrow_solar_history_sync",
       "mcp_sungrow_solar_history_query",
       "mcp_sungrow_solar_history_stats",
       "mcp_sungrow_solar_history_status"

  reportsTo "Owner":
    role "boss"
    trustLevel 100

# ── Company Rules ─────────────────────────────────────
defaults:
  maxTokens 8192         # wide enough that Chinese analytical markdown doesn't truncate
  temperature 0.5        # lower than MyCompany — analytics prefers deterministic output
  maxToolIterations 40   # report-generation chains can legitimately need 15-25 tool calls

security:
  policy "rate_limit",
    "Sungrow iSolarCloud recommends >=5 minutes between realtime queries for the same device. Do not poll in loops."
  policy "no_control",
    "This company is READ-ONLY. Never attempt parameter writes, grid control, or firmware operations via the Sungrow API."

gateway:
  host "127.0.0.1"
  port 18791           # differs from MyCompany so both can run in parallel

# ── Skills (Tier 2 Company Lab) ───────────────────────
# Tier 1 base skills (forge-tool, delegate) are universal — reference via
# `uses "..."` on an agent, no company-level `skill "..."` line needed.
#
# For `sungrow` and `doc-parse` you need either:
#   - a fork in your own GitHub:  skill "sungrow", "github:<you>/claw-sungrow-skill"
#   - a `claw:` ref to a company that owns them:  skill "claw:<Co>/sungrow"
# See skills/sungrow/ in the claw.nim repo for the reference implementation.
#   skill "sungrow",   "github:<you>/claw-sungrow-skill"
#   skill "doc-parse", "github:<you>/claw-doc-parse-skill"
skill "anygen", "github:AnyGenIO/anygen-suite-skill/anygen-suite"
build(currentSourcePath())
