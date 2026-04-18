## Orpheus TTS model — Llama-3 architecture with SNAC audio output.
## Generates emotion-tagged speech with autoregressive token generation.

import std/[tables, strutils, math]
import ../ggml_bindings
import ../gguf_loader
import ../sampler
import ../codecs/snac
import ../common
import ../tokenizer

# ── Constants ─────────────────────────────────────────────────────

const
  OrpheusVoices* = ["zoe", "zac", "jess", "leo", "mia", "julia", "leah"]
  PrependedTokens = [128259'u32, 128000]
  AppendedTokens = [128009'u32, 128260, 128261, 128257]
  AudioHeadRouting = [0'u32, 1, 2, 2, 1, 2, 2]  # 7-token chunk → 3 SNAC heads

# ── Types ─────────────────────────────────────────────────────────

type
  OrpheusConfig* = object
    vocabSize*: uint32
    nAttnHeads*: uint32
    nKvAttnHeads*: uint32
    headSize*: uint32
    hiddenSize*: uint32
    kvHiddenSize*: uint32
    nLayers*: int
    maxContextLen*: uint32
    maxGenSize*: uint32
    stoppingTokenId*: uint32
    eosTokenId*: uint32
    bosTokenId*: uint32
    audioHeads*: uint32

  OrpheusLayer* = object
    inputNorm*, postAttnNorm*: ptr GgmlTensor
    q*, k*, v*, o*: ptr GgmlTensor
    gate*, up*, down*: ptr GgmlTensor

  KvCache* = object
    kl*, vl*: seq[ptr GgmlTensor]
    ctx*: ptr GgmlContext
    buf*: ptr GgmlBackendBuffer

  OrpheusModel* = object
    config*: OrpheusConfig
    gguf*: GgufModel
    snac*: SnacModel
    bpe*: BpeTokenizer
    layers*: seq[OrpheusLayer]
    head*, embd*, outputNorm*: ptr GgmlTensor
    ropeFreq*: ptr GgmlTensor
    kvCache*: KvCache
    currentPos*: uint32
    outputTokens*: seq[uint32]

# ── RMSNorm ───────────────────────────────────────────────────────

proc rmsNorm(ctx: ptr GgmlContext, x, weight: ptr GgmlTensor): ptr GgmlTensor =
  ggml_mul(ctx, ggml_rms_norm(ctx, x, 1e-5), weight)

# ── KV Cache ──────────────────────────────────────────────────────

proc initKvCache*(model: var OrpheusModel) =
  let cfg = model.config
  let nLayers = cfg.nLayers
  let cacheSize = cfg.hiddenSize * (cfg.maxContextLen + cfg.maxGenSize)

  let memSize = csize_t((2 * nLayers + 1) * int(ggml_tensor_overhead()))
  let params = GgmlInitParams(mem_size: memSize, mem_buffer: nil, no_alloc: true)
  let ctx = ggml_init(params)

  model.kvCache.ctx = ctx
  model.kvCache.kl = newSeq[ptr GgmlTensor](nLayers)
  model.kvCache.vl = newSeq[ptr GgmlTensor](nLayers)

  for i in 0..<nLayers:
    model.kvCache.kl[i] = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, int64(cacheSize))
    model.kvCache.vl[i] = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, int64(cacheSize))

  let buft = ggml_backend_cpu_buffer_type()
  model.kvCache.buf = ggml_backend_alloc_ctx_tensors(ctx, ggml_backend_cpu_init())
  ggml_backend_buffer_clear(model.kvCache.buf, 0)

# ── KV Store (with GQA repeat-interleave) ─────────────────────────

proc buildKvStore(ctx: ptr GgmlContext, gf: ptr GgmlCgraph,
                  model: OrpheusModel, kCur, vCur, positions: ptr GgmlTensor,
                  layerIdx: int, nTokens: uint32, repeat: int) =
  let cfg = model.config
  let elemSize = ggml_element_size(model.kvCache.kl[layerIdx])

  # Apply RoPE to K
  var kRoped = ggml_rope_ext(ctx,
    ggml_cont(ctx, ggml_reshape_3d(ctx, kCur,
      int64(cfg.headSize), int64(cfg.nKvAttnHeads), int64(nTokens))),
    positions, model.ropeFreq,
    cint(cfg.headSize), 2, 0, 500000.0,
    1.0, 0.0, 1.0, 0.0, 0.0)

  # Repeat-interleave: copy KV heads 'repeat' times into cache with stride
  for i in 0..<repeat:
    let kView = ggml_view_3d(ctx, model.kvCache.kl[layerIdx],
      int64(cfg.headSize), int64(cfg.nKvAttnHeads), int64(nTokens),
      csize_t(elemSize * cfg.headSize * uint32(repeat)),
      csize_t(elemSize * cfg.nAttnHeads * cfg.headSize),
      csize_t(elemSize * cfg.nAttnHeads * cfg.headSize * model.currentPos +
              uint32(i) * elemSize * cfg.headSize))
    ggml_build_forward_expand(gf, ggml_cpy(ctx, kRoped, kView))

    let vView = ggml_view_3d(ctx, model.kvCache.vl[layerIdx],
      int64(cfg.headSize), int64(cfg.nKvAttnHeads), int64(nTokens),
      csize_t(elemSize * cfg.headSize * uint32(repeat)),
      csize_t(elemSize * cfg.nAttnHeads * cfg.headSize),
      csize_t(elemSize * cfg.nAttnHeads * cfg.headSize * model.currentPos +
              uint32(i) * elemSize * cfg.headSize))
    ggml_build_forward_expand(gf, ggml_cpy(ctx, vCur, vView))

# ── Forward pass graph ────────────────────────────────────────────

type ForwardResult = tuple
  gf: ptr GgmlCgraph
  ctx: ptr GgmlContext
  inpTokens, positions, attnMask: ptr GgmlTensor

proc buildForwardGraph(model: OrpheusModel, nTokens: int): ForwardResult =
  let cfg = model.config
  let fullSeqLen = int(model.currentPos) + nTokens
  let memSize = csize_t(8192 * 300 * ggml_type_size(GGML_TYPE_F32))
  let params = GgmlInitParams(mem_size: memSize, mem_buffer: nil, no_alloc: true)
  let ctx = ggml_init(params)
  let gf = ggml_new_graph_custom(ctx, 8192, false)

  let positions = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, int64(nTokens))
  ggml_set_input(positions)
  let inpTokens = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, int64(nTokens))
  ggml_set_input(inpTokens)
  let attnMask = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, int64(fullSeqLen), int64(fullSeqLen))
  ggml_set_input(attnMask)

  var inpL = ggml_get_rows(ctx, model.embd, inpTokens)
  let repeat = int(cfg.nAttnHeads div cfg.nKvAttnHeads)  # 3

  for l in 0..<cfg.nLayers:
    let residual = inpL
    var cur = rmsNorm(ctx, inpL, model.layers[l].inputNorm)

    # Self-attention with GQA
    let qcur = ggml_mul_mat(ctx, model.layers[l].q, cur)
    let kcur = ggml_mul_mat(ctx, model.layers[l].k, cur)
    let vcur = ggml_mul_mat(ctx, model.layers[l].v, cur)

    buildKvStore(ctx, gf, model, kcur, vcur, positions, l, uint32(nTokens), repeat)

    # Read full K from cache
    let k = ggml_cont(ctx, ggml_view_3d(ctx, model.kvCache.kl[l],
      int64(cfg.headSize), int64(fullSeqLen), int64(cfg.nAttnHeads),
      csize_t(ggml_element_size(model.kvCache.kl[l]) * cfg.nAttnHeads * cfg.headSize),
      csize_t(ggml_element_size(model.kvCache.kl[l]) * cfg.headSize),
      0))

    # Read full V from cache
    var v = ggml_view_2d(ctx, model.kvCache.vl[l],
      int64(cfg.hiddenSize), int64(fullSeqLen),
      csize_t(ggml_element_size(model.kvCache.vl[l]) * cfg.hiddenSize),
      0)
    v = ggml_cont_3d(ctx, ggml_transpose(ctx, v),
      int64(fullSeqLen), int64(cfg.headSize), int64(cfg.nAttnHeads))

    # Q with RoPE
    var q = ggml_rope_ext(ctx,
      ggml_cont(ctx, ggml_reshape_3d(ctx, qcur,
        int64(cfg.headSize), int64(cfg.nAttnHeads), int64(nTokens))),
      positions, model.ropeFreq,
      cint(cfg.headSize), 2, 0, 500000.0,
      1.0, 0.0, 1.0, 0.0, 0.0)
    q = ggml_cont(ctx, ggml_permute(ctx, q, 0, 2, 1, 3))

    var kq = ggml_mul_mat(ctx, k, q)
    kq = ggml_soft_max_ext(ctx, kq, attnMask, 1.0 / sqrt(float32(cfg.headSize)), 0.0)

    let kqv = ggml_mul_mat(ctx, kq, v)
    let kqvMerged = ggml_permute(ctx, kqv, 2, 0, 1, 3)
    var attnOut = ggml_cont_2d(ctx, kqvMerged, int64(cfg.hiddenSize), int64(nTokens))
    attnOut = ggml_mul_mat(ctx, model.layers[l].o, attnOut)

    cur = ggml_add(ctx, attnOut, residual)
    let residualFfn = cur

    # SwiGLU MLP
    cur = rmsNorm(ctx, cur, model.layers[l].postAttnNorm)
    cur = ggml_mul(ctx, ggml_silu(ctx, ggml_mul_mat(ctx, model.layers[l].gate, cur)),
                   ggml_mul_mat(ctx, model.layers[l].up, cur))
    cur = ggml_mul_mat(ctx, model.layers[l].down, cur)

    cur = ggml_add(ctx, cur, residualFfn)
    inpL = cur

  # Final norm + LM head
  var cur = rmsNorm(ctx, inpL, model.outputNorm)
  cur = ggml_mul_mat(ctx, model.head, cur)

  # Only take last token's logits
  if nTokens > 1:
    cur = ggml_cont(ctx, ggml_view_1d(ctx, cur,
      int64(cfg.vocabSize),
      csize_t(ggml_element_size(cur) * uint32(nTokens - 1) * cfg.vocabSize)))

  ggml_set_output(cur)
  ggml_build_forward_expand(gf, cur)
  return (gf, ctx, inpTokens, positions, attnMask)

