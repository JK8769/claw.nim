## Text-to-phoneme conversion for Kokoro TTS.
## Requires espeak-ng C library (libespeak-ng) for English/European languages.
## Uses native Bopomofo for Chinese, with espeak-ng for embedded English.
## Install: brew install espeak-ng (macOS) / apt install libespeak-ng-dev (Linux)

import std/[strutils, tables, unicode]
import bopomofo
import espeak

type
  PhonemizerMode* = enum
    pmEspeak      ## Use espeak-ng C library
    pmBopomofo    ## Use native Nim Bopomofo + espeak-ng for English
    pmPassthrough ## Pass text through as-is (for pre-phonemized input)

  Phonemizer* = object
    mode*: PhonemizerMode
    espeakVoice*: string
    langCode*: char  ## Kokoro language code: a/b/e/f/h/i/j/p/z
    bpmf: Bopomofo   ## Native Bopomofo phonemizer (for Chinese)

# Kokoro language code → espeak voice mapping
const LangToEspeak* = {
  'a': "en-us",
  'b': "en",
  'e': "es",
  'f': "fr",
  'h': "hi",
  'i': "it",
  'j': "ja",
  'p': "pt-br",
}.toTable

# Languages that use Bopomofo (native Nim phonemizer)
const BopomofoLangs* = {'z'}

proc newPhonemizer*(voice: string = "af_maple"): Phonemizer =
  ## Create a phonemizer. Voice first char determines language.
  ## Requires espeak-ng C library.
  let langChar = if voice.len > 0: voice[0] else: 'a'
  if not initEspeak():
    raise newException(IOError,
      "espeak-ng library not found. Install it:\n" &
      "  macOS:  brew install espeak-ng\n" &
      "  Linux:  apt install libespeak-ng-dev")
  let espeakVoice = LangToEspeak.getOrDefault(langChar, "en-us")

  if langChar in BopomofoLangs:
    return Phonemizer(mode: pmBopomofo, langCode: langChar,
                      bpmf: newBopomofo(), espeakVoice: "en-us")
  else:
    return Phonemizer(mode: pmEspeak, langCode: langChar,
                      espeakVoice: espeakVoice)

# Interjections that espeak-ng can't pronounce — map to IPA directly
const Interjections = {
  "pffft": "ʌm:", "pfft": "ʌm:", "tch": "ʌm:", "tsk": "ʌm:",
  "shh": "ʌm:", "hmm": "ʌm:", "grr": "ʌm:", "brr": "ʌm:",
  "ugh": "ʌm:", "gah": "ʌm:", "bah": "ʌm:",
  "meh": "ʌm:", "heh": "ʌm:",
}.toTable

proc collapseRepeats(word: string): string =
  ## Collapse 3+ repeated chars to 1: pleeeease → please, sooooo → so
  result = ""
  var i = 0
  while i < word.len:
    result.add word[i]
    if i + 2 < word.len and word[i] == word[i+1] and word[i] == word[i+2]:
      # Skip all repeats of this char
      let ch = word[i]
      while i + 1 < word.len and word[i+1] == ch: inc i
    inc i

proc isStutter(prefix: string, word: string): bool =
  ## Check if prefix-word is a stutter pattern: w-what, I—I, d-do
  prefix.len <= 2 and word.len > 0 and
    prefix[0].toLowerAscii == word[0].toLowerAscii

proc splitTrailingPunct(word: string): (string, string) =
  ## Split "word..." into ("word", "..."), preserving trailing punctuation
  ## including multi-byte … and —. Normalizes ... to ….
  var w = word
  var trail = ""
  # Strip trailing ASCII punct (right to left)
  while w.len > 0 and w[^1] in {',', '.', '!', '?', ':', ';', '"', '\'', ')', ']'}:
    trail = $w[^1] & trail
    w.setLen(w.len - 1)
  # Strip trailing multi-byte punct (… = E2 80 A6, — = E2 80 94)
  while w.len >= 3 and w[^3] == '\xE2' and w[^2] == '\x80' and
        w[^1] in {'\xA6', '\x94'}:
    trail = w[^3..^1] & trail
    w.setLen(w.len - 3)
  # Normalize ... → … in trailing punctuation
  trail = trail.replace("...", "\xe2\x80\xa6")
  return (w, trail)

