## lark-suite.nim — vendor MCP server for Lark Suite productivity APIs.
##
## Exposes Lark Suite's request/reply features (docs, sheets, calendar,
## tasks, drive, wiki, contacts) as `mcp_lark-suite_<op>` tools,
## registered via MCP stdio so the framework's generic registry-scan
## picks them up at gateway boot. The unified `channel` tool then
## dispatches `channel docs vendor=lark-suite op=…` to these tools
## (mirrors the solar-adapter → mcp_<vendor>_<op> pattern).
##
## Each tool is a thin wrapper around a `lark-cli` subprocess call. The
## binary lookup falls back through (1) findExe (PATH), (2) the
## framework's bundled `channels/bin/lark-cli` if reachable. Config dir
## (auth) is the first `lark-cli-<APP_ID>/` directory under
## `<NIMCLAW_DIR>/channels/feishu/` — shared with the in-binary
## messaging channel (channels/feishu.nim) so both halves of the
## Lark/Feishu integration use one set of credentials per app.

import std/[json, os, osproc, streams, strtabs, strutils, options, times]
import mcp

const ServerName    = "lark-suite"
const ServerVersion = "0.1.0"

# ── lark-cli locator ─────────────────────────────────────────────────

proc findLarkCli(): string =
  ## (1) PATH; (2) common framework-bundled location.
  let onPath = findExe("lark-cli")
  if onPath.len > 0: return onPath
  # Walk a few likely framework locations.
  let candidates = [
    getEnv("HOME") / "Work/Agents/nimclaw/channels/bin/lark-cli",
    "/usr/local/bin/lark-cli",
    "/opt/lark-cli/lark-cli"
  ]
  for c in candidates:
    if fileExists(c): return c
  ""

proc nimclawDir(): string =
  let env = getEnv("NIMCLAW_DIR")
  if env.len > 0: return env
  getEnv("HOME") / ".nimclaw"

proc findConfigDir(): string =
  ## Use the first lark-cli-<APP_ID>/ directory found under
  ## <NIMCLAW_DIR>/channels/feishu/. Multi-app deployments may want
  ## to pin to a specific app via env override; out of MVP scope.
  let envOverride = getEnv("FEISHU_CONFIG_DIR")
  if envOverride.len > 0 and dirExists(envOverride): return envOverride
  let base = nimclawDir() / "channels" / "feishu"
  if not dirExists(base): return ""
  for kind, path in walkDir(base):
    if kind == pcDir and path.extractFilename.startsWith("lark-cli-"):
      if fileExists(path / "config.json"):
        return path
  ""

# ── lark-cli invocation ──────────────────────────────────────────────

proc runLarkCli(args: seq[string], timeout = 30): tuple[code: int, output: string] =
  ## Synchronous lark-cli call. Returns (exit code, combined stdout+stderr).
  let bin = findLarkCli()
  if bin.len == 0:
    return (-1, "lark-cli binary not found (checked PATH + common locations)")
  let configDir = findConfigDir()
  if configDir.len == 0:
    return (-1, "no configured Feishu/Lark app found at " & nimclawDir() &
                "/channels/feishu/lark-cli-*/ — run `claw channel add " &
                "feishu <APP_ID> <APP_SECRET>` first")
  let env = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): env[k] = v
  env["LARKSUITE_CLI_CONFIG_DIR"] = configDir
  try:
    let p = startProcess(bin, args = args, env = env,
                         options = {poUsePath, poStdErrToStdOut})
    let started = now()
    var output = ""
    while p.running:
      if (now() - started) > initDuration(seconds = timeout):
        p.terminate()
        discard p.waitForExit(3000)
        p.close()
        return (-1, "lark-cli timed out after " & $timeout & "s")
      let chunk = p.outputStream.readStr(4096)
      if chunk.len > 0: output.add(chunk)
      sleep(50)
    output.add(p.outputStream.readAll())
    let code = p.peekExitCode()
    p.close()
    return (code, output.strip())
  except CatchableError as e:
    return (-1, "lark-cli exec failed: " & e.msg)

# ── helpers for parsing lark-cli output ──────────────────────────────

proc extractDocUrl(output: string): string =
  ## lark-cli docs +create prints the doc URL on a line containing
  ## the URL. Find it heuristically.
  for line in output.splitLines:
    let t = line.strip()
    if t.startsWith("https://") and ("/docx/" in t or "/docs/" in t or
                                     "/doc/" in t):
      return t
    # Some versions print "URL: <url>" — strip the prefix
    if t.startsWith("URL:") or t.startsWith("url:"):
      let rest = t[4..^1].strip()
      if rest.startsWith("https://"): return rest
  ""

# ── MCP server + tools ───────────────────────────────────────────────

let server = mcpServer(ServerName, ServerVersion):

  mcpTool:
    proc docs_create(title: string, markdown: string): JsonNode =
      ## Create a new Lark Doc with the given title and markdown body.
      ## Returns {"doc_url": "..."} on success or {"error": "..."} on
      ## failure. The agent reaches this via:
      ##   channel docs vendor=lark-suite op=create args={title:…, markdown:…}
      if title.len == 0:
        return %*{"error": "title is required"}
      if markdown.len == 0:
        return %*{"error": "markdown body is required"}
      # `--as bot` posts under the bot's own identity (no shared user
      # account needed). `--markdown` flag carries the body inline.
      let (code, output) = runLarkCli(@[
        "docs", "+create",
        "--as", "bot",
        "--title", title,
        "--markdown", markdown
      ], timeout = 60)
      if code != 0:
        return %*{"error": "lark-cli failed",
                  "exit_code": code,
                  "output": output}
      let url = extractDocUrl(output)
      if url.len == 0:
        return %*{"error": "doc URL not found in lark-cli output",
                  "output": output}
      return %*{"doc_url": url}

  mcpTool:
    proc docs_fetch(url: string): JsonNode =
      ## Fetch the content of an existing Lark Doc by URL. Returns
      ## {"content": "..."} on success or {"error": "..."} on failure.
      ## The agent reaches this via:
      ##   channel docs vendor=lark-suite op=fetch args={url:…}
      if url.len == 0:
        return %*{"error": "url is required"}
      let (code, output) = runLarkCli(@[
        "docs", "+fetch",
        "--doc", url
      ], timeout = 30)
      if code != 0:
        return %*{"error": "lark-cli failed",
                  "exit_code": code,
                  "output": output}
      return %*{"content": output, "url": url}

when isMainModule:
  let transport = newStdioTransport()
  transport.serve(server)