# ── Loading ───────────────────────────────────────────────────────

proc loadOrpheusConfig(gguf: GgufModel): OrpheusConfig =
  result = OrpheusConfig(
    vocabSize: 156940, nAttnHeads: 24, nKvAttnHeads: 8,
    headSize: 128, hiddenSize: 3072, kvHiddenSize: 1024,
    nLayers: 28, maxContextLen: 1024, maxGenSize: 2100,
    stoppingTokenId: 128258, eosTokenId: 128001, bosTokenId: 128000,
    audioHeads: 3,
  )
  result.vocabSize = gguf.getU32("orpheus.vocab_size", result.vocabSize)
  result.nAttnHeads = gguf.getU32("orpheus.attn_heads", result.nAttnHeads)
  result.nKvAttnHeads = gguf.getU32("orpheus.kv_attn_heads", result.nKvAttnHeads)
  result.headSize = gguf.getU32("orpheus.head_dim", result.headSize)
  result.hiddenSize = gguf.getU32("orpheus.hidden_size", result.hiddenSize)
  result.kvHiddenSize = gguf.getU32("orpheus.kv_hidden_size", result.kvHiddenSize)
  result.stoppingTokenId = gguf.getU32("orpheus.stopping_token_id", result.stoppingTokenId)
  result.eosTokenId = gguf.getU32("tokenizer.ggml.eos_token_id", result.eosTokenId)
  result.bosTokenId = gguf.getU32("tokenizer.ggml.bos_token_id", result.bosTokenId)
  let nLayers = gguf.getU32("orpheus.layers", uint32(result.nLayers))
  result.nLayers = int(nLayers)