proc cleanTextForEspeak*(text: string): string =
  ## Clean up expressive text conventions that espeak-ng doesn't understand:
  ## - Collapse stretched words (pleeeease → please, sooooo → so)
  ## - Join syllable-split emphasis (UN-BE-LIEVABLE → unbelievable)
  ## - Handle stutter hyphens (w-what → what)
  ## - Handle em-dash stutter (I—I've → I've)
  ## - Replace interjections with IPA (pffft → [[pft]])
  ## Trailing punctuation is separated first so it's never lost.
  var words: seq[string]
  for rawWord in text.split(' '):
    if rawWord.len == 0: continue

    # Separate word from trailing punctuation (hello... → hello + …)
    var (base, trailing) = splitTrailingPunct(rawWord)
    if base.len == 0:
      if trailing.len > 0: words.add trailing  # bare punctuation
      continue

    # Drop periods after short non-caps words (do. Not. → do Not)
    # Keep periods for ALL-CAPS emphatic words (I. SAID. NO!)
    if base.len <= 3 and trailing == ".":
      var allUpper = true
      for c in base:
        if c.isLowerAscii: allUpper = false; break
      if not allUpper:
        trailing = ""

    # Check for interjection (case-insensitive)
    let lower = base.toLowerAscii
    if lower in Interjections:
      words.add "[[" & Interjections[lower] & "]]" & trailing
      continue

    # Handle em-dash stutter (I—I've → I've)
    if "\xe2\x80\x94" in base:
      let parts = base.split("\xe2\x80\x94")
      if parts.len == 2 and isStutter(parts[0], parts[1]):
        # Drop trailing period — stutters are emphatic, not sentence-ending
        let t = if trailing == ".": "" else: trailing
        words.add parts[1] & t
        continue

    # Handle hyphens: stutter (w-what) vs syllable-split (UN-BE-LIEVABLE)
    if '-' in base:
      let parts = base.split('-')
      if parts.len == 2 and isStutter(parts[0], parts[1]):
        let t = if trailing == ".": "" else: trailing
        words.add parts[1] & t
      else:
        # Lowercase joined result to avoid espeak splitting mixed-case
        words.add parts.join("").toLowerAscii & trailing
      continue

    # Collapse stretched words (3+ repeated chars)
    var hasRepeat = false
    for i in 0..<base.len - 2:
      if base[i] == base[i+1] and base[i] == base[i+2]:
        hasRepeat = true; break
    if hasRepeat:
      words.add collapseRepeats(base) & trailing
      continue

    words.add base & trailing

  result = words.join(" ")

type
  SegKind = enum skText, skIPA, skPunct
  Segment = object
    case kind: SegKind
    of skText: text: string
    of skIPA: ipa: string
    of skPunct: punct: string

proc parseSegments(cleaned: string): seq[Segment] =
  ## Parse cleaned text into segments: text (for espeak), [[IPA]] markers,
  ## and punctuation characters that Kokoro understands.
  ## espeak-ng strips all punctuation, so we extract it here to re-insert
  ## into the phoneme stream after phonemization.
  var cur = ""
  var i = 0
  template flushText() =
    let t = cur.strip()
    if t.len > 0: result.add Segment(kind: skText, text: t)
    cur = ""

  while i < cleaned.len:
    # [[IPA]] marker
    if i + 1 < cleaned.len and cleaned[i] == '[' and cleaned[i+1] == '[':
      flushText()
      let endMark = cleaned.find("]]", i + 2)
      if endMark < 0: break
      result.add Segment(kind: skIPA, ipa: cleaned[i+2..<endMark])
      i = endMark + 2
      continue
    # Multi-byte: ... → colon (only : produces audible pauses in Kokoro)
    if i + 2 < cleaned.len and cleaned[i] == '.' and cleaned[i+1] == '.' and cleaned[i+2] == '.':
      flushText()
      result.add Segment(kind: skPunct, punct: ":")
      i += 3
      while i < cleaned.len and cleaned[i] == '.': inc i
      continue
    # Multi-byte punct: — (E2 80 94), … (E2 80 A6) → colon for pause
    if i + 2 < cleaned.len and cleaned[i] == '\xE2' and cleaned[i+1] == '\x80':
      if cleaned[i+2] in {'\x94', '\xA6'}:  # — or …
        flushText()
        result.add Segment(kind: skPunct, punct: ":")
        i += 3; continue
    # ASCII punctuation Kokoro understands
    # ; → : (semicolon is noisy), others pass through
    if cleaned[i] in {',', '.', '!', '?', ':'}:
      flushText()
      result.add Segment(kind: skPunct, punct: $cleaned[i])
      inc i; continue
    if cleaned[i] == ';':
      flushText()
      result.add Segment(kind: skPunct, punct: ":")
      inc i; continue
    cur.add cleaned[i]
    inc i
  flushText()

proc phonemize*(p: Phonemizer, text: string): string =
  ## Convert text to phonemes with punctuation preserved for Kokoro.
  ## espeak-ng strips all punctuation, so we extract it first,
  ## phonemize word groups, then re-insert punctuation tokens.
  case p.mode
  of pmBopomofo:
    var enCb: EnCallback = proc(text: string): string =
      let cleaned = cleanTextForEspeak(text)
      espeakPhonemes(cleaned, "en-us")
    result = p.bpmf.phonemize(text, enCb)
  of pmEspeak:
    let cleaned = cleanTextForEspeak(text)
    let segments = parseSegments(cleaned)
    for seg in segments:
      case seg.kind
      of skText:
        if result.len > 0: result.add ' '
        result.add espeakPhonemes(seg.text, p.espeakVoice)
      of skIPA:
        if result.len > 0: result.add ' '
        result.add seg.ipa
      of skPunct:
        result.add seg.punct
  of pmPassthrough:
    result = text

proc normalizeForKokoro*(text: string): string =
  ## Light normalization before phonemization.
  result = text.replace("\n", " ")
