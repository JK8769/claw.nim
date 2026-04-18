## Shared protocol definitions for nimclaw CLI ↔ nimclawd communication.
## HTTP on Unix socket. Path helpers, status event types.

import std/[json, os]

const
  SocketName* = "nimclaw.sock"
  PidFileName* = "nimclawd.pid"
  StatusFileName* = "status.jsonl"

type
  StatusEventKind* = enum
    seAgentStatus = "agent_status"
    seChannelMsg = "channel_msg"
    seToolCall = "tool_call"
    seTts = "tts"
    seGatewayStart = "gateway_start"
    seGatewayStop = "gateway_stop"

  StatusEvent* = object
    ts*: string
    kind*: StatusEventKind
    data*: JsonNode

# ── Path resolution ─────────────────────────────────────────────────
# Runtime base is ~/.nimclawd/, namespaced by service: ~/.nimclawd/<service>/.
# Each service instance gets its own socket, PID, logs, config pointer.
# Config dir (~/.nimclaw or NIMCLAW_DIR) is separate — see config.nim.

const RuntimeBaseDir* = "~/.nimclawd"

proc serviceRuntimeName*(): string =
  ## Runtime service name from NIMCLAW_SERVICE env. Defaults to "default".
  let env = getEnv("NIMCLAW_SERVICE", "default")
  if env == "": "default" else: env

proc runtimeDir*(): string =
  expandTilde(RuntimeBaseDir) / serviceRuntimeName()

proc socketPath*(): string =
  runtimeDir() / SocketName

proc pidFilePath*(): string =
  runtimeDir() / PidFileName

proc statusLogPath*(): string =
  runtimeDir() / StatusFileName

proc logsDir*(): string =
  runtimeDir() / "logs"

const ConfigDirFile* = "config_dir"

proc configDirPointer*(): string =
  runtimeDir() / ConfigDirFile

# ── Legacy JSON-RPC types (kept for backward compatibility during migration) ──

type
  RpcRequest* = object
    id*: int
    `method`*: string
    params*: JsonNode

  RpcResponse* = object
    id*: int
    data*: JsonNode
    error*: string

proc newRpcRequest*(id: int, meth: string, params: JsonNode = newJObject()): RpcRequest =
  RpcRequest(id: id, `method`: meth, params: params)

proc newRpcResponse*(id: int, data: JsonNode): RpcResponse =
  RpcResponse(id: id, data: data, error: "")

proc newRpcError*(id: int, error: string): RpcResponse =
  RpcResponse(id: id, data: newJNull(), error: error)

proc toJson*(req: RpcRequest): string =
  $ %*{"id": req.id, "method": req.`method`, "params": req.params}

proc toJson*(resp: RpcResponse): string =
  if resp.error != "":
    $ %*{"id": resp.id, "error": resp.error}
  else:
    $ %*{"id": resp.id, "result": resp.data}

proc parseRpcRequest*(data: string): RpcRequest =
  let j = parseJson(data)
  RpcRequest(
    id: j{"id"}.getInt(0),
    `method`: j{"method"}.getStr(""),
    params: j.getOrDefault("params")
  )

proc parseRpcResponse*(data: string): RpcResponse =
  let j = parseJson(data)
  let err = j{"error"}.getStr("")
  var resp = RpcResponse(id: j{"id"}.getInt(0), error: err)
  resp.data = if err == "": j.getOrDefault("result") else: newJNull()
  resp
