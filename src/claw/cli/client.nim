## Socket client for nimclaw CLI → nimclawd communication.
## Connects to the Unix domain socket, sends a JSON-RPC request, reads the response.

import std/[net, json, strutils, posix]
import ../protocol

type
  DaemonClient* = ref object
    path: string

proc newDaemonClient*(): DaemonClient =
  DaemonClient(path: socketPath())

proc newDaemonClient*(sockPath: string): DaemonClient =
  DaemonClient(path: sockPath)

proc isRunning*(dc: DaemonClient): bool =
  ## Check if nimclawd socket exists. fileExists() doesn't work on sockets,
  ## so we use stat() which handles all file types.
  var st: Stat
  stat(dc.path.cstring, st) == 0

proc call*(dc: DaemonClient, meth: string, params: JsonNode = newJObject()): RpcResponse =
  ## Send an RPC request to nimclawd and return the response.
  ## Raises IOError if the daemon is not running.
  if not dc.isRunning():
    raise newException(IOError, "nimclawd is not running (no socket at " & dc.path & ")")

  let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  defer: sock.close()

  sock.connectUnix(dc.path)

  let req = newRpcRequest(1, meth, params)
  let data = req.toJson()

  # Send length-prefixed message
  var lenBuf: array[4, char]
  lenBuf[0] = char((data.len shr 24) and 0xFF)
  lenBuf[1] = char((data.len shr 16) and 0xFF)
  lenBuf[2] = char((data.len shr 8) and 0xFF)
  lenBuf[3] = char(data.len and 0xFF)
  sock.send(lenBuf.join("") & data)

  # Read length-prefixed response
  var respLenBuf = newString(4)
  let bytesRead = sock.recv(respLenBuf, 4)
  if bytesRead < 4:
    raise newException(IOError, "Incomplete response from nimclawd")

  let respLen = (respLenBuf[0].int shl 24) or (respLenBuf[1].int shl 16) or
                (respLenBuf[2].int shl 8) or respLenBuf[3].int
  if respLen <= 0 or respLen > 1_048_576:
    raise newException(IOError, "Invalid response length from nimclawd")

  var respData = newString(respLen)
  let respRead = sock.recv(respData, respLen)
  if respRead < respLen:
    raise newException(IOError, "Incomplete response body from nimclawd")

  return parseRpcResponse(respData)

proc callOrDie*(dc: DaemonClient, meth: string, params: JsonNode = newJObject()): JsonNode =
  ## call() but prints error and exits on failure.
  try:
    let resp = dc.call(meth, params)
    if resp.error != "":
      echo "Error: ", resp.error
      quit(1)
    return resp.data
  except IOError as e:
    echo "Error: ", e.msg
    quit(1)
