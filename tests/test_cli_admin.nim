import std/[unittest, strutils, json]
import ../src/nimclaw/cli_admin
import ../src/nimclaw/config

suite "CLI Admin Commands":
  let cfg = defaultConfig()

  # ── workspace ─────────────────────────────────────────────────
  test "workspace shows usage with no args":
    let output = runWorkspaceCommand(cfg, @[])
    check "Usage:" in output

  test "workspace edit requires filename":
    let output = runWorkspaceCommand(cfg, @["edit"])
    check "Usage:" in output

  test "workspace edit rejects non-bootstrap files":
    let output = runWorkspaceCommand(cfg, @["edit", "random.txt"])
    check "Not a bootstrap" in output

  test "workspace reset-md dry run":
    let output = runWorkspaceCommand(cfg, @["reset-md", "--dry-run"])
    check "Dry run" in output

  test "isBootstrapFile recognizes valid files":
    check isBootstrapFile("SOUL.md")
    check isBootstrapFile("AGENTS.md")
    check not isBootstrapFile("README.md")

  # ── capabilities ──────────────────────────────────────────────
  test "capabilities text mode":
    let output = runCapabilitiesCommand(cfg, false)
    check "provider:" in output
    check "tools:" in output

  test "capabilities json mode":
    let output = runCapabilitiesCommand(cfg, true)
    let j = parseJson(output)
    check j.hasKey("provider")
    check j.hasKey("tools")

  # ── models ────────────────────────────────────────────────────
  test "models list":
    let output = runModelsCommand(cfg, @["list"])
    check "Known providers" in output
    check "openrouter" in output

  test "models info":
    let output = runModelsCommand(cfg, @["info", "gpt-4.1"])
    check "Model: gpt-4.1" in output

  test "models benchmark":
    let output = runModelsCommand(cfg, @["benchmark"])
    check "benchmark" in output

  test "models usage":
    let output = runModelsCommand(cfg, @[])
    check "Usage:" in output

  # ── auth ──────────────────────────────────────────────────────
  test "auth usage":
    let output = runAuthCommand(@[])
    check "Usage:" in output

  test "auth unknown provider":
    let output = runAuthCommand(@["login", "google"])
    check "Unknown auth provider" in output

  test "auth status":
    let output = runAuthCommand(@["status", "openai-codex"])
    check "not authenticated" in output

  # ── channel ───────────────────────────────────────────────────
  test "channel list":
    let output = runChannelCommand(cfg, @["list"])
    check "telegram" in output
    check "discord" in output

  test "channel status":
    let output = runChannelCommand(cfg, @["status"])
    check "CLI: ok" in output

  # ── hardware ──────────────────────────────────────────────────
  test "hardware usage":
    let output = runHardwareCommand(@[])
    check "Usage:" in output

  test "hardware flash needs file":
    let output = runHardwareCommand(@["flash"])
    check "Usage:" in output

  # ── migrate ───────────────────────────────────────────────────
  test "migrate usage":
    let output = runMigrateCommand(cfg, @[])
    check "Usage:" in output

  test "migrate unknown source":
    let output = runMigrateCommand(cfg, @["badtool"])
    check "Unknown migration source" in output

  test "migrate openclaw dry-run":
    let output = runMigrateCommand(cfg, @["openclaw", "--dry-run"])
    check "DRY RUN" in output

  # ── service ───────────────────────────────────────────────────
  test "service usage":
    let output = runServiceCommand(cfg, @[])
    check "Usage:" in output

  test "service unknown command":
    let output = runServiceCommand(cfg, @["badcmd"])
    check "Unknown service command" in output

  # ── update ────────────────────────────────────────────────────
  test "update check only":
    let output = runUpdateCommand(@["--check"])
    check "up to date" in output

  test "update full":
    let output = runUpdateCommand(@[])
    check "not yet implemented" in output
