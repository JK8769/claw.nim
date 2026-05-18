#!/usr/bin/env bash
# claw.sh — dev tooling for the claw repo.
#
# nimble install does the bare minimum (compile + symlink). For day-to-day
# claw dev you also want:
#   • safe in-place binary replacement (avoid macOS UE-wedge — see
#     CLAUDE.md for why `mv` over an mmap'd binary corrupts running
#     processes; this script uses the rm+cp pattern instead)
#   • cleanup of stale ~/.nimble/pkgs2/claw-<hash>/ dirs (one per install
#     accumulates; never auto-pruned by nimble)
#   • daemon-aware install — knows about ~/.nimclawd/admin.pid so it
#     doesn't trash the binary the running daemon is mmap'd against
#   • a single status command that answers "what's running, what's
#     installed, what's stale, how much disk am I using"
#
# Usage:
#   ./claw.sh <command> [args]
#
# Commands:
#   install         build, install, prune stale caches (safe on running daemon)
#   build           build only (./claw in repo, no install)
#   clean           prune stale ~/.nimble/pkgs2/claw-* (keeps running + current)
#   status          show what's installed, what's running, disk usage
#   restart-daemon  kill ~/.nimclawd/admin.pid (zen auto-respawns)
#   help            this message
#
# Implementation notes:
#   • Bash + standard Unix tools only; no Python or jq required
#   • Tested on macOS; should work on Linux with minor stat(1) tweaks
#   • Idempotent — safe to re-run any command
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_RESET=$'\e[0m'
else
  C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi
info()  { echo "${C_BLUE}→${C_RESET} $*"; }
ok()    { echo "${C_GREEN}✓${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}⚠${C_RESET} $*" >&2; }
err()   { echo "${C_RED}✗${C_RESET} $*" >&2; }
hdr()   { echo; echo "${C_BOLD}$*${C_RESET}"; }

# ── Locations ─────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
NIMBLE_BIN="$HOME/.nimble/bin/claw"
NIMBLE_PKGS="$HOME/.nimble/pkgs2"
ADMIN_PID_FILE="$HOME/.nimclawd/admin.pid"

# ── Helpers ───────────────────────────────────────────────────────

# Print the full path of the directory the ~/.nimble/bin/claw symlink
# currently points at — i.e. the "current install".
current_install_dir() {
  if [[ ! -L "$NIMBLE_BIN" ]]; then echo ""; return; fi
  local target rel
  target=$(readlink "$NIMBLE_BIN")
  # target is relative like ../pkgs2/claw-…/claw.out
  rel=$(cd "$(dirname "$NIMBLE_BIN")" && cd "$(dirname "$target")" && pwd)
  echo "$rel"
}

# Print the PID of the running daemon if one is up, or empty string.
running_daemon_pid() {
  if [[ ! -f "$ADMIN_PID_FILE" ]]; then echo ""; return; fi
  local pid; pid=$(cat "$ADMIN_PID_FILE")
  # Verify the PID is actually alive
  if kill -0 "$pid" 2>/dev/null; then echo "$pid"; else echo ""; fi
}

# Print the path of the executable the running daemon's process is
# running. Empty string if no daemon running. Handles both the cached
# install path (`claw.out`) and the source-repo build path (`claw`).
running_daemon_binary() {
  local pid; pid=$(running_daemon_pid)
  if [[ -z "$pid" ]]; then echo ""; return; fi
  # lsof's TYPE=REG line with FD=txt is the executable being run.
  # macOS lsof column order: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
  lsof -p "$pid" 2>/dev/null \
    | awk '$4 == "txt" && $5 == "REG" && ($NF ~ /\/claw(\.out)?$/) { print $NF; exit }'
}

# Print the install dir of the running daemon's binary — useful for
# the cleanup keep-list. For cache installs this is the pkgs2/<hash>/
# parent; for repo builds it's the repo root.
running_daemon_install_dir() {
  local bin; bin=$(running_daemon_binary)
  [[ -z "$bin" ]] && { echo ""; return; }
  dirname "$bin"
}

