## Kokoro TTS model runner.
## Non-autoregressive model: text → duration prediction → acoustic synthesis → iSTFT → audio.
## Port of TTS.cpp/src/models/kokoro/model.cpp to Nim.

import std/[tables, strutils, math, random, unicode]
import ../ggml_bindings
import ../gguf_loader
import ../common
import ../tokenizer
import ../phonemizer

# ── Configuration ────────────────────────────────────────────────

type
  KokoroConfig* = object
    bosTokenId*: uint32
    eosTokenId*: uint32
    spaceTokenId*: uint32
    maxContextLength*: uint32
    vocabSize*: uint32
    hiddenSize*: uint32
    nAttnHeads*: uint32
    nLayers*: uint32
    nRecurrence*: uint32
    headSize*: uint32
    durationHiddenSize*: uint32
    upSamplingFactor*: uint32
    upsampleScale*: float32
    scale*: float32
    f0NBlocks*: uint32
    nDurationPredictionLayers*: uint32
    maxDurationPerToken*: uint32
    styleHalfSize*: uint32
    nConvLayers*: uint32
    nKernels*: uint32
    nUpsamples*: uint32
    nDecoderBlocks*: uint32
    nResBlocks*: uint32
    nNoiseBlocks*: uint32
    outConvPadding*: uint32
    postNFft*: uint32
    trueNFft*: uint32
    stftHop*: uint32
    harmonicNum*: uint32
    sinAmp*: float32
    noiseStd*: float32
    voiceThreshold*: float32
    sampleRate*: float32

proc defaultKokoroConfig*(): KokoroConfig =
  KokoroConfig(
    bosTokenId: 0, eosTokenId: 0, spaceTokenId: 16,
    maxContextLength: 512, vocabSize: 178,
    hiddenSize: 768, nAttnHeads: 12, nLayers: 1,
    nRecurrence: 12, headSize: 64,
    durationHiddenSize: 512, upSamplingFactor: 600,
    upsampleScale: 300.0, scale: 0.125,
    f0NBlocks: 3, nDurationPredictionLayers: 3,
    maxDurationPerToken: 20, styleHalfSize: 128,
    nConvLayers: 3, nKernels: 3, nUpsamples: 2,
    nDecoderBlocks: 4, nResBlocks: 6, nNoiseBlocks: 2,
    outConvPadding: 3, postNFft: 11, trueNFft: 20,
    stftHop: 5, harmonicNum: 8,
    sinAmp: 0.1, noiseStd: 0.003,
    voiceThreshold: 10.0, sampleRate: 24000.0,
  )

# ── Weight structures ────────────────────────────────────────────

type
  LstmCell* = object
    weights*: seq[ptr GgmlTensor]     # 8 weight matrices (I,F,G,O input + hidden)
    biases*: seq[ptr GgmlTensor]      # 8 bias vectors
    revWeights*: seq[ptr GgmlTensor]  # reverse direction weights
    revBiases*: seq[ptr GgmlTensor]   # reverse direction biases

  Lstm* = object
    hidden*: seq[ptr GgmlTensor]
    states*: seq[ptr GgmlTensor]
    bidirectional*: bool
    cells*: seq[LstmCell]

  AlbertLayer* = object
    ffn*, ffnOut*: ptr GgmlTensor
    ffnBias*, ffnOutBias*: ptr GgmlTensor
    layerOutputNormWeight*, layerOutputNormBias*: ptr GgmlTensor
    q*, k*, v*, o*: ptr GgmlTensor
    qBias*, kBias*, vBias*, oBias*: ptr GgmlTensor
    attnNormWeight*, attnNormBias*: ptr GgmlTensor

  AdaResConvBlock* = object
    conv1*, conv1Bias*: ptr GgmlTensor
    conv2*, conv2Bias*: ptr GgmlTensor
    norm1Gamma*, norm1GammaBias*: ptr GgmlTensor
    norm1Beta*, norm1BetaBias*: ptr GgmlTensor
    norm2Gamma*, norm2GammaBias*: ptr GgmlTensor
    norm2Beta*, norm2BetaBias*: ptr GgmlTensor
    pool*, poolBias*: ptr GgmlTensor
    upsample*, upsampleBias*: ptr GgmlTensor

  DurationPredictorLayer* = object
    rnn*: Lstm
    adaNormGammaWeight*, adaNormGammaBias*: ptr GgmlTensor
    adaNormBetaWeight*, adaNormBetaBias*: ptr GgmlTensor

  DurationPredictor* = object
    albertEncode*, albertEncodeBias*: ptr GgmlTensor
    layers*: seq[DurationPredictorLayer]
    durationProjLstm*: Lstm
    durationProj*, durationProjBias*: ptr GgmlTensor
    nProjKernel*, nProjBias*: ptr GgmlTensor
    f0ProjKernel*, f0ProjBias*: ptr GgmlTensor
    sharedLstm*: Lstm
    f0Blocks*: seq[AdaResConvBlock]
    nBlocks*: seq[AdaResConvBlock]

  TextEncoderConvLayer* = object
    normGamma*, normBeta*: ptr GgmlTensor
    convWeight*, convBias*: ptr GgmlTensor

  TextEncoder* = object
    embd*: ptr GgmlTensor
    convLayers*: seq[TextEncoderConvLayer]
    outLstm*: Lstm

  GenResBlock* = object
    conv1Dilations*: seq[uint32]
    conv1Paddings*: seq[uint32]
    adain1dGamma1Weights*, adain1dGamma1Biases*: seq[ptr GgmlTensor]
    adain1dBeta1Weights*, adain1dBeta1Biases*: seq[ptr GgmlTensor]
    adain1dGamma2Weights*, adain1dGamma2Biases*: seq[ptr GgmlTensor]
    adain1dBeta2Weights*, adain1dBeta2Biases*: seq[ptr GgmlTensor]
    inputAlphas*, outputAlphas*: seq[ptr GgmlTensor]
    convs1Weights*, convs1Biases*: seq[ptr GgmlTensor]
    convs2Weights*, convs2Biases*: seq[ptr GgmlTensor]

  NoiseResBlock* = object
    inputConvStride*: uint32
    inputConvPadding*: uint32
    inputConv*, inputConvBias*: ptr GgmlTensor
    resBlock*: GenResBlock

  GenUpsampleBlock* = object
    padding*: uint32
    stride*: uint32
    upsampleWeight*, upsampleBias*: ptr GgmlTensor

  Generator* = object
    window*: ptr GgmlTensor
    mSourceWeight*, mSourceBias*: ptr GgmlTensor
    outConvWeight*, outConvBias*: ptr GgmlTensor
    noiseBlocks*: seq[NoiseResBlock]
    resBlocks*: seq[GenResBlock]
    ups*: seq[GenUpsampleBlock]

  Decoder* = object
    f0Conv*, f0ConvBias*: ptr GgmlTensor
    nConv*, nConvBias*: ptr GgmlTensor
    asrConv*, asrConvBias*: ptr GgmlTensor
    decoderBlocks*: seq[AdaResConvBlock]
    encoderBlock*: AdaResConvBlock
    generator*: Generator

# ── Main model ───────────────────────────────────────────────────

type
  KokoroModel* = object
    config*: KokoroConfig
    gguf*: GgufModel

    # ALBERT embeddings
    tokenEmbd*, positionEmbd*: ptr GgmlTensor
    staticTokenTypeValues*: ptr GgmlTensor
    inputNormWeight*, inputNormBias*: ptr GgmlTensor
    embdHidden*, embdHiddenBias*: ptr GgmlTensor
    albertLayers*: seq[AlbertLayer]

    # Voice embeddings
    voices*: Table[string, ptr GgmlTensor]

    # Pre-computed constants
    harmonicSamplingNorm*: ptr GgmlTensor
    samplingFactorScalar*: ptr GgmlTensor
    sqrtTensor*: ptr GgmlTensor
    nKernelsTensor*: ptr GgmlTensor

    # Sub-models
    prosodyPred*: DurationPredictor
    textEncoder*: TextEncoder
    decoder*: Decoder

    # Tokenizer + phonemizer
    tokenizer*: Tokenizer
    phmzr*: Phonemizer

  DurationResponse* = object
    nOutputs*: int
    lengths*: seq[float32]
    hiddenStates*: seq[float32]

# ── GGUF Weight Loading ──────────────────────────────────────────

proc loadConfig(model: GgufModel): KokoroConfig =
  var cfg = defaultKokoroConfig()
  cfg.nRecurrence = model.getU32("kokoro.duration_predictor.albert.recurrence", 12)
  cfg.nAttnHeads = model.getU32("kokoro.duration_predictor.albert.attn_heads", 12)
  cfg.hiddenSize = model.getU32("kokoro.duration_predictor.albert.hidden_size", 768)
  cfg.nLayers = model.getU32("kokoro.duration_predictor.albert.layers", 1)
  cfg.maxContextLength = model.getU32("kokoro.duration_predictor.albert.context_length", 512)
  cfg.durationHiddenSize = model.getU32("kokoro.duration_predictor.hidden_size", 512)
  cfg.nDurationPredictionLayers = model.getU32("kokoro.duration_predictor.layers", 3)
  cfg.f0NBlocks = model.getU32("kokoro.duration_predictor.f0_n_blocks", 3)
  cfg.nConvLayers = model.getU32("kokoro.text_encoder.layers", 3)
  cfg.upSamplingFactor = model.getU32("kokoro.decoder.generator.up_sampling_factor", 600)
  cfg.nDecoderBlocks = model.getU32("kokoro.decoder.generator.layers", 4)
  cfg.trueNFft = model.getU32("kokoro.decoder.generator.n_fft", 20)
  cfg.stftHop = model.getU32("kokoro.decoder.generator.hop", 5)
  cfg.headSize = cfg.hiddenSize div cfg.nAttnHeads
  cfg.scale = 1.0 / sqrt(float32(cfg.headSize))
  cfg.postNFft = cfg.trueNFft div 2 + 1
  return cfg

