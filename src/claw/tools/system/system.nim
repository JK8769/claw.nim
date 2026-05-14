## system — the sea of the system / shell / workstation trio.
##
## Direct OS / hardware substrate operations. Host-focused: this runs on
## the developer's machine, not on embedded devices. For working WITH
## an embedded device, see the transports (uart, bluetooth, usb).
##
## Actions:
##
##   ── Display + OS primitives (Phase 1) ──
##   capture     — screenshot the display
##   info        — host machine info (hostname, OS, arch, cpu count, etc.)
##
##   ── Transports — host ↔ device (Phase 2 stubs) ──
##   uart        — serial ports (list, open/close, send/receive, configure)
##   bluetooth   — BLE (scan, connect, read/write characteristic)
##   usb         — USB device enumeration
##
##   ── Host introspection (Phase 2 stubs) ──
##   processes   — list running processes
##   metrics     — CPU / memory / disk / network sample
##   services    — systemd / launchd: list / start / stop / status
##   signal      — send POSIX signal to PID
##   clipboard   — read/write OS clipboard
##   notify      — desktop notification

import std/[json, tables, asyncdispatch, strutils, os, osproc, cpuinfo]
import ../types
import ../spec

const ToolSpec* = spec(
  name = "system",
  description = "Host machine substrate. Display capture + host info today; transports (uart/bluetooth/usb), introspection (processes/metrics/services/signal/clipboard/notify) declared and stubbed for Phase 2. For embedded peripheral I/O (i2c/spi/gpio) install a separate skill.",
  tags = @["system", "host", "core"],
  searchKeywords = @["screenshot", "screen capture", "display", "host info",
                      "machine info", "hostname", "uname", "cpu",
                      "uart", "serial", "tty", "flash firmware", "console",
                      "bluetooth", "ble", "usb", "lsusb",
                      "processes", "ps", "top", "metrics",
                      "services", "systemd", "launchd",
                      "signal", "kill", "clipboard", "pasteboard",
                      "notify", "notification"],
  domain = "system",
  default = true,
  heartbeatSafe = false,
  category = "system",
)

type
  SystemTool* = ref object of Tool
    workspaceDir*: string

proc newSystemTool*(workspaceDir: string): SystemTool =
  SystemTool(workspaceDir: workspaceDir)

method name*(t: SystemTool): string = "system"

method description*(t: SystemTool): string =
  "Host machine substrate — the sea of the system / shell / workstation trio.\n\n" &
  "Phase 1 actions (implemented):\n" &
  "  capture  — screenshot the display (returns [IMAGE:path] marker)\n" &
  "  info     — host machine info (hostname / OS / arch / cpu count)\n\n" &
  "Phase 2 actions (declared, return 'not yet implemented' — surface " &
  "locked so agents can plan against the future API):\n" &
  "  uart       — serial ports (list/open/send/receive — for firmware flash, console)\n" &
  "  bluetooth  — BLE (scan/connect/read/write characteristic)\n" &
  "  usb        — USB device enumeration\n" &
  "  processes  — list running processes\n" &
  "  metrics    — CPU / memory / disk / network sample\n" &
  "  services   — systemd / launchd lifecycle\n" &
  "  signal     — send POSIX signal to PID\n" &
  "  clipboard  — read / write OS clipboard\n" &
  "  notify     — desktop notification\n\n" &
  "For on-device peripheral I/O (i2c / spi / gpio), install a separate " &
  "skill — host-focused system tool intentionally omits them."

method parameters*(t: SystemTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["capture", "info",
                 "uart", "bluetooth", "usb",
                 "processes", "metrics", "services", "signal",
                 "clipboard", "notify"],
        "description": "System operation to perform. capture/info implemented; rest declared for Phase 2."
      },
      "filename": {
        "type": "string",
        "description": "capture (optional) — output filename. Default: screenshot.png in workspace."
      }
    },
    "required": %["action"]
  }.toTable

# ── action handlers ─────────────────────────────────────────────────

proc doCapture(t: SystemTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let filename = if args.hasKey("filename"): args["filename"].getStr() else: "screenshot.png"
  let outputPath = t.workspaceDir / filename

  # In test mode, return a mock result without spawning a real process
  let isTesting = defined(testing)
  if isTesting:
    return "[IMAGE:" & outputPath & "]"

  var argv: seq[string]
  when hostOS == "macosx":
    argv = @["screencapture", "-x", outputPath]
  elif hostOS == "linux":
    argv = @["import", "-window", "root", outputPath]
  else:
    return "Error: capture not supported on this platform"

  try:
    let (output, exitCode) = execCmdEx(argv.join(" "))
    if exitCode == 0:
      return "[IMAGE:" & outputPath & "]"
    let errMsg = if output.len > 0: output else: "unknown error"
    return "Error: capture command failed: " & errMsg
  except Exception as e:
    return "Error: failed to spawn capture command: " & e.msg

proc doInfo(t: SystemTool): string =
  ## Host machine info — hostname, OS, arch, cpu count.
  ## Cheap; pulls only stdlib data (no shell). Extend with OS-specific
  ## detail (CPU model, memory totals, etc.) when there's a need.
  var lines: seq[string]
  let host = block:
    try: getEnv("HOSTNAME", "") & (if getEnv("HOSTNAME", "") == "": "unknown" else: "")
    except: "unknown"
  let hostname = if host.len > 0 and host != "unknown": host
                 else:
                   try:
                     let (out2, code) = execCmdEx("hostname")
                     if code == 0: out2.strip() else: "unknown"
                   except: "unknown"
  lines.add("hostname: " & hostname)
  lines.add("os: " & hostOS)
  lines.add("arch: " & hostCPU)
  lines.add("cpus: " & $cpuinfo.countProcessors())
  lines.add("workspace: " & t.workspaceDir)
  lines.join("\n")

# ── Phase 2 stub helper ─────────────────────────────────────────────

proc phase2Stub(action: string): string =
  "Error: '" & action & "' is in the action set but not yet implemented " &
  "(planned for Phase 2). The surface is locked so agents can plan " &
  "against the future API."

# ── dispatch ────────────────────────────────────────────────────────

method execute*(t: SystemTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required"
  let action = args["action"].getStr().toLowerAscii()
  case action
  of "capture":   return await doCapture(t, args)
  of "info":      return doInfo(t)
  of "uart", "bluetooth", "usb",
     "processes", "metrics", "services", "signal",
     "clipboard", "notify":
    return phase2Stub(action)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: capture | info | uart | bluetooth | usb | " &
           "processes | metrics | services | signal | clipboard | notify."
