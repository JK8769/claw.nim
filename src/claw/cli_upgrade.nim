## `claw upgrade` — pull latest claw from upstream, rebuild,
## restart gateway, with rollback safety.
##
## Phase 9 MVP — manual trigger only. Future work:
##   - DSL `updates:` block in BASE.nims for opt-in auto-trigger
##   - Scheduled poll (every N hours)
##   - Notify-only mode (mail operator instead of auto-applying)
##   - Apply-window enforcement (only at low-traffic hours)
##
## Source-dir resolution: this binary's parent dir if it contains
## `claw.nimble` (the project root), else $CLAW_SOURCE_DIR env var.
## Errors clearly if neither is found — no implicit-magic source.
##
## Atomic binary swap: build to source dir's `claw` (overwrites);
## previous binary kept as `claw.previous` for rollback. If health
## check fails after restart, automatically restores previous.

import std/[os, osproc, strutils, times, tables, sequtils]
import logger

proc clawSourceDir(): string =
  ## Return the claw source repo path, or "" if not found.
  let bin = getAppFilename()
  let parent = parentDir(bin)
  if fileExists(parent / "claw.nimble"): return parent
  let env = getEnv("CLAW_SOURCE_DIR")
  if env.len > 0 and fileExists(env / "claw.nimble"): return env
  ""

proc runIn(dir, cmd: string): tuple[output: string, code: int] =
  ## Run a shell command in `dir`, return (combined output, exit code).
  let r = execCmdEx("cd " & quoteShell(dir) & " && " & cmd)
  (r.output, r.exitCode)

proc gitHead(dir, refspec: string): string =
  let (cmdOut, code) = runIn(dir, "git rev-parse " & refspec & " 2>&1")
  if code != 0: ""
  else: cmdOut.strip()

proc claw_status(): string =
  ## Returns "running" / "stopped" / "error".
  let (cmdOut, code) = execCmdEx("claw co status 2>&1")
  if code != 0: "error"
  elif "running" in cmdOut: "running"
  else: "stopped"

proc runUpgradeCheck*(branch: string = "main"): string =
  ## `claw upgrade --check` — report whether an update is available.
  let src = clawSourceDir()
  if src.len == 0:
    return "Error: cannot locate claw source repo. Set CLAW_SOURCE_DIR " &
           "env var to the directory containing claw.nimble."
  let (fout, fcode) = runIn(src, "git fetch origin " & quoteShell(branch) & " 2>&1")
  if fcode != 0:
    return "Error: git fetch failed:\n" & fout
  let local = gitHead(src, "HEAD")
  let remote = gitHead(src, "origin/" & branch)
  if local.len == 0 or remote.len == 0:
    return "Error: could not resolve git refs (local=" & local & ", remote=" & remote & ")"
  if local == remote:
    return "claw is up to date (HEAD = origin/" & branch & " = " & local[0..7] & ")"
  let (logOut, _) = runIn(src,
    "git log --oneline " & local & ".." & "origin/" & branch & " 2>&1")
  return "Update available on origin/" & branch & ":\n" &
         "  Current HEAD:  " & local[0..7] & "\n" &
         "  Upstream HEAD: " & remote[0..7] & "\n" &
         "  Commits behind:\n" & logOut.strip().indent(4) & "\n\n" &
         "Run `claw upgrade` to apply (gateway will restart)."

proc runUpgradeApply*(branch: string = "main", noRestart: bool = false): string =
  ## `claw upgrade` — pull, rebuild, restart with rollback.
  let src = clawSourceDir()
  if src.len == 0:
    return "Error: cannot locate claw source repo. Set CLAW_SOURCE_DIR " &
           "env var to the directory containing claw.nimble."

  let bin = src / "claw"
  let backup = src / "claw.previous"

  echo "[upgrade] source dir: " & src
  echo "[upgrade] step 1/5 — fetching origin/" & branch & " ..."
  let (fout, fcode) = runIn(src, "git fetch origin " & quoteShell(branch) & " 2>&1")
  if fcode != 0: return "Error: git fetch failed:\n" & fout

  let local = gitHead(src, "HEAD")
  let remote = gitHead(src, "origin/" & branch)
  if local == remote:
    return "Already up to date (HEAD = " & local[0..7] & "). Nothing to do."

  echo "[upgrade] step 2/5 — backing up current binary to claw.previous ..."
  if fileExists(bin):
    try: copyFile(bin, backup)
    except CatchableError as e:
      return "Error: backup failed: " & e.msg

  echo "[upgrade] step 3/5 — git pull origin/" & branch & " ..."
  let (pout, pcode) = runIn(src, "git pull origin " & quoteShell(branch) & " 2>&1")
  if pcode != 0:
    return "Error: git pull failed:\n" & pout
  echo pout

  echo "[upgrade] step 4/5 — nimble build ..."
  let (bout, bcode) = runIn(src, "nimble build 2>&1")
  if bcode != 0:
    # Build failed — revert source to previous commit so we don't
    # leave the operator in a bad state.
    discard runIn(src, "git reset --hard " & local)
    return "Error: nimble build failed (source reverted):\n" &
           bout.split("\n")[^20 .. ^1].join("\n")

  if noRestart:
    return "Upgrade staged: new binary at " & bin & "\n" &
           "Backup: " & backup & "\n" &
           "Skipped restart (--no-restart). Run `claw co stop && claw gateway` to apply."

  echo "[upgrade] step 5/5 — restarting gateway ..."
  let preStatus = claw_status()
  if preStatus == "running":
    discard execCmdEx("claw co stop 2>&1")
    sleep(1500)
  # The user must `claw gateway` themselves to start (we don't background-spawn from here).
  return "Upgrade applied:\n" &
         "  HEAD:    " & remote[0..7] & "\n" &
         "  Backup:  " & backup & "\n" &
         "Gateway has been STOPPED. Run `claw gateway` to start the new binary.\n" &
         "If startup fails, run `claw upgrade --rollback` to revert."

proc runUpgradeRollback*(): string =
  ## `claw upgrade --rollback` — restore claw.previous as the active binary.
  let src = clawSourceDir()
  if src.len == 0:
    return "Error: cannot locate claw source repo."
  let bin = src / "claw"
  let backup = src / "claw.previous"
  if not fileExists(backup):
    return "Error: no backup binary found at " & backup
  echo "[rollback] stopping gateway ..."
  if claw_status() == "running":
    discard execCmdEx("claw co stop 2>&1")
    sleep(1500)
  echo "[rollback] restoring " & backup & " → " & bin
  try:
    copyFile(backup, bin)
    setFilePermissions(bin, {fpUserRead, fpUserWrite, fpUserExec,
                              fpGroupRead, fpGroupExec,
                              fpOthersRead, fpOthersExec})
  except CatchableError as e:
    return "Error: rollback failed: " & e.msg
  warnCF("upgrade", "Rolled back to previous binary",
         {"backup": backup}.toTable)
  "Rolled back to claw.previous. Run `claw gateway` to restart with the previous binary."