proc assignLstmWeight(lstm: var Lstm, name: string, tensor: ptr GgmlTensor) =
  ## Route a tensor to the correct LSTM cell slot based on name pattern.
  ## Names like "0.weights.3" or "0.biases.5" or "0.reverse_weights.2"
  let parts = name.split('.')
  if parts.len < 3: return
  let cellIdx = parseInt(parts[0])
  let category = parts[1]
  let idx = parseInt(parts[2])

  # Ensure enough cells
  while lstm.cells.len <= cellIdx:
    lstm.cells.add(LstmCell(
      weights: newSeq[ptr GgmlTensor](8),
      biases: newSeq[ptr GgmlTensor](8),
      revWeights: newSeq[ptr GgmlTensor](8),
      revBiases: newSeq[ptr GgmlTensor](8),
    ))
    lstm.hidden.add(nil)
    lstm.states.add(nil)

  case category
  of "weights": lstm.cells[cellIdx].weights[idx] = tensor
  of "biases": lstm.cells[cellIdx].biases[idx] = tensor
  of "reverse_weights":
    lstm.cells[cellIdx].revWeights[idx] = tensor
    lstm.bidirectional = true
  of "reverse_biases":
    lstm.cells[cellIdx].revBiases[idx] = tensor
    lstm.bidirectional = true
  of "hidden": lstm.hidden[cellIdx] = tensor
  of "states": lstm.states[cellIdx] = tensor
  else: discard

proc assignAdaResBlock(blk: var AdaResConvBlock, name: string, tensor: ptr GgmlTensor) =
  if name == "conv1_weight": blk.conv1 = tensor
  elif name == "conv1_bias": blk.conv1Bias = tensor
  elif name == "conv2_weight": blk.conv2 = tensor
  elif name == "conv2_bias": blk.conv2Bias = tensor
  elif name == "norm1_gamma_weight": blk.norm1Gamma = tensor
  elif name == "norm1_gamma_bias": blk.norm1GammaBias = tensor
  elif name == "norm1_beta_weight": blk.norm1Beta = tensor
  elif name == "norm1_beta_bias": blk.norm1BetaBias = tensor
  elif name == "norm2_gamma_weight": blk.norm2Gamma = tensor
  elif name == "norm2_gamma_bias": blk.norm2GammaBias = tensor
  elif name == "norm2_beta_weight": blk.norm2Beta = tensor
  elif name == "norm2_beta_bias": blk.norm2BetaBias = tensor
  elif name == "pool_weight": blk.pool = tensor
  elif name == "pool_bias": blk.poolBias = tensor
  elif name == "conv1x1_weight": blk.upsample = tensor
  elif name == "upsample_bias": blk.upsampleBias = tensor

proc loadKokoro*(path: string, voice: string = "af_heart"): KokoroModel =
  ## Load a Kokoro GGUF model file and prepare for inference.
  var gguf = loadGguf(path)
  let config = loadConfig(gguf)

  var model = KokoroModel(
    config: config,
    gguf: gguf,
    tokenizer: loadTokenizer(gguf),
    phmzr: newPhonemizer(voice),
  )

  # Walk all tensors and assign to model structure
  for name, tensor in gguf.tensors:
    if not name.startsWith("kokoro."): continue
    let trimmed = name[7..^1]  # strip "kokoro."

    if trimmed.startsWith("duration_predictor."):
      let dpName = trimmed[19..^1]
      # Route to duration predictor sub-components
      if dpName == "encode":
        model.prosodyPred.albertEncode = tensor
      elif dpName == "encode_bias":
        model.prosodyPred.albertEncodeBias = tensor
      elif dpName.startsWith("layers."):
        let rest = dpName[7..^1]  # after "layers."
        let dotPos = rest.find('.')
        if dotPos > 0:
          let rawIdx = parseInt(rest[0..<dotPos])
          let layerName = rest[dotPos+1..^1]
          # Layers alternate: even=LSTM (0,2,4), odd=adaNorm (1,3,5)
          # Map to DurationPredictorLayer index: 0→0, 1→0, 2→1, 3→1, 4→2, 5→2
          let dpLayerIdx = rawIdx div 2
          while model.prosodyPred.layers.len <= dpLayerIdx:
            model.prosodyPred.layers.add(DurationPredictorLayer())
          if rawIdx mod 2 == 0:
            # Even index = LSTM
            if layerName.startsWith("lstm."):
              assignLstmWeight(model.prosodyPred.layers[dpLayerIdx].rnn, layerName[5..^1], tensor)
          else:
            # Odd index = ada norm
            case layerName
            of "gamma_weight": model.prosodyPred.layers[dpLayerIdx].adaNormGammaWeight = tensor
            of "gamma_bias": model.prosodyPred.layers[dpLayerIdx].adaNormGammaBias = tensor
            of "beta_weight": model.prosodyPred.layers[dpLayerIdx].adaNormBetaWeight = tensor
            of "beta_bias": model.prosodyPred.layers[dpLayerIdx].adaNormBetaBias = tensor
            else: discard
      elif dpName.startsWith("duration_lstm."):
        assignLstmWeight(model.prosodyPred.durationProjLstm, dpName[14..^1], tensor)
      elif dpName == "duration_proj": model.prosodyPred.durationProj = tensor
      elif dpName == "duration_proj_bias": model.prosodyPred.durationProjBias = tensor
      elif dpName.startsWith("shared_lstm."):
        assignLstmWeight(model.prosodyPred.sharedLstm, dpName[12..^1], tensor)
      elif dpName.startsWith("f0_blocks."):
        let rest = dpName[10..^1]
        let dotPos = rest.find('.')
        if dotPos > 0:
          let idx = parseInt(rest[0..<dotPos])
          while model.prosodyPred.f0Blocks.len <= idx:
            model.prosodyPred.f0Blocks.add(AdaResConvBlock())
          assignAdaResBlock(model.prosodyPred.f0Blocks[idx], rest[dotPos+1..^1], tensor)
      elif dpName.startsWith("n_blocks."):
        let rest = dpName[9..^1]
        let dotPos = rest.find('.')
        if dotPos > 0:
          let idx = parseInt(rest[0..<dotPos])
          while model.prosodyPred.nBlocks.len <= idx:
            model.prosodyPred.nBlocks.add(AdaResConvBlock())
          assignAdaResBlock(model.prosodyPred.nBlocks[idx], rest[dotPos+1..^1], tensor)
      elif dpName == "n_proj_kernel": model.prosodyPred.nProjKernel = tensor
      elif dpName == "n_proj_bias": model.prosodyPred.nProjBias = tensor
      elif dpName == "f0_proj_kernel": model.prosodyPred.f0ProjKernel = tensor
      elif dpName == "f0_proj_bias": model.prosodyPred.f0ProjBias = tensor

    elif trimmed.startsWith("text_encoder."):
      let teName = trimmed[13..^1]
      if teName == "embedding_weight":
        model.textEncoder.embd = tensor
      elif teName.startsWith("layers."):
        let rest = teName[7..^1]
        let dotPos = rest.find('.')
        if dotPos > 0:
          let idx = parseInt(rest[0..<dotPos])
          let field = rest[dotPos+1..^1]
          while model.textEncoder.convLayers.len <= idx:
            model.textEncoder.convLayers.add(TextEncoderConvLayer())
          case field
          of "weight": model.textEncoder.convLayers[idx].convWeight = tensor
          of "bias": model.textEncoder.convLayers[idx].convBias = tensor
          of "gamma": model.textEncoder.convLayers[idx].normGamma = tensor
          of "beta": model.textEncoder.convLayers[idx].normBeta = tensor
          else: discard
      elif teName.startsWith("lstm."):
        assignLstmWeight(model.textEncoder.outLstm, teName[5..^1], tensor)

    elif trimmed.startsWith("decoder."):
      let decName = trimmed[8..^1]
      if decName.startsWith("generator."):
        let genName = decName[10..^1]
        if genName == "m_source_weight": model.decoder.generator.mSourceWeight = tensor
        elif genName == "m_source_bias": model.decoder.generator.mSourceBias = tensor
        elif genName == "conv_post_weight": model.decoder.generator.outConvWeight = tensor
        elif genName == "conv_post_bias": model.decoder.generator.outConvBias = tensor
        elif genName.startsWith("noise_blocks."):
          let rest = genName[13..^1]
          let dotPos = rest.find('.')
          if dotPos > 0:
            let idx = parseInt(rest[0..<dotPos])
            let field = rest[dotPos+1..^1]
            while model.decoder.generator.noiseBlocks.len <= idx:
              model.decoder.generator.noiseBlocks.add(NoiseResBlock())
            if field == "conv_weight": model.decoder.generator.noiseBlocks[idx].inputConv = tensor
            elif field == "conv_bias": model.decoder.generator.noiseBlocks[idx].inputConvBias = tensor
            elif field.startsWith("resblock."):
              # resblock.N.fieldname
              let rbRest = field[9..^1]
              let rbDot = rbRest.find('.')
              if rbDot > 0:
                let subIdx = parseInt(rbRest[0..<rbDot])
                let subField = rbRest[rbDot+1..^1]
                # Noise blocks have a single res block with sub-indexed entries
                let rb = addr model.decoder.generator.noiseBlocks[idx].resBlock
                # Add entries for the sub-index
                while rb.convs1Weights.len <= subIdx:
                  rb.convs1Weights.add(nil)
                  rb.convs1Biases.add(nil)
                  rb.convs2Weights.add(nil)
                  rb.convs2Biases.add(nil)
                  rb.adain1dGamma1Weights.add(nil)
                  rb.adain1dGamma1Biases.add(nil)
                  rb.adain1dBeta1Weights.add(nil)
                  rb.adain1dBeta1Biases.add(nil)
                  rb.adain1dGamma2Weights.add(nil)
                  rb.adain1dGamma2Biases.add(nil)
                  rb.adain1dBeta2Weights.add(nil)
                  rb.adain1dBeta2Biases.add(nil)
                  rb.inputAlphas.add(nil)
                  rb.outputAlphas.add(nil)
                  rb.conv1Dilations.add(0)
                  rb.conv1Paddings.add(0)
                if subField == "convs1_weight": rb.convs1Weights[subIdx] = tensor
                elif subField == "convs1_bias": rb.convs1Biases[subIdx] = tensor
                elif subField == "convs2_weight": rb.convs2Weights[subIdx] = tensor
                elif subField == "convs2_bias": rb.convs2Biases[subIdx] = tensor
                elif subField == "gamma1_weight": rb.adain1dGamma1Weights[subIdx] = tensor
                elif subField == "gamma1_bias": rb.adain1dGamma1Biases[subIdx] = tensor
                elif subField == "beta1_weight": rb.adain1dBeta1Weights[subIdx] = tensor
                elif subField == "beta1_bias": rb.adain1dBeta1Biases[subIdx] = tensor
                elif subField == "gamma2_weight": rb.adain1dGamma2Weights[subIdx] = tensor
                elif subField == "gamma2_bias": rb.adain1dGamma2Biases[subIdx] = tensor
                elif subField == "beta2_weight": rb.adain1dBeta2Weights[subIdx] = tensor
                elif subField == "beta2_bias": rb.adain1dBeta2Biases[subIdx] = tensor
                elif subField == "alpha1": rb.inputAlphas[subIdx] = tensor
                elif subField == "alpha2": rb.outputAlphas[subIdx] = tensor
        elif genName.startsWith("resblocks."):
          let rest = genName[10..^1]
          let dotPos = rest.find('.')
          if dotPos > 0:
            let idx = parseInt(rest[0..<dotPos])
            let subRest = rest[dotPos+1..^1]
            let subDot = subRest.find('.')
            if subDot > 0:
              let subIdx = parseInt(subRest[0..<subDot])
              let field = subRest[subDot+1..^1]
              while model.decoder.generator.resBlocks.len <= idx:
                model.decoder.generator.resBlocks.add(GenResBlock())
              let rb = addr model.decoder.generator.resBlocks[idx]
              while rb.convs1Weights.len <= subIdx:
                rb.convs1Weights.add(nil)
                rb.convs1Biases.add(nil)
                rb.convs2Weights.add(nil)
                rb.convs2Biases.add(nil)
                rb.adain1dGamma1Weights.add(nil)
                rb.adain1dGamma1Biases.add(nil)
                rb.adain1dBeta1Weights.add(nil)
                rb.adain1dBeta1Biases.add(nil)
                rb.adain1dGamma2Weights.add(nil)
                rb.adain1dGamma2Biases.add(nil)
                rb.adain1dBeta2Weights.add(nil)
                rb.adain1dBeta2Biases.add(nil)
                rb.inputAlphas.add(nil)
                rb.outputAlphas.add(nil)
                rb.conv1Dilations.add(0)
                rb.conv1Paddings.add(0)
              if field == "convs1_weight": rb.convs1Weights[subIdx] = tensor
              elif field == "convs1_bias": rb.convs1Biases[subIdx] = tensor
              elif field == "convs2_weight": rb.convs2Weights[subIdx] = tensor
              elif field == "convs2_bias": rb.convs2Biases[subIdx] = tensor
              elif field == "gamma1_weight": rb.adain1dGamma1Weights[subIdx] = tensor
              elif field == "gamma1_bias": rb.adain1dGamma1Biases[subIdx] = tensor
              elif field == "beta1_weight": rb.adain1dBeta1Weights[subIdx] = tensor
              elif field == "beta1_bias": rb.adain1dBeta1Biases[subIdx] = tensor
              elif field == "gamma2_weight": rb.adain1dGamma2Weights[subIdx] = tensor
              elif field == "gamma2_bias": rb.adain1dGamma2Biases[subIdx] = tensor
              elif field == "beta2_weight": rb.adain1dBeta2Weights[subIdx] = tensor
              elif field == "beta2_bias": rb.adain1dBeta2Biases[subIdx] = tensor
              elif field == "alpha1": rb.inputAlphas[subIdx] = tensor
              elif field == "alpha2": rb.outputAlphas[subIdx] = tensor
        elif genName.startsWith("ups."):
          let rest = genName[4..^1]
          let dotPos = rest.find('.')
          if dotPos > 0:
            let idx = parseInt(rest[0..<dotPos])
            let field = rest[dotPos+1..^1]
            while model.decoder.generator.ups.len <= idx:
              model.decoder.generator.ups.add(GenUpsampleBlock())
            if field == "weight": model.decoder.generator.ups[idx].upsampleWeight = tensor
            elif field == "bias": model.decoder.generator.ups[idx].upsampleBias = tensor
      elif decName.startsWith("decoder_blocks."):
        let rest = decName[15..^1]
        let dotPos = rest.find('.')
        if dotPos > 0:
          let idx = parseInt(rest[0..<dotPos])
          while model.decoder.decoderBlocks.len <= idx:
            model.decoder.decoderBlocks.add(AdaResConvBlock())
          assignAdaResBlock(model.decoder.decoderBlocks[idx], rest[dotPos+1..^1], tensor)
      elif decName.startsWith("encoder_block."):
        assignAdaResBlock(model.decoder.encoderBlock, decName[14..^1], tensor)
      elif decName == "f0_conv_weight": model.decoder.f0Conv = tensor
      elif decName == "f0_conv_bias": model.decoder.f0ConvBias = tensor
      elif decName == "n_conv_weight": model.decoder.nConv = tensor
      elif decName == "n_conv_bias": model.decoder.nConvBias = tensor
      elif decName == "asr_conv_weight": model.decoder.asrConv = tensor
      elif decName == "asr_conv_bias": model.decoder.asrConvBias = tensor

    # ALBERT weights (kokoro.albert.*)
    elif trimmed.startsWith("albert."):
      let aName = trimmed[7..^1]
      if aName.startsWith("layer."):
        let rest = aName[6..^1]
        let dotPos = rest.find('.')
        if dotPos > 0:
          let idx = parseInt(rest[0..<dotPos])
          let field = rest[dotPos+1..^1]
          while model.albertLayers.len <= idx:
            model.albertLayers.add(AlbertLayer())
          let l = addr model.albertLayers[idx]
          case field
          of "q": l.q = tensor
          of "k": l.k = tensor
          of "v": l.v = tensor
          of "o": l.o = tensor
          of "q_bias": l.qBias = tensor
          of "k_bias": l.kBias = tensor
          of "v_bias": l.vBias = tensor
          of "o_bias": l.oBias = tensor
          of "ffn": l.ffn = tensor
          of "ffn_out": l.ffnOut = tensor
          of "ffn_bias": l.ffnBias = tensor
          of "ffn_out_bias": l.ffnOutBias = tensor
          of "attn_norm": l.layerOutputNormWeight = tensor
          of "attn_norm_bias": l.layerOutputNormBias = tensor
          of "ffn_norm": l.attnNormWeight = tensor
          of "ffn_norm_bias": l.attnNormBias = tensor
          else: discard
      elif aName == "token_embd": model.tokenEmbd = tensor
      elif aName == "position_embd": model.positionEmbd = tensor
      elif aName == "token_type_embd": model.staticTokenTypeValues = tensor
      elif aName == "norm": model.inputNormWeight = tensor
      elif aName == "norm_bias": model.inputNormBias = tensor
      elif aName == "embd": model.embdHidden = tensor
      elif aName == "embd_bias": model.embdHiddenBias = tensor

    # Voice embeddings (kokoro.voice_tensors.<name>)
    elif trimmed.startsWith("voice_tensors."):
      let voiceName = trimmed[14..^1]
      model.voices[voiceName] = tensor

  # Load noise block / upsample config from metadata
  let ggufCtx = gguf.ggufCtx
  for i in 0..<model.decoder.generator.noiseBlocks.len:
    let prefix = "kokoro.decoder.generator.noise_blocks." & $i & "."
    model.decoder.generator.noiseBlocks[i].inputConvStride = gguf.getU32(prefix & "stride", 1)
    model.decoder.generator.noiseBlocks[i].inputConvPadding = gguf.getU32(prefix & "padding", 0)
    # Load res_block dilation/padding from metadata
    for j in 0..<model.decoder.generator.noiseBlocks[i].resBlock.convs1Weights.len:
      let rbPrefix = prefix & "res_block." & $j & "."
      model.decoder.generator.noiseBlocks[i].resBlock.conv1Dilations[j] = gguf.getU32(rbPrefix & "dilation", 1)
      model.decoder.generator.noiseBlocks[i].resBlock.conv1Paddings[j] = gguf.getU32(rbPrefix & "padding", 1)

  for i in 0..<model.decoder.generator.resBlocks.len:
    for j in 0..<model.decoder.generator.resBlocks[i].convs1Weights.len:
      let prefix = "kokoro.decoder.generator.res_blocks." & $i & "." & $j & "."
      model.decoder.generator.resBlocks[i].conv1Dilations[j] = gguf.getU32(prefix & "dilation", 1)
      model.decoder.generator.resBlocks[i].conv1Paddings[j] = gguf.getU32(prefix & "padding", 1)

  for i in 0..<model.decoder.generator.ups.len:
    let prefix = "kokoro.decoder.generator.up_convs." & $i & "."
    model.decoder.generator.ups[i].stride = gguf.getU32(prefix & "stride", 1)
    model.decoder.generator.ups[i].padding = gguf.getU32(prefix & "padding", 0)

  # Post-load: allocate LSTM hidden/cell states (zero-initialized)
  # The C++ version does this in post_load_assign() using buffer offsets.
  # For our simple CPU-only approach, we'll create these in the graph context.

  return model

