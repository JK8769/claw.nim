import std/[json, asyncdispatch, tables, os, strutils, times, algorithm]
import types
import ../tts/engine
import ../tts/common
import ../logger

type
  TTSTool* = ref object of Tool
    engine*: TTSEngine
    outputDir*: string

proc newTTSTool*(engine: TTSEngine, outputDir: string): TTSTool =
  TTSTool(engine: engine, outputDir: outputDir)

method name*(t: TTSTool): string = "tts"
method description*(t: TTSTool): string =
  "Synthesize speech from text. Returns path to generated WAV file. Voice names: {lang}{gender}_{name} where lang=a(American)/b(British)/z(Chinese), gender=f(female)/m(male). Examples: af_maple (American female), bm_george (British male), zf_001 (Chinese female). Use action=list_voices to see all."

method parameters*(t: TTSTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "text": {
        "type": "string",
        "description": "The text to synthesize into speech"
      },
      "voice": {
        "type": "string",
        "description": "Voice ID: {lang}{gender}_{name}. lang: a=American, b=British, z=Chinese. gender: f=female, m=male. e.g. af_maple, bm_george, zf_001. Default: af_maple"
      },
      "action": {
        "type": "string",
        "enum": ["synthesize", "list_voices"],
        "description": "Action to perform. Default: synthesize"
      }
    },
    "required": %["text"]
  }.toTable

method execute*(t: TTSTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let action = if args.hasKey("action"): args["action"].getStr("synthesize") else: "synthesize"

  if action == "list_voices":
    var voices = t.engine.listVoices()
    if voices.len == 0:
      return "TTS engine not loaded. No voices available."
    voices.sort()
    var groups: Table[string, seq[string]]
    for v in voices:
      let key = if v.len >= 2: v[0..1] else: "??"
      if key notin groups: groups[key] = @[]
      groups[key].add(v)
    var lines: seq[string]
    const prefixes = [("af", "American Female"), ("am", "American Male"),
                      ("bf", "British Female"), ("bm", "British Male"),
                      ("zf", "Chinese Female"), ("zm", "Chinese Male")]
    for pair in prefixes:
      if pair[0] in groups:
        lines.add(pair[1] & ": " & groups[pair[0]].join(", "))
    # Any remaining groups not in the known prefixes
    for key, vlist in groups:
      var found = false
      for pair in prefixes:
        if pair[0] == key: found = true
      if not found:
        lines.add(key & ": " & vlist.join(", "))
    return "Available voices (" & $voices.len & "):\n" & lines.join("\n")

  if not t.engine.isLoaded():
    return "Error: TTS engine not loaded. Set NIMCLAW_TTS_MODEL environment variable to the path of a Kokoro GGUF model."

  let text = if args.hasKey("text"): args["text"].getStr() else: ""
  if text.len == 0:
    return "Error: text parameter is required"

  let voice = if args.hasKey("voice"): args["voice"].getStr("af_maple") else: "af_maple"

  let outDir = t.outputDir / "audio"
  createDir(outDir)
  let timestamp = now().format("yyyyMMdd'T'HHmmss")
  let filename = "tts_" & timestamp & ".wav"
  let outPath = outDir / filename

  try:
    let audio = t.engine.synthesize(text, voice)
    if audio.samples.len == 0:
      return "Error: synthesis produced no audio (text may be empty after normalization)"
    audio.writeWav(outPath)
    let duration = audio.samples.len.float / audio.sampleRate.float
    return "Generated " & formatFloat(duration, ffDecimal, 1) & "s audio → " & outPath
  except Exception as e:
    errorCF("tts", "Synthesis failed", {"error": e.msg, "text": text[0..min(50, text.len-1)]}.toTable)
    return "Error: synthesis failed — " & e.msg
