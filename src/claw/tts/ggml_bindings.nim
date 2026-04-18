## Nim FFI bindings for ggml (mmwillet/ggml fork, support-for-tts branch)
## Only the functions needed for TTS model inference are wrapped.

const
  ggmlH = "ggml.h"
  ggmlBackendH = "ggml-backend.h"
  ggmlCpuH = "ggml-cpu.h"

  GGML_MAX_DIMS* = 4
  GGML_MAX_SRC* = 10
  GGML_MAX_OP_PARAMS* = 64
  GGML_MAX_NAME* = 128
  GGML_DEFAULT_GRAPH_SIZE* = 2048

# ── Types ─────────────────────────────────────────────────────────

type
  GgmlType* {.importc: "enum ggml_type", header: ggmlH, size: sizeof(cint).} = enum
    GGML_TYPE_F32 = 0
    GGML_TYPE_F16 = 1
    GGML_TYPE_Q4_0 = 2
    GGML_TYPE_Q4_1 = 3
    GGML_TYPE_Q5_0 = 6
    GGML_TYPE_Q5_1 = 7
    GGML_TYPE_Q8_0 = 8
    GGML_TYPE_Q8_1 = 9
    GGML_TYPE_I8 = 24
    GGML_TYPE_I16 = 25
    GGML_TYPE_I32 = 26
    GGML_TYPE_I64 = 27

  GgmlContext* {.importc: "struct ggml_context", header: ggmlH, incompleteStruct.} = object
  GgmlBackend* {.importc: "struct ggml_backend", header: ggmlBackendH, incompleteStruct.} = object
  GgmlBackendBuffer* {.importc: "struct ggml_backend_buffer", header: ggmlBackendH, incompleteStruct.} = object
  GgmlBackendBufferType* {.importc: "ggml_backend_buffer_type_t", header: ggmlBackendH.} = pointer
  GgmlBackendSched* {.importc: "ggml_backend_sched_t", header: ggmlBackendH.} = pointer
  GgmlGallocr* {.importc: "ggml_gallocr_t", header: ggmlH.} = pointer

  GgmlTensor* {.importc: "struct ggml_tensor", header: ggmlH, bycopy.} = object
    `type`* {.importc: "type".}: GgmlType
    buffer*: ptr GgmlBackendBuffer
    ne*: array[GGML_MAX_DIMS, int64]
    nb*: array[GGML_MAX_DIMS, csize_t]
    op*: cint
    op_params*: array[GGML_MAX_OP_PARAMS div sizeof(int32), int32]
    flags*: int32
    src*: array[GGML_MAX_SRC, ptr GgmlTensor]
    view_src*: ptr GgmlTensor
    view_offs*: csize_t
    data*: pointer
    name*: array[GGML_MAX_NAME, char]
    extra*: pointer
    padding*: array[8, char]

  GgmlInitParams* {.importc: "struct ggml_init_params", header: ggmlH, bycopy.} = object
    mem_size*: csize_t
    mem_buffer*: pointer
    no_alloc*: bool

  GgmlCgraph* {.importc: "struct ggml_cgraph", header: ggmlH, incompleteStruct.} = object

# ── Init / Free ───────────────────────────────────────────────────

proc ggml_init*(params: GgmlInitParams): ptr GgmlContext
  {.importc, header: ggmlH.}
proc ggml_free*(ctx: ptr GgmlContext)
  {.importc, header: ggmlH.}

# ── Tensor Info ───────────────────────────────────────────────────

proc ggml_nelements*(tensor: ptr GgmlTensor): int64
  {.importc, header: ggmlH.}
proc ggml_nbytes*(tensor: ptr GgmlTensor): csize_t
  {.importc, header: ggmlH.}
proc ggml_type_size*(t: GgmlType): csize_t
  {.importc, header: ggmlH.}
proc ggml_set_name*(tensor: ptr GgmlTensor, name: cstring): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_set_input*(tensor: ptr GgmlTensor)
  {.importc, header: ggmlH.}
proc ggml_set_output*(tensor: ptr GgmlTensor)
  {.importc, header: ggmlH.}

# ── Tensor Creation ───────────────────────────────────────────────

proc ggml_new_tensor_1d*(ctx: ptr GgmlContext, t: GgmlType, ne0: int64): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_new_tensor_2d*(ctx: ptr GgmlContext, t: GgmlType, ne0, ne1: int64): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_new_tensor_3d*(ctx: ptr GgmlContext, t: GgmlType, ne0, ne1, ne2: int64): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_new_tensor_4d*(ctx: ptr GgmlContext, t: GgmlType, ne0, ne1, ne2, ne3: int64): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── Arithmetic Ops ─────────────────────────────────────���──────────

proc ggml_add*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_mul*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_div*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_sqr*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_sin*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_exp*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_tanh*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_sigmoid*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_clamp*(ctx: ptr GgmlContext, a: ptr GgmlTensor, min_val, max_val: cfloat): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_sum_rows*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_round*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── TTS-specific ops (fork only) ───────────────────────��─────────

