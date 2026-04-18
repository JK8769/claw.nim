## Unified TTS engine — loads models and synthesizes speech.
## Currently supports Kokoro only.

import std/[os, strutils]
import common
import models/kokoro

type
  TTSEngine* = ref object
    kokoro: KokoroModel
    loaded: bool
    modelPath: string

proc newTTSEngine*(): TTSEngine =
  TTSEngine(loaded: false)

proc loadModel*(e: TTSEngine, path: string) =
  if e.loaded:
    e.kokoro.close()
  e.kokoro = loadKokoro(path)
  e.kokoro.postLoadInit()
  e.modelPath = path
  e.loaded = true

proc isLoaded*(e: TTSEngine): bool = e.loaded

proc listVoices*(e: TTSEngine): seq[string] =
  if not e.loaded: return @[]
  return e.kokoro.listVoices()

proc synthesize*(e: TTSEngine, text: string, voice: string = "af_maple",
                 speed: float32 = 1.0): AudioOutput =
  if not e.loaded:
    raise newException(ValueError, "TTS engine not loaded. Set NIMCLAW_TTS_MODEL path.")
  e.kokoro.synthesize(text, voice)

proc close*(e: TTSEngine) =
  if e.loaded:
    e.kokoro.close()
    e.loaded = false
