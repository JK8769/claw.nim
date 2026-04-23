## NKN Bridge — subprocess-based NKN client.
##
## Replaces the C FFI shared library approach with a Go subprocess
## that communicates via NDJSON on stdin/stdout. Messages received
## from the NKN network are pushed asynchronously to a callback.

import std/[json, osproc, streams, os, locks, tables, atomics]

type
  NknMessageCallback* = proc(clientAddr, src, data: string) {.gcsafe.}

  NknBridge* = ref object
    process: Process
    writerLock: Lock
    pendingLock: Lock
    pending: Table[string, ptr Channel[string]]
    nextId: Atomic[int]
    onMessage*: NknMessageCallback
    running*: bool
    readerThread: Thread[(NknBridge,)]  ## kept as a field so the
                                         ## handle outlives createThread
                                         ## — stack-allocating triggers
                                         ## SIGILL on ARM64.

proc findBridgeBinary(): string =
  # Look in channels/bin/nkn-cli, next to executable, then on PATH
  let srcDir = currentSourcePath().parentDir()
  let binDir = srcDir / ".." / ".." / ".." / "channels" / "bin"
  let path = binDir / "nkn-cli"
  if fileExists(path): return path
  let appPath = getAppDir() / "nkn-cli"
  if fileExists(appPath): return appPath
  let onPath = findExe("nkn-cli")
  if onPath.len > 0: return onPath
  return ""

proc sendRequest(b: NknBridge, meth: string, params: JsonNode): JsonNode =
  let id = $b.nextId.fetchAdd(1)
  let req = %*{"id": id, "method": meth, "params": params}

  var ch: Channel[string]
  ch.open()

  acquire(b.pendingLock)
  b.pending[id] = addr ch
  release(b.pendingLock)

  acquire(b.writerLock)
  try:
    b.process.inputStream.writeLine($req)
    b.process.inputStream.flush()
  finally:
    release(b.writerLock)

  # Block until response arrives
  let raw = ch.recv()
  ch.close()
  result = parseJson(raw)

proc readerLoop(args: (NknBridge,)) {.thread.} =
  let b = args[0]
  let stream = b.process.outputStream
  while b.running:
    try:
      let line = stream.readLine()
      if line.len == 0:
        if not b.process.running:
          break
        continue
      let j = parseJson(line)

      # Incoming pushed message (no id)
      if j.hasKey("type") and j["type"].getStr() == "message":
        if b.onMessage != nil:
          b.onMessage(
            j["client_addr"].getStr(),
            j["src"].getStr(),
            j["data"].getStr()
          )
        continue

      # Response to a pending request
      let id = j.getOrDefault("id").getStr()
      if id.len > 0:
        acquire(b.pendingLock)
        let chPtr = b.pending.getOrDefault(id, nil)
        if chPtr != nil:
          b.pending.del(id)
        release(b.pendingLock)
        if chPtr != nil:
          chPtr[].send(line)
    except IOError:
      break
    except:
      discard

proc newNknBridge*(onMessage: NknMessageCallback = nil): NknBridge =
  let binPath = findBridgeBinary()
  if binPath.len == 0:
    raise newException(IOError, "nkn_bridge binary not found. Build with: cd src/claw/libnkn && go build -o nkn_bridge nkn_bridge.go")

  let process = startProcess(binPath, options = {poUsePath})

  var b = NknBridge(
    process: process,
    pending: initTable[string, ptr Channel[string]](),
    onMessage: onMessage,
    running: true
  )
  initLock(b.writerLock)
  initLock(b.pendingLock)

  createThread(b.readerThread, readerLoop, (b,))
  return b

proc stop*(b: NknBridge) =
  b.running = false
  try:
    b.process.inputStream.close()  # signals EOF to Go bridge
    discard b.process.waitForExit(3000)
    if b.process.running:
      b.process.terminate()
      discard b.process.waitForExit(1000)
      if b.process.running:
        b.process.kill()
    b.process.close()
  except:
    discard

# --- Public API matching the old FFI interface ---

