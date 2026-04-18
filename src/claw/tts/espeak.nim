## espeak-ng C library bindings for text-to-phoneme conversion.
## Links against libespeak-ng — no subprocess overhead.

when defined(macosx):
  const espeakLib = "/opt/homebrew/lib/libespeak-ng.dylib"
elif defined(linux):
  const espeakLib = "libespeak-ng(|.1).so"
else:
  const espeakLib = "libespeak-ng(|.1).dylib"

type
  EspeakAudioOutput {.size: sizeof(cint).} = enum
    aoPlayback = 0
    aoRetrieval = 1
    aoSynchronous = 2
    aoSynchPlayback = 3

  EspeakError {.size: sizeof(cint).} = enum
    eeOk = 0
    eeInternal = -1
    eeBufferFull = 1
    eeNotFound = 2

const
  espeakCHARS_UTF8 = cint(1)
  espeakPHONEMES_IPA = cint(0x02)

proc espeak_Initialize(output: EspeakAudioOutput, buflength: cint,
                       path: cstring, options: cint): cint
  {.cdecl, dynlib: espeakLib, importc.}

proc espeak_SetVoiceByName(name: cstring): EspeakError
  {.cdecl, dynlib: espeakLib, importc.}

proc espeak_TextToPhonemes(textptr: ptr pointer, textmode: cint,
                           phonememode: cint): cstring
  {.cdecl, dynlib: espeakLib, importc.}

proc espeak_Terminate(): EspeakError
  {.cdecl, dynlib: espeakLib, importc.}

# High-level API

var espeakReady = false

proc initEspeak*(dataPath: string = ""): bool =
  ## Initialize espeak-ng. Returns true on success.
  if espeakReady: return true
  let path = if dataPath.len > 0: cstring(dataPath) else: nil
  let sr = espeak_Initialize(aoSynchronous, 0, path, 0)
  if sr > 0:
    espeakReady = true
  return espeakReady

proc espeakPhonemes*(text: string, voice: string = "en-us"): string =
  ## Convert text to IPA phonemes using espeak-ng C library.
  if not espeakReady: return ""
  discard espeak_SetVoiceByName(cstring(voice))
  var textCopy = text
  var textptr = cast[pointer](addr textCopy[0])
  while textptr != nil:
    let ph = espeak_TextToPhonemes(addr textptr, espeakCHARS_UTF8, espeakPHONEMES_IPA)
    if ph != nil and ph[0] != '\0':
      if result.len > 0: result.add ' '
      result.add $ph

proc closeEspeak*() =
  if espeakReady:
    discard espeak_Terminate()
    espeakReady = false

when isMainModule:
  if initEspeak():
    echo "espeak-ng initialized"
    echo "hello world: ", espeakPhonemes("hello world")
    echo "pulled: ", espeakPhonemes("pulled")
    echo "never: ", espeakPhonemes("never")
    echo "shoulder: ", espeakPhonemes("shoulder")
    echo "excuse me: ", espeakPhonemes("excuse me")
    echo "guys: ", espeakPhonemes("guys")
    echo "SO TOTALLY OVER: ", espeakPhonemes("SO TOTALLY OVER")
    closeEspeak()
  else:
    echo "espeak-ng not available"