proc postLoadInit*(model: var KokoroModel) =
  ## Create runtime constants needed for inference.
  ## Must be called after loadKokoro and before building graphs.
  ## Allocates constant tensors in a small ggml context.
  let constMemSize = csize_t(64 * 1024)  # 64KB for constants
  let constParams = GgmlInitParams(mem_size: constMemSize, mem_buffer: nil, no_alloc: false)
  let constCtx = ggml_init(constParams)

  # n_kernels_tensor (scalar float = n_kernels)
  model.nKernelsTensor = ggml_new_tensor_1d(constCtx, GGML_TYPE_F32, 1)
  tensorData(model.nKernelsTensor)[0] = float32(model.config.nKernels)

  # sqrt(2) tensor for residual division
  model.sqrtTensor = ggml_new_tensor_1d(constCtx, GGML_TYPE_F32, 1)
  tensorData(model.sqrtTensor)[0] = sqrt(2.0'f32)

  # Hann window for STFT/iSTFT
  let nFft = int(model.config.trueNFft)
  model.decoder.generator.window = ggml_new_tensor_1d(constCtx, GGML_TYPE_F32, int64(nFft))
  let winData = tensorData(model.decoder.generator.window)
  for i in 0..<nFft:
    winData[i] = float32(pow(sin(PI * float64(i) / float64(nFft)), 2.0))

  # Harmonic sampling norm: [(i+1)/sample_rate for i in 0..harmonic_num]
  let nHarm = int(model.config.harmonicNum) + 1
  model.harmonicSamplingNorm = ggml_new_tensor_2d(constCtx, GGML_TYPE_F32, 1, int64(nHarm))
  let harmData = tensorData(model.harmonicSamplingNorm)
  for i in 0..<nHarm:
    harmData[i] = (float32(i) + 1.0) / model.config.sampleRate

  # Sampling factor scalar: upsample_scale * 2 * pi
  model.samplingFactorScalar = ggml_new_tensor_1d(constCtx, GGML_TYPE_F32, 1)
  tensorData(model.samplingFactorScalar)[0] = model.config.upsampleScale * 2.0 * PI

  # Initialize LSTM hidden/cell states (zero) for all LSTMs that don't have them from GGUF
  proc initLstmStates(lstm: var Lstm, constCtx: ptr GgmlContext) =
    for c in 0..<lstm.cells.len:
      if lstm.cells[c].weights.len < 2: continue
      # Hidden size = hidden-to-hidden weight dim (weights[1]), not input-to-hidden (weights[0])
      let hiddenSize = lstm.cells[c].weights[1].ne[0]
      if lstm.hidden[c] == nil:
        lstm.hidden[c] = ggml_new_tensor_2d(constCtx, GGML_TYPE_F32, hiddenSize, 1)
        let hd = tensorData(lstm.hidden[c])
        for i in 0..<int(hiddenSize): hd[i] = 0.0
      if lstm.states[c] == nil:
        lstm.states[c] = ggml_new_tensor_2d(constCtx, GGML_TYPE_F32, hiddenSize, 1)
        let sd = tensorData(lstm.states[c])
        for i in 0..<int(hiddenSize): sd[i] = 0.0

  # Duration predictor LSTMs
  for i in 0..<model.prosodyPred.layers.len:
    initLstmStates(model.prosodyPred.layers[i].rnn, constCtx)
  initLstmStates(model.prosodyPred.durationProjLstm, constCtx)
  initLstmStates(model.prosodyPred.sharedLstm, constCtx)

  # Text encoder LSTM
  initLstmStates(model.textEncoder.outLstm, constCtx)

# ── Graph Building Helpers ───────────────────────────────────────

proc addConvBias(ctx: ptr GgmlContext, conv, bias: ptr GgmlTensor): ptr GgmlTensor =
  ## Add bias after conv_1d. Conv output is [OL, OC, N], bias is [OC].
  ## Reshape bias to [1, OC] for broadcasting.
  let biasReshaped = ggml_reshape_2d(ctx, bias, 1, bias.ne[0])
  return ggml_add(ctx, conv, biasReshaped)

proc buildAlbertNorm(ctx: ptr GgmlContext, cur, weight, bias: ptr GgmlTensor): ptr GgmlTensor =
  ## LayerNorm with eps=1e-12 (standard ALBERT epsilon)
  var x = ggml_norm(ctx, cur, 1e-12)
  x = ggml_add(ctx, ggml_mul(ctx, x, weight), bias)
  return ggml_cont(ctx, x)

proc buildAlbertInputs(ctx: ptr GgmlContext, model: KokoroModel,
                       inpTokens, positions: ptr GgmlTensor): ptr GgmlTensor =
  var tinpts = ggml_cont(ctx, ggml_get_rows(ctx, model.tokenEmbd, inpTokens))
  let pinpts = ggml_get_rows(ctx, model.positionEmbd, positions)
  var inpts = ggml_cont(ctx, ggml_add(ctx, tinpts, pinpts))
  # Static token types (always used in Kokoro)
  let ainpts = ggml_add(ctx, inpts, model.staticTokenTypeValues)
  var output = ggml_cont(ctx, buildAlbertNorm(ctx, ainpts, model.inputNormWeight, model.inputNormBias))
  return ggml_add(ctx, ggml_mul_mat(ctx, model.embdHidden, output), model.embdHiddenBias)

proc buildLstmRun(ctx: ptr GgmlContext, gf: ptr GgmlCgraph, input, h0, c0: ptr GgmlTensor,
                  weights, biases: seq[ptr GgmlTensor], seqLen: uint32,
                  reversed: bool = false): ptr GgmlTensor =
  ## Single LSTM cell forward pass over a sequence.
  var iGate = ggml_add(ctx, ggml_mul_mat(ctx, weights[0], input), biases[0])
  var fGate = ggml_add(ctx, ggml_mul_mat(ctx, weights[2], input), biases[2])
  var gGate = ggml_add(ctx, ggml_mul_mat(ctx, weights[4], input), biases[4])
  var oGate = ggml_add(ctx, ggml_mul_mat(ctx, weights[6], input), biases[6])

  var h = h0
  var c = c0
  var outputs: ptr GgmlTensor = nil

  for idx in 0..<int(seqLen):
    let i = if reversed: int(seqLen) - 1 - idx else: idx

    var iCur = ggml_view_3d(ctx, iGate, iGate.ne[0], 1, iGate.ne[2], iGate.nb[0], iGate.nb[1], csize_t(uint64(iGate.nb[1]) * uint64(i)))
    iCur = ggml_sigmoid(ctx, ggml_add(ctx, iCur, ggml_add(ctx, ggml_mul_mat(ctx, weights[1], h), biases[1])))

    var fCur = ggml_view_3d(ctx, fGate, fGate.ne[0], 1, fGate.ne[2], fGate.nb[0], fGate.nb[1], csize_t(uint64(fGate.nb[1]) * uint64(i)))
    fCur = ggml_sigmoid(ctx, ggml_add(ctx, fCur, ggml_add(ctx, ggml_mul_mat(ctx, weights[3], h), biases[3])))

    var gCur = ggml_view_3d(ctx, gGate, gGate.ne[0], 1, gGate.ne[2], gGate.nb[0], gGate.nb[1], csize_t(uint64(gGate.nb[1]) * uint64(i)))
    gCur = ggml_tanh(ctx, ggml_add(ctx, gCur, ggml_add(ctx, ggml_mul_mat(ctx, weights[5], h), biases[5])))

    var oCur = ggml_view_3d(ctx, oGate, oGate.ne[0], 1, oGate.ne[2], oGate.nb[0], oGate.nb[1], csize_t(uint64(oGate.nb[1]) * uint64(i)))
    oCur = ggml_sigmoid(ctx, ggml_add(ctx, oCur, ggml_add(ctx, ggml_mul_mat(ctx, weights[7], h), biases[7])))

    c = ggml_add(ctx, ggml_mul(ctx, fCur, c), ggml_mul(ctx, iCur, gCur))
    h = ggml_mul(ctx, ggml_tanh(ctx, c), oCur)

    if idx == 0:
      outputs = h
    else:
      outputs = if reversed: ggml_concat(ctx, h, outputs, 1)
                else: ggml_concat(ctx, outputs, h, 1)
    ggml_build_forward_expand(gf, outputs)

  return outputs

proc buildLstm(ctx: ptr GgmlContext, input: ptr GgmlTensor, lstm: Lstm,
               seqLen: uint32, gf: ptr GgmlCgraph): ptr GgmlTensor =
  var resp = input
  var revResp = input

  for c in 0..<lstm.cells.len:
    ggml_build_forward_expand(gf, resp)
    resp = buildLstmRun(ctx, gf, resp, lstm.hidden[c], lstm.states[c],
                        lstm.cells[c].weights, lstm.cells[c].biases, seqLen)
    if lstm.bidirectional:
      revResp = buildLstmRun(ctx, gf, revResp, lstm.hidden[c], lstm.states[c],
                             lstm.cells[c].revWeights, lstm.cells[c].revBiases, seqLen, reversed = true)

  if lstm.bidirectional:
    resp = ggml_concat(ctx, resp, revResp, 0)
  return resp

proc buildAdaResConv(ctx: ptr GgmlContext, x: ptr GgmlTensor, blk: AdaResConvBlock,
                     style, sqrtT: ptr GgmlTensor): ptr GgmlTensor =
  ## Adaptive instance normalization residual conv block.
  var cur = x

  var gamma = ggml_add(ctx, ggml_mul_mat(ctx, blk.norm1Gamma, style), blk.norm1GammaBias)
  var beta = ggml_add(ctx, ggml_mul_mat(ctx, blk.norm1Beta, style), blk.norm1BetaBias)
  cur = ggml_norm(ctx, x, 1e-5)
  cur = ggml_add(ctx, cur, ggml_mul(ctx, cur, ggml_transpose(ctx, gamma)))
  cur = ggml_add(ctx, cur, ggml_transpose(ctx, beta))
  cur = ggml_leaky_relu(ctx, cur, 0.2, false)

  if blk.pool != nil:
    cur = ggml_conv_transpose_1d(ctx, blk.pool, cur, 2, 1, 1, 1, cint(cur.ne[1]))
    cur = addConvBias(ctx, cur, blk.poolBias)

  cur = addConvBias(ctx, ggml_conv_1d(ctx, blk.conv1, cur, 1, 1, 1), blk.conv1Bias)

  gamma = ggml_add(ctx, ggml_mul_mat(ctx, blk.norm2Gamma, style), blk.norm2GammaBias)
  beta = ggml_add(ctx, ggml_mul_mat(ctx, blk.norm2Beta, style), blk.norm2BetaBias)
  cur = ggml_norm(ctx, cur, 1e-5)
  cur = ggml_add(ctx, cur, ggml_mul(ctx, cur, ggml_transpose(ctx, gamma)))
  cur = ggml_add(ctx, cur, ggml_transpose(ctx, beta))
  cur = ggml_leaky_relu(ctx, cur, 0.2, false)
  cur = addConvBias(ctx, ggml_conv_1d(ctx, blk.conv2, cur, 1, 1, 1), blk.conv2Bias)

  var res = cur
  cur = x
  if blk.upsample != nil:
    # conv1x1 is a [1, in_ch, out_ch] conv kernel — use conv_1d for channel projection
    cur = ggml_conv_1d(ctx, blk.upsample, cur, 1, 0, 1)
    if blk.upsampleBias != nil:
      cur = addConvBias(ctx, cur, blk.upsampleBias)
    if blk.pool != nil:
      cur = ggml_upscale_ext(ctx, cur, cur.ne[0] * 2, cur.ne[1], cur.ne[2], cur.ne[3])

  cur = ggml_div(ctx, ggml_add(ctx, res, cur), sqrtT)
  return cur

proc snake1d(ctx: ptr GgmlContext, alpha, a: ptr GgmlTensor): ptr GgmlTensor =
  ## Snake activation: x + sin(x*α)² / α
  let sinPart = ggml_sqr(ctx, ggml_sin(ctx, ggml_mul(ctx, a, alpha)))
  return ggml_add(ctx, a, ggml_mul(ctx, sinPart, ggml_reciprocal(ctx, alpha)))

proc buildGenResBlock(ctx: ptr GgmlContext, x, style: ptr GgmlTensor,
                      blk: GenResBlock): ptr GgmlTensor =
  ## Generator residual block with snake activation + AdaIN.
  var inpl = x
  for i in 0..<blk.convs1Weights.len:
    var gamma = ggml_add(ctx, ggml_mul_mat(ctx, blk.adain1dGamma1Weights[i], style), blk.adain1dGamma1Biases[i])
    var beta = ggml_add(ctx, ggml_mul_mat(ctx, blk.adain1dBeta1Weights[i], style), blk.adain1dBeta1Biases[i])
    var cur = ggml_cont(ctx, ggml_transpose(ctx, ggml_norm(ctx, inpl, 1e-5)))
    cur = ggml_add(ctx, ggml_add(ctx, cur, ggml_mul(ctx, cur, gamma)), beta)
    cur = snake1d(ctx, blk.inputAlphas[i], ggml_cont(ctx, ggml_transpose(ctx, cur)))
    cur = addConvBias(ctx, ggml_conv_1d(ctx, blk.convs1Weights[i], cur, 1, cint(blk.conv1Paddings[i]), cint(blk.conv1Dilations[i])), blk.convs1Biases[i])

    gamma = ggml_add(ctx, ggml_mul_mat(ctx, blk.adain1dGamma2Weights[i], style), blk.adain1dGamma2Biases[i])
    beta = ggml_add(ctx, ggml_mul_mat(ctx, blk.adain1dBeta2Weights[i], style), blk.adain1dBeta2Biases[i])
    cur = ggml_cont(ctx, ggml_transpose(ctx, ggml_norm(ctx, cur, 1e-5)))
    cur = ggml_cont(ctx, ggml_transpose(ctx, ggml_add(ctx, ggml_add(ctx, cur, ggml_mul(ctx, cur, gamma)), beta)))
    cur = snake1d(ctx, blk.outputAlphas[i], cur)
    cur = addConvBias(ctx, ggml_conv_1d(ctx, blk.convs2Weights[i], cur, 1, cint(blk.conv1Paddings[0]), 1), blk.convs2Biases[i])
    inpl = ggml_add(ctx, inpl, cur)
  return inpl

# ── Duration Prediction Graph ────────────────────────────────────

proc buildDurationGraph*(model: KokoroModel, nTokens: int,
                         voiceName: string): tuple[gf: ptr GgmlCgraph,
                         ctx: ptr GgmlContext,
                         inpTokens, positions, attnMask: ptr GgmlTensor] =
  ## Build the ALBERT + LSTM duration prediction graph.
  let cfg = model.config
  let memSize = csize_t(110000 * 300 * ggml_type_size(GGML_TYPE_F32))
  let params = GgmlInitParams(mem_size: memSize, mem_buffer: nil, no_alloc: true)
  let ctx = ggml_init(params)
  let gf = ggml_new_graph_custom(ctx, 110000, false)

  let voice = model.voices[voiceName]
  let styleHalf = ggml_view_1d(ctx, voice, voice.ne[0] div 2,
    csize_t(uint64(voice.ne[0] div 2) * uint64(voice.nb[0]) + uint64(nTokens - 3) * uint64(voice.nb[1])))

  # Input tensors
  let inpTokens = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, int64(nTokens))
  ggml_set_input(inpTokens)
  let positions = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, int64(nTokens))
  ggml_set_input(positions)
  let attnMask = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, int64(nTokens), int64(nTokens))
  ggml_set_input(attnMask)

  var cur = buildAlbertInputs(ctx, model, inpTokens, positions)

  # ALBERT transformer: n_recurrence iterations of shared layer(s)
  for r in 0..<int(cfg.nRecurrence):
    for l in 0..<int(cfg.nLayers):
      let residual = cur
      # Self-attention
      var qcur = ggml_add(ctx, ggml_mul_mat(ctx, model.albertLayers[l].q, cur), model.albertLayers[l].qBias)
      var kcur = ggml_add(ctx, ggml_mul_mat(ctx, model.albertLayers[l].k, cur), model.albertLayers[l].kBias)
      let vcur = ggml_add(ctx, ggml_mul_mat(ctx, model.albertLayers[l].v, cur), model.albertLayers[l].vBias)

      qcur = ggml_reshape_3d(ctx, qcur, int64(cfg.headSize), int64(cfg.nAttnHeads), int64(nTokens))
      kcur = ggml_reshape_3d(ctx, kcur, int64(cfg.headSize), int64(cfg.nAttnHeads), int64(nTokens))

      let q = ggml_permute(ctx, qcur, 0, 2, 1, 3)
      let k = ggml_cont(ctx, ggml_permute(ctx, kcur, 0, 2, 1, 3))
      var kq = ggml_mul_mat(ctx, k, q)
      kq = ggml_soft_max_ext(ctx, kq, attnMask, cfg.scale, 0.0)

      let v = ggml_cont_3d(ctx, ggml_transpose(ctx, vcur), int64(nTokens), int64(cfg.headSize), int64(cfg.nAttnHeads))
      let kqv = ggml_mul_mat(ctx, kq, v)
      let kqvMerged = ggml_permute(ctx, kqv, 2, 0, 1, 3)
      var attnOut = ggml_cont_2d(ctx, kqvMerged, int64(cfg.hiddenSize), int64(nTokens))
      attnOut = ggml_add(ctx, ggml_mul_mat(ctx, model.albertLayers[l].o, attnOut), model.albertLayers[l].oBias)

      cur = ggml_add(ctx, attnOut, residual)
      cur = buildAlbertNorm(ctx, cur, model.albertLayers[l].attnNormWeight, model.albertLayers[l].attnNormBias)

      # FFN
      let residualFfn = cur
      cur = ggml_gelu(ctx, ggml_add(ctx, ggml_mul_mat(ctx, model.albertLayers[l].ffn, cur), model.albertLayers[l].ffnBias))
      cur = ggml_add(ctx, ggml_mul_mat(ctx, model.albertLayers[l].ffnOut, cur), model.albertLayers[l].ffnOutBias)
      cur = ggml_add(ctx, cur, residualFfn)
      cur = buildAlbertNorm(ctx, cur, model.albertLayers[l].layerOutputNormWeight, model.albertLayers[l].layerOutputNormBias)

    ggml_build_forward_expand(gf, cur)

  # Duration / prosody prediction
  cur = ggml_add(ctx, ggml_mul_mat(ctx, model.prosodyPred.albertEncode, cur), model.prosodyPred.albertEncodeBias)
  let styleHalfCont = ggml_cont(ctx, styleHalf)
  cur = ggml_concat(ctx, cur, ggml_repeat(ctx, styleHalfCont, ggml_new_tensor_2d(ctx, GGML_TYPE_F32, styleHalfCont.ne[0], cur.ne[1])), 0)

  for i, layer in model.prosodyPred.layers:
    cur = buildLstm(ctx, cur, layer.rnn, uint32(nTokens), gf)
    let gamma = ggml_add(ctx, ggml_mul_mat(ctx, layer.adaNormGammaWeight, styleHalfCont), layer.adaNormGammaBias)
    let beta = ggml_add(ctx, ggml_mul_mat(ctx, layer.adaNormBetaWeight, styleHalfCont), layer.adaNormBetaBias)
    cur = ggml_norm(ctx, cur, 1e-5)
    cur = ggml_add(ctx, ggml_add(ctx, cur, ggml_mul(ctx, cur, gamma)), beta)
    cur = ggml_concat(ctx, cur, ggml_repeat(ctx, styleHalfCont, ggml_new_tensor_2d(ctx, GGML_TYPE_F32, styleHalfCont.ne[0], cur.ne[1])), 0)

  # Hidden states output
  let d = ggml_cont(ctx, cur)
  discard ggml_set_name(d, "duration_hidden_states")
  ggml_set_output(d)
  ggml_build_forward_expand(gf, d)

  # Duration length prediction
  cur = buildLstm(ctx, cur, model.prosodyPred.durationProjLstm, uint32(nTokens), gf)
  cur = ggml_sigmoid(ctx, ggml_add(ctx, ggml_mul_mat(ctx, model.prosodyPred.durationProj, cur), model.prosodyPred.durationProjBias))
  let lengths = ggml_clamp(ctx, ggml_round(ctx, ggml_sum_rows(ctx, cur)), 1.0, 50.0)
  ggml_set_output(lengths)
  ggml_build_forward_expand(gf, lengths)

  return (gf, ctx, inpTokens, positions, attnMask)

