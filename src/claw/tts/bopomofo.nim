## Native Bopomofo phonemizer for Kokoro TTS (v1.1-zh model).
## Converts Chinese text → Bopomofo notation matching misaki/zh_frontend.py output.
##
## Pipeline: text → punctuation map → segment → pinyin → tone sandhi → Bopomofo
## Zero runtime dependencies — pinyin data embedded at compile time via staticRead.

import std/[tables, strutils, sequtils, unicode]

const
  PinyinRaw = staticRead("data/pinyin.txt")
  VocabRaw = staticRead("data/zh_seg.vocab")
  PhrasesRaw = staticRead("data/phrases.txt")

# Pinyin component → Bopomofo symbol (from misaki/zh_frontend.py ZH_MAP)
const ZhMap* = {
  # Initials (声母)
  "b": "ㄅ", "p": "ㄆ", "m": "ㄇ", "f": "ㄈ",
  "d": "ㄉ", "t": "ㄊ", "n": "ㄋ", "l": "ㄌ",
  "g": "ㄍ", "k": "ㄎ", "h": "ㄏ",
  "j": "ㄐ", "q": "ㄑ", "x": "ㄒ",
  "zh": "ㄓ", "ch": "ㄔ", "sh": "ㄕ", "r": "ㄖ",
  "z": "ㄗ", "c": "ㄘ", "s": "ㄙ",
  # Simple finals (韵母)
  "a": "ㄚ", "o": "ㄛ", "e": "ㄜ", "ie": "ㄝ",
  "ai": "ㄞ", "ei": "ㄟ", "ao": "ㄠ", "ou": "ㄡ",
  "an": "ㄢ", "en": "ㄣ", "ang": "ㄤ", "eng": "ㄥ",
  "er": "ㄦ",
  "i": "ㄧ", "u": "ㄨ", "v": "ㄩ",
  # Special apical vowels
  "ii": "ㄭ",    # zi, ci, si
  "iii": "十",   # zhi, chi, shi, ri
  # Compound finals
  "ve": "月", "ia": "压", "ian": "言", "iang": "阳", "iao": "要",
  "in": "阴", "ing": "应", "iong": "用", "iou": "又", "ong": "中",
  "ua": "穵", "uai": "外", "uan": "万", "uang": "王",
  "uei": "为", "uen": "文", "ueng": "瓮", "uo": "我",
  "van": "元", "vn": "云",
}.toTable

const DigitToChinese = {
  '0': "零", '1': "一", '2': "二", '3': "三", '4': "四",
  '5': "五", '6': "六", '7': "七", '8': "八", '9': "九",
}.toTable

# Common neutral-tone particles/suffixes
const NeutralChars = [
  "吧", "呢", "啊", "呐", "噻", "嘛", "吖", "嗨", "哦", "哒",
  "滴", "哩", "哟", "喽", "啰", "耶", "喔", "诶", "的",
]

type
  PinyinEntry* = tuple[initial, final: string]

  PhraseEntry* = seq[PinyinEntry]  ## Sequence of (initial, final) for each char

  Bopomofo* = object
    pinyinDict*: Table[int32, PinyinEntry]  # keyed by Unicode codepoint
    phraseDict*: Table[string, PhraseEntry] # word → pinyin override for polyphones
    vocab*: Table[string, float32]          # token → log probability
    maxTokenLen*: int                       # max token length in runes