proc ggml_mod*(ctx: ptr GgmlContext, a: ptr GgmlTensor, mod_val: cfloat): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_cumsum*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_reciprocal*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_stft*(ctx: ptr GgmlContext, a, window: ptr GgmlTensor,
                filter_length, hop_length: cint, compute_abs_and_angle: bool): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_istft*(ctx: ptr GgmlContext, a, window: ptr GgmlTensor,
                 filter_length, hop_length: cint, from_abs_and_angle: bool): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_upscale_linear*(ctx: ptr GgmlContext, a: ptr GgmlTensor, scale_factor: cint): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── Matrix Ops ────────────────────────────────────────────────────

proc ggml_mul_mat*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_get_rows*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_repeat*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_concat*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor, dim: cint): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── Normalization ─────────────────────────────────────────────────

proc ggml_norm*(ctx: ptr GgmlContext, a: ptr GgmlTensor, eps: cfloat): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_rms_norm*(ctx: ptr GgmlContext, a: ptr GgmlTensor, eps: cfloat): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── Activations ───────────────────────────────────────────────────

proc ggml_silu*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_gelu*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_leaky_relu*(ctx: ptr GgmlContext, a: ptr GgmlTensor, negative_slope: cfloat, inplace: bool): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── Attention ─────────────────────────────────────────────────────

proc ggml_soft_max_ext*(ctx: ptr GgmlContext, a, mask: ptr GgmlTensor, scale, max_bias: cfloat): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_rope*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor,
                n_dims: cint, mode: cint): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_rope_ext*(ctx: ptr GgmlContext, a, b, c: ptr GgmlTensor,
                    n_dims, mode: cint, n_ctx_orig: cint,
                    freq_base, freq_scale: cfloat,
                    ext_factor, attn_factor, beta_fast, beta_slow: cfloat): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── Convolution ───────────────────────────────────────────────────

proc ggml_conv_1d*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor,
                   s0, p0, d0: cint): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_conv_1d_dw*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor,
                      s0, p0, d0: cint): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_conv_transpose_1d*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor,
                             s0, p0, d0, op0, g0: cint): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── Shape Manipulation ────────────────────────────────────────────

proc ggml_cont*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_cont_2d*(ctx: ptr GgmlContext, a: ptr GgmlTensor, ne0, ne1: int64): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_cont_3d*(ctx: ptr GgmlContext, a: ptr GgmlTensor, ne0, ne1, ne2: int64): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_cont_4d*(ctx: ptr GgmlContext, a: ptr GgmlTensor, ne0, ne1, ne2, ne3: int64): ptr GgmlTensor
  {.importc, header: ggmlH.}

proc ggml_view_1d*(ctx: ptr GgmlContext, a: ptr GgmlTensor, ne0: int64, offset: csize_t): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_view_2d*(ctx: ptr GgmlContext, a: ptr GgmlTensor,
                   ne0, ne1: int64, nb1: csize_t, offset: csize_t): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_view_3d*(ctx: ptr GgmlContext, a: ptr GgmlTensor,
                   ne0, ne1, ne2: int64, nb1, nb2: csize_t, offset: csize_t): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_view_4d*(ctx: ptr GgmlContext, a: ptr GgmlTensor,
                   ne0, ne1, ne2, ne3: int64, nb1, nb2, nb3: csize_t, offset: csize_t): ptr GgmlTensor
  {.importc, header: ggmlH.}

proc ggml_reshape_2d*(ctx: ptr GgmlContext, a: ptr GgmlTensor, ne0, ne1: int64): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_reshape_3d*(ctx: ptr GgmlContext, a: ptr GgmlTensor, ne0, ne1, ne2: int64): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_reshape_4d*(ctx: ptr GgmlContext, a: ptr GgmlTensor, ne0, ne1, ne2, ne3: int64): ptr GgmlTensor
  {.importc, header: ggmlH.}