proc getWallet*(b: NknBridge, password: string): (string, string) =
  let resp = b.sendRequest("generate_wallet", %*{"password": password})
  (resp.getOrDefault("result").getStr(), resp.getOrDefault("error").getStr())

proc generateWalletWithSeed*(b: NknBridge, seedHex, password: string): (string, string) =
  let resp = b.sendRequest("generate_wallet_with_seed", %*{"seed_hex": seedHex, "password": password})
  (resp.getOrDefault("result").getStr(), resp.getOrDefault("error").getStr())

proc createNKNClient*(b: NknBridge, walletJson, password, identifier: string, numSubClients: int = 4, originalClient: bool = false): (string, string) =
  let resp = b.sendRequest("create_client", %*{
    "wallet_json": walletJson,
    "password": password,
    "identifier": identifier,
    "num_sub_clients": numSubClients,
    "original_client": originalClient
  })
  (resp.getOrDefault("result").getStr(), resp.getOrDefault("error").getStr())

proc getNKNAddress*(b: NknBridge, walletJson, password, identifier: string): (string, string) =
  let resp = b.sendRequest("get_address", %*{
    "wallet_json": walletJson,
    "password": password,
    "identifier": identifier
  })
  (resp.getOrDefault("result").getStr(), resp.getOrDefault("error").getStr())

proc sendNKNMessage*(b: NknBridge, clientAddr, destAddr, message: string, maxHoldingSeconds: int = 0, noReply: bool = false): (string, string) =
  let resp = b.sendRequest("send_message", %*{
    "client_addr": clientAddr,
    "dest_addr": destAddr,
    "message": message,
    "max_holding_seconds": maxHoldingSeconds,
    "no_reply": noReply
  })
  (resp.getOrDefault("result").getStr(), resp.getOrDefault("error").getStr())

proc closeNKNClient*(b: NknBridge, clientAddr: string): (string, string) =
  let resp = b.sendRequest("close_client", %*{"client_addr": clientAddr})
  (resp.getOrDefault("result").getStr(), resp.getOrDefault("error").getStr())

# --- Seed-centric API — the preferred path for claw's nmobile channel. ---
# The seed (32-byte Ed25519) IS the NKN identity. No password layer, no
# encrypted wallet file — the seed lives in `.env` alongside other secrets
# and the wallet-file indirection is skipped entirely.

proc generateSeed*(b: NknBridge): (string, string) =
  ## Fresh random seed for a brand-new NKN identity.
  let resp = b.sendRequest("generate_seed", newJObject())
  (resp.getOrDefault("result").getStr(), resp.getOrDefault("error").getStr())

proc extractSeed*(b: NknBridge, walletJson, password: string): (string, string) =
  ## Decrypt an existing encrypted wallet (e.g. exported from the nMobile
  ## app) once to recover its seed, so it can be persisted in `.env` and
  ## the wallet file discarded.
  let resp = b.sendRequest("extract_seed", %*{
    "wallet_json": walletJson,
    "password": password
  })
  (resp.getOrDefault("result").getStr(), resp.getOrDefault("error").getStr())

proc createClientFromSeed*(b: NknBridge, seedHex, identifier: string,
                           numSubClients: int = 4, originalClient: bool = false):
                           (string, string) =
  ## Open a sub-client on `<identifier>.<pubkey>`. Same seed can back
  ## many identifiers — the phone-line-plus-extension model.
  let resp = b.sendRequest("create_client_from_seed", %*{
    "seed_hex": seedHex,
    "identifier": identifier,
    "num_sub_clients": numSubClients,
    "original_client": originalClient
  })
  (resp.getOrDefault("result").getStr(), resp.getOrDefault("error").getStr())

proc getAddressFromSeed*(b: NknBridge, seedHex, identifier: string):
                        (string, string) =
  ## Compute the public `identifier.<pubkey>` address without opening a
  ## client. Used by `co update` to stamp graph entities with their
  ## full NKN address.
  let resp = b.sendRequest("get_address_from_seed", %*{
    "seed_hex": seedHex,
    "identifier": identifier
  })
  (resp.getOrDefault("result").getStr(), resp.getOrDefault("error").getStr())
