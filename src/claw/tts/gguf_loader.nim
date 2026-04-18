## GGUF model file loader using ggml's built-in GGUF reader.
## Loads model weights and metadata from .gguf files.

import std/[tables, strutils]
import ggml_bindings

const ggmlH = "ggml.h"

# ── GGUF C types ──────────────────────────────────────────────────

type
  GgufContext* {.importc: "struct gguf_context", header: ggmlH, incompleteStruct.} = object

  GgufInitParams* {.importc: "struct gguf_init_params", header: ggmlH, bycopy.} = object
    no_alloc*: bool
    ctx*: ptr ptr GgmlContext

# ── GGUF C functions ──────────────────────────────────────────────

proc gguf_init_from_file*(fname: cstring, params: GgufInitParams): ptr GgufContext
  {.importc, header: ggmlH.}
proc gguf_free*(ctx: ptr GgufContext)
  {.importc, header: ggmlH.}

proc gguf_get_n_kv*(ctx: ptr GgufContext): cint
  {.importc, header: ggmlH.}
proc gguf_find_key*(ctx: ptr GgufContext, key: cstring): cint
  {.importc, header: ggmlH.}
proc gguf_get_key*(ctx: ptr GgufContext, key_id: cint): cstring
  {.importc, header: ggmlH.}

proc gguf_get_val_u32*(ctx: ptr GgufContext, key_id: cint): uint32
  {.importc, header: ggmlH.}
proc gguf_get_val_i32*(ctx: ptr GgufContext, key_id: cint): int32
  {.importc, header: ggmlH.}
proc gguf_get_val_f32*(ctx: ptr GgufContext, key_id: cint): cfloat
  {.importc, header: ggmlH.}
proc gguf_get_val_str*(ctx: ptr GgufContext, key_id: cint): cstring
  {.importc, header: ggmlH.}
proc gguf_get_val_bool*(ctx: ptr GgufContext, key_id: cint): bool
  {.importc, header: ggmlH.}

proc gguf_get_arr_n*(ctx: ptr GgufContext, key_id: cint): cint
  {.importc, header: ggmlH.}
proc gguf_get_arr_data*(ctx: ptr GgufContext, key_id: cint): pointer
  {.importc, header: ggmlH.}
proc gguf_get_arr_str*(ctx: ptr GgufContext, key_id: cint, i: cint): cstring
  {.importc, header: ggmlH.}

proc gguf_get_n_tensors*(ctx: ptr GgufContext): cint
  {.importc, header: ggmlH.}
proc gguf_get_tensor_name*(ctx: ptr GgufContext, i: cint): cstring
  {.importc, header: ggmlH.}
proc gguf_get_tensor_offset*(ctx: ptr GgufContext, i: cint): csize_t
  {.importc, header: ggmlH.}
proc gguf_get_tensor_type*(ctx: ptr GgufContext, i: cint): GgmlType
  {.importc, header: ggmlH.}
proc gguf_get_data_offset*(ctx: ptr GgufContext): csize_t
  {.importc, header: ggmlH.}

proc ggml_get_tensor*(ctx: ptr GgmlContext, name: cstring): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── High-level loader ─────────────────────────────────────────────

type
  GgufModel* = object
    ggufCtx*: ptr GgufContext
    ggmlCtx*: ptr GgmlContext
    tensors*: Table[string, ptr GgmlTensor]
    architecture*: string

proc getStr*(model: GgufModel, key: string, default: string = ""): string =
  let id = gguf_find_key(model.ggufCtx, key.cstring)
  if id < 0: return default
  return $gguf_get_val_str(model.ggufCtx, id)

proc getU32*(model: GgufModel, key: string, default: uint32 = 0): uint32 =
  let id = gguf_find_key(model.ggufCtx, key.cstring)
  if id < 0: return default
  return gguf_get_val_u32(model.ggufCtx, id)

proc getI32*(model: GgufModel, key: string, default: int32 = 0): int32 =
  let id = gguf_find_key(model.ggufCtx, key.cstring)
  if id < 0: return default
  return gguf_get_val_i32(model.ggufCtx, id)

proc getF32*(model: GgufModel, key: string, default: float32 = 0): float32 =
  let id = gguf_find_key(model.ggufCtx, key.cstring)
  if id < 0: return default
  return gguf_get_val_f32(model.ggufCtx, id)

proc getBool*(model: GgufModel, key: string, default: bool = false): bool =
  let id = gguf_find_key(model.ggufCtx, key.cstring)
  if id < 0: return default
  return gguf_get_val_bool(model.ggufCtx, id)

proc getStrArr*(model: GgufModel, key: string): seq[string] =
  let id = gguf_find_key(model.ggufCtx, key.cstring)
  if id < 0: return @[]
  let n = gguf_get_arr_n(model.ggufCtx, id)
  for i in 0..<n:
    result.add($gguf_get_arr_str(model.ggufCtx, id, i))

proc getF32Arr*(model: GgufModel, key: string): seq[float32] =
  let id = gguf_find_key(model.ggufCtx, key.cstring)
  if id < 0: return @[]
  let n = gguf_get_arr_n(model.ggufCtx, id)
  let data = cast[ptr UncheckedArray[float32]](gguf_get_arr_data(model.ggufCtx, id))
  for i in 0..<n:
    result.add(data[i])

proc tensor*(model: GgufModel, name: string): ptr GgmlTensor =
  if model.tensors.hasKey(name):
    return model.tensors[name]
  # Try looking up directly
  let t = ggml_get_tensor(model.ggmlCtx, name.cstring)
  if t != nil: return t
  raise newException(KeyError, "tensor not found: " & name)

