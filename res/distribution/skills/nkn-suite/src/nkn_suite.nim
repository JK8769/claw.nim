## nkn_suite.nim — vendor MCP server for NKN mainnet read-only ops.
##
## Exposes NKN's chain-inspection RPCs (balance, transaction lookup,
## current block height) as `mcp_nkn-suite_<op>` tools, registered via
## MCP stdio so the framework's generic registry-scan picks them up at
## gateway boot. The `payment` tool then dispatches `payment balance
## vendor=nkn-suite address=...` to these tools (mirrors the solar +
## lark-suite vendor patterns).
##
## Each tool is a thin wrapper around an `nkn-cli` subprocess call.
## The binary lookup falls back through (1) findExe (PATH), (2) the
## framework's bundled `channels/bin/nkn-cli`.
##
## Read-only by design (Phase 1). Transfer / write ops deferred until
## the payment approval-flow design lands (Phase 4-6).

import std/[json, os, osproc, streams, strutils, options, times]
import mcp

const ServerName    = "nkn-suite"
const ServerVersion = "0.1.0"

# ── nkn-cli locator ──────────────────────────────────────────────────

proc findNknCli(): string =
  ## (1) PATH; (2) common framework-bundled location.
  let onPath = findExe("nkn-cli")
  if onPath.len > 0: return onPath
  let candidates = [
    getEnv("HOME") / "Work/Agents/nimclaw/channels/bin/nkn-cli",
    "/usr/local/bin/nkn-cli",
    "/opt/nkn-cli/nkn-cli"
  ]
  for c in candidates:
    if fileExists(c): return c
  ""

# ── nkn-cli invocation (NDJSON request/response over stdio) ──────────

proc callNknCli(method_name: string, params: JsonNode,
                timeout = 15): JsonNode =
  ## One-shot synchronous call: spawn nkn-cli, send a single NDJSON
  ## request line, read the response line, kill the subprocess. The
  ## subprocess is designed for long-lived clients but works fine
  ## one-shot for read-only ops where we don't need persistent state.
  let bin = findNknCli()
  if bin.len == 0:
    return %*{"error": "nkn-cli binary not found (PATH + common locations)"}

  let req = %*{
    "id": "p1",
    "method": method_name,
    "params": params
  }

  try:
    let p = startProcess(bin, args = @[], options = {poUsePath, poStdErrToStdOut})
    p.inputStream.writeLine($req)
    p.inputStream.flush()
    let started = now()
    var line = ""
    while p.running:
      if (now() - started) > initDuration(seconds = timeout):
        p.terminate()
        discard p.waitForExit(2000)
        p.close()
        return %*{"error": "nkn-cli timed out after " & $timeout & "s"}
      if p.outputStream.atEnd: sleep(40); continue
      line = p.outputStream.readLine()
      if line.len > 0: break
    p.terminate()
    discard p.waitForExit(2000)
    p.close()
    if line.len == 0:
      return %*{"error": "no response from nkn-cli"}
    try:
      return parseJson(line)
    except CatchableError as e:
      return %*{"error": "invalid JSON from nkn-cli: " & e.msg,
                "raw": line}
  except CatchableError as e:
    return %*{"error": "nkn-cli exec failed: " & e.msg}

# ── MCP server + tools ───────────────────────────────────────────────

let server = mcpServer(ServerName, ServerVersion):

  mcpTool:
    proc get_balance(address: string): JsonNode =
      ## NKN balance for an address. Returns {"balance": "<amount>"} on
      ## success, {"error": "..."} on failure (network unreachable,
      ## invalid address, etc.).
      ## Reached via: payment balance vendor=nkn-suite address=…
      if address.len == 0:
        return %*{"error": "address is required"}
      let resp = callNknCli("get_balance", %*{"address": address})
      if resp.hasKey("error") and resp["error"].getStr().len > 0:
        return %*{"error": resp["error"].getStr()}
      if resp.hasKey("result"):
        return %*{"balance": resp["result"].getStr(), "address": address}
      return %*{"error": "unexpected response shape from nkn-cli",
                "raw": resp}

  mcpTool:
    proc get_height(): JsonNode =
      ## Current NKN mainnet block height. Useful as a chain-reachability
      ## probe before issuing other queries.
      ## Reached via: payment status vendor=nkn-suite (no tx_hash)
      let resp = callNknCli("get_height", newJObject())
      if resp.hasKey("error") and resp["error"].getStr().len > 0:
        return %*{"error": resp["error"].getStr()}
      if resp.hasKey("result"):
        try:
          let h = parseInt(resp["result"].getStr())
          return %*{"height": h}
        except CatchableError:
          return %*{"height_str": resp["result"].getStr()}
      return %*{"error": "unexpected response shape from nkn-cli",
                "raw": resp}

  mcpTool:
    proc get_transaction(hash: string): JsonNode =
      ## NKN transaction lookup by hash. Currently returns a friendly
      ## error pointing at the seed-node REST endpoint — nkn-sdk-go's
      ## public API doesn't expose lookup-by-hash yet. Will be wired
      ## through cleanly when the SDK gains it (or when nkn-cli adds
      ## a direct REST-call passthrough).
      ## Reached via: payment status vendor=nkn-suite tx_hash=…
      if hash.len == 0:
        return %*{"error": "hash is required"}
      let resp = callNknCli("get_transaction", %*{"hash": hash})
      # nkn-cli currently returns an error explaining the REST fallback —
      # surface it as-is so callers can either retry on a different
      # tool or hit the REST endpoint themselves.
      if resp.hasKey("error"):
        return %*{"error": resp["error"].getStr(), "hash": hash}
      return resp

when isMainModule:
  let transport = newStdioTransport()
  transport.serve(server)
