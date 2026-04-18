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
  defaultModel "deepseek-chat"
  models "deepseek-chat", "deepseek-reasoner"

provider "ollama":
  apiKey "ollama"
  defaultModel "gemma4:31b-cloud"

# ── Agents ────────────────────────────────────────────
agent "Lexi":
  model "deepseek-chat"
  provider "deepseek"
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
  model "deepseek-chat"
  provider "deepseek"
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
