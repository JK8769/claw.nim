## Structured JSONL status emitter for Zen dashboard.
## nimclawd writes events here; Zen (or any monitor) tails the file.

import std/[json, os, times, locks, posix]
import ../protocol

const MaxStatusFileSize = 5_000_000  # 5MB, then rotate

type
  StatusEmitter* = ref object
    path: string
    file: File
    bytesWritten: int
    lock: Lock

proc newStatusEmitter*(): StatusEmitter =
  let path = statusLogPath()
  let dir = path.parentDir()
  if not dirExists(dir): createDir(dir)
  result = StatusEmitter(path: path, bytesWritten: 0)
  initLock(result.lock)
  var f: File
  if open(f, path, fmAppend):
    result.file = f
    result.bytesWritten = getFileSize(path).int

proc rotate(se: StatusEmitter) =
  if se.file != nil:
    se.file.close()
  let rotated = se.path & ".1"
  if fileExists(rotated): removeFile(rotated)
  moveFile(se.path, rotated)
  var f: File
  if open(f, se.path, fmAppend):
    se.file = f
    se.bytesWritten = 0
    discard chmod(se.path.cstring, 0o600)

proc emit*(se: StatusEmitter, kind: StatusEventKind, data: JsonNode) =
  withLock(se.lock):
    if se.file == nil: return
    let event = %*{
      "ts": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
      "type": $kind,
      "data": data
    }
    let line = $event & "\n"
    se.file.write(line)
    se.file.flushFile()
    se.bytesWritten += line.len
    if se.bytesWritten > MaxStatusFileSize:
      se.rotate()

proc emitAgentStatus*(se: StatusEmitter, name, status: string, ops, tokens: int) =
  se.emit(seAgentStatus, %*{"name": name, "status": status, "ops": ops, "tokens": tokens})

proc emitChannelMsg*(se: StatusEmitter, channel, direction, sender: string) =
  se.emit(seChannelMsg, %*{"channel": channel, "direction": direction, "sender": sender})

proc emitToolCall*(se: StatusEmitter, agent, tool: string, durationMs: int) =
  se.emit(seToolCall, %*{"agent": agent, "tool": tool, "duration_ms": durationMs})

proc emitTts*(se: StatusEmitter, agent, voice: string, durationS: float) =
  se.emit(seTts, %*{"agent": agent, "voice": voice, "duration_s": durationS})

proc emitGatewayStart*(se: StatusEmitter, pid: int) =
  se.emit(seGatewayStart, %*{"pid": pid})

proc emitGatewayStop*(se: StatusEmitter) =
  se.emit(seGatewayStop, %*{})

proc close*(se: StatusEmitter) =
  withLock(se.lock):
    if se.file != nil:
      se.file.close()
      se.file = nil
  deinitLock(se.lock)
