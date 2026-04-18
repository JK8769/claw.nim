import nimclaw/clawdsl

org "TestCompany":
  description "A test company for verifying the Clawfile DSL."

person "Jerry":
  permission "SuperAdmin"
  identifier "feishu", "ou_test123"

provider "deepseek":
  apiBase "https://api.deepseek.com"
  apiKey "${DEEPSEEK_API_KEY}"
  defaultModel "deepseek-chat"
  models "deepseek-chat", "deepseek-reasoner"

agent "Lexi":
  model "deepseek-chat"
  provider "deepseek"
  role "Admin"
  identity "Staff"
  jobTitle "Secretary"
  profile "Secretary"
  maxDepth 10

  reportsTo "Jerry":
    role "boss"
    trustLevel 100
    etiquette "This is your primary lead."

channel "feishu":
  app "cli_test_app"
  requireMention false

channel "telegram":
  token "${TELEGRAM_BOT_TOKEN}"

defaults:
  maxTokens 4096
  temperature 0.7
  maxToolIterations 20

security:
  policy "identity_upgrades", "Ask for Invitation Code."

gateway:
  host "0.0.0.0"
  port 18790

tools:
  webSearchKey "${BRAVE_API_KEY}"

skill "playwright"

build()
