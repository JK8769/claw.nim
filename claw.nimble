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
requires "mummy"
requires "nimcrypto"
requires "unicodedb"
# TTML markup spec + producer-side smart constructors for tui's
# extension tags. The daemon's dashboard work imports:
#   • ttml/build for standard-tag construction (Box, Text, Rule, …)
#   • tui/spec/<widget> for typed extension-tag builders (e.g.
#     tContextMenu for the [+ New company] picker)
# Neither pulls in any rendering code — `nm` on the built claw binary
# shows 0 symbols from tui/runtime or tui/components. The two-package
# dependency captures the spec+spec-shim surface a producer needs.
# Dev overrides in config.nims point at sibling working trees;
# production resolves via the nimble cache from the GitHub repos.
requires "https://github.com/JK8769/ttml.git >= 0.3.0"
requires "https://github.com/JK8769/tui.git >= 0.1.0"

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

task test_zen_integration, "Run e2e tests against Zen's TTML runtime":
  # Verifies the TTML strings the daemon emits parse correctly via the
  # real ttml package — guards against regressions in attribute encoding
  # (e.g. &#10; -> newline), escape ordering, and component construction.
  # Requires the Zen monorepo to be checked out at ../../Zen relative to
  # this checkout. Override ZEN_TTML_SRC if you've parked Zen elsewhere.
  let ttmlSrc = getEnv("ZEN_TTML_SRC", "../../Zen/nim-pkgs/ttml/src")
  exec "nim c -r --hints:off --path:" & ttmlSrc &
       " tests/test_daemon_orch_ttml.nim"

# ── Docs ─────────────────────────────────────────────────────────

task docs, "Generate searchable HTML documentation":
  exec "nim doc --project --outdir:docs --index:on --hints:off --warnings:off src/claw.nim"
  echo "Documentation generated in docs/"