proc loadOrpheus*(path: string): OrpheusModel =
  var gguf = loadGguf(path)
  let config = loadOrpheusConfig(gguf)
  result = OrpheusModel(config: config, gguf: gguf)

  for i in 0..<config.nLayers:
    result.layers.add(OrpheusLayer())

  # Load SNAC codec and BPE tokenizer from same GGUF
  result.snac = loadSnac(gguf)
  result.bpe = loadBpeTokenizer(gguf)

  # Assign tensors
  for name, tensor in gguf.tensors:
    if name.startsWith("snac."):
      discard  # Already loaded via loadSnac
    elif name.startsWith("orpheus."):
      let oname = name[8..^1]  # strip "orpheus."
      if oname == "norm":
        result.outputNorm = tensor
      elif oname == "lm_head":
        result.head = tensor
      elif oname == "embed_tokens":
        result.embd = tensor
      elif oname == "rope_frequencies":
        result.ropeFreq = tensor
      elif oname.startsWith("layers."):
        let rest = oname[7..^1]
        let dotPos = rest.find('.')
        if dotPos > 0:
          let layerIdx = parseInt(rest[0..<dotPos])
          let lname = rest[dotPos..^1]
          if layerIdx < result.layers.len:
            let l = addr result.layers[layerIdx]
            case lname
            of ".input_layernorm": l.inputNorm = tensor
            of ".post_attention_layernorm": l.postAttnNorm = tensor
            of ".self_attn.q_proj": l.q = tensor
            of ".self_attn.k_proj": l.k = tensor
            of ".self_attn.v_proj": l.v = tensor
            of ".self_attn.o_proj": l.o = tensor
            of ".mlp.gate_proj": l.gate = tensor
            of ".mlp.up_proj": l.up = tensor
            of ".mlp.down_proj": l.down = tensor
            else: discard