proc newBopomofo*(): Bopomofo =
  ## Create phonemizer with embedded pinyin dictionary and Unigram vocab.
  result.maxTokenLen = 0
  # Parse pinyin entries: "char\tinitial\tfinal_with_tone"
  for line in PinyinRaw.splitLines():
    if line.len == 0: continue
    let parts = line.split('\t')
    if parts.len != 3: continue
    let cp = line.runeAt(0).int32
    let initial = if parts[1] == "_": "" else: parts[1]
    result.pinyinDict[cp] = (initial, parts[2])
  # Parse phrase overrides: "phrase\tinitial1 final1 initial2 final2 ..."
  for line in PhrasesRaw.splitLines():
    if line.len == 0: continue
    let tab = line.find('\t')
    if tab < 0: continue
    let phrase = line[0 ..< tab]
    let parts = line[tab + 1 .. ^1].split(' ')
    # Each syllable is 2 parts: initial final (pairs)
    if parts.len < 2 or parts.len mod 2 != 0: continue
    var entry: PhraseEntry
    for i in countup(0, parts.len - 1, 2):
      let initial = if parts[i] == "_": "" else: parts[i]
      entry.add (initial, parts[i + 1])
    result.phraseDict[phrase] = entry
  # Parse Unigram vocab: "token\tlog_score"
  for line in VocabRaw.splitLines():
    if line.len == 0: continue
    let tab = line.find('\t')
    if tab < 0: continue
    let token = line[0 ..< tab]
    let score = parseFloat(line[tab + 1 .. ^1]).float32
    result.vocab[token] = score
    let rl = token.runeLen
    if rl > result.maxTokenLen:
      result.maxTokenLen = rl

proc isCjk(cp: int32): bool {.inline.} =
  cp >= 0x4E00'i32 and cp <= 0x9FFF'i32

proc mapPunctuation(text: string): string =
  ## Normalize Chinese punctuation to ASCII equivalents.
  ## Pause durations are handled by kokoro.nim's unified pause system.
  result = text
  result = result.replace("、", ", ").replace("，", ", ")
  result = result.replace("。", ". ").replace("．", ". ")
  result = result.replace("！", "! ").replace("？", "? ")
  result = result.replace("：", ": ").replace("；", "; ")
  result = result.replace("《", " \"").replace("》", "\" ")
  result = result.replace("「", " \"").replace("」", "\" ")
  result = result.replace("【", " \"").replace("】", "\" ")
  result = result.replace("（", " (").replace("）", ") ")
  result = result.replace("……", "… ").replace("…", "… ")
  result = result.replace("——", "— ").replace("—", "— ")

proc normalizeNumbers(text: string): string =
  ## Replace ASCII digits with Chinese characters.
  result = newStringOfCap(text.len)
  for c in text:
    if c in DigitToChinese:
      result.add DigitToChinese[c]
    else:
      result.add c

proc segment*(bp: Bopomofo, text: string): seq[string] =
  ## Viterbi segmentation using Unigram language model.
  ## Finds the maximum log-probability tokenization of the text.
  let runes = text.toRunes()
  let n = runes.len
  if n == 0: return @[]

  const unkScore = -20.0'f32  # penalty for unknown single chars
  # best[i] = best log-prob for runes[0..i-1], from[i] = start of last token
  var best = newSeq[float32](n + 1)
  var frm = newSeq[int](n + 1)
  best[0] = 0.0'f32
  for i in 1 .. n:
    best[i] = -1e18'f32

  for i in 0 ..< n:
    if best[i] <= -1e17'f32: continue
    let maxLen = min(bp.maxTokenLen, n - i)
    for length in 1 .. maxLen:
      var token = ""
      for j in i ..< i + length:
        token.add $runes[j]
      var score: float32
      if token in bp.vocab:
        score = bp.vocab[token]
      elif length == 1:
        score = unkScore  # single unknown char fallback
      else:
        continue  # multi-char token not in vocab — skip
      let newScore = best[i] + score
      if newScore > best[i + length]:
        best[i + length] = newScore
        frm[i + length] = i

  # Backtrack
  var tokens: seq[string]
  var pos = n
  while pos > 0:
    let start = frm[pos]
    var token = ""
    for j in start ..< pos:
      token.add $runes[j]
    tokens.add token
    pos = start

  # Reverse to get left-to-right order
  for i in 0 ..< tokens.len div 2:
    swap(tokens[i], tokens[tokens.len - 1 - i])
  return tokens