# ── UV Noise Custom Op ───────────────────────────────────────────

proc uvNoiseComputeImpl(dst: ptr GgmlTensor, a, b, c: ptr GgmlTensor,
                        ith, nth: cint, userdata: pointer) {.cdecl, exportc.} =
  ## Custom op: generates UV (voiced/unvoiced) mask and noise for sinusoidal source.
  ## a = fake tensor (defines output shape: [seq_len, harmonic_num, 2])
  ## b = upscaled F0 curve (threshold comparison)
  ## c = packed data: [voice_threshold, noise_std, sin_amp, sin_amp/3, ...random_noise...]
  let voiceThreshold = cast[ptr UncheckedArray[float32]](c.data)[0]
  let noiseStd = cast[ptr UncheckedArray[float32]](c.data)[1]
  let sinAmp = cast[ptr UncheckedArray[float32]](c.data)[2]
  let sinAmpDiv = cast[ptr UncheckedArray[float32]](c.data)[3]
  let randInit = cast[ptr UncheckedArray[float32]](cast[uint](c.data) + 4 * sizeof(float32))

  let rpt = (int(b.ne[0]) + int(nth) - 1) div int(nth)
  let start = int(ith) * rpt
  let finish = min((int(ith) + 1) * rpt, int(b.ne[0]))

  let uvDst = cast[ptr UncheckedArray[float32]](dst.data)
  let noiseDst = cast[ptr UncheckedArray[float32]](cast[uint](dst.data) + uint(dst.nb[2]))
  let tgt = cast[ptr UncheckedArray[float32]](b.data)

  for bt in 0..<int(b.ne[2]):
    for r in start..<finish:
      if tgt[r] > voiceThreshold:
        for h in 0..<int(a.ne[1]):
          let index = h * int(dst.ne[0]) + r
          uvDst[index] = sinAmp
          noiseDst[index] = noiseStd * randInit[index]
      else:
        for h in 0..<int(a.ne[1]):
          let index = h * int(dst.ne[0]) + r
          uvDst[index] = 0.0
          noiseDst[index] = sinAmpDiv * randInit[index]

