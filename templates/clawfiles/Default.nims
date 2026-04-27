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
  defaultModel "deepseek-v4-flash"
  models "deepseek-v4-flash", "deepseek-v4-pro"

# ── Agent ─────────────────────────────────────────────
agent "Lexi":
  model "deepseek-v4-flash"
  provider "deepseek"
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
