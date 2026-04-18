version       = "0.1.0"
author        = "Claw contributors"
description   = "AI agent framework"
license       = "MIT"
srcDir        = "src"
bin           = @["claw"]
installDirs   = @["templates", "deps", "res"]
installExt    = @["nim", "nims", "json", "md"]

requires "nim >= 2.0.0"
requires "jsony"
requires "docopt >= 0.8.0"
requires "ws"
requires "regex"
requires "nimsync >= 1.0.0"
requires "QRgen"
requires "curly"
requires "webby"
requires "nimcrypto"
requires "unicodedb"

# Standard build switches
switch("define", "ssl")
switch("define", "release")
switch("threads", "on")

# ── Build helpers ────────────────────────────────────────────────

task build_nkn, "Build nkn-cli (requires Go 1.21+)":
  exec "./channels/build_nkn_cli.sh"

task build_lark, "Build lark-cli from submodule (requires Go 1.23+, Python 3)":
  exec "./channels/build_lark_cli.sh"

task build_all, "Build claw and all channel CLIs":
  exec "./channels/build_nkn_cli.sh"
  exec "./channels/build_lark_cli.sh"
  exec "nimble build"

# ── Test ─────────────────────────────────────────────────────────

task test, "Run unit tests":
  exec "nim c -r --hints:off tests/test_schema.nim"
  exec "nim c -r --hints:off tests/test_path_security.nim"
  exec "nim c -r --hints:off tests/test_filesystem.nim"
  exec "nim c -r --hints:off tests/test_tool_registry.nim"

# ── Docs ─────────────────────────────────────────────────────────

task docs, "Generate searchable HTML documentation":
  exec "nim doc --project --outdir:docs --index:on --hints:off --warnings:off src/claw.nim"
  echo "Documentation generated in docs/"