let uvNoiseCompute* = cast[GgmlCustom3Fn](uvNoiseComputeImpl)

# ── Generation Graph Helpers ─────────────────────────────────────

proc buildSinGen(ctx: ptr GgmlContext, model: KokoroModel,
                 f0Curve: ptr GgmlTensor, harmonicNum, seqLen: int): tuple[
                 sinGen, uvNoiseData: ptr GgmlTensor] =
  ## Build sinusoidal source generator subgraph.
  ## Returns (sin_gen output, uv_noise_data input tensor to fill).
  let cfg = model.config
  # Repeat F0 across harmonics and multiply by harmonic norm
  var cur = ggml_mul(ctx,
    ggml_repeat(ctx, f0Curve,
      ggml_new_tensor_2d(ctx, GGML_TYPE_F32, f0Curve.ne[0], int64(harmonicNum))),
    model.harmonicSamplingNorm)
  # Cumulative phase: cumsum(mod(cur, 1.0)) * sampling_factor
  cur = ggml_mul(ctx, ggml_cumsum(ctx, ggml_mod(ctx, cur, 1.0'f32)), model.samplingFactorScalar)
  # Upsample phase to audio rate
  cur = ggml_upscale_linear(ctx, cur, cint(cfg.upsampleScale))
  # Upsample F0 for threshold comparison
  let upscaled = ggml_upscale_ext(ctx, f0Curve,
    f0Curve.ne[0] * int64(cfg.upsampleScale), f0Curve.ne[1], f0Curve.ne[2], f0Curve.ne[3])

  # UV noise data: packed [voice_threshold, noise_std, sin_amp, sin_amp/3, ...random_floats...]
  let uvNoiseData = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, int64(seqLen * harmonicNum + 4))
  ggml_set_input(uvNoiseData)

  let fake = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, int64(seqLen), int64(harmonicNum), 2)
  let uvNoise = ggml_map_custom3(ctx, fake, upscaled, uvNoiseData, uvNoiseCompute, cint(seqLen), nil)

  # Split UV mask and noise from output
  let uv = ggml_cont(ctx, ggml_view_2d(ctx, uvNoise, uvNoise.ne[0], uvNoise.ne[1], uvNoise.nb[1], 0))
  let noise = ggml_cont(ctx, ggml_view_2d(ctx, uvNoise, uvNoise.ne[0], uvNoise.ne[1], uvNoise.nb[1], uvNoise.nb[2]))

  # sin(phase) * uv_mask + noise → transpose
  let sinGen = ggml_cont(ctx, ggml_transpose(ctx,
    ggml_add(ctx, ggml_mul(ctx, ggml_sin(ctx, cur), uv), noise)))

  return (sinGen, uvNoiseData)

proc buildNoiseBlock(ctx: ptr GgmlContext, blk: NoiseResBlock,
                     x, style: ptr GgmlTensor): ptr GgmlTensor =
  ## Noise residual block: input conv → generator res block.
  var cur = addConvBias(ctx,
    ggml_conv_1d(ctx, blk.inputConv, x, cint(blk.inputConvStride), cint(blk.inputConvPadding), 1),
    blk.inputConvBias)
  return buildGenResBlock(ctx, cur, style, blk.resBlock)

proc buildGenerator(ctx: ptr GgmlContext, model: KokoroModel,
                    x, style, f0Curve, windowSqSum: ptr GgmlTensor,
                    seqLen: int, gf: ptr GgmlCgraph): tuple[
                    audio, uvNoiseData: ptr GgmlTensor] =
  ## Build the full generator subgraph: sinusoidal source → STFT → upsample → res blocks → iSTFT.
  let cfg = model.config
  let gen = model.decoder.generator
  let harmonicNum = int(cfg.harmonicNum) + 1
  let totalFrames = int(f0Curve.ne[0]) * int(cfg.upsampleScale)

  # Build sinusoidal source
  let (sinGen, uvNoiseData) = buildSinGen(ctx, model, f0Curve, harmonicNum,
    totalFrames)

  # Harmonic processing: linear → tanh → STFT
  var har = ggml_tanh(ctx, ggml_add(ctx, ggml_mul_mat(ctx, gen.mSourceWeight, sinGen), gen.mSourceBias))
  har = ggml_stft(ctx, ggml_cont(ctx, ggml_transpose(ctx, har)), gen.window,
    cint(cfg.trueNFft), cint(cfg.stftHop), true)
  # One-sided: take first n_fft/2+1 frequency bins
  har = ggml_cont(ctx, ggml_view_4d(ctx, har,
    int64(cfg.postNFft), har.ne[1], har.ne[2], har.ne[3],
    har.nb[1], har.nb[2], har.nb[3], 0))
  # Split magnitude and phase, recombine
  let mhar = ggml_cont(ctx, ggml_view_3d(ctx, har, har.ne[0], har.ne[1], har.ne[2], har.nb[1], har.nb[2], 0))
  let phhar = ggml_cont(ctx, ggml_view_3d(ctx, har, har.ne[0], har.ne[1], har.ne[2], har.nb[1], har.nb[2], har.nb[3]))
  let combinedHar = ggml_cont(ctx, ggml_transpose(ctx, ggml_concat(ctx, mhar, phhar, 0)))

  # Upsample loop
  var cur = x
  for i in 0..<gen.ups.len:
    cur = ggml_leaky_relu(ctx, cur, 0.1, false)
    cur = addConvBias(ctx,
      ggml_conv_transpose_1d(ctx, gen.ups[i].upsampleWeight,
        ggml_cont(ctx, ggml_transpose(ctx, cur)),
        cint(gen.ups[i].stride), cint(gen.ups[i].padding), 1, 0, 1),
      gen.ups[i].upsampleBias)
    # Last upsample: expand first dim
    if i == gen.ups.len - 1:
      let temp = ggml_cont(ctx, ggml_view_3d(ctx, cur, 1, cur.ne[1], cur.ne[2],
        cur.nb[1], cur.nb[2], cur.nb[0]))
      cur = ggml_concat(ctx, temp, cur, 0)
    # Add noise source
    let xSource = buildNoiseBlock(ctx, gen.noiseBlocks[i], ggml_cont(ctx, combinedHar), style)
    cur = ggml_add(ctx, cur, xSource)
    # Res blocks: sum of n_kernels blocks, divided by n_kernels
    let xIn = cur
    for ii in 0..<int(cfg.nKernels):
      let rbIdx = i * int(cfg.nKernels) + ii
      if ii == 0:
        cur = buildGenResBlock(ctx, xIn, style, gen.resBlocks[rbIdx])
      else:
        cur = ggml_add(ctx, cur, buildGenResBlock(ctx, xIn, style, gen.resBlocks[rbIdx]))
    cur = ggml_cont(ctx, ggml_transpose(ctx, ggml_div(ctx, cur, model.nKernelsTensor)))
    ggml_build_forward_expand(gf, cur)

  # Output conv → split spec/phase → iSTFT
  cur = ggml_leaky_relu(ctx, cur, 0.01, false)
  cur = addConvBias(ctx,
    ggml_conv_1d(ctx, gen.outConvWeight,
      ggml_cont(ctx, ggml_transpose(ctx, cur)), 1, cint(cfg.outConvPadding), 1),
    gen.outConvBias)

  # Split: first postNFft channels = log magnitude, rest = phase
  let spec = ggml_exp(ctx, ggml_view_3d(ctx, cur, cur.ne[0], int64(cfg.postNFft), cur.ne[2],
    cur.nb[1], cur.nb[2], 0))
  let phase = ggml_sin(ctx, ggml_view_3d(ctx, cur, cur.ne[0],
    cur.ne[1] - int64(cfg.postNFft), cur.ne[2],
    cur.nb[1], cur.nb[2], csize_t(uint64(cur.nb[1]) * uint64(cfg.postNFft))))

  let stftInput = ggml_concat(ctx, spec, phase, 3)
  let audio = ggml_div(ctx,
    ggml_istft(ctx, ggml_cont(ctx, ggml_transpose(ctx, stftInput)), gen.window,
      cint(cfg.trueNFft), cint(cfg.stftHop), true),
    windowSqSum)
  discard ggml_set_name(audio, "audio_output")

  return (audio, uvNoiseData)

# ── Full Generation Graph ────────────────────────────────────────

type
  GenerationGraphResult* = object
    gf*: ptr GgmlCgraph
    ctx*: ptr GgmlContext
    inpTokens*: ptr GgmlTensor
    durationMask*: ptr GgmlTensor
    durationPred*: ptr GgmlTensor
    windowSqSum*: ptr GgmlTensor
    uvNoiseData*: ptr GgmlTensor

proc buildGenerationGraph*(model: KokoroModel, nTokens: int,
                           totalDuration: int, voiceName: string): GenerationGraphResult =
  ## Build the full Kokoro generation graph (text encoder + decoder + generator).
  let cfg = model.config
  let memSize = csize_t(570000 * 300 * ggml_type_size(GGML_TYPE_F32))
  let params = GgmlInitParams(mem_size: memSize, mem_buffer: nil, no_alloc: true)
  let ctx = ggml_init(params)
  let gf = ggml_new_graph_custom(ctx, 570000, false)

  let voice = model.voices[voiceName]
  let styleHalf = ggml_view_1d(ctx, voice, voice.ne[0] div 2,
    csize_t(uint64(voice.ne[0] div 2) * uint64(voice.nb[0]) + uint64(nTokens - 3) * uint64(voice.nb[1])))
  let styleHalf2 = ggml_view_1d(ctx, voice, voice.ne[0] div 2,
    csize_t(uint64(nTokens - 3) * uint64(voice.nb[1])))

  # Input tensors
  let inpTokens = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, int64(nTokens))
  ggml_set_input(inpTokens)

  let durationMask = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, int64(totalDuration), int64(nTokens))
  ggml_set_input(durationMask)

  let durationPred = ggml_new_tensor_2d(ctx, GGML_TYPE_F32,
    int64(cfg.durationHiddenSize + cfg.styleHalfSize), int64(nTokens))
  ggml_set_input(durationPred)

  # ── Step 1: Expand hidden states using duration mask ──
  var cur = ggml_mul_mat(ctx,
    ggml_cont(ctx, ggml_transpose(ctx, durationMask)),
    ggml_cont(ctx, ggml_transpose(ctx, durationPred)))
  cur = ggml_cont(ctx, ggml_transpose(ctx, cur))

  # ── Step 2: Shared LSTM ──
  cur = buildLstm(ctx, cur, model.prosodyPred.sharedLstm, uint32(totalDuration), gf)

  # ── Step 3: F0 prediction path ──
  var f0Curve = ggml_cont(ctx, ggml_transpose(ctx, cur))
  for i, blk in model.prosodyPred.f0Blocks:
    f0Curve = buildAdaResConv(ctx, f0Curve, blk, styleHalf, model.sqrtTensor)
  # f0ProjKernel is [1, 256] conv kernel: kernel_size=1, in_ch=256, out_ch=1
  f0Curve = ggml_conv_1d(ctx, model.prosodyPred.f0ProjKernel, f0Curve, 1, 0, 1)
  f0Curve = ggml_reshape_2d(ctx, ggml_cont(ctx, f0Curve), f0Curve.ne[0], 1)
  f0Curve = ggml_add(ctx, f0Curve, model.prosodyPred.f0ProjBias)
  discard ggml_set_name(f0Curve, "f0_out")

  # ── Step 4: Noise prediction path ──
  var n = ggml_cont(ctx, ggml_transpose(ctx, cur))
  for i, blk in model.prosodyPred.nBlocks:
    n = buildAdaResConv(ctx, n, blk, styleHalf, model.sqrtTensor)
  # nProjKernel is [1, 256] conv kernel: kernel_size=1, in_ch=256, out_ch=1
  n = ggml_conv_1d(ctx, model.prosodyPred.nProjKernel, n, 1, 0, 1)
  n = ggml_reshape_2d(ctx, ggml_cont(ctx, n), n.ne[0], 1)
  n = ggml_add(ctx, n, model.prosodyPred.nProjBias)
  discard ggml_set_name(n, "n_out")
  ggml_build_forward_expand(gf, n)

  # ── Step 5: Text encoder ──
  var asr: ptr GgmlTensor
  block:
    var te = ggml_get_rows(ctx, model.textEncoder.embd, inpTokens)
    for i, l in model.textEncoder.convLayers:
      te = ggml_cont(ctx, ggml_transpose(ctx, addConvBias(ctx,
        ggml_conv_1d(ctx, l.convWeight, ggml_cont(ctx, ggml_transpose(ctx, te)), 1, 2, 1),
        l.convBias)))
      te = ggml_norm(ctx, te, 1e-5)
      te = ggml_add(ctx, ggml_mul(ctx, te, l.normGamma), l.normBeta)
      te = ggml_leaky_relu(ctx, te, 0.2, false)
    te = buildLstm(ctx, te, model.textEncoder.outLstm, uint32(nTokens), gf)
    # Expand text encoder output using duration mask
    asr = ggml_mul_mat(ctx,
      ggml_cont(ctx, ggml_transpose(ctx, te)),
      ggml_cont(ctx, ggml_transpose(ctx, durationMask)))

  # ── Step 6: Decoder ──
  block:
    let f0Dec = addConvBias(ctx,
      ggml_conv_1d(ctx, model.decoder.f0Conv, f0Curve, 2, 1, 1),
      model.decoder.f0ConvBias)
    let nDec = addConvBias(ctx,
      ggml_conv_1d(ctx, model.decoder.nConv, n, 2, 1, 1),
      model.decoder.nConvBias)

    # Combine: concat(transpose(asr), f0, n) on dim 1
    cur = ggml_concat(ctx,
      ggml_concat(ctx, ggml_cont(ctx, ggml_transpose(ctx, asr)), f0Dec, 1),
      nDec, 1)
    cur = buildAdaResConv(ctx, cur, model.decoder.encoderBlock, styleHalf2, model.sqrtTensor)
    ggml_build_forward_expand(gf, cur)

    # ASR residual path: asr_conv_weight is [1, 512, 64] conv kernel
    var asrRes = addConvBias(ctx,
      ggml_conv_1d(ctx, model.decoder.asrConv, ggml_cont(ctx, ggml_transpose(ctx, asr)), 1, 0, 1),
      model.decoder.asrConvBias)

    # Decoder blocks with residual connections
    for blk in model.decoder.decoderBlocks:
      cur = ggml_concat(ctx,
        ggml_concat(ctx,
          ggml_concat(ctx, cur, asrRes, 1),
          f0Dec, 1),
        nDec, 1)
      cur = buildAdaResConv(ctx, cur, blk, styleHalf2, model.sqrtTensor)
      ggml_build_forward_expand(gf, cur)

    cur = ggml_cont(ctx, ggml_transpose(ctx, cur))

  # ── Step 7: Generator ──
  let windowSqSum = ggml_new_tensor_1d(ctx, GGML_TYPE_F32,
    int64(totalDuration) * int64(cfg.upSamplingFactor))
  ggml_set_input(windowSqSum)

  let (audio, uvNoiseData) = buildGenerator(ctx, model, cur, styleHalf2, f0Curve,
    windowSqSum, nTokens, gf)
  ggml_set_output(audio)
  ggml_build_forward_expand(gf, audio)

  return GenerationGraphResult(
    gf: gf, ctx: ctx,
    inpTokens: inpTokens,
    durationMask: durationMask,
    durationPred: durationPred,
    windowSqSum: windowSqSum,
    uvNoiseData: uvNoiseData,
  )

