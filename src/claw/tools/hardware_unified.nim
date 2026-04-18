## Unified hardware tool — replaces i2c, spi, hardware_board_info, hardware_memory.
## Single tool with `action` parameter dispatching to the appropriate operation.

import std/[json, tables, asyncdispatch, strutils, strformat]
import types
import i2c, spi, hardware_info, hardware_memory

type
  UnifiedHardwareTool* = ref object of Tool
    i2cTool: I2cTool
    spiTool: SpiTool
    boardInfoTool: HardwareBoardInfoTool
    memoryTool: HardwareMemoryTool

proc newUnifiedHardwareTool*(boards: seq[string] = @[]): UnifiedHardwareTool =
  UnifiedHardwareTool(
    i2cTool: newI2cTool(),
    spiTool: newSpiTool(),
    boardInfoTool: newHardwareBoardInfoTool(boards),
    memoryTool: newHardwareMemoryTool(boards)
  )

method name*(t: UnifiedHardwareTool): string = "hardware"

method description*(t: UnifiedHardwareTool): string =
  "Hardware peripheral access for I2C, SPI, board info, and memory operations.\n\n" &
  "Actions:\n" &
  "  i2c        — I2C operations (detect/scan/read/write). Params: bus, address, register, value, length\n" &
  "  spi        — SPI operations (list/transfer/read). Params: device, data, speed_hz, mode\n" &
  "  board_info — Query board specs. Params: board (optional)\n" &
  "  mem_read   — Read board memory. Params: address, length, board\n" &
  "  mem_write  — Write board memory. Params: address, value, board\n\n" &
  "For I2C: address in hex (0x03-0x77). For SPI: device path like /dev/spidevX.Y."

method parameters*(t: UnifiedHardwareTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["i2c", "spi", "board_info", "mem_read", "mem_write"],
        "description": "Hardware operation to perform"
      },
      "sub_action": {
        "type": "string",
        "description": "Sub-action for i2c (detect/scan/read/write) or spi (list/transfer/read)"
      },
      "bus": {"type": "integer", "description": "I2C bus number"},
      "address": {"type": "string", "description": "Device/memory address in hex"},
      "register": {"type": "integer", "description": "I2C register number"},
      "value": {"type": "string", "description": "Value to write (hex)"},
      "length": {"type": "integer", "description": "Bytes to read"},
      "device": {"type": "string", "description": "SPI device path"},
      "data": {"type": "string", "description": "SPI data bytes in hex"},
      "speed_hz": {"type": "integer", "description": "SPI clock speed"},
      "mode": {"type": "integer", "description": "SPI mode 0-3"},
      "board": {"type": "string", "description": "Board identifier"}
    },
    "required": %["action"]
  }.toTable

method execute*(t: UnifiedHardwareTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let action = if args.hasKey("action"): args["action"].getStr() else: ""

  case action
  of "i2c":
    # Delegate to I2C tool — pass action as sub_action
    var i2cArgs = args
    if args.hasKey("sub_action"):
      i2cArgs["action"] = args["sub_action"]
    elif not args.hasKey("action") or args["action"].getStr() == "i2c":
      i2cArgs["action"] = %"detect"
    return await t.i2cTool.execute(i2cArgs)

  of "spi":
    var spiArgs = args
    if args.hasKey("sub_action"):
      spiArgs["action"] = args["sub_action"]
    elif not args.hasKey("action") or args["action"].getStr() == "spi":
      spiArgs["action"] = %"list"
    return await t.spiTool.execute(spiArgs)

  of "board_info":
    return await t.boardInfoTool.execute(args)

  of "mem_read":
    var memArgs = args
    memArgs["action"] = %"read"
    return await t.memoryTool.execute(memArgs)

  of "mem_write":
    var memArgs = args
    memArgs["action"] = %"write"
    return await t.memoryTool.execute(memArgs)

  else:
    return "Error: Unknown action '{action}'. Use: i2c, spi, board_info, mem_read, mem_write".fmt
