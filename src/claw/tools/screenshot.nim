import std/[json, tables, asyncdispatch, strutils, os, osproc]
import types

type
  ScreenshotTool* = ref object of Tool
    workspaceDir*: string

proc newScreenshotTool*(workspaceDir: string): ScreenshotTool =
  ScreenshotTool(workspaceDir: workspaceDir)

method name*(t: ScreenshotTool): string = "screenshot"

method description*(t: ScreenshotTool): string = "Capture a screenshot of the current screen. Returns [IMAGE:path] marker — include it verbatim in your response to send the image to the user."

method parameters*(t: ScreenshotTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "filename": {"type": "string", "description": "Optional filename (default: screenshot.png). Saved in workspace."}
    }
  }.toTable

method execute*(t: ScreenshotTool, args: Table[string, JsonNode]): Future[string] {.async.} =
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
    return "Error: Screenshot not supported on this platform"

  try:
    let (output, exitCode) = execCmdEx(argv.join(" "))
    if exitCode == 0:
      return "[IMAGE:" & outputPath & "]"
    else:
      let errMsg = if output.len > 0: output else: "unknown error"
      return "Error: Screenshot command failed: " & errMsg
  except Exception as e:
    return "Error: Failed to spawn screenshot command: " & e.msg
