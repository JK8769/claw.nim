## Tokenizers for TTS models:
## - Kokoro: single-pass UTF-8 character tokenizer
## - Orpheus: byte-level BPE tokenizer (Llama-3 style)
## Loads vocabulary from GGUF metadata (tokenizer.ggml.tokens).

import std/[tables, strutils, algorithm]
import gguf_loader

type
  Tokenizer* = object
    tokens*: seq[string]
    tokenMap*: Table[string, uint32]
    eosId*: uint32
    padId*: uint32

proc loadTokenizer*(model: GgufModel): Tokenizer =
  ## Load tokenizer from GGUF metadata arrays.
  let ggufCtx = model.ggufCtx
  let tokensKeyId = gguf_find_key(ggufCtx, "tokenizer.ggml.tokens")
  if tokensKeyId < 0:
    raise newException(KeyError, "tokenizer.ggml.tokens not found in GGUF")

  let nTokens = gguf_get_arr_n(ggufCtx, tokensKeyId)
  var tokenizer = Tokenizer(
    eosId: model.getU32("tokenizer.ggml.eos_token_id"),
    padId: model.getU32("tokenizer.ggml.padding_token_id"),
  )

  for i in 0..<nTokens:
    let tok = $gguf_get_arr_str(ggufCtx, tokensKeyId, i)
    tokenizer.tokens.add(tok)
    tokenizer.tokenMap[tok] = uint32(i)

  return tokenizer

proc tokenize*(t: Tokenizer, text: string): seq[uint32] =
  ## Tokenize a phonemized string into token IDs.
  ## Kokoro uses single UTF-8 character tokens.
  var i = 0
  while i < text.len:
    # Determine UTF-8 character length
    let b = uint8(text[i])
    let charLen = if b < 0x80: 1
                  elif b < 0xE0: 2
                  elif b < 0xF0: 3
                  else: 4
    let ch = text[i..<min(i + charLen, text.len)]
    if t.tokenMap.hasKey(ch):
      result.add(t.tokenMap[ch])
    # Skip unknown characters silently
    i += charLen

proc wrapTokens*(t: Tokenizer, tokens: seq[uint32], bosId: uint32 = 0): seq[uint32] =
  ## Wrap token sequence with BOS and EOS tokens.
  result.add(bosId)
  result.add(tokens)
  result.add(t.eosId)

# ── BPE Tokenizer (Orpheus / Llama-3) ────────────────────────────

type
  BpeTokenizer* = object
    tokensToIds*: Table[string, uint32]
    ranks*: Table[(string, string), int]  # merge pair → rank
    bosTokenId*, eosTokenId*: uint32

  BpeSymbol = ref object
    token: string
    prev, next: BpeSymbol
    pos: int

  BpeMerge = object
    a, b: BpeSymbol
    rank: int
    newSize: int

proc utf8CharLen(c: char): int =
  let b = uint8(c)
  if (b and 0x80) == 0: 1
  elif (b and 0xE0) == 0xC0: 2
  elif (b and 0xF0) == 0xE0: 3
  else: 4

proc addMerges(s: BpeSymbol, merges: var seq[BpeMerge],
               ranks: Table[(string, string), int], onlyForward: bool = false) =
  if not onlyForward and s.prev != nil:
    let pair = (s.prev.token, s.token)
    if pair in ranks:
      merges.add(BpeMerge(a: s.prev, b: s, rank: ranks[pair],
                           newSize: s.prev.token.len + s.token.len))
  if s.next != nil:
    let pair = (s.token, s.next.token)
    if pair in ranks:
      merges.add(BpeMerge(a: s, b: s.next, rank: ranks[pair],
                           newSize: s.token.len + s.next.token.len))

proc doMerge(m: BpeMerge): BpeSymbol =
  m.a.token &= m.b.token
  m.b.token = ""
  m.a.next = m.b.next
  if m.a.next != nil:
    m.a.next.prev = m.a
  return m.a

proc joinPairs(parts: seq[BpeSymbol], ranks: Table[(string, string), int]) =
  var merges: seq[BpeMerge]
  for p in parts:
    p.addMerges(merges, ranks, onlyForward = true)

  while merges.len > 0:
    # Sort: lowest rank first, tie-break by position
    merges.sort(proc(a, b: BpeMerge): int =
      if a.rank != b.rank: cmp(a.rank, b.rank)
      else: cmp(a.a.pos, b.a.pos))

    let m = merges[0]
    merges.delete(0)

    # Skip stale merges
    if m.a.token.len == 0 or m.b.token.len == 0: continue
    if m.newSize != m.a.token.len + m.b.token.len: continue

    let merged = doMerge(m)
    var newMerges: seq[BpeMerge]
    merged.addMerges(newMerges, ranks)
    merges.add(newMerges)

proc bpeTokenize(t: BpeTokenizer, chunk: string, tokenIds: var seq[uint32]) =
  if chunk in t.tokensToIds:
    tokenIds.add(t.tokensToIds[chunk])
    return

  # Build linked list of UTF-8 characters
  var parts: seq[BpeSymbol]
  var i = 0
  var prev: BpeSymbol = nil
  while i < chunk.len:
    let clen = utf8CharLen(chunk[i])
    let sym = BpeSymbol(token: chunk[i..<i+clen], pos: i)
    if prev != nil:
      prev.next = sym
      sym.prev = prev
    prev = sym
    parts.add(sym)
    i += clen

  joinPairs(parts, t.ranks)

  # Collect surviving symbols
  var cur = parts[0]
  while cur != nil:
    if cur.token.len > 0 and cur.token in t.tokensToIds:
      tokenIds.add(t.tokensToIds[cur.token])
    cur = cur.next

proc tokenize*(t: BpeTokenizer, text: string): seq[uint32] =
  ## Tokenize text using byte-level BPE.
  ## Spaces become Ġ (U+0120) prefix on the following word.
  let chunks = text.split(' ')
  var spacePrior = false
  for chunk in chunks:
    if chunk == "":
      spacePrior = true
    else:
      let encoded = if spacePrior: "\xC4\xA0" & chunk else: chunk
      t.bpeTokenize(encoded, result)
      spacePrior = true

proc loadBpeTokenizer*(gguf: GgufModel, baseName: string = "tokenizer.ggml"): BpeTokenizer =
  let tokens = gguf.getStrArr(baseName & ".tokens")
  if tokens.len == 0:
    raise newException(ValueError, "BPE: no tokens at " & baseName & ".tokens")
  let mergesRaw = gguf.getStrArr(baseName & ".merges")
  if mergesRaw.len == 0:
    raise newException(ValueError, "BPE: no merges at " & baseName & ".merges")

  for i, tok in tokens:
    result.tokensToIds[tok] = uint32(i)

  for i, raw in mergesRaw:
    let spacePos = raw.find(' ')
    if spacePos > 0:
      result.ranks[(raw[0..<spacePos], raw[spacePos+1..^1])] = i

  result.bosTokenId = gguf.getU32(baseName & ".bos_token_id", 128000)
  result.eosTokenId = gguf.getU32(baseName & ".eos_token_id", 128001)