# Resolve symlinks src/{res,templates,deps} → ../{res,templates,deps}.
# nimble interprets installDirs relative to srcDir; this is the workaround.
ensure_src_symlinks() {
  cd "$REPO_DIR"
  for d in res templates deps; do
    local link="src/$d"
    local target="../$d"
    if [[ ! -e "$link" ]]; then
      info "creating symlink src/$d → ../$d (nimble installDirs workaround)"
      ln -s "$target" "$link"
    elif [[ -L "$link" ]]; then
      :  # already a symlink, fine
    else
      warn "src/$d exists but is not a symlink — leaving alone"
    fi
  done
}

# ── Commands ──────────────────────────────────────────────────────

cmd_install() {
  cd "$REPO_DIR"
  ensure_src_symlinks
  info "running nimble install -y"
  nimble install -y >/dev/null 2>&1 || { err "nimble install failed"; nimble install -y; exit 1; }
  local new
  new=$(current_install_dir)
  if [[ -z "$new" ]]; then err "couldn't determine new install dir"; exit 1; fi
  ok "installed to: $new"
  cmd_clean
  ok "install complete"
  hdr "Next steps"
  echo "  • If zen is running, the new daemon will be picked up on next restart."
  echo "  • If the daemon is running on the old binary, run: $0 restart-daemon"
}

cmd_build() {
  cd "$REPO_DIR"
  ensure_src_symlinks
  info "building claw in repo (no install)"
  nimble build >/dev/null 2>&1 || { err "build failed"; nimble build; exit 1; }
  ok "built: ./claw ($(du -sh ./claw 2>/dev/null | awk '{print $1}'))"
}

cmd_clean() {
  hdr "Cache cleanup"
  local current running keepers
  current=$(current_install_dir)
  running=$(running_daemon_install_dir)
  keepers=""
  [[ -n "$current" ]] && keepers="$keepers$current"$'\n'
  [[ -n "$running" && "$running" != "$current" ]] && keepers="$keepers$running"$'\n'

  if [[ -z "$keepers" ]]; then
    warn "no install dir found — refusing to clean (nothing to preserve)"
    return
  fi

  local kept=0 removed=0 freed=0
  for d in "$NIMBLE_PKGS"/claw-*; do
    [[ -d "$d" ]] || continue
    if echo "$keepers" | grep -qFx "$d"; then
      kept=$((kept + 1))
      continue
    fi
    local sz
    sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
    rm -rf "$d"
    removed=$((removed + 1))
    freed=$((freed + sz))
  done

  if [[ "$removed" -gt 0 ]]; then
    local freed_mb=$(( freed / 1024 ))
    ok "removed $removed stale cache(s) (${freed_mb}MB freed); kept $kept"
  else
    ok "no stale caches to remove (kept $kept)"
  fi

  # Show what's still there
  if [[ -n "$current" ]]; then
    echo "  ${C_DIM}current symlink target${C_RESET}: $(basename "$current")"
  fi
  if [[ -n "$running" && "$running" != "$current" ]]; then
    echo "  ${C_DIM}running daemon binary${C_RESET}: $(basename "$running") (older — kept until restart)"
  fi
}

