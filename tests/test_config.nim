import std/unittest
import ../src/nimclaw/config
import std/[os, json]
import std/posix

suite "Config tests":
  setup:
    let tempDir = getTempDir() / "nimclaw_test_config_" & $getpid()
    createDir(tempDir)
    let testConfigPath = tempDir / "config.json"
    
    # Save current env before overriding
    let origProvider = getEnv("NIMCLAW_PROVIDER")
    let origModel = getEnv("NIMCLAW_MODEL")
    let origTemp = getEnv("NIMCLAW_TEMPERATURE")
    let origPort = getEnv("NIMCLAW_GATEWAY_PORT")
    let origHost = getEnv("NIMCLAW_GATEWAY_HOST")
    let origWs = getEnv("NIMCLAW_WORKSPACE")
    let origDefaultsWs = getEnv("NIMCLAW_AGENTS_DEFAULTS_WORKSPACE")
    let origDefaultsModel = getEnv("NIMCLAW_AGENTS_DEFAULTS_MODEL")

    # Clear test env vars
    delEnv("NIMCLAW_PROVIDER")
    delEnv("NIMCLAW_MODEL")
    delEnv("NIMCLAW_TEMPERATURE")
    delEnv("NIMCLAW_GATEWAY_PORT")
    delEnv("NIMCLAW_GATEWAY_HOST")
    delEnv("NIMCLAW_WORKSPACE")
    delEnv("NIMCLAW_AGENTS_DEFAULTS_WORKSPACE")
    delEnv("NIMCLAW_AGENTS_DEFAULTS_MODEL")

  teardown:
    removeDir(tempDir)
    
    # Restore env vars
    if origProvider.len > 0: putEnv("NIMCLAW_PROVIDER", origProvider) else: delEnv("NIMCLAW_PROVIDER")
    if origModel.len > 0: putEnv("NIMCLAW_MODEL", origModel) else: delEnv("NIMCLAW_MODEL")
    if origTemp.len > 0: putEnv("NIMCLAW_TEMPERATURE", origTemp) else: delEnv("NIMCLAW_TEMPERATURE")
    if origPort.len > 0: putEnv("NIMCLAW_GATEWAY_PORT", origPort) else: delEnv("NIMCLAW_GATEWAY_PORT")
    if origHost.len > 0: putEnv("NIMCLAW_GATEWAY_HOST", origHost) else: delEnv("NIMCLAW_GATEWAY_HOST")
    if origWs.len > 0: putEnv("NIMCLAW_WORKSPACE", origWs) else: delEnv("NIMCLAW_WORKSPACE")
    if origDefaultsWs.len > 0: putEnv("NIMCLAW_AGENTS_DEFAULTS_WORKSPACE", origDefaultsWs) else: delEnv("NIMCLAW_AGENTS_DEFAULTS_WORKSPACE")
    if origDefaultsModel.len > 0: putEnv("NIMCLAW_AGENTS_DEFAULTS_MODEL", origDefaultsModel) else: delEnv("NIMCLAW_AGENTS_DEFAULTS_MODEL")

  test "defaultConfig populates expected defaults":
    let cfg = defaultConfig()
    check cfg.agents.defaults.model == "openrouter"
    check cfg.agents.defaults.workspace == "~/.nimclaw/workspace"
    check cfg.agents.defaults.temperature == 0.7
    check cfg.gateway.host == "0.0.0.0"
    check cfg.gateway.port == 18790
    check cfg.channels.telegram.enabled == false
    check cfg.default_provider == "openrouter" # NullClaw parity
    check cfg.default_temperature == 0.7       # NullClaw parity
    
  test "parseEnv overrides nested and flat properties":
    putEnv("NIMCLAW_PROVIDER", "anthropic")
    putEnv("NIMCLAW_MODEL", "claude-3-opus-20240229")
    putEnv("NIMCLAW_TEMPERATURE", "0.5")
    putEnv("NIMCLAW_GATEWAY_PORT", "8080")
    putEnv("NIMCLAW_GATEWAY_HOST", "127.0.0.1")
    putEnv("NIMCLAW_WORKSPACE", "/tmp/override_workspace")
    
    var cfg = defaultConfig()
    parseEnv(cfg)
    
    # Flat convenience props (parity with nullclaw)
    check cfg.default_provider == "anthropic"
    check cfg.default_model == "claude-3-opus-20240229"
    check cfg.default_temperature == 0.5
    check cfg.gateway.port == 8080
    check cfg.gateway.host == "127.0.0.1"
    check cfg.workspacePath() == "/tmp/override_workspace"
    
  test "loadConfig gracefully handles missing file and uses defaults":
    let cfg = loadConfig("nonexistent/path/to/config.json")
    check cfg.agents.defaults.model == "openrouter"
    check cfg.agents.defaults.max_tokens == 4096
    check cfg.gateway.port == 18790

  test "invalid temperature is clamped or ignored in parseEnv":
    putEnv("NIMCLAW_TEMPERATURE", "3.14")
    var cfg = defaultConfig()
    parseEnv(cfg)
    # TDD Expectation: Should ignore invalid >= 2.0 or < 0.0 values like in nullclaw
    check cfg.default_temperature == 0.7 