# ── Inference Helpers ────────────────────────────────────────────

proc computeWindowSquaredSum*(nFft, hop: int, nFrames: int,
                              tgt: ptr UncheckedArray[float32],
                              window: ptr UncheckedArray[float32]) =
  ## Compute the window squared sum for iSTFT normalization.
  let cutoff = nFrames * hop
  let half = nFft div 2
  for i in 0..<cutoff:
    tgt[i] = 0.0
  for i in 0..<nFrames + (half div hop):
    for ii in 0..<nFft:
      let index = ii + i * hop - half
      if index >= 0 and index < cutoff:
        tgt[index] += window[ii] * window[ii]

proc randomUniformGen*(count: int, tgt: ptr UncheckedArray[float32],
                       minVal: float32 = -1.0, maxVal: float32 = 1.0) =
  ## Fill buffer with uniform random floats.
  for i in 0..<count:
    tgt[i] = minVal + rand(1.0).float32 * (maxVal - minVal)

# ── Synthesize ───────────────────────────────────────────────────

proc synthesizeTokens*(model: KokoroModel, wrapped: seq[uint32],
                       voice: string = "af_heart", speed: float32 = 1.0): AudioOutput =
  ## Synthesize from pre-tokenized input (already wrapped with BOS/EOS).
  let cfg = model.config
  let nTokens = wrapped.len

  # Step 1: Build and run duration graph
  let backend = ggml_backend_cpu_init()
  let buft = ggml_backend_cpu_buffer_type()

  var durResult = buildDurationGraph(model, nTokens, voice)
  let durGalloc = ggml_gallocr_new(buft)
  discard ggml_gallocr_reserve(durGalloc, durResult.gf)
  discard ggml_gallocr_alloc_graph(durGalloc, durResult.gf)

  # Set duration graph inputs
  let tokenData = cast[ptr UncheckedArray[int32]](durResult.inpTokens.data)
  for i in 0..<nTokens:
    tokenData[i] = int32(wrapped[i])
  let posData = cast[ptr UncheckedArray[int32]](durResult.positions.data)
  for i in 0..<nTokens:
    posData[i] = int32(i)
  let maskData = tensorData(durResult.attnMask)
  for i in 0..<nTokens * nTokens:
    maskData[i] = 0.0  # Causal mask: 0 = attend, -inf = block

  discard ggml_backend_graph_compute(backend, durResult.gf)

  # Extract duration response
  var durResp = DurationResponse(nOutputs: nTokens)
  durResp.lengths.setLen(nTokens)
  durResp.hiddenStates.setLen(nTokens * int(cfg.durationHiddenSize + cfg.styleHalfSize))

  # Find output tensors by name
  let durNNodes = ggml_graph_n_nodes(durResult.gf)
  for nodeIdx in 0..<durNNodes:
    let node = ggml_graph_node(durResult.gf, nodeIdx)
    let name = tensorName(node)
    if name == "duration_hidden_states":
      ggml_backend_tensor_get(node, addr durResp.hiddenStates[0], 0,
        csize_t(durResp.hiddenStates.len * sizeof(float32)))
  # Get lengths from last node
  let lastNode = ggml_graph_node(durResult.gf, durNNodes - 1)
  ggml_backend_tensor_get(lastNode, addr durResp.lengths[0], 0,
    csize_t(nTokens * sizeof(float32)))

  # Apply speed scaling to durations
  var totalDuration: int = 0
  for i in 0..<nTokens:
    durResp.lengths[i] = max(1.0, durResp.lengths[i] / speed)

  # Punctuation pauses handled natively by the model's duration predictor.
  # Semicolons replaced with colons before tokenization (noisy token).

  for i in 0..<nTokens:
    totalDuration += int(durResp.lengths[i])


  ggml_gallocr_free(durGalloc)
  ggml_free(durResult.ctx)

  if totalDuration == 0:
    ggml_backend_free(backend)
    return AudioOutput(samples: @[], sampleRate: int32(cfg.sampleRate), channels: 1)

  # Step 3: Build and run generation graph
  var genResult = buildGenerationGraph(model, nTokens, totalDuration, voice)
  let genGalloc = ggml_gallocr_new(buft)
  discard ggml_gallocr_reserve(genGalloc, genResult.gf)
  discard ggml_gallocr_alloc_graph(genGalloc, genResult.gf)

  # Set generation graph inputs: tokens
  let genTokenData = cast[ptr UncheckedArray[int32]](genResult.inpTokens.data)
  for i in 0..<nTokens:
    genTokenData[i] = int32(wrapped[i])

  # Set duration mask (binary expansion matrix)
  let dmData = tensorData(genResult.durationMask)
  var running: float32 = 0.0
  for i in 0..<nTokens:
    let nextRunning = running + durResp.lengths[i]
    for ii in 0..<totalDuration:
      dmData[i * totalDuration + ii] = if float32(ii) >= running and float32(ii) < nextRunning: 1.0 else: 0.0
    running = nextRunning

  # Set duration prediction hidden states
  let dpData = tensorData(genResult.durationPred)
  copyMem(dpData, addr durResp.hiddenStates[0],
    nTokens * int(cfg.durationHiddenSize + cfg.styleHalfSize) * sizeof(float32))

  # Set window squared sum
  let totalAudioSamples = totalDuration * int(cfg.upSamplingFactor)
  let nFrames = totalAudioSamples div int(cfg.stftHop)
  computeWindowSquaredSum(int(cfg.trueNFft), int(cfg.stftHop), nFrames,
    tensorData(genResult.windowSqSum),
    tensorData(model.decoder.generator.window))

  # Set UV noise data (random noise + parameters)
  let harmonicNum = int(cfg.harmonicNum) + 1
  let uvData = tensorData(genResult.uvNoiseData)
  uvData[0] = cfg.voiceThreshold
  uvData[1] = cfg.noiseStd
  uvData[2] = cfg.sinAmp
  uvData[3] = cfg.sinAmp / 3.0
  randomUniformGen(totalAudioSamples * harmonicNum,
    cast[ptr UncheckedArray[float32]](cast[uint](uvData) + 4 * sizeof(float32)))

  discard ggml_backend_graph_compute(backend, genResult.gf)

  # Extract audio output
  result = AudioOutput(
    sampleRate: int32(cfg.sampleRate),
    channels: 1,
  )
  result.samples.setLen(totalAudioSamples)

  # Find audio output tensor (last node in graph)
  let genNNodes = ggml_graph_n_nodes(genResult.gf)
  let audioNode = ggml_graph_node(genResult.gf, genNNodes - 1)
  ggml_backend_tensor_get(audioNode, addr result.samples[0], 0,
    csize_t(totalAudioSamples * sizeof(float32)))

  # Cleanup
  ggml_gallocr_free(genGalloc)
  ggml_free(genResult.ctx)
  ggml_backend_free(backend)

