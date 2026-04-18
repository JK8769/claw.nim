## Common types for TTS.nim

type
  TTSModelKind* = enum
    tmKokoro
    tmOrpheus
    tmDia
    tmParler

  TTSVoice* = object
    name*: string
    id*: int32
    lang*: string

  GenerationConfig* = object
    temperature*: float32
    topK*: int32
    topP*: float32
    speed*: float32
    voice*: string
    maxTokens*: int32
    repetitionPenalty*: float32

  AudioOutput* = object
    samples*: seq[float32]
    sampleRate*: int32
    channels*: int32

proc defaultGenConfig*(): GenerationConfig =
  GenerationConfig(
    temperature: 0.7,
    topK: 50,
    topP: 0.9,
    speed: 1.0,
    voice: "af_heart",
    maxTokens: 2048,
    repetitionPenalty: 1.1
  )

proc writeLE16(f: File, v: int16) =
  var val = v
  discard f.writeBuffer(addr val, 2)

proc writeLE32(f: File, v: int32) =
  var val = v
  discard f.writeBuffer(addr val, 4)

proc writeWav*(output: AudioOutput, path: string) =
  ## Write AudioOutput to a WAV file (16-bit PCM)
  let numSamples = output.samples.len
  let dataSize = int32(numSamples * 2)
  let fileSize = int32(36 + dataSize)

  var f = open(path, fmWrite)
  defer: f.close()

  # RIFF header
  f.write("RIFF")
  f.writeLE32(fileSize)
  f.write("WAVE")

  # fmt chunk
  f.write("fmt ")
  f.writeLE32(16)
  f.writeLE16(1)                                    # PCM format
  f.writeLE16(int16(output.channels))
  f.writeLE32(output.sampleRate)
  f.writeLE32(output.sampleRate * int32(output.channels) * 2)  # byte rate
  f.writeLE16(int16(output.channels) * 2)           # block align
  f.writeLE16(16)                                   # bits per sample

  # data chunk
  f.write("data")
  f.writeLE32(dataSize)

  for s in output.samples:
    let clamped = max(-1.0'f32, min(1.0'f32, s))
    f.writeLE16(int16(clamped * 32767.0'f32))
