import std/[json, tables, strutils, asyncdispatch, os]
import types

when defined(linux):
  import std/posix
  
  const I2C_SLAVE: culong = 0x0703
  const I2C_FUNCS: culong = 0x0705

const I2C_ADDR_MIN: uint8 = 0x03
const I2C_ADDR_MAX: uint8 = 0x77

type
  I2cTool* = ref object of Tool

proc newI2cTool*(): I2cTool =
  I2cTool()

method name*(t: I2cTool): string = "i2c"

method description*(t: I2cTool): string =
  "I2C hardware tool. Actions: detect (list buses), scan (find devices on bus), " &
  "read (read register bytes), write (write register byte). Linux only."

method parameters*(t: I2cTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "description": "Action: detect, scan, read, write"
      },
      "bus": {
        "type": "integer",
        "description": "I2C bus number (e.g. 1 for /dev/i2c-1)"
      },
      "address": {
        "type": "string",
        "description": "Device address in hex (0x03-0x77)"
      },
      "register": {
        "type": "integer",
        "description": "Register number to read/write"
      },
      "value": {
        "type": "integer",
        "description": "Byte value to write (0-255)"
      },
      "length": {
        "type": "integer",
        "description": "Number of bytes to read (default 1)"
      }
    },
    "required": %["action"]
  }.toTable

when defined(linux):
  proc parseAddress(args: Table[string, JsonNode]): int =
    if not args.hasKey("address") or args["address"].kind != JString:
      return -1
    let addrStr = args["address"].getStr()
    var hex = addrStr.strip()
    if hex.toLowerAscii().startsWith("0x"):
      hex = hex[2..^1]
    if hex == "": return -1
    try:
      let val = parseHexInt(hex)
      if val < I2C_ADDR_MIN.int or val > I2C_ADDR_MAX.int: return -1
      return val
    except ValueError:
      return -1

  proc detectLinux(): string =
    var found = 0
    var output = "{\"buses\":["
    for i in 0..15:
      let path = "/dev/i2c-" & $i
      if fileExists(path):
        if found > 0: output &= ","
        output &= "\"" & path & "\""
        found += 1
    output &= "],\"count\":" & $found & "}"
    return output

  proc scanLinux(bus: int): string =
    let path = "/dev/i2c-" & $bus
    let fd = posix.open(path.cstring, O_RDWR, 0)
    if fd < 0:
      return "Error: Cannot open I2C bus (permission denied or bus not found)"
    defer: discard posix.close(fd)

    var output = "{\"bus\":" & $bus & ",\"devices\":["
    var found = 0

    for addr in I2C_ADDR_MIN..I2C_ADDR_MAX:
      let rc = ioctl(fd, I2C_SLAVE, addr)
      if rc < 0: continue

      var dummy: array[0, uint8]
      let wrc = posix.write(fd, addr(dummy), 0)
      if wrc < 0: continue
      
      if found > 0: output &= ","
      output &= "\"0x" & toHex(addr, 2) & "\""
      found += 1
      
    output &= "],\"count\":" & $found & "}"
    return output

  proc readLinux(bus: int, address: int, reg: int, length: int): string =
    let path = "/dev/i2c-" & $bus
    let fd = posix.open(path.cstring, O_RDWR, 0)
    if fd < 0:
      return "Error: Cannot open I2C bus"
    defer: discard posix.close(fd)

    let rc = ioctl(fd, I2C_SLAVE, cint(address))
    if rc < 0:
      return "Error: Failed to set I2C slave address"

    var regByte = uint8(reg)
    if posix.write(fd, addr(regByte), 1) != 1:
      return "Error: Failed to write register address"

    var readBuf = newSeq[uint8](length)
    let n = posix.read(fd, addr(readBuf[0]), length)
    if n < 0:
      return "Error: Failed to read from I2C device"
      
    var output = "{\"bus\":" & $bus & ",\"address\":\"0x" & toHex(address, 2) & "\",\"register\":" & $reg & ",\"data\":["
    for i in 0..<n:
      if i > 0: output &= ","
      output &= $readBuf[i]
      
    output &= "],\"hex\":\""
    for i in 0..<n:
      output &= toHex(readBuf[i], 2)
    output &= "\"}"
    return output

  proc writeLinux(bus: int, address: int, reg: int, value: int): string =
    let path = "/dev/i2c-" & $bus
    let fd = posix.open(path.cstring, O_RDWR, 0)
    if fd < 0:
      return "Error: Cannot open I2C bus"
    defer: discard posix.close(fd)

    let rc = ioctl(fd, I2C_SLAVE, cint(address))
    if rc < 0:
      return "Error: Failed to set I2C slave address"

    var writeBuf: array[2, uint8]
    writeBuf[0] = uint8(reg)
    writeBuf[1] = uint8(value)
    if posix.write(fd, addr(writeBuf[0]), 2) != 2:
      return "Error: Failed to write to I2C device"
      
    return "{\"bus\":" & $bus & ",\"address\":\"0x" & toHex(address, 2) & "\",\"register\":" & $reg & ",\"value\":" & $value & ",\"status\":\"ok\"}"

method execute*(t: I2cTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: Missing 'action' parameter"
  
  when not defined(linux):
    return "Error: I2C not supported on this platform"
  else:
    let actionStr = args["action"].getStr()
    if actionStr == "detect":
      return detectLinux()
      
    elif actionStr == "scan":
      if not args.hasKey("bus") or args["bus"].kind != JInt:
        return "Error: Missing 'bus' parameter for scan"
      let bus = args["bus"].getInt()
      if bus < 0: return "Error: Bus number must be non-negative"
      return scanLinux(bus)
      
    elif actionStr == "read":
      if not args.hasKey("bus") or args["bus"].kind != JInt:
        return "Error: Missing 'bus' parameter for read"
      let bus = args["bus"].getInt()
      if bus < 0: return "Error: Bus number must be non-negative"
      
      let addrVal = parseAddress(args)
      if addrVal < 0: return "Error: Missing or invalid 'address' (hex 0x03-0x77)"
      
      if not args.hasKey("register") or args["register"].kind != JInt:
        return "Error: Missing 'register' parameter for read"
      let reg = args["register"].getInt()
      if reg < 0 or reg > 255: return "Error: Register must be 0-255"
      
      var length = 1
      if args.hasKey("length") and args["length"].kind == JInt:
        length = args["length"].getInt()
      if length < 1 or length > 32: return "Error: Length must be 1-32"
      
      return readLinux(bus, addrVal, reg, length)
      
    elif actionStr == "write":
      if not args.hasKey("bus") or args["bus"].kind != JInt:
        return "Error: Missing 'bus' parameter for write"
      let bus = args["bus"].getInt()
      if bus < 0: return "Error: Bus number must be non-negative"
      
      let addrVal = parseAddress(args)
      if addrVal < 0: return "Error: Missing or invalid 'address' (hex 0x03-0x77)"
      
      if not args.hasKey("register") or args["register"].kind != JInt:
        return "Error: Missing 'register' parameter for write"
      let reg = args["register"].getInt()
      if reg < 0 or reg > 255: return "Error: Register must be 0-255"
      
      if not args.hasKey("value") or args["value"].kind != JInt:
        return "Error: Missing 'value' parameter for write"
      let value = args["value"].getInt()
      if value < 0 or value > 255: return "Error: Value must be 0-255"
      
      return writeLinux(bus, addrVal, reg, value)
      
    else:
      return "Error: Unknown action. Use: detect, scan, read, write"
