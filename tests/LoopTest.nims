import nimclaw/clawdsl

org "LoopTestCorp":
  description "Testing NimScript features"

person "Boss":
  permission "SuperAdmin"

# Variables
let baseModel = "deepseek-v4-flash"

# Provider with template defaults (apiBase auto-filled)
provider "deepseek":
  apiKey "${DEEPSEEK_API_KEY}"
  defaultModel baseModel
  models "deepseek-v4-flash", "deepseek-v4-pro"

# Loop — bulk team creation
let team = @[("Alice", "Analyst"), ("Bob", "Engineer"), ("Charlie", "Designer")]
for pair in team:
  let (name, title) = pair
  agent name:
    model baseModel
    provider "deepseek"
    jobTitle title
    reportsTo "Boss":
      role "boss"
      trustLevel 80

# Conditional
let isProd = getEnv("TEST_ENV") == "production"
if isProd:
  channel "feishu":
    app "prod_app_id"
else:
  channel "telegram":
    token "${TELEGRAM_TOKEN}"

defaults:
  maxTokens 8192

build()
