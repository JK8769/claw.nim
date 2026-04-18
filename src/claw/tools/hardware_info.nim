import std/[json, tables, strutils, options, asyncdispatch]
import types

type
  BoardInfo = object
    id: string
    chip: string
    desc: string

const BOARD_DB = [
  BoardInfo(
    id: "nucleo-f401re",
    chip: "STM32F401RET6",
    desc: "ARM Cortex-M4, 84 MHz. Flash: 512 KB, RAM: 128 KB. User LED on PA5 (pin 13)."
  ),
  BoardInfo(
    id: "nucleo-f411re",
    chip: "STM32F411RET6",
    desc: "ARM Cortex-M4, 100 MHz. Flash: 512 KB, RAM: 128 KB. User LED on PA5 (pin 13)."
  ),
  BoardInfo(
    id: "arduino-uno",
    chip: "ATmega328P",
    desc: "8-bit AVR, 16 MHz. Flash: 16 KB, SRAM: 2 KB. Built-in LED on pin 13."
  ),
  BoardInfo(
    id: "arduino-uno-q",
    chip: "STM32U585 + Qualcomm",
    desc: "Dual-core: STM32 (MCU) + Linux (aarch64). GPIO via Bridge app on port 9999."
  ),
  BoardInfo(
    id: "esp32",
    chip: "ESP32",
    desc: "Dual-core Xtensa LX6, 240 MHz. Flash: 4 MB typical. Built-in LED on GPIO 2."
  ),
  BoardInfo(
    id: "rpi-gpio",
    chip: "Raspberry Pi",
    desc: "ARM Linux. Native GPIO via sysfs/rppal. No fixed LED pin."
  )
]

type
  HardwareBoardInfoTool* = ref object of Tool
    boards*: seq[string]

proc newHardwareBoardInfoTool*(boards: seq[string]): HardwareBoardInfoTool =
  HardwareBoardInfoTool(boards: boards)

method name*(t: HardwareBoardInfoTool): string = "hardware_board_info"

method description*(t: HardwareBoardInfoTool): string =
  "Return board info (chip, architecture, memory map) for connected hardware. " &
  "Use for: 'board info', 'what board', 'connected hardware', 'chip info', 'memory map'."

method parameters*(t: HardwareBoardInfoTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "board": {
        "type": "string",
        "description": "Board name (e.g. nucleo-f401re). If omitted, returns info for first configured board."
      }
    }
  }.toTable

proc memoryMapStatic(board: string): Option[string] =
  if board == "nucleo-f401re" or board == "nucleo-f411re":
    return some("Flash: 0x0800_0000 - 0x0807_FFFF (512 KB)\nRAM: 0x2000_0000 - 0x2001_FFFF (128 KB)")
  if board == "arduino-uno":
    return some("Flash: 16 KB, SRAM: 2 KB, EEPROM: 1 KB")
  if board == "esp32":
    return some("Flash: 4 MB, IRAM/DRAM per ESP-IDF layout")
  return none(string)

method execute*(t: HardwareBoardInfoTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.boards.len == 0:
    return "Error: No peripherals configured. Add boards to config.toml [peripherals.boards]."

  let board = if args.hasKey("board") and args["board"].kind == JString:
    args["board"].getStr()
  else:
    if t.boards.len > 0: t.boards[0] else: "unknown"

  for entry in BOARD_DB:
    if entry.id == board:
      var output = "**Board:** " & board & "\n**Chip:** " & entry.chip & "\n**Description:** " & entry.desc
      let memMap = memoryMapStatic(board)
      if memMap.isSome:
        output.add("\n\n**Memory map:**\n" & memMap.get)
      return output

  return strutils.format("Board '$1' configured. No static info available.", board)
