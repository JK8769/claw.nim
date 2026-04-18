## Token sampler for autoregressive TTS models.
## Supports top-k, top-p (nucleus), temperature, and repetition penalty.

import std/[algorithm, random, math]

type
  Sampler* = object
    vocabSize*: uint32
    temperature*: float32
    topK*: uint32
    topP*: float32
    repetitionPenalty*: float32
    doSample*: bool
    lastTokenId*: int32
    repetitionCount*: uint32

proc newSampler*(vocabSize: uint32, temperature: float32 = 1.0,
                 topK: uint32 = 50, topP: float32 = 1.0,
                 repetitionPenalty: float32 = 1.0): Sampler =
  Sampler(
    vocabSize: vocabSize,
    temperature: temperature,
    topK: topK,
    topP: topP,
    repetitionPenalty: repetitionPenalty,
    doSample: true,
    lastTokenId: -1,
    repetitionCount: 0,
  )

proc reset*(s: var Sampler) =
  s.lastTokenId = -1
  s.repetitionCount = 0

proc sample*(s: var Sampler, logits: openArray[float32]): uint32 =
  ## Sample a token from logits using configured strategy.
  let n = min(int(s.vocabSize), logits.len)

  if not s.doSample:
    # Greedy: argmax
    var bestIdx = 0
    var bestVal = logits[0]
    for i in 1..<n:
      if logits[i] > bestVal:
        bestVal = logits[i]
        bestIdx = i
    result = uint32(bestIdx)
  else:
    # Build (index, probability) pairs
    type TokenProb = tuple[idx: int, prob: float32]
    var probs = newSeq[TokenProb](n)

    # Find max for numerical stability
    var maxVal = logits[0]
    for i in 1..<n:
      if logits[i] > maxVal: maxVal = logits[i]

    # Apply repetition penalty
    var adjusted = newSeq[float32](n)
    for i in 0..<n:
      adjusted[i] = logits[i]
    if s.repetitionPenalty != 1.0 and s.lastTokenId >= 0 and s.lastTokenId < int32(n):
      let penalty = pow(s.repetitionPenalty, float32(s.repetitionCount))
      adjusted[s.lastTokenId] /= penalty

    # Apply temperature
    if s.temperature != 1.0 and s.temperature > 0:
      for i in 0..<n:
        adjusted[i] /= s.temperature

    # Softmax
    var sumExp: float32 = 0
    for i in 0..<n:
      let e = exp(adjusted[i] - maxVal)
      probs[i] = (i, e)
      sumExp += e
    for i in 0..<n:
      probs[i].prob /= sumExp

    # Sort by probability descending
    probs.sort(proc(a, b: TokenProb): int = cmp(b.prob, a.prob))

    # Top-K filtering
    var candidates = probs
    if s.topK > 0 and s.topK < uint32(n):
      candidates = candidates[0..<int(s.topK)]

    # Top-P (nucleus) filtering
    if s.topP < 1.0:
      var cumSum: float32 = 0
      var cutoff = candidates.len
      for i in 0..<candidates.len:
        cumSum += candidates[i].prob
        if cumSum >= s.topP:
          cutoff = i + 1
          break
      candidates = candidates[0..<cutoff]

    # Multinomial sampling
    var cumSum: float32 = 0
    for c in candidates:
      cumSum += c.prob
    let r = rand(cumSum)
    var running: float32 = 0
    for c in candidates:
      running += c.prob
      if r <= running:
        result = uint32(c.idx)
        break

  # Update repetition tracking
  if int32(result) == s.lastTokenId:
    s.repetitionCount += 1
  else:
    s.lastTokenId = int32(result)
    s.repetitionCount = 1
