import std/[os, strutils, strformat]
import config

const ModelsDir = "tts" / "models"

proc modelsPath(): string =
  getNimClawDir() / ModelsDir

proc runTtsCommand*(args: seq[string]): string =
  let action = if args.len > 0: args[0] else: "list"
  let rest = if args.len > 1: args[1..^1] else: @[]

  case action
  of "list", "ls":
    let dir = modelsPath()
    if not dirExists(dir):
      return "No TTS models installed.\nRun: nimclaw service tts add <path-to-gguf>"
    var models: seq[string]
    for kind, path in walkDir(dir):
      if kind == pcFile and path.endsWith(".gguf"):
        let name = extractFilename(path)
        let size = getFileSize(path)
        let mb = size div (1024 * 1024)
        models.add(fmt"  {name} ({mb}MB)")
    if models.len == 0:
      return "No TTS models installed.\nRun: nimclaw service tts add <path-to-gguf>"
    let envVal = getEnv("NIMCLAW_TTS_MODEL", "(not set)")
    result = "TTS Models (" & dir & "):\n" & models.join("\n")
    result &= "\n\nActive model (NIMCLAW_TTS_MODEL): " & envVal

  of "add", "install":
    if rest.len == 0:
      return "Usage: nimclaw service tts add <path-to-gguf>\n  Copies or symlinks a GGUF model into the TTS models directory."
    let src = rest[0]
    if not fileExists(src):
      return "Error: file not found: " & src
    let dir = modelsPath()
    createDir(dir)
    let name = extractFilename(src)
    let dst = dir / name
    if fileExists(dst):
      return "Model already exists: " & dst
    copyFile(src, dst)
    result = "Installed: " & dst
    result &= "\n\nTo activate, set:\n  export NIMCLAW_TTS_MODEL=" & dst
    result &= "\nor add to your service .env file."

  of "remove", "rm", "delete":
    if rest.len == 0:
      return "Usage: nimclaw service tts remove <model-name>"
    let name = rest[0]
    let path = if fileExists(name): name
               else: modelsPath() / name
    if not fileExists(path):
      # Try with .gguf extension
      let withExt = modelsPath() / name & ".gguf"
      if fileExists(withExt):
        removeFile(withExt)
        return "Removed: " & withExt
      return "Model not found: " & name
    removeFile(path)
    return "Removed: " & path

  of "test":
    let modelPath = getEnv("NIMCLAW_TTS_MODEL", "")
    if modelPath.len == 0:
      # Try first model in dir
      let dir = modelsPath()
      if dirExists(dir):
        for kind, path in walkDir(dir):
          if kind == pcFile and path.endsWith(".gguf"):
            return "Found model: " & path & "\nSet NIMCLAW_TTS_MODEL=" & path & " to use it."
      return "No TTS model configured. Set NIMCLAW_TTS_MODEL=<path>"
    if not fileExists(modelPath):
      return "Error: model file not found: " & modelPath
    return "Model: " & modelPath & " (" & $(getFileSize(modelPath) div (1024*1024)) & "MB)\nTo test synthesis, start the gateway and use the tts tool."

  else:
    result = "Usage: nimclaw service tts <command>\n"
    result &= "\nCommands:\n"
    result &= "  list                    Show installed TTS models\n"
    result &= "  add <path.gguf>         Install a GGUF model\n"
    result &= "  remove <name>           Remove a model\n"
    result &= "  test                    Check TTS configuration"