# ── Voices ───────────────────────────────────────────────────────

proc listVoices*(model: KokoroModel): seq[string] =
  for name in model.voices.keys:
    result.add(name)

proc synthesizeSentence(model: KokoroModel, phmzr: Phonemizer,
                        sentence: string, voice: string,
                        speed: float32): AudioOutput =
  ## Synthesize a single sentence. Punctuation tokens pass through to the
  ## model — it handles pauses natively via its duration predictor.
  ## Semicolons → colons and punctuation preservation handled in phonemizer.
  let cfg = model.config
  let normalized = normalizeForKokoro(sentence)
  let phonemes = phmzr.phonemize(normalized)
  var clean = phonemes
  # Strip trailing sentence-end punctuation (pause comes from silence gap)
  # Strip multi-byte trailing: … (E2 80 A6), — (E2 80 94), : used as pause
  while clean.len >= 3 and clean[^3] == '\xE2' and clean[^2] == '\x80' and
        clean[^1] in {'\xA6', '\x94'}:
    clean.setLen(clean.len - 3)
  while clean.len > 0 and clean[^1] in {'.', '!', '?', ':'}:
    clean.setLen(clean.len - 1)
  clean = clean.strip()
  if clean.len == 0:
    return AudioOutput(samples: @[], sampleRate: int32(cfg.sampleRate), channels: 1)
  let tokens = model.tokenizer.tokenize(clean)
  let wrapped = model.tokenizer.wrapTokens(tokens, cfg.bosTokenId)
  return model.synthesizeTokens(wrapped, voice, speed)

