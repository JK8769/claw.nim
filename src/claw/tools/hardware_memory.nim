import std/[json, tables, strutils, osproc, asyncdispatch]
import types

const NUCLEO_RAM_BASE* = 0x2000_0000

type
  HardwareMemoryTool* = ref object of Tool
    boards*: seq[string]

proc newHardwareMemoryTool*(boards: seq[string]): HardwareMemoryTool =
  HardwareMemoryTool(boards: boards)

method name*(t: HardwareMemoryTool): string = "hardware_memory"

method description*(t: HardwareMemoryTool): string =
  "Read/write hardware memory maps via probe-rs. " &
  "Use for: 'read memory', 'read register', 'dump memory', 'write memory'. " &
  "Params: action (read/write), address (hex), length (bytes), value (for write)."

method parameters*(t: HardwareMemoryTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["read", "write"],
        "description": "read or write memory"
      },
      "address": {
        "type": "string",
        "description": "Memory address in hex (e.g. 0x20000000)"
      },
      "length": {
        "type": "integer",
        "description": "Bytes to read (default 128, max 256)"
      },
      "value": {
        "type": "string",
        "description": "Hex value to write (for write action)"
      },
      "board": {
        "type": "string",
        "description": "Board name (optional if only one configured)"
      }
    },
    "required": %["action"]
  }.toTable

proc chipForBoard(board: string): string =
  if board == "nucleo-f401re": return "STM32F401RETx"
  if board == "nucleo-f411re": return "STM32F411RETx"
  return ""

proc parseHexAddress(s: string): uint64 =
  var trimmed = s.strip()
  if trimmed.toLowerAscii().startsWith("0x"):
    trimmed = trimmed[2..^1]
  try:
    return parseHexInt(trimmed).uint64
  except ValueError:
    return 0'u64

proc probeRsAvailable(): bool =
  let (_, exitCode) = execCmdEx("probe-rs --version")
  return exitCode == 0

proc probeRead(chip: string, address: uint64, length: int): Future[string] {.async.} =
  if not probeRsAvailable():
    return "Error: probe-rs not found. Install with: cargo install probe-rs-tools"
  
  let addrStr = strutils.format("0x$1", toHex(address, 8))
  let lenStr = $length
  
  let cmd = "probe-rs read --chip " & chip & " " & addrStr & " " & lenStr
  let (outp, exitCode) = execCmdEx(cmd)
  
  if exitCode == 0:
    if outp.strip() != "":
      return outp.strip()
    return "(no output from probe-rs)"
  
  return "Error: probe-rs read failed (exit " & $exitCode & "):\n" & outp.strip()

proc probeWrite(chip: string, address: uint64, value: string): Future[string] {.async.} =
  if not probeRsAvailable():
    return "Error: probe-rs not found. Install with: cargo install probe-rs-tools"
  
  let addrStr = strutils.format("0x$1", toHex(address, 8))
  
  let cmd = "probe-rs write --chip " & chip & " " & addrStr & " " & value
  let (outp, exitCode) = execCmdEx(cmd)
  
  if exitCode == 0:
    return strutils.format("Write OK: $1 <- $2 ($3)\n$4", addrStr, value, chip, outp.strip())
  
  return "Error: probe-rs write failed (exit " & $exitCode & "):\n" & outp.strip()

method execute*(t: HardwareMemoryTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.boards.len == 0:
    return "Error: No peripherals configured. Add boards to config.toml [peripherals.boards]."

  if not args.hasKey("action"):
    return "Error: Missing 'action' parameter (read or write)"
  let action = args["action"].getStr()

  let board = if args.hasKey("board") and args["board"].kind == JString:
    args["board"].getStr()
  else:
    if t.boards.len > 0: t.boards[0] else: "unknown"

  let chip = chipForBoard(board)
  if chip == "":
    return "Error: Memory operations only support nucleo-f401re, nucleo-f411re. Got: " & board

  let addressStr = if args.hasKey("address") and args["address"].kind == JString:
    args["address"].getStr()
  else:
    "0x20000000"
  
  var address = parseHexAddress(addressStr)
  if address == 0 and addressStr.strip() != "0x0" and addressStr.strip() != "0":
    address = NUCLEO_RAM_BASE

  if action == "read":
    var length = 128
    if args.hasKey("length") and args["length"].kind == JInt:
      length = args["length"].getInt()
    length = clamp(length, 1, 256)
    return await probeRead(chip, address, length)
  elif action == "write":
    if not args.hasKey("value"):
      return "Error: Missing 'value' parameter for write action"
    let value = args["value"].getStr()
    return await probeWrite(chip, address, value)
  else:
    return "Error: Unknown action '" & action & "'. Use 'read' or 'write'."
