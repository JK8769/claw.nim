## SNAC (Scale Neural Audio Codec) decoder.
## Converts discrete audio tokens (from Orpheus) to PCM audio.

import std/[tables, strutils, math, random]
import ../ggml_bindings
import ../gguf_loader

# ── Types ─────────────────────────────────────────────────────────

type
  ResidualUnit* = object
    padding*, dilation*, groups*: uint32
    inAlpha*, outAlpha*: ptr GgmlTensor
    inConvKernel*, inConvBias*: ptr GgmlTensor
    outConvKernel*, outConvBias*: ptr GgmlTensor

  SnacLayer* = object
    padding*, stride*: uint32
    inAlpha*: ptr GgmlTensor
    inConvKernel*, inConvBias*: ptr GgmlTensor
    noiseConvKernel*: ptr GgmlTensor
    residualBlocks*: seq[ResidualUnit]

  QuantizerLayer* = object
    outProjKernel*, outProjBias*: ptr GgmlTensor
    codebook*: ptr GgmlTensor

  SnacConfig* = object
    nLayers*: uint32
    nHeads*: uint32
    upSamplingFactor*: uint32
    embd*: uint32
    maxGenSize*: uint32
    repeats*: array[3, uint32]
    noiseSteps*: array[4, uint32]
    noiseStepsSum*: uint32

  SnacModel* = object
    config*: SnacConfig
    gguf*: GgufModel
    inConvKernel*, inConvBias*: ptr GgmlTensor
    upConvKernel*, upConvBias*: ptr GgmlTensor
    outConvKernel*, outConvBias*: ptr GgmlTensor
    snakeAlpha*: ptr GgmlTensor
    layers*: seq[SnacLayer]
    quantizerLayers*: seq[QuantizerLayer]

# ── Snake activation ──────────────────────────────────────────────

proc snake1d(ctx: ptr GgmlContext, alpha, a: ptr GgmlTensor): ptr GgmlTensor =
  let sinPart = ggml_sqr(ctx, ggml_sin(ctx, ggml_mul(ctx, a, alpha)))
  return ggml_add(ctx, a, ggml_mul(ctx, sinPart, ggml_reciprocal(ctx, alpha)))

# ── Graph builders ────────────────────────────────────────────────

proc buildQuantizeLayer(ctx: ptr GgmlContext, inp: ptr GgmlTensor,
                        ql: QuantizerLayer): ptr GgmlTensor =
  var cur = ggml_get_rows(ctx, ql.codebook, inp)
  cur = ggml_cont(ctx, ggml_transpose(ctx, cur))
  cur = ggml_conv_1d(ctx, ql.outProjKernel, cur, 1, 0, 1)
  cur = ggml_add(ctx, cur, ql.outProjBias)
  return cur

proc buildResidualUnit(ctx: ptr GgmlContext, cur: ptr GgmlTensor,
                       unit: ResidualUnit): ptr GgmlTensor =
  let residual = cur
  var x = snake1d(ctx, unit.inAlpha, cur)
  if unit.groups > 1:
    x = ggml_conv_1d_dw(ctx, unit.inConvKernel, x, 1, cint(unit.padding), cint(unit.dilation))
  else:
    x = ggml_conv_1d(ctx, unit.inConvKernel, x, 1, cint(unit.padding), cint(unit.dilation))
  x = ggml_add(ctx, x, unit.inConvBias)
  x = snake1d(ctx, unit.outAlpha, x)
  x = ggml_conv_1d(ctx, unit.outConvKernel, x, 1, 0, 1)
  x = ggml_add(ctx, x, unit.outConvBias)
  return ggml_add(ctx, x, residual)

proc buildSnacLayer(ctx: ptr GgmlContext, cur: ptr GgmlTensor,
                    layer: SnacLayer, noise: ptr GgmlTensor): ptr GgmlTensor =
  var x = snake1d(ctx, layer.inAlpha, cur)
  x = ggml_conv_transpose_1d(ctx, layer.inConvKernel, x,
    cint(layer.stride), cint(layer.padding), 1, 0, 1)
  x = ggml_add(ctx, x, layer.inConvBias)
  # Noise injection
  if layer.noiseConvKernel != nil and noise != nil:
    var n = ggml_conv_1d(ctx, layer.noiseConvKernel, x, 1, 0, 1)
    n = ggml_mul(ctx, n, noise)
    x = ggml_add(ctx, x, n)
  for i in 0..<layer.residualBlocks.len:
    x = buildResidualUnit(ctx, x, layer.residualBlocks[i])
  return x

# ── Loading ───────────────────────────────────────────────────────