proc hasTensor*(model: GgufModel, name: string): bool =
  model.tensors.hasKey(name) or ggml_get_tensor(model.ggmlCtx, name.cstring) != nil

proc loadGguf*(path: string): GgufModel =
  ## Load a GGUF file, allocating all tensor data into a ggml context.
  var ggmlCtx: ptr GgmlContext = nil
  let params = GgufInitParams(
    no_alloc: false,
    ctx: addr ggmlCtx
  )

  let ggufCtx = gguf_init_from_file(path.cstring, params)
  if ggufCtx == nil:
    raise newException(IOError, "failed to load GGUF: " & path)
  if ggmlCtx == nil:
    gguf_free(ggufCtx)
    raise newException(IOError, "failed to allocate tensors from GGUF: " & path)

  # Build tensor lookup table
  var tensors: Table[string, ptr GgmlTensor]
  let nTensors = gguf_get_n_tensors(ggufCtx)
  for i in 0..<nTensors:
    let name = $gguf_get_tensor_name(ggufCtx, i)
    let t = ggml_get_tensor(ggmlCtx, name.cstring)
    if t != nil:
      tensors[name] = t

  let arch = block:
    let id = gguf_find_key(ggufCtx, "general.architecture")
    if id >= 0: $gguf_get_val_str(ggufCtx, id) else: "unknown"

  result = GgufModel(
    ggufCtx: ggufCtx,
    ggmlCtx: ggmlCtx,
    tensors: tensors,
    architecture: arch
  )

proc loadGgufMeta*(path: string): GgufModel =
  ## Load only GGUF metadata (no tensor data). For tokenizer loading etc.
  var ggmlCtx: ptr GgmlContext = nil
  let params = GgufInitParams(no_alloc: true, ctx: addr ggmlCtx)
  let ggufCtx = gguf_init_from_file(path.cstring, params)
  if ggufCtx == nil:
    raise newException(IOError, "failed to load GGUF metadata: " & path)
  let arch = block:
    let id = gguf_find_key(ggufCtx, "general.architecture")
    if id >= 0: $gguf_get_val_str(ggufCtx, id) else: "unknown"
  result = GgufModel(ggufCtx: ggufCtx, ggmlCtx: ggmlCtx, architecture: arch)

proc close*(model: var GgufModel) =
  if model.ggufCtx != nil:
    gguf_free(model.ggufCtx)
    model.ggufCtx = nil
  if model.ggmlCtx != nil:
    ggml_free(model.ggmlCtx)
    model.ggmlCtx = nil
  model.tensors.clear()

# ── Smoke test ────────────────────────────────────────────────────

when isMainModule:
  import std/os
  if paramCount() < 1:
    echo "Usage: gguf_loader <model.gguf>"
    quit(1)

  let path = paramStr(1)
  echo "Loading: ", path
  var model = loadGguf(path)
  echo "Architecture: ", model.architecture
  echo "Tensors: ", model.tensors.len

  # Print first 10 tensors
  var count = 0
  for name, t in model.tensors:
    echo "  ", name, " [", t.ne[0], "x", t.ne[1], "x", t.ne[2], "x", t.ne[3], "] type=", t.`type`
    count += 1
    if count >= 10:
      echo "  ... (", model.tensors.len - 10, " more)"
      break

  # Print key metadata values
  echo "Key parameters:"
  echo "  name: ", model.getStr("general.name")
  echo "  type: ", model.getStr("general.type")
  echo "  size_label: ", model.getStr("general.size_label")
  echo "  decoder_start_token_id: ", model.getU32("kokoro.decoder_start_token_id")
  echo "  padding_token_id: ", model.getU32("tokenizer.ggml.padding_token_id")
  echo "  eos_token_id: ", model.getU32("tokenizer.ggml.eos_token_id")
  echo "  text_encoder.layers: ", model.getU32("kokoro.text_encoder.layers")
  echo "  dp.albert.layers: ", model.getU32("kokoro.duration_predictor.albert.layers")
  echo "  dp.albert.attn_heads: ", model.getU32("kokoro.duration_predictor.albert.attn_heads")
  echo "  dp.albert.hidden_size: ", model.getU32("kokoro.duration_predictor.albert.hidden_size")
  echo "  dp.albert.recurrence: ", model.getU32("kokoro.duration_predictor.albert.recurrence")
  echo "  dp.albert.context_length: ", model.getU32("kokoro.duration_predictor.albert.context_length")
  echo "  dp.hidden_size: ", model.getU32("kokoro.duration_predictor.hidden_size")
  echo "  dp.layers: ", model.getU32("kokoro.duration_predictor.layers")
  echo "  dp.f0_n_blocks: ", model.getU32("kokoro.duration_predictor.f0_n_blocks")
  echo "  gen.up_sampling_factor: ", model.getU32("kokoro.decoder.generator.up_sampling_factor")
  echo "  gen.layers: ", model.getU32("kokoro.decoder.generator.layers")
  echo "  gen.n_fft: ", model.getU32("kokoro.decoder.generator.n_fft")
  echo "  gen.hop: ", model.getU32("kokoro.decoder.generator.hop")
  echo "  phonemizer.type: ", model.getU32("phonemizer.type")
  echo "  phonemizer.phoneme_type: ", model.getU32("phonemizer.phoneme_type")
  echo "  quantization_type: ", model.getU32("general.quantization_type")

  model.close()
  echo "OK"