proc normalizePunctuation(text: string): string =
  ## Normalize all CJK punctuation to ASCII equivalents.
  ## Collapses multiple consecutive punctuation and ensures spaces after
  ## sentence-ending marks (Chinese text has no spaces between sentences).
  result = text
  result = result.replace("，", ",").replace("、", ",")
  result = result.replace("。", ".").replace("．", ".")
  result = result.replace("！", "!").replace("？", "?")
  result = result.replace("：", ":").replace("；", ";")
  result = result.replace("——", "—").replace("―", "—")
  result = result.replace("……", "…").replace("⋯", "…").replace("...", "…")
  result = result.replace("《", "\"").replace("》", "\"")
  result = result.replace("「", "\"").replace("」", "\"")
  result = result.replace(""", "\"").replace(""", "\"")
  result = result.replace("【", "[").replace("】", "]")
  result = result.replace("（", "(").replace("）", ")")
  result = result.replace("\n", " ")
  # Collapse multiple consecutive punctuation (！！！ → !, ？？？ → ?)
  while "!!" in result: result = result.replace("!!", "!")
  while "??" in result: result = result.replace("??", "?")
  # Ensure space after sentence-ending punctuation when not already present.
  # Chinese text has no spaces between sentences — only . and … are true
  # sentence boundaries (from 。and ……). ！/？ stay as in-sentence emphasis.
  var spaced = newStringOfCap(result.len + 20)
  var i = 0
  while i < result.len:
    # Multi-byte … (E2 80 A6)
    if i + 2 < result.len and result[i] == '\xE2' and result[i+1] == '\x80' and
       result[i+2] == '\xA6':
      spaced.add result[i .. i+2]
      i += 3
      if i < result.len and result[i] != ' ':
        spaced.add ' '
      continue
    spaced.add result[i]
    # Only add space after . (sentence-ending period from 。)
    if result[i] == '.':
      if i + 1 < result.len and result[i + 1] notin {' ', '.', '"', '\'',
          ')', ']'}:
        spaced.add ' '
    inc i
  result = spaced

proc isEmphatic(text: string, pos: int): bool =
  ## Check if the word immediately before text[pos] is emphatic:
  ## all-caps (SO. TOTALLY.) or short ≤3 chars (do. Not. Ask.)
  ## CJK / non-ASCII words are never emphatic — they use periods as sentence ends.
  var j = pos - 1
  while j >= 0 and text[j] == ' ': dec j
  var wordEnd = j
  while j >= 0 and text[j] != ' ': dec j
  let wordStart = j + 1
  if wordStart > wordEnd: return false
  # Non-ASCII (CJK, accented chars) are never emphatic
  for k in wordStart..wordEnd:
    if text[k].ord >= 0x80: return false
  let wordLen = wordEnd - wordStart + 1
  # Short ASCII words before periods are almost always emphatic
  if wordLen <= 3: return true
  # All-caps words are emphatic
  for k in wordStart..wordEnd:
    if text[k].isLowerAscii: return false
  return true

type SplitKind = enum skSentence, skEllipsis

proc splitSentences(text: string): seq[(string, SplitKind)] =
  ## Split on: "! " "? " always; ". " if word before is not emphatic;
  ## "… " (ellipsis) always. Returns (sentence, split_kind) for pause control.
  var cur = ""
  var i = 0
  while i < text.len:
    # Check for … (E2 80 A6) — 3-byte sequence
    if i + 2 < text.len and text[i] == '\xE2' and text[i+1] == '\x80' and text[i+2] == '\xA6':
      cur.add text[i..i+2]
      if i + 3 >= text.len or text[i + 3] == ' ':
        let s = cur.strip()
        if s.len > 0: result.add (s, skEllipsis)
        cur = ""
        if i + 3 < text.len and text[i + 3] == ' ': inc i
      i += 3
      continue
    cur.add text[i]
    if text[i] in {'!', '?'}:
      if i + 1 >= text.len or text[i + 1] == ' ':
        let s = cur.strip()
        if s.len > 0: result.add (s, skSentence)
        cur = ""
        if i + 1 < text.len and text[i + 1] == ' ': inc i
    elif text[i] == '.':
      if (i + 1 >= text.len or text[i + 1] == ' ') and not isEmphatic(text, i):
        let s = cur.strip()
        if s.len > 0: result.add (s, skSentence)
        cur = ""
        if i + 1 < text.len and text[i + 1] == ' ': inc i
    inc i
  let s = cur.strip()
  if s.len > 0: result.add (s, skSentence)

proc synthesize*(model: KokoroModel, text: string,
                 voice: string = "af_maple", speed: float32 = 1.0): AudioOutput =
  ## Full Kokoro TTS pipeline: text → phonemes → tokens → duration → generation → audio.
  ## Normalizes punctuation (CJK → ASCII), splits on sentence boundaries,
  ## and inserts silence between sentences (7x pause = 350ms).
  let cfg = model.config

  # Pick phonemizer based on voice language (first char)
  let voiceLang = if voice.len > 0: voice[0] else: 'a'
  let phmzr = if voiceLang != model.phmzr.langCode:
    newPhonemizer(voice)
  else:
    model.phmzr

  let normalized = normalizePunctuation(text)
  let splits = splitSentences(normalized)

  if splits.len == 0:
    return AudioOutput(samples: @[], sampleRate: int32(cfg.sampleRate), channels: 1)

  # Silence durations: sentence boundary = 350ms, ellipsis = 500ms
  let sr = float32(cfg.sampleRate)
  let sentenceSilence = int(0.35 * sr)
  let ellipsisSilence = int(0.5 * sr)
  var allSamples: seq[float32]

  for i, (sentence, kind) in splits:
    let audio = model.synthesizeSentence(phmzr, sentence, voice, speed)
    if audio.samples.len > 0:
      if allSamples.len > 0:
        # Use previous split's kind to determine gap before this segment
        let gap = if splits[i-1][1] == skEllipsis: ellipsisSilence
                  else: sentenceSilence
        allSamples.setLen(allSamples.len + gap)
      allSamples.add audio.samples

  return AudioOutput(samples: allSamples, sampleRate: int32(cfg.sampleRate), channels: 1)

proc close*(model: var KokoroModel) =
  model.gguf.close()

# ── Smoke test ───────────────────────────────────────────────────

when isMainModule:
  import std/[os, strutils, sequtils, algorithm]
  if paramCount() < 1:
    echo "Usage: kokoro <model.gguf> [voice] [text | --tokens 0,50,83,...]"
    quit(1)

  let path = paramStr(1)
  let voice = if paramCount() >= 2: paramStr(2) else: "af_heart"
  let arg3 = if paramCount() >= 3: paramStr(3) else: ""

  var model = loadKokoro(path, voice)
  model.postLoadInit()
  echo "Loaded: ", model.listVoices().len, " voices, ", model.tokenizer.tokens.len, " tokens"

  if voice == "--tokens-dump":
    for tok, id in model.tokenizer.tokenMap:
      let display = if tok.len == 1 and tok[0].ord < 32: "0x" & tok[0].ord.toHex(2)
                    else: tok
      echo id, "\t", display
    model.close()
    quit(0)

  if voice == "--voices":
    var voices = model.listVoices()
    voices.sort()
    for v in voices: echo v
    model.close()
    quit(0)

  if arg3 == "--tokens" and paramCount() >= 4:
    # Raw token mode: feed exact token IDs for verification
    let tokenStr = paramStr(4)
    let wrapped = tokenStr.split(',').mapIt(uint32(parseInt(it.strip())))
    echo "Raw tokens (", wrapped.len, "): ", wrapped
    let audio = model.synthesizeTokens(wrapped, voice)
    echo "Audio: ", audio.samples.len, " samples @ ", audio.sampleRate, " Hz (",
         audio.samples.len.float / audio.sampleRate.float, "s)"
    if audio.samples.len > 0:
      audio.writeWav("kokoro_output.wav")
      echo "Written to: kokoro_output.wav"
  elif arg3.len > 0:
    echo "Synthesizing: '", arg3, "' with voice '", voice, "'"
    let audio = model.synthesize(arg3, voice)
    echo "Audio: ", audio.samples.len, " samples @ ", audio.sampleRate, " Hz (",
         audio.samples.len.float / audio.sampleRate.float, "s)"
    if audio.samples.len > 0:
      audio.writeWav("kokoro_output.wav")
      echo "Written to: kokoro_output.wav"
  else:
    echo "Usage: kokoro model.gguf voice \"text\""
    echo "       kokoro model.gguf voice --tokens 0,50,83,54,..."

  model.close()
