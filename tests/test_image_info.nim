import std/[unittest, json, tables, os, strutils, asyncdispatch, options, sequtils]
import ../src/nimclaw/tools/types
import ../src/nimclaw/tools/image_info

suite "ImageInfoTool Format Detection":
  test "detect PNG":
    let bytes = [byte 0x89, 'P'.byte, 'N'.byte, 'G'.byte, 0x0D, 0x0A, 0x1A, 0x0A]
    check detectFormat(@bytes) == "png"

  test "detect JPEG":
    let bytes = [byte 0xFF, 0xD8, 0xFF, 0xE0]
    check detectFormat(@bytes) == "jpeg"

  test "detect GIF":
    let bytes = "GIF89a"
    var bSeq = newSeq[byte](bytes.len)
    for i, c in bytes: bSeq[i] = c.byte
    check detectFormat(bSeq) == "gif"

  test "detect BMP":
    let bytes = [byte 'B'.byte, 'M'.byte, 0x00, 0x00]
    check detectFormat(@bytes) == "bmp"

  test "detect WEBP":
    let bytes = [byte 'R'.byte, 'I'.byte, 'F'.byte, 'F'.byte, 0x00, 0x00, 0x00, 0x00, 'W'.byte, 'E'.byte, 'B'.byte, 'P'.byte]
    check detectFormat(@bytes) == "webp"

  test "detect unknown short":
    let bytes = [byte 0x00, 0x01]
    check detectFormat(@bytes) == "unknown"

suite "ImageInfoTool Dimension Extraction":
  test "PNG dimensions":
    var bytes = newSeq[byte](30)
    # Signature
    bytes[0..7] = [byte 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    # IHDR length (13)
    bytes[8..11] = [byte 0x00, 0x00, 0x00, 0x0D]
    # "IHDR"
    bytes[12..15] = [byte 0x49, 0x48, 0x44, 0x52]
    # Width: 800 (Big Endian) 0x00000320
    bytes[16..19] = [byte 0x00, 0x00, 0x03, 0x20]
    # Height: 600 (Big Endian) 0x00000258
    bytes[20..23] = [byte 0x00, 0x00, 0x02, 0x58]
    
    let dims = extractDimensions(bytes, "png")
    check dims.isSome
    check dims.get[0] == 800
    check dims.get[1] == 600

  test "GIF dimensions":
    let bytes = [
      byte 0x47, 0x49, 0x46, 0x38, 0x39, 0x61, # GIF89a
      0x40, 0x01, # width: 320 (Little Endian)
      0xF0, 0x00  # height: 240 (Little Endian)
    ]
    let dims = extractDimensions(@bytes, "gif")
    check dims.isSome
    check dims.get[0] == 320
    check dims.get[1] == 240

  test "BMP dimensions":
    var bytes = newSeq[byte](30)
    bytes[0] = 'B'.byte
    bytes[1] = 'M'.byte
    # width: 1024 (LE)
    bytes[18..21] = [byte 0x00, 0x04, 0x00, 0x00]
    # height: 768 (LE)
    bytes[22..25] = [byte 0x00, 0x03, 0x00, 0x00]
    
    let dims = extractDimensions(bytes, "bmp")
    check dims.isSome
    check dims.get[0] == 1024
    check dims.get[1] == 768

  test "JPEG dimensions":
    var bytes = newSeq[byte](26)
    bytes[0..5] = [byte 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] # SOI, APP0
    bytes[20..25] = [
      byte 0xFF, 0xC0, # SOF0
      0x00, 0x11,      # Length
      0x08,            # Prec
      0x01, 0xE0       # Height 480
    ]
    # Wait, the array size above is tricky to pack exactly like Zig because Nim slices behave differently. Let's just mock a standard stream
    var jpegBytes: seq[byte] = @[
      byte 0xFF, 0xD8, # SOI
      0xFF, 0xE0, # APP0
      0x00, 0x10  # APP0 len 16
    ]
    for i in 0..13: jpegBytes.add(0)
    jpegBytes.add([
      byte 0xFF, 0xC0, # SOF0
      0x00, 0x11, # Len
      0x08, # Prec
      0x01, 0xE0, # Height: 480 (BE)
      0x02, 0x80  # Width: 640 (BE)
    ])

    let dims = extractDimensions(jpegBytes, "jpeg")
    check dims.isSome
    check dims.get[0] == 640
    check dims.get[1] == 480

suite "ImageInfoTool Schema":
  test "tool name":
    var tool = newImageInfoTool()
    check tool.name() == "image_info"
    
  test "schema has path":
    var tool = newImageInfoTool()
    let params = tool.parameters()
    check "path" in params["required"].getElems().mapIt(it.getStr())
    check params["properties"].hasKey("path")