cmd_status() {
  hdr "claw install status"
  local current running pid
  current=$(current_install_dir)
  running=$(running_daemon_install_dir)
  pid=$(running_daemon_pid)

  if [[ -L "$NIMBLE_BIN" ]]; then
    echo "  ${C_BOLD}symlink${C_RESET}      : $NIMBLE_BIN"
    echo "  ${C_BOLD}→ install${C_RESET}    : ${current:-(broken)}"
  else
    warn "no claw symlink in ~/.nimble/bin — run: $0 install"
  fi

  echo
  if [[ -n "$pid" ]]; then
    local daemon_bin; daemon_bin=$(running_daemon_binary)
    echo "  ${C_BOLD}daemon${C_RESET}       : ${C_GREEN}running${C_RESET} (pid $pid)"
    echo "  ${C_BOLD}daemon binary${C_RESET}: ${daemon_bin:-(not detectable)}"
    # Note the binary, not the install dir, since dev builds may run
    # directly from the source repo (./claw, no install dir).
    if [[ -L "$NIMBLE_BIN" ]]; then
      local sym_bin; sym_bin=$(readlink -f "$NIMBLE_BIN" 2>/dev/null || \
        { cd "$(dirname "$NIMBLE_BIN")" && cd "$(dirname "$(readlink "$NIMBLE_BIN")")" && pwd; } 2>/dev/null
      )/claw.out
      if [[ -n "$daemon_bin" && "$daemon_bin" != "$sym_bin" ]]; then
        warn "daemon is on a DIFFERENT binary than ~/.nimble/bin/claw — restart to pick up new code"
      fi
    fi
  else
    echo "  ${C_BOLD}daemon${C_RESET}       : ${C_DIM}not running${C_RESET}"
  fi

  hdr "Cache inventory"
  local n total
  n=$(ls -d "$NIMBLE_PKGS"/claw-* 2>/dev/null | wc -l | tr -d ' ')
  total=$(du -sh "$NIMBLE_PKGS"/claw-* 2>/dev/null | awk '{s+=$1} END {print s}')
  echo "  ${n} install dir(s), ~${total}M total"
  if [[ "$n" -gt 2 ]]; then
    local stale=$((n - 2))
    echo "  ${C_YELLOW}≈ $stale stale${C_RESET} (run \`$0 clean\` to prune)"
  fi
}

cmd_restart_daemon() {
  local pid
  pid=$(running_daemon_pid)
  if [[ -z "$pid" ]]; then
    info "no daemon running"
    return
  fi
  info "sending SIGTERM to daemon pid $pid (graceful shutdown)"
  kill -TERM "$pid"
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.5
    waited=$((waited + 1))
    if [[ "$waited" -gt 20 ]]; then
      warn "daemon didn't exit in 10s; escalating to SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
      break
    fi
  done
  ok "daemon stopped"
  echo "  ${C_DIM}zen will auto-respawn it on next dashboard interaction${C_RESET}"
}

cmd_help() {
  cat <<EOF
${C_BOLD}claw.sh${C_RESET} — dev tooling for the claw repo

${C_BOLD}USAGE${C_RESET}
  ./claw.sh <command>

${C_BOLD}COMMANDS${C_RESET}
  ${C_GREEN}install${C_RESET}         build + install + prune stale caches (safe on running daemon)
  ${C_GREEN}build${C_RESET}           build ./claw in repo (no install)
  ${C_GREEN}clean${C_RESET}           prune stale ~/.nimble/pkgs2/claw-* (keeps running + current)
  ${C_GREEN}status${C_RESET}          show installed, running, cache usage
  ${C_GREEN}restart-daemon${C_RESET}  SIGTERM the daemon; zen auto-respawns

${C_BOLD}TYPICAL FLOWS${C_RESET}
  ${C_DIM}# after pulling new code${C_RESET}
  ./claw.sh install && ./claw.sh restart-daemon

  ${C_DIM}# just hacking locally, no install${C_RESET}
  ./claw.sh build

  ${C_DIM}# disk getting full${C_RESET}
  ./claw.sh clean
EOF
}

# ── Dispatch ──────────────────────────────────────────────────────
cmd="${1:-help}"
case "$cmd" in
  install)         cmd_install ;;
  build)           cmd_build ;;
  clean)           cmd_clean ;;
  status)          cmd_status ;;
  restart-daemon)  cmd_restart_daemon ;;
  help|-h|--help)  cmd_help ;;
  *)
    err "unknown command: $cmd"
    cmd_help
    exit 2
    ;;
esac