proc ggml_transpose*(ctx: ptr GgmlContext, a: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_permute*(ctx: ptr GgmlContext, a: ptr GgmlTensor, axis0, axis1, axis2, axis3: cint): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_cpy*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── Scaling / Upscale ─────────────────────────────────────────────

proc ggml_upscale_ext*(ctx: ptr GgmlContext, a: ptr GgmlTensor,
                       ne0, ne1, ne2, ne3: int64): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── Custom Ops ────────────────────────────────────────────────────

type
  GgmlCustom2Fn* {.importc: "ggml_custom2_op_t", header: ggmlH.} = distinct pointer
  GgmlCustom3Fn* {.importc: "ggml_custom3_op_t", header: ggmlH.} = distinct pointer

proc ggml_map_custom2*(ctx: ptr GgmlContext, a, b: ptr GgmlTensor,
                       fun: GgmlCustom2Fn, n_tasks: cint, userdata: pointer): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_map_custom3*(ctx: ptr GgmlContext, a, b, c: ptr GgmlTensor,
                       fun: GgmlCustom3Fn, n_tasks: cint, userdata: pointer): ptr GgmlTensor
  {.importc, header: ggmlH.}

# ── Graph ─────────────────────────────────────────────────────────

proc ggml_new_graph*(ctx: ptr GgmlContext): ptr GgmlCgraph
  {.importc, header: ggmlH.}
proc ggml_new_graph_custom*(ctx: ptr GgmlContext, size: csize_t, grads: bool): ptr GgmlCgraph
  {.importc, header: ggmlH.}
proc ggml_build_forward_expand*(cgraph: ptr GgmlCgraph, tensor: ptr GgmlTensor)
  {.importc, header: ggmlH.}
proc ggml_graph_compute_with_ctx*(ctx: ptr GgmlContext, cgraph: ptr GgmlCgraph, n_threads: cint)
  {.importc, header: ggmlH.}
proc ggml_graph_node*(cgraph: ptr GgmlCgraph, i: cint): ptr GgmlTensor
  {.importc, header: ggmlH.}
proc ggml_graph_n_nodes*(cgraph: ptr GgmlCgraph): cint
  {.importc, header: ggmlH.}

# ── Backend ───────────────────────────────────────────────────────

proc ggml_backend_cpu_init*(): ptr GgmlBackend
  {.importc, header: ggmlCpuH.}
proc ggml_backend_free*(backend: ptr GgmlBackend)
  {.importc, header: ggmlBackendH.}
proc ggml_backend_cpu_buffer_type*(): GgmlBackendBufferType
  {.importc, header: ggmlCpuH.}

proc ggml_backend_alloc_ctx_tensors*(ctx: ptr GgmlContext, backend: ptr GgmlBackend): ptr GgmlBackendBuffer
  {.importc, header: ggmlBackendH.}

proc ggml_backend_tensor_set*(tensor: ptr GgmlTensor, data: pointer, offset: csize_t, size: csize_t)
  {.importc, header: ggmlBackendH.}
proc ggml_backend_tensor_get*(tensor: ptr GgmlTensor, data: pointer, offset: csize_t, size: csize_t)
  {.importc, header: ggmlBackendH.}

proc ggml_backend_graph_compute*(backend: ptr GgmlBackend, cgraph: ptr GgmlCgraph): cint
  {.importc, header: ggmlBackendH.}

proc ggml_backend_buffer_free*(buffer: ptr GgmlBackendBuffer)
  {.importc, header: ggmlBackendH.}
proc ggml_backend_buffer_get_size*(buffer: ptr GgmlBackendBuffer): csize_t
  {.importc, header: ggmlBackendH.}
proc ggml_element_size*(tensor: ptr GgmlTensor): csize_t
  {.importc, header: ggmlH.}
proc ggml_tensor_overhead*(): csize_t
  {.importc, header: ggmlH.}

proc ggml_backend_buffer_clear*(buffer: ptr GgmlBackendBuffer, value: uint8)
  {.importc, header: ggmlBackendH.}

# ── Graph Allocator ───────────────────────────────────────────────

proc ggml_gallocr_new*(buft: GgmlBackendBufferType): GgmlGallocr
  {.importc, header: ggmlH.}
proc ggml_gallocr_free*(galloc: GgmlGallocr)
  {.importc, header: ggmlH.}
proc ggml_gallocr_reserve*(galloc: GgmlGallocr, graph: ptr GgmlCgraph): bool
  {.importc, header: ggmlH.}
proc ggml_gallocr_alloc_graph*(galloc: GgmlGallocr, graph: ptr GgmlCgraph): bool
  {.importc, header: ggmlH.}

# ── Convenience ───────────────────────────────────────────────────

proc tensorData*(t: ptr GgmlTensor): ptr UncheckedArray[float32] =
  cast[ptr UncheckedArray[float32]](t.data)

proc tensorDataI32*(t: ptr GgmlTensor): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](t.data)

proc tensorName*(t: ptr GgmlTensor): string =
  $cast[cstring](addr t.name[0])

# ── Smoke test ────────────────────────────────────────────────────

when isMainModule:
  echo "Testing ggml bindings..."
  let params = GgmlInitParams(mem_size: 16 * 1024 * 1024, mem_buffer: nil, no_alloc: false)
  let ctx = ggml_init(params)
  if ctx == nil:
    echo "FAIL: ggml_init returned nil"
    quit(1)

  let a = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 4)
  discard ggml_set_name(a, "test_tensor")
  echo "  tensor name: ", tensorName(a)
  echo "  tensor ne[0]: ", a.ne[0]
  echo "  tensor type: ", a.`type`

  # Set data
  let data = tensorData(a)
  data[0] = 1.0
  data[1] = 2.0
  data[2] = 3.0
  data[3] = 4.0
  echo "  data: [", data[0], ", ", data[1], ", ", data[2], ", ", data[3], "]"

  ggml_free(ctx)
  echo "OK: ggml bindings work"
