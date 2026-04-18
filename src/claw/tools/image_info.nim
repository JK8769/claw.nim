import std/[json, tables, os, asyncdispatch, strutils, options]
import types
const MAX_IMAGE_BYTES: uint64 = 5_242_880

type
  ImageInfoTool* = ref object of Tool

proc newImageInfoTool*(): ImageInfoTool =
  ImageInfoTool()

method name*(t: ImageInfoTool): string = "image_info"

method description*(t: ImageInfoTool): string = "Read image file metadata (format, dimensions, size)."

method parameters*(t: ImageInfoTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {"type": "string", "description": "Path to the image file"}
    },
    "required": %*["path"]
  }.toTable

proc detectFormat*(bytes: seq[byte] | openArray[byte]): string =
  if bytes.len < 4: return "unknown"
  if bytes[0] == 0x89.byte and bytes[1] == 'P'.byte and bytes[2] == 'N'.byte and bytes[3] == 'G'.byte: return "png"
  if bytes[0] == 0xFF.byte and bytes[1] == 0xD8.byte and bytes[2] == 0xFF.byte: return "jpeg"
  if bytes[0] == 'G'.byte and bytes[1] == 'I'.byte and bytes[2] == 'F'.byte and bytes[3] == '8'.byte: return "gif"
  if bytes[0] == 'R'.byte and bytes[1] == 'I'.byte and bytes[2] == 'F'.byte and bytes[3] == 'F'.byte:
    if bytes.len >= 12 and bytes[8] == 'W'.byte and bytes[9] == 'E'.byte and bytes[10] == 'B'.byte and bytes[11] == 'P'.byte: return "webp"
  if bytes[0] == 'B'.byte and bytes[1] == 'M'.byte: return "bmp"
  return "unknown"

proc jpegDimensions(bytes: seq[byte] | openArray[byte]): Option[(uint32, uint32)] =
  var i = 2
  while i + 1 < bytes.len:
    if bytes[i] != 0xFF.byte: return none((uint32, uint32))
    let marker = bytes[i + 1]
    i += 2

    # SOF0..SOF3
    if marker >= 0xC0.byte and marker <= 0xC3.byte:
      if i + 7 <= bytes.len:
        let h = (uint32(bytes[i + 3]) shl 8) or uint32(bytes[i + 4])
        let w = (uint32(bytes[i + 5]) shl 8) or uint32(bytes[i + 6])
        return some((w, h))
      return none((uint32, uint32))

    # Skip segment
    if i + 1 < bytes.len:
      let segLen: uint16 = (uint16(bytes[i]) shl 8) or uint16(bytes[i + 1])
      if segLen < 2: return none((uint32, uint32))
      i += int(segLen)
    else:
      return none((uint32, uint32))
  return none((uint32, uint32))

proc extractDimensions*(bytes: seq[byte] | openArray[byte], format: string): Option[(uint32, uint32)] =
  if format == "png":
    if bytes.len >= 24:
      let w = (uint32(bytes[16]) shl 24) or (uint32(bytes[17]) shl 16) or (uint32(bytes[18]) shl 8) or uint32(bytes[19])
      let h = (uint32(bytes[20]) shl 24) or (uint32(bytes[21]) shl 16) or (uint32(bytes[22]) shl 8) or uint32(bytes[23])
      return some((w, h))
  
  if format == "gif":
    if bytes.len >= 10:
      let w = uint32(bytes[6]) or (uint32(bytes[7]) shl 8)
      let h = uint32(bytes[8]) or (uint32(bytes[9]) shl 8)
      return some((w, h))

  if format == "bmp":
    if bytes.len >= 26:
      let w = uint32(bytes[18]) or (uint32(bytes[19]) shl 8) or (uint32(bytes[20]) shl 16) or (uint32(bytes[21]) shl 24)
      # Height can be negative in BMP, so we need to process it as signed 32-bit then abs
      var hRaw: int32 = cast[int32](uint32(bytes[22]) or (uint32(bytes[23]) shl 8) or (uint32(bytes[24]) shl 16) or (uint32(bytes[25]) shl 24))
      let h = if hRaw < 0: uint32(-hRaw) else: uint32(hRaw)
      return some((w, h))

  if format == "jpeg":
    return jpegDimensions(bytes)

  return none((uint32, uint32))

method execute*(t: ImageInfoTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let path = if args.hasKey("path"): args["path"].getStr() else: ""
  if path == "": return "Error: Missing 'path' parameter"

  let absPath = if isAbsolute(path): path else: getCurrentDir() / path
  if not fileExists(absPath):
    return "Error: File not found: " & path

  let size = cast[uint64](getFileSize(absPath))
  if size > MAX_IMAGE_BYTES:
    return "Error: Image too large: " & $size & " bytes (max " & $MAX_IMAGE_BYTES & " bytes)"

  try:
    var f = open(absPath)
    defer: f.close()
    
    var headerStr = newString(128)
    let bytesRead = f.readChars(headerStr.toOpenArray(0, 127))
    
    var bytes = newSeq[byte](bytesRead)
    for i in 0..<bytesRead: bytes[i] = headerStr[i].byte

    let format = detectFormat(bytes)
    let dims = extractDimensions(bytes, format)

    var output = "File: " & absPath & "\nFormat: " & format & "\nSize: " & $size & " bytes"
    if dims.isSome:
      let (w, h) = dims.get
      output &= "\nDimensions: " & $w & "x" & $h
    
    return output
  except Exception as e:
    return "Error reading metadata: " & e.msg