# ── Forward pass ──────────────────────────────────────────────────

proc forward*(model: var OrpheusModel, tokens: seq[uint32]): seq[float32] =
  ## Run a single forward pass, returning logits for the last token.
  let cfg = model.config
  let nTokens = tokens.len
  let fullSeqLen = int(model.currentPos) + nTokens

  var fwd = buildForwardGraph(model, nTokens)

  # Allocate computation graph (KV cache is separate)
  let backend = ggml_backend_cpu_init()
  let buft = ggml_backend_cpu_buffer_type()
  let galloc = ggml_gallocr_new(buft)
  discard ggml_gallocr_reserve(galloc, fwd.gf)
  discard ggml_gallocr_alloc_graph(galloc, fwd.gf)

  # Set inputs
  let tokenData = cast[ptr UncheckedArray[int32]](fwd.inpTokens.data)
  for i in 0..<nTokens:
    tokenData[i] = int32(tokens[i])

  let posData = cast[ptr UncheckedArray[int32]](fwd.positions.data)
  for i in 0..<nTokens:
    posData[i] = int32(model.currentPos) + int32(i)

  let maskData = cast[ptr UncheckedArray[float32]](fwd.attnMask.data)
  for i in 0..<nTokens:
    let pos = int32(model.currentPos) + int32(i)
    for j in 0..<fullSeqLen:
      maskData[i * fullSeqLen + j] = if int32(j) > pos: -Inf else: 0.0'f32

  discard ggml_backend_graph_compute(backend, fwd.gf)

  # Extract logits
  result.setLen(int(cfg.vocabSize))
  let nNodes = ggml_graph_n_nodes(fwd.gf)
  let outputNode = ggml_graph_node(fwd.gf, nNodes - 1)
  ggml_backend_tensor_get(outputNode, addr result[0], 0,
    csize_t(int(cfg.vocabSize) * sizeof(float32)))

  model.currentPos += uint32(nTokens)

  ggml_gallocr_free(galloc)
  ggml_free(fwd.ctx)
  ggml_backend_free(backend)

