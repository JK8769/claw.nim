# Default.nims — Minimal single-agent setup.
# Run: nimclaw create Default.nims
import claw/clawdsl

# ── Organization ──────────────────────────────────────
org "MyCompany":
  description "Personal AI workspace."

# ── People ────────────────────────────────────────────
person "Owner":
  permission "SuperAdmin"

# ── Provider ──────────────────────────────────────────
# DeepSeek — apiBase auto-filled from template.
# Set DEEPSEEK_API_KEY in your environment or the generated .env file.
provider "deepseek":
  apiKey "${DEEPSEEK_API_KEY}"
  # `models[0]` is the provider's canonical primary; agents pick which
  # model THEY want (in their own `models "..."` lines below). The
  # provider just declares what it serves.
  models "deepseek-v4-flash", "deepseek-v4-pro"

# ── Agent ─────────────────────────────────────────────
# Every agent must declare what model(s) they want — capability is
# the agent's concern, not the provider's. `models[0]` is the primary;
# add more entries for cross-provider fallback (e.g. `models "X", "Y"`).
# See docs/provider-config-refactor.md.
agent "Lexi":
  models "deepseek-v4-flash"
  profile "Secretary"

  reportsTo "Owner":
    role "boss"
    trustLevel 100

# ── Channel ───────────────────────────────────────────
# Uncomment the channel you want to use:
#
# channel "telegram":
#   token "${TELEGRAM_BOT_TOKEN}"
#
# channel "feishu":
#   app "${FEISHU_APP_ID}"
#
# channel "discord":
#   token "${DISCORD_BOT_TOKEN}"

# ── Defaults ──────────────────────────────────────────
defaults:
  maxTokens 4096

build(currentSourcePath())