proc loadSnacConfig(gguf: GgufModel): SnacConfig =
  result = SnacConfig(
    nLayers: 4, nHeads: 3, upSamplingFactor: 512,
    embd: 768, maxGenSize: 2580,
    repeats: [4'u32, 2, 1],
    noiseSteps: [8'u32, 64, 256, 512],
    noiseStepsSum: 840,
  )
  result.nHeads = gguf.getU32("snac.audio_token_channels", result.nHeads)
  result.upSamplingFactor = gguf.getU32("snac.up_sampling_factor", result.upSamplingFactor)
  result.maxGenSize = gguf.getU32("snac.max_generation_size", result.maxGenSize)

proc assignResidualUnit(unit: var ResidualUnit, name: string, tensor: ptr GgmlTensor) =
  if name.endsWith(".res.initial.alpha") or name.endsWith(".in_alpha"):
    unit.inAlpha = tensor
  elif name.endsWith(".res.initial.weight") or name.endsWith(".in_weight"):
    unit.inConvKernel = tensor
  elif name.endsWith(".res.initial.bias") or name.endsWith(".in_bias"):
    unit.inConvBias = tensor
  elif name.endsWith(".res.final.alpha") or name.endsWith(".out_alpha"):
    unit.outAlpha = tensor
  elif name.endsWith(".res.final.weight") or name.endsWith(".out_weight"):
    unit.outConvKernel = tensor
  elif name.endsWith(".res.final.bias") or name.endsWith(".out_bias"):
    unit.outConvBias = tensor

proc loadSnac*(gguf: GgufModel): SnacModel =
  let config = loadSnacConfig(gguf)
  result = SnacModel(config: config, gguf: gguf)

  # Initialize quantizer layers
  for i in 0..<int(config.nHeads):
    result.quantizerLayers.add(QuantizerLayer())

  # Initialize decoder layers with residual blocks
  for i in 0..<int(config.nLayers):
    let stride = gguf.getU32("snac.snac_layer_stride_" & $i, 1)
    let padding = gguf.getU32("snac.snac_layer_padding_" & $i, 0)
    let grouping = gguf.getU32("snac.snac_layer_grouping_" & $i, 1)
    var layer = SnacLayer(padding: padding, stride: stride)
    for j in 0..2:
      layer.residualBlocks.add(ResidualUnit(
        padding: uint32(pow(3.0, float(j + 1))),
        dilation: uint32(pow(3.0, float(j))),
        groups: grouping,
      ))
    result.layers.add(layer)

  # Assign tensors
  for name, tensor in gguf.tensors:
    if not name.startsWith("snac."): continue
    let sname = name[5..^1]  # strip "snac."

    if sname == "alpha_out":
      result.snakeAlpha = tensor
    elif sname == "in.weight":
      result.inConvKernel = tensor
    elif sname == "in.bias":
      result.inConvBias = tensor
    elif sname == "up.weight":
      result.upConvKernel = tensor
    elif sname == "up.bias":
      result.upConvBias = tensor
    elif sname == "final.weight":
      result.outConvKernel = tensor
    elif sname == "final.bias":
      result.outConvBias = tensor
    elif sname.startsWith("layers."):
      let rest = sname[7..^1]
      let dotPos = rest.find('.')
      if dotPos > 0:
        let layerIdx = parseInt(rest[0..<dotPos])
        let lname = rest[dotPos..^1]  # includes the dot
        if layerIdx < result.layers.len:
          let l = addr result.layers[layerIdx]
          if lname == ".alpha" or lname == ".final.alpha":
            l.inAlpha = tensor
          elif lname == ".weight" or lname == ".final.weight":
            l.inConvKernel = tensor
          elif lname == ".bias" or lname == ".final.bias":
            l.inConvBias = tensor
          elif lname == ".noise_weight":
            l.noiseConvKernel = tensor
          elif lname.contains(".res.") or lname.contains(".in_") or lname.contains(".out_"):
            # Parse residual block index: layers.0.0.res.initial.alpha → block 0
            let resRest = lname[1..^1]  # strip leading dot
            let resDotPos = resRest.find('.')
            if resDotPos > 0:
              let blockIdx = parseInt(resRest[0..<resDotPos])
              if blockIdx < l.residualBlocks.len:
                assignResidualUnit(l.residualBlocks[blockIdx], lname, tensor)
    elif sname.startsWith("quantizers."):
      let rest = sname[11..^1]
      let dotPos = rest.find('.')
      if dotPos > 0:
        let qIdx = parseInt(rest[0..<dotPos])
        let qname = rest[dotPos..^1]
        if qIdx < result.quantizerLayers.len:
          if qname == ".out_proj.weight":
            result.quantizerLayers[qIdx].outProjKernel = tensor
          elif qname == ".out_proj.bias":
            result.quantizerLayers[qIdx].outProjBias = tensor
          elif qname == ".codebook.weight":
            result.quantizerLayers[qIdx].codebook = tensor

# ── Decode ────────────────────────────────────────────────────────

proc decode*(model: SnacModel, tokens: array[3, seq[uint32]]): seq[float32] =
  ## Decode 3 streams of audio tokens to PCM samples.
  let cfg = model.config
  let seqLen = tokens[2].len  # Head 2 has full length (repeat=1)

  # Build graph
  let memSize = csize_t(8192 * 300 * ggml_type_size(GGML_TYPE_F32))
  let params = GgmlInitParams(mem_size: memSize, mem_buffer: nil, no_alloc: true)
  let ctx = ggml_init(params)
  let gf = ggml_new_graph_custom(ctx, 8192, false)

  # Noise input
  let totalNoise = int(cfg.noiseStepsSum) * seqLen
  let noiseInput = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, int64(totalNoise))
  ggml_set_input(noiseInput)

  # Build audio inputs from 3 token streams
  let totalTokens = seqLen div 4 + seqLen div 2 + seqLen
  let inpTokens = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, int64(totalTokens))
  ggml_set_input(inpTokens)

  var embd: ptr GgmlTensor = nil
  var lastStride: csize_t = 0
  for i in 0..<int(cfg.nHeads):
    let headLen = seqLen div int(cfg.repeats[i])
    let inpHead = ggml_cont(ctx, ggml_view_1d(ctx, inpTokens, int64(headLen), lastStride))
    lastStride += csize_t(headLen * int(ggml_element_size(inpTokens)))
    var code = buildQuantizeLayer(ctx, inpHead, model.quantizerLayers[i])
    if cfg.repeats[i] > 1:
      # repeat_interleave: reshape to [1, len, embd] → repeat to [rep, len, embd] → reshape to [len*rep, embd]
      code = ggml_repeat(ctx,
        ggml_cont_3d(ctx, code, 1, code.ne[0], code.ne[1]),
        ggml_new_tensor_3d(ctx, GGML_TYPE_F32, int64(cfg.repeats[i]), code.ne[0], int64(cfg.embd)))
      code = ggml_cont_2d(ctx, code, int64(seqLen), code.ne[2])
    if embd == nil:
      embd = code
    else:
      embd = ggml_add(ctx, embd, code)

  # SNAC decoder
  var cur = ggml_conv_1d_dw(ctx, model.inConvKernel, embd, 1, 3, 1)
  cur = ggml_add(ctx, cur, model.inConvBias)
  cur = ggml_conv_1d(ctx, model.upConvKernel, cur, 1, 0, 1)
  cur = ggml_add(ctx, cur, model.upConvBias)

  var noiseOffset: csize_t = 0
  for l in 0..<model.layers.len:
    let noiseLen = int(cfg.noiseSteps[l]) * seqLen
    let noise = ggml_cont(ctx, ggml_view_1d(ctx, noiseInput, int64(noiseLen), noiseOffset))
    noiseOffset += csize_t(noiseLen * sizeof(float32))
    cur = buildSnacLayer(ctx, cur, model.layers[l], noise)

  cur = snake1d(ctx, model.snakeAlpha, cur)
  cur = ggml_conv_1d(ctx, model.outConvKernel, cur, 1, 3, 1)
  cur = ggml_add(ctx, cur, model.outConvBias)
  cur = ggml_tanh(ctx, cur)
  ggml_set_output(cur)
  ggml_build_forward_expand(gf, cur)

  # Allocate and compute
  let backend = ggml_backend_cpu_init()
  let buft = ggml_backend_cpu_buffer_type()
  let galloc = ggml_gallocr_new(buft)
  discard ggml_gallocr_reserve(galloc, gf)
  discard ggml_gallocr_alloc_graph(galloc, gf)

  # Set token inputs (3 heads concatenated)
  let tokenData = cast[ptr UncheckedArray[int32]](inpTokens.data)
  var offset = 0
  for i in 0..2:
    for j in 0..<tokens[i].len:
      tokenData[offset + j] = int32(tokens[i][j])
    offset += tokens[i].len

  # Set noise (random normal)
  let noiseData = cast[ptr UncheckedArray[float32]](noiseInput.data)
  for i in 0..<totalNoise:
    noiseData[i] = gauss(0.0, 1.0).float32

  discard ggml_backend_graph_compute(backend, gf)

  # Extract output
  let nSamples = seqLen * int(cfg.upSamplingFactor)
  result.setLen(nSamples)
  let nNodes = ggml_graph_n_nodes(gf)
  let outputNode = ggml_graph_node(gf, nNodes - 1)
  ggml_backend_tensor_get(outputNode, addr result[0], 0,
    csize_t(nSamples * sizeof(float32)))

  ggml_gallocr_free(galloc)
  ggml_free(ctx)
  ggml_backend_free(backend)
