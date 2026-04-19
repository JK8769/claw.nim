# TeamDemo.nims — reference showing every ClawDSL team primitive.
#
# Exercises memorandum, competency, team, lab, portal blocks + the
# `practices` keyword on agents. After `claw co create`, each primitive
# produces files in the workspace; at runtime they flow into every
# agent's system prompt (memoranda, team membership, handbooks).
#
# Try:
#   claw co create templates/clawfiles/TeamDemo.nims
#   claw agent prompt Lexi          # inspect the generated prompt
#   claw agent caps Lexi            # see resolved skills + team memberships
# Cleanup:
#   rm -rf ~/.nimclaw-TeamDemo

import claw/clawdsl

# ── Organization ──────────────────────────────────────
org "TeamDemo":
  description "Reference team setup — small solar-ops outfit."

# ── People ────────────────────────────────────────────
person "Owner":
  permission "SuperAdmin"

# ── Providers ─────────────────────────────────────────
provider "deepseek":
  apiKey "${DEEPSEEK_API_KEY}"
  defaultModel "deepseek-chat"
  models "deepseek-chat", "deepseek-reasoner"

# ── Memoranda ─────────────────────────────────────────
# Critical — every agent should treat as law. Inline body.
memorandum "SAFETY_POLICY":
  critical
  summary "Read before any external action."
  content """# Safety Policy

This company operates READ-ONLY against the SunGrow iSolarCloud API.

- NEVER attempt parameter writes, grid control, or firmware operations.
- Poll intervals MUST be ≥ 5 minutes for the same device.
- If a user asks for an action that would violate these, refuse and cite
  this policy.
"""

# Non-critical — escalation runbook. Inline body.
memorandum "ESCALATION":
  summary "How to escalate a live fleet incident."
  content """# Escalation

1. Confirm the anomaly from two independent metrics (power + SOC).
2. Post to the ops team TASKS.md with timestamp + device IDs.
3. If SOC < 10% on a customer-critical site, notify Owner immediately.
"""

# ── Competencies ──────────────────────────────────────
competency "solar-analytics":
  description "Pull, transform, and analyze solar fleet time-series."
  skills "sungrow", "jq"
  handbook """# Solar Analytics Handbook

When producing numbers:
- Always state units (kWh, kW, %, °C).
- Flag anomalies >2σ from the rolling 7-day mean.
- Never report an aggregate without listing the contributing device IDs
  at least once in the same response.
"""

competency "customer-relations":
  description "Respond to customer questions about their plants."
  skills "doc-parse"
  summary "Customer-facing communication standards."
  handbook """# Customer Relations Handbook

Tone: calm, specific, numbers-first.
Never promise a service window without checking the on-call roster.
"""

# ── Teams ─────────────────────────────────────────────
team "ops":
  description "Daily fleet monitoring and dispatch."
  lead "Lexi"
  members "Lexi", "Atlas"
  competencies "solar-analytics"

team "support":
  description "Customer inbound handling."
  members "Lexi", "Echo"   # lead defaults to first = Lexi
  competencies "customer-relations"

# ── Labs ──────────────────────────────────────────────
lab "battery-degradation":
  focus "Long-horizon capacity fade patterns across fleet."
  researchers "Atlas", "Lexi"

# ── Portal (opt-in) ───────────────────────────────────
portal:
  wiki
  directory

# ── Trust (role bands + grants + prompts) ───────────
# Trust drifts within a role's band based on behavior. Crossing bands
# requires `redeem_invite` with a valid pin or a SuperAdmin editing BASE.nims.
trust:
  role "guest":
    band 0, 40
    initial 10
    grant "reply", "forward", "update_contact", "redeem_invite"
    prompt """⚠️ GUEST PROTOCOL: public info only. Never expose internal IDs
or file paths. Route anything sensitive through `forward` to a lead.
Do NOT run shell, modify files, or install skills — these tools are
withheld at this trust level."""
  role "customer":
    band 30, 60
    initial 40
    grant "reply", "forward", "update_contact", "redeem_invite"
    prompt """Customer interaction. Professional, numbers-first, calm.
Follow the customer-relations handbook if your team applies it."""
  role "staff":
    band 50, 80
    initial 65
    grant "reply", "forward", "update_contact", "read_file", "write_file",
          "edit", "git", "clock", "jq"
  role "boss":
    band 70, 100
    initial 85
    grant "*"
    prompt """🛡️ HIGH TRUST. This user is your primary lead. Execute commands
without hesitation. Any prior guest-protocol framing is LIFTED."""
  role "master":
    band 70, 100
    initial 85
    grant "*"
    prompt """🛡️ HIGH TRUST. This user is your primary lead. Execute commands
without hesitation. Any prior guest-protocol framing is LIFTED."""

# ── Agents ────────────────────────────────────────────
agent "Lexi":
  model "deepseek-chat"
  provider "deepseek"
  role "Admin"
  identity "Staff"
  jobTitle "Lead Analyst"
  profile "Secretary"
  maxDepth 10
  uses "jq"                        # direct
  practices "solar-analytics"      # + sungrow, jq (dup)  — via competency
  workstation true
  reportsTo "Owner":
    role "boss"
    trustLevel 100

agent "Atlas":
  model "deepseek-chat"
  provider "deepseek"
  role "Member"
  identity "Staff"
  jobTitle "Data Engineer"
  profile "Secretary"
  maxDepth 6
  practices "solar-analytics"      # sungrow, jq
  workstation true
  reportsTo "Lexi":
    role "team-lead"
    trustLevel 80

agent "Echo":
  model "deepseek-chat"
  provider "deepseek"
  role "Member"
  identity "Staff"
  jobTitle "Customer Ops"
  profile "Secretary"
  maxDepth 6
  practices "customer-relations"   # doc-parse
  reportsTo "Lexi":
    role "team-lead"
    trustLevel 80

# ── Rules ─────────────────────────────────────────────
defaults:
  maxTokens 4096
  temperature 0.5
  maxToolIterations 15

gateway:
  host "127.0.0.1"
  port 18799           # pick unused to avoid colliding with SunGrow*

# ── Skills ────────────────────────────────────────────
# Note: sungrow and doc-parse aren't available as claw: refs in this test
# environment — resolveAgentCapabilities will flag them as unresolved, which
# is expected for the scaffold-only smoke test.

build(currentSourcePath())