proc getInitialFinal(bp: Bopomofo, cp: int32): PinyinEntry =
  ## Look up character pinyin. Returns (initial, final_with_tone).
  if cp in bp.pinyinDict:
    return bp.pinyinDict[cp]
  # Special case: 嗯 — pypinyin returns empty for both
  if cp == 0x55EF'i32:
    return ("", "n2")
  return ("", "")

proc applyIiSubst(initial, final: string): string =
  ## zi/ci/si finals become ii; zhi/chi/shi/ri finals become iii.
  ## Only when final is literally "i" + tone digit.
  if final.len == 2 and final[0] == 'i' and final[1] in '1'..'5':
    if initial in ["z", "c", "s"]:
      return "ii" & final[1 .. ^1]
    elif initial in ["zh", "ch", "sh", "r"]:
      return "iii" & final[1 .. ^1]
  result = final

proc syllableToBopomofo(initial, final: string): string =
  ## Convert one syllable (initial + final_with_tone) to Bopomofo string.
  if initial.len > 0:
    result.add ZhMap.getOrDefault(initial, "\xE2\x9D\x93")  # ❓
  if final.len == 0: return
  # Separate trailing tone digit
  let last = final[^1]
  var vowel, tone: string
  if last in '1'..'5':
    vowel = final[0 ..< ^1]
    tone = $last
  else:
    vowel = final
    tone = ""
  # Handle erhua marker
  var hasR = false
  if vowel.len > 0 and vowel[^1] == 'R':
    hasR = true
    vowel = vowel[0 ..< ^1]
  if vowel.len > 0:
    result.add ZhMap.getOrDefault(vowel, "\xE2\x9D\x93")
  if hasR:
    result.add "R"
  if tone.len > 0:
    result.add tone

# ---- Tone sandhi ----

proc sandhiThree(finals: var seq[string]) =
  ## Tone 3+3 → 2+3 rule applied pairwise right-to-left.
  if finals.len < 2: return
  # For 2-char: simple rule
  if finals.len == 2:
    if finals[0].len > 0 and finals[1].len > 0 and
       finals[0][^1] == '3' and finals[1][^1] == '3':
      finals[0][^1] = '2'
    return
  # For 3+ chars: split into pairs from left, apply to each pair
  # 4-char: split as 2+2 (idiom pattern)
  if finals.len == 4:
    for start in [0, 2]:
      if finals[start].len > 0 and finals[start+1].len > 0 and
         finals[start][^1] == '3' and finals[start+1][^1] == '3':
        finals[start][^1] = '2'
    return
  # General: pairwise from right
  var i = finals.len - 2
  while i >= 0:
    if finals[i].len > 0 and finals[i+1].len > 0 and
       finals[i][^1] == '3' and finals[i+1][^1] == '3':
      finals[i][^1] = '2'
    dec i

proc sandhiBu(finals: var seq[string], runes: seq[Rune]) =
  ## 不 before tone 4 → tone 2; middle of 3-char → tone 5.
  for i, r in runes:
    if r.int32 != 0x4E0D'i32 or i >= finals.len: continue  # 不
    if runes.len == 3 and i == 1:
      if finals[i].len > 0: finals[i][^1] = '5'
    elif i + 1 < finals.len and finals[i+1].len > 0 and finals[i+1][^1] == '4':
      if finals[i].len > 0: finals[i][^1] = '2'

