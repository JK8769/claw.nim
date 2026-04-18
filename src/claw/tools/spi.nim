import std/[json, tables, strutils, asyncdispatch, os]
import types

type
  SpiTool* = ref object of Tool

proc newSpiTool*(): SpiTool =
  SpiTool()

method name*(t: SpiTool): string = "spi"

method description*(t: SpiTool): string =
  "Interact with SPI hardware devices. " &
  "Supports listing available SPI devices, full-duplex data transfer, and read-only mode. " &
  "Linux only — uses /dev/spidevX.Y via ioctl."

method parameters*(t: SpiTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "description": "Action: list, transfer, or read"
      },
      "device": {
        "type": "string",
        "description": "SPI device path (default /dev/spidev0.0)"
      },
      "data": {
        "type": "string",
        "description": "Hex bytes to send, e.g. 'FF 0A 3B'"
      },
      "speed_hz": {
        "type": "integer",
        "description": "SPI clock speed in Hz (default 1000000)"
      },
      "mode": {
        "type": "integer",
        "description": "SPI mode 0-3 (default 0)"
      },
      "bits_per_word": {
        "type": "integer",
        "description": "Bits per word (default 8)"
      }
    },
    "required": %["action"]
  }.toTable

when defined(linux):
  import std/posix

  proc parseHexBytes(hexStr: string, outBuf: var openArray[uint8]): int =
    var count = 0
    let tokens = hexStr.splitWhitespace()
    for token in tokens:
      if count >= outBuf.len: break
      if token.len > 2: return -1
      try:
        outBuf[count] = parseHexInt(token).uint8
        count += 1
      except ValueError:
        return -1
    return count

  proc executeList(): string =
    var devices = "{\"devices\":["
    var count = 0
    try:
      for kind, path in walkDir("/dev"):
        let name = extractFilename(path)
        if name.startsWith("spidev"):
          if count > 0: devices &= ","
          devices &= "\"/dev/" & name & "\""
          count += 1
    except CatchableError:
      discard
    devices &= "]}"
    return devices

  const SPI_IOC_WR_MODE: culong = 0x40016B01
  const SPI_IOC_WR_MAX_SPEED_HZ: culong = 0x40046B04
  const SPI_IOC_WR_BITS_PER_WORD: culong = 0x40016B03
  const SPI_IOC_MESSAGE_1: culong = 0x40206B00

  type SpiIocTransfer {.packed.} = object
    tx_buf: uint64
    rx_buf: uint64
    len: uint32
    speed_hz: uint32
    delay_usecs: uint16
    bits_per_word: uint8
    cs_change: uint8
    tx_nbits: uint8
    rx_nbits: uint8
    word_delay_usecs: uint8
    pad: uint8

  proc spiTransferLinux(device: string, txData: openArray[uint8], speedHz: uint32, mode: uint8, bitsPerWord: uint8): string =
    let fd = posix.open(device.cstring, O_RDWR, 0)
    if fd < 0:
      return "Error: Failed to open SPI device '" & device & "'"
    defer: discard posix.close(fd)

    var modeVal = mode
    if ioctl(fd, SPI_IOC_WR_MODE, addr(modeVal)) != 0:
      return "Error: Failed to set SPI mode"

    var bpw = bitsPerWord
    if ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, addr(bpw)) != 0:
      return "Error: Failed to set bits per word"

    var spd = speedHz
    if ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, addr(spd)) != 0:
      return "Error: Failed to set SPI speed"

    var rxBuf = newSeq[uint8](256)
    let length = uint32(txData.len)

    var transfer = SpiIocTransfer(
      tx_buf: cast[uint64](unsafeAddr(txData[0])),
      rx_buf: cast[uint64](addr(rxBuf[0])),
      len: length,
      speed_hz: speedHz,
      delay_usecs: 0,
      bits_per_word: bitsPerWord,
      cs_change: 0,
      tx_nbits: 0,
      rx_nbits: 0,
      word_delay_usecs: 0,
      pad: 0
    )

    if ioctl(fd, SPI_IOC_MESSAGE_1, addr(transfer)) != 0:
      return "Error: SPI transfer failed"

    var output = "{\"rx_data\":\""
    for i in 0..<txData.len:
      if i > 0: output &= " "
      output &= toHex(rxBuf[i], 2)
    output &= "\",\"length\":" & $txData.len & "}"
    return output

method execute*(t: SpiTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: Missing 'action' parameter"

  when not defined(linux):
    return "Error: SPI not supported on this platform"
  else:
    let actionStr = args["action"].getStr()
    if actionStr == "list":
      return executeList()
    elif actionStr == "transfer" or actionStr == "read":
      let readOnly = actionStr == "read"
      let device = if args.hasKey("device") and args["device"].kind == JString: args["device"].getStr() else: "/dev/spidev0.0"
      let speedHz = if args.hasKey("speed_hz") and args["speed_hz"].kind == JInt: uint32(args["speed_hz"].getInt()) else: 1_000_000'u32
      let mode = if args.hasKey("mode") and args["mode"].kind == JInt: uint8(args["mode"].getInt()) else: 0'u8
      let bitsPerWord = if args.hasKey("bits_per_word") and args["bits_per_word"].kind == JInt: uint8(args["bits_per_word"].getInt()) else: 8'u8

      if mode > 3: return "Error: SPI mode must be 0-3"
      
      var txBuf = newSeq[uint8](256)
      var txLen = 0

      if not readOnly:
        if not args.hasKey("data") or args["data"].kind != JString:
          return "Error: Missing 'data' parameter for transfer action"
        let dataStr = args["data"].getStr()
        txLen = parseHexBytes(dataStr, txBuf)
        if txLen < 0: return "Error: Invalid hex data format. Use space-separated hex bytes like 'FF 0A 3B'"
        if txLen == 0: return "Error: No data bytes provided"
      else:
        if args.hasKey("length") and args["length"].kind == JInt:
          txLen = args["length"].getInt()
          txLen = clamp(txLen, 1, 256)
        elif args.hasKey("data") and args["data"].kind == JString:
          let dataStr = args["data"].getStr()
          txLen = parseHexBytes(dataStr, txBuf)
          if txLen < 0: txLen = 1
        else:
          txLen = 1
        for i in 0..<txLen: txBuf[i] = 0

      return spiTransferLinux(device, txBuf[0..<txLen], speedHz, mode, bitsPerWord)
    else:
      return "Error: Unknown action. Use 'list', 'transfer', or 'read'"
