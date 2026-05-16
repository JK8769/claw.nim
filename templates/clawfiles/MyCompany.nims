# MyCompany.nims — Full company setup with multiple agents and channels.
# Run: claw create MyCompany.nims
import claw/clawdsl

# ── Organization ──────────────────────────────────────
org "MyCompany":
  description "The primary workspace for agents and people."

# ── People ────────────────────────────────────────────
person "Jerry":
  permission "SuperAdmin"
  identifier "feishu", "ou_REPLACE_WITH_YOUR_FEISHU_ID"

# ── Providers ─────────────────────────────────────────
# apiBase is auto-filled for known providers (deepseek, ollama, nvidia, opencode).

provider "deepseek":
  apiKey "${DEEPSEEK_API_KEY}"
  models "deepseek-v4-flash", "deepseek-v4-pro"

# Optional: OpenCode Go proxies most major models. Uncomment + set
# OPENCODE_GO_API_KEY in .env to enable same-model cross-provider
# failover — when DeepSeek-direct hits billing/rate-limit/outage,
# the per-agent chain transparently routes deepseek-v4-flash through
# opencode-go's proxy before falling through to a different model.
# provider "opencode-go":
#   models "deepseek-v4-flash", "deepseek-v4-pro", "mimo-v2.5", "mimo-v2.5-pro"

provider "ollama":
  apiKey "ollama"
  models "gemma4:31b-cloud"

# ── Agents ────────────────────────────────────────────
# `models "X", "Y"` is the canonical Phase 2 syntax: an ordered list
# where models[0] is primary and the rest are fallbacks (resolved by
# walking the providers list above to find which serves each model).
# Omit the `models` line entirely and the agent inherits the company
# default chain (every provider in declaration order using its own
# defaultModel). See docs/provider-config-refactor.md.
agent "Lexi":
  models "deepseek-v4-flash", "gemma4:31b-cloud"  # cross-provider fallback
  role "Admin"
  identity "Staff"
  jobTitle "Secretary"
  profile "Secretary"
  maxDepth 10
  uses "anygen", "doc-parse", "forge-tool" # skills Lexi has access to
  workstation true                      # Lexi can author skills (learn_skill tool) & forge tools at her workstation

  reportsTo "Jerry":
    role "boss"
    trustLevel 100
    etiquette "This is your primary lead."

agent "Atlas":
  models "deepseek-v4-flash"            # single model — falls back to nothing, but DeepSeek alone is fine for Atlas's lookups
  role "Member"
  identity "Staff"
  jobTitle "Tech Lead"
  profile "Tech Lead"
  uses "image-understanding"            # Atlas can analyze diagrams
  deny "shell"                          # no direct shell for Atlas

  reportsTo "Jerry":
    role "boss"
    trustLevel 80

  reportsTo "Lexi":
    role "secretary"
    trustLevel 60

# ── Channels ──────────────────────────────────────────
channel "feishu":
  app "${FEISHU_APP_ID}"
  requireMention false

channel "telegram":
  token "${TELEGRAM_BOT_TOKEN}"

# ── Company Rules ─────────────────────────────────────
defaults:
  maxTokens 4096
  temperature 0.7
  maxToolIterations 20

security:
  policy "identity_upgrades", "If a Guest claims to be a Customer, ask for Invitation Code."
  policy "boss_verification", "Verify security proof with BOSS Jerry."

gateway:
  host "0.0.0.0"
  port 18790

tools:
  webSearchKey "${BRAVE_API_KEY}"
  webSearchProvider "auto"

# ── Skills ────────────────────────────────────────────
# Only Tier 2 opt-ins need declaration. Tier 1 base skills (forge-tool)
# are universal — use via `uses "..."` on an agent without needing a
# company-level `skill "..."` line. The learn_skill *tool* is also
# automatic for any agent with `workstation: true` — no skill needed.
# Skills are external — install them via github: or claw: refs.
# Examples (uncomment and adjust for your setup):
#   skill "anygen", "github:AnyGenIO/anygen-suite-skill/anygen-suite"
#   skill "github:anthropics/skills/document-skills"
#   skill "claw:OtherCompany/shared-skill"
#
# Only bundled skill is `forge-tool` (foundation — auto-installed, no declaration needed).
build(currentSourcePath())