proc sandhiYi(finals: var seq[string], runes: seq[Rune]) =
  ## 一 sandhi: before T4→T2, before non-T4→T4, reduplication→T5.
  const yiCp = 0x4E00'i32
  # Check if all chars are digits/一 — if so, keep original tone
  var allNum = true
  for r in runes:
    let cp = r.int32
    if cp != yiCp and not(cp >= 0x30'i32 and cp <= 0x39'i32) and
       not(cp >= 0x96F6'i32 and cp <= 0x4E5D'i32): # 零-九 range approx
      allNum = false
      break
  if allNum and runes.len > 1: return

  for i, r in runes:
    if r.int32 != yiCp or i >= finals.len: continue
    if i + 1 >= finals.len or finals[i+1].len == 0: continue
    # Reduplication: X一X
    if runes.len == 3 and i == 1 and runes[0] == runes[2]:
      if finals[i].len > 0: finals[i][^1] = '5'
    elif finals[i+1][^1] in {'4', '5'}:
      if finals[i].len > 0: finals[i][^1] = '2'
    else:
      if finals[i].len > 0: finals[i][^1] = '4'

proc sandhiGe(finals: var seq[string], runes: seq[Rune]) =
  ## 个 as measure word after numerals/quantifiers → neutral tone.
  const geCp = 0x4E2A'i32  # 个
  const geContext = "几有两半多各整每做是"
  for i, r in runes:
    if r.int32 != geCp or i >= finals.len: continue
    if i == 0 and runes.len == 1:
      # Standalone 个
      if finals[i].len > 0: finals[i][^1] = '5'
    elif i >= 1:
      let prev = runes[i-1]
      let prevCh = $prev
      let isNumPrev = (prev.int32 >= 0x30'i32 and prev.int32 <= 0x39'i32) or
                      prevCh in ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
                                 "零", "百", "千", "万", "亿"]
      var isCtxPrev = false
      for c in geContext.runes:
        if prev == c: isCtxPrev = true; break
      if isNumPrev or isCtxPrev:
        if finals[i].len > 0: finals[i][^1] = '5'

proc sandhiNeutral(initials, finals: var seq[string], runes: seq[Rune],
                   prevWordLen: int) =
  ## Common particles become neutral tone (5). Also handles 地/得 reading override.
  if runes.len != 1: return
  let ch = $runes[0]
  # 地/得: structural particles that need full reading override (dì→de, dé→de)
  if ch == "地" and prevWordLen >= 2:
    initials[0] = "d"; finals[0] = "e5"; return
  if ch == "得" and prevWordLen > 0:
    initials[0] = "d"; finals[0] = "e5"; return
  # Simple tone neutralization for sentence-final / structural particles
  for p in NeutralChars:
    if ch == p:
      if finals[0].len > 0: finals[0][^1] = '5'
      return
  # 了/着/过 as aspect markers
  if ch in ["了", "着", "过"]:
    if finals[0].len > 0: finals[0][^1] = '5'

type EnCallback* = proc(text: string): string
  ## Callback to phonemize non-Chinese text (e.g., English via espeak).