# ── Token preparation ─────────────────────────────────────────────

proc wrapTokens*(model: OrpheusModel, text: string, voice: string): seq[uint32] =
  ## Tokenize text and wrap with Orpheus special tokens.
  ## Format: [128259, 128000] + BPE("voice: text") + [128009, 128260, 128261, 128257]
  for t in PrependedTokens:
    result.add(t)
  let sentence = if voice.len > 0: voice & ": " & text else: text
  result.add(model.bpe.tokenize(sentence))
  for t in AppendedTokens:
    result.add(t)

proc prepareOutputTokens*(outputTokens: seq[uint32]): array[3, seq[uint32]] =
  ## Convert Orpheus output tokens to 3 SNAC head streams.
  let chunks = outputTokens.len div 7
  for i in 0..<chunks:
    for j in 0..6:
      let thead = AudioHeadRouting[j]
      let t = outputTokens[i * 7 + j] - 128266 - uint32(j mod 7) * 4096
      result[thead].add(t)

# ── Generate ──────────────────────────────────────────────────────

proc generate*(model: var OrpheusModel, tokens: seq[uint32],
               temperature: float32 = 1.0, topK: uint32 = 50,
               topP: float32 = 1.0, repPenalty: float32 = 1.0): AudioOutput =
  ## Generate audio from wrapped token sequence.
  let cfg = model.config

  # Initialize KV cache
  model.initKvCache()
  model.currentPos = 0
  model.outputTokens = @[]

  var samp = newSampler(cfg.vocabSize, temperature, topK, topP, repPenalty)

  # Initial prompt pass
  var logits = model.forward(tokens)
  var nextToken = samp.sample(logits)
  model.outputTokens.add(nextToken)

  # Autoregressive generation loop
  while nextToken != cfg.stoppingTokenId and
        model.outputTokens.len < int(cfg.maxGenSize):
    logits = model.forward(@[nextToken])
    nextToken = samp.sample(logits)
    model.outputTokens.add(nextToken)

  # Convert output tokens to SNAC format and decode
  let snacTokens = prepareOutputTokens(model.outputTokens)
  let samples = model.snac.decode(snacTokens)

  result = AudioOutput(
    samples: samples,
    sampleRate: 24000,
    channels: 1,
  )

proc synthesize*(model: var OrpheusModel, text: string,
                 voice: string = "zoe",
                 temperature: float32 = 1.0): AudioOutput =
  ## Full pipeline: tokenize → wrap → generate → decode to audio.
  let wrapped = model.wrapTokens(text, voice)
  return model.generate(wrapped, temperature)

proc close*(model: var OrpheusModel) =
  if model.kvCache.buf != nil:
    ggml_backend_buffer_free(model.kvCache.buf)
  if model.kvCache.ctx != nil:
    ggml_free(model.kvCache.ctx)
  model.gguf.close()

# ── Smoke test ────────────────────────────────────────────────────

when isMainModule:
  import std/os
  if paramCount() < 1:
    echo "Usage: orpheus <model.gguf> [voice] [text]"
    quit(1)

  let path = paramStr(1)
  let voice = if paramCount() >= 2: paramStr(2) else: "zoe"
  let text = if paramCount() >= 3: paramStr(3) else: "Hello, how are you?"

  echo "Loading Orpheus model..."
  var model = loadOrpheus(path)
  echo "Loaded: ", model.config.nLayers, " layers, vocab=", model.config.vocabSize
  echo "BPE vocab: ", model.bpe.tokensToIds.len, " tokens, ", model.bpe.ranks.len, " merges"

  echo "Voice: ", voice
  echo "Text: ", text

  let wrapped = model.wrapTokens(text, voice)
  echo "Wrapped tokens (", wrapped.len, "): ", wrapped[0..min(19, wrapped.len-1)]
  if wrapped.len > 20:
    echo "  ... (", wrapped.len - 20, " more)"

  model.close()