proc phonemize*(bp: Bopomofo, text: string, enCallback: EnCallback = nil): string =
  ## Convert Chinese text to Bopomofo notation for Kokoro v1.1-zh.
  ## Non-Chinese segments are routed through enCallback (espeak IPA) if provided.
  ## Output format: ㄋㄧ2ㄏㄠ3, ㄓㄜ4/ㄕ十4/ㄧ2ㄍㄜ5/ㄩ3阴1...
  let normalized = normalizeNumbers(text)
  let mapped = mapPunctuation(normalized)

  # Split into Chinese, English, and punctuation/space segments
  type SegKind = enum skChinese, skEnglish, skOther
  type Segment = tuple[text: string, kind: SegKind]
  var segments: seq[Segment]
  var cur = ""
  var curKind = skOther

  for r in mapped.runes:
    let cp = r.int32
    let kind = if isCjk(cp): skChinese
               elif (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A) or
                    cp == 0x27: skEnglish  # A-Z, a-z, apostrophe
               else: skOther
    if cur.len == 0:
      cur = $r
      curKind = kind
    elif kind == curKind:
      cur.add $r
    elif cp == 0x20 and curKind == skChinese:
      # Space inside Chinese context = explicit word boundary, keep in segment
      cur.add $r
    else:
      segments.add (cur, curKind)
      cur = $r
      curKind = kind
  if cur.len > 0:
    segments.add (cur, curKind)

  for seg in segments:
    if seg.kind == skEnglish:
      if enCallback != nil:
        let ipa = enCallback(seg.text)
        if ipa.len > 0:
          result.add ipa
      # If no callback or empty result, skip (English can't be Bopomofo-ized)
      continue
    if seg.kind == skOther:
      result.add seg.text
      continue

    # Phase 1: Segment and collect all syllable data
    type SylInfo = object
      initial, final: string
      wordEnd: bool  # last syllable in its word
    # Spaces in Chinese text are explicit word boundaries — skip Viterbi
    let words = if ' ' in seg.text:
                  seg.text.split(' ').filterIt(it.len > 0)
                else:
                  bp.segment(seg.text)
    var syls: seq[SylInfo]
    var prevWordLen = 0  # rune length of previous word

    for word in words:
      let runes = word.toRunes()
      var initials = newSeq[string](runes.len)
      var finals = newSeq[string](runes.len)

      # Check phrase dictionary first (polyphone disambiguation)
      let phrase = bp.phraseDict.getOrDefault(word)
      if phrase.len == runes.len:
        for i in 0 ..< runes.len:
          initials[i] = phrase[i].initial
          finals[i] = applyIiSubst(phrase[i].initial, phrase[i].final)
      else:
        # No phrase match or length mismatch — char-level pinyin
        for i, r in runes:
          let (init, fin) = bp.getInitialFinal(r.int32)
          initials[i] = init
          finals[i] = applyIiSubst(init, fin)

      # Word-level tone sandhi
      sandhiThree(finals)
      sandhiBu(finals, runes)
      sandhiYi(finals, runes)
      sandhiGe(finals, runes)
      sandhiNeutral(initials, finals, runes, prevWordLen)

      prevWordLen = runes.len
      for i in 0 ..< runes.len:
        syls.add SylInfo(initial: initials[i], final: finals[i],
                         wordEnd: i == runes.len - 1)

    # Phase 2: Cross-word tone 3 sandhi
    # If last syllable of word N and first syllable of word N+1 are both tone 3,
    # merge them: change the earlier one to tone 2
    for i in 0 ..< syls.len - 1:
      if syls[i].wordEnd and syls[i].final.len > 0 and syls[i+1].final.len > 0 and
         syls[i].final[^1] == '3' and syls[i+1].final[^1] == '3':
        syls[i].final[^1] = '2'

    # Phase 3: Convert to Bopomofo string
    for i, syl in syls:
      if i > 0 and syls[i-1].wordEnd:
        result.add "/"
      result.add syllableToBopomofo(syl.initial, syl.final)

when isMainModule:
  import std/osproc

  let bp = newBopomofo()
  echo "Loaded ", bp.pinyinDict.len, " pinyin entries, ", bp.vocab.len, " vocab tokens"
  echo ""

  # espeak callback for English segments
  proc espeakEn(text: string): string =
    let cmd = "espeak-ng -v en-us -q --ipa=3 \"" & text.replace("\"", "\\\"") & "\""
    let (output, exitCode) = execCmdEx(cmd, options = {poUsePath})
    if exitCode == 0:
      result = output.strip().replace("\n", " ").replace("  ", " ")

  let enCb: EnCallback = espeakEn

  echo "=== Chinese ==="
  for t in ["你好", "你好，这是一个语音合成测试。", "研究生命的起源"]:
    echo t
    echo "  → ", bp.phonemize(t, enCb)
    echo ""

  echo "=== Mixed Language ==="
  let mixedTests = [
    "我喜欢Python编程",
    "今天去Starbucks喝咖啡",
    "她在Google工作",
    "用ChatGPT写代码很方便",
    "iPhone和Android哪个好？",
  ]
  for t in mixedTests:
    echo t
    echo "  → ", bp.phonemize(t, enCb)
    echo ""
