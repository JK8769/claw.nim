## forge — author/update CLI-tool scripts at runtime.
##
## Sister to tools/mcp/forge.nim but for the lighter CLI surface:
##   - No compilation step.
##   - Script can be any language with a `#!` interpreter line
##     (bash, python, node, ruby, ...). On macOS/Linux we chmod +x.
##   - A `tool.json` spec describes the schema so the registry can
##     re-discover the tool on next gateway start.
##
## Contract for the script the agent writes:
##   - Reads a JSON object on stdin (the tool args)
##   - Writes a single string on stdout (the tool result)
##   - Non-zero exit code → CliTool.execute returns an Error message
##   - See cli_tool.nim for the runtime details.

import std/[json, tables, os, strutils]
import cli_tool
import ../../logger

const
  AllowedShebangs* = ["#!/bin/sh", "#!/bin/bash", "#!/usr/bin/env bash",
                     "#!/usr/bin/env sh",
                     "#!/usr/bin/env python", "#!/usr/bin/env python3",
                     "#!/usr/bin/env node",
                     "#!/usr/bin/env ruby", "#!/usr/bin/env perl"]
    ## Whitelist for the script's first line. Prevents the agent from
    ## smuggling in unusual interpreters (or no shebang at all, which
    ## would default to /bin/sh on most systems but break on others).
    ## Anchored to known interpreters that ship on every Mac/Linux dev
    ## box; extend as new languages become necessary.

proc validateName*(name: string): string =
  ## Kebab-case, ASCII, no path separators. Returns "" if valid, error
  ## message otherwise.
  if name.len == 0: return "name must not be empty"
  if name.len > 60: return "name must be <= 60 chars (got " & $name.len & ")"
  if "/" in name or ".." in name or name[0] == '.':
    return "name must not contain slashes or '..' (got '" & name & "')"
  for c in name:
    if c notin {'a'..'z', '0'..'9', '-', '_'}:
      return "name must be kebab/snake-case (lowercase letters, digits, '-' or '_'). Got: '" & name & "'"
  ""

proc validateShebang*(script: string): string =
  ## Returns "" if the script has an allowed shebang, error otherwise.
  let firstLine = script.splitLines()[0].strip()
  for allowed in AllowedShebangs:
    if firstLine.startsWith(allowed): return ""
  "script must start with one of: " & AllowedShebangs.join(", ") &
    " (got first line: '" & firstLine & "')"

proc validateParametersSchema*(params: JsonNode): string =
  ## A minimal JSON-schema sanity check. The LLM provider will reject
  ## obviously malformed schemas at tool-list time anyway, but this
  ## catches structural mistakes before the tool ever ships.
  if params.kind != JObject: return "parameters must be a JSON object"
  let typeField = params{"type"}
  if typeField.kind != JString or typeField.getStr() != "object":
    return "parameters.type must be \"object\""
  let props = params{"properties"}
  if props.isNil or props.kind != JObject:
    return "parameters.properties must be an object"
  ""

proc writeCliTool*(officeDir, name, description, script: string,
                    parameters: JsonNode, timeoutMs: int,
                    overwrite: bool): tuple[ok: bool, msg: string,
                                            tool: CliTool] =
  ## Validate, write tool.json + run, chmod +x, return a CliTool ready
  ## to register. On error, ok=false and msg explains.
  let nameErr = validateName(name)
  if nameErr.len > 0:
    return (false, "Error: " & nameErr, nil)
  let shebangErr = validateShebang(script)
  if shebangErr.len > 0:
    return (false, "Error: " & shebangErr, nil)
  let schemaErr = validateParametersSchema(parameters)
  if schemaErr.len > 0:
    return (false, "Error: " & schemaErr, nil)
  if officeDir.len == 0:
    return (false, "Error: tool not bound to an office workspace", nil)

  let toolDir = cliToolDir(officeDir, name)
  let specPath = toolDir / "tool.json"
  let scriptPath = toolDir / "run"

  if fileExists(specPath) and not overwrite:
    return (false, "Error: CLI tool '" & name & "' already exists at " &
            toolDir & ". Use `tools method=update name=" & name &
            "` to rewrite, or pick a different name.", nil)

  try:
    if not dirExists(toolDir): createDir(toolDir)
    var spec = newJObject()
    spec["name"] = %name
    spec["description"] = %description
    spec["parameters"] = parameters
    spec["timeout_ms"] = %timeoutMs
    writeFile(specPath, spec.pretty(2))
    writeFile(scriptPath, script)
    when defined(posix):
      # 0o755 — owner rwx, group/other rx.
      setFilePermissions(scriptPath, {fpUserRead, fpUserWrite, fpUserExec,
                                       fpGroupRead, fpGroupExec,
                                       fpOthersRead, fpOthersExec})
  except CatchableError as e:
    return (false, "Error: failed to write CLI tool artifacts: " & e.msg, nil)

  let tool = fromDir(toolDir)
  infoCF("cli_forge", "CLI tool written",
         {"name": name, "dir": toolDir, "bytes": $script.len,
          "overwrite": $overwrite}.toTable)
  (true, "ok", tool)

proc removeCliTool*(officeDir, name: string,
                     keepSource: bool = true): tuple[ok: bool, msg: string] =
  ## Delete an authored CLI tool's spec/script. By default keeps the
  ## directory so the agent can recover (matches purge_mcp_tool's
  ## delete_source=false default).
  let nameErr = validateName(name)
  if nameErr.len > 0:
    return (false, "Error: " & nameErr)
  let toolDir = cliToolDir(officeDir, name)
  if not dirExists(toolDir):
    return (false, "Error: no CLI tool named '" & name & "' at " & toolDir)
  try:
    if keepSource:
      let specPath = toolDir / "tool.json"
      let scriptPath = toolDir / "run"
      if fileExists(specPath): removeFile(specPath)
      if fileExists(scriptPath): removeFile(scriptPath)
      return (true, "Removed CLI tool '" & name & "' (spec/script deleted; " &
              "parent dir retained at " & toolDir & ")")
    else:
      removeDir(toolDir)
      return (true, "Removed CLI tool '" & name & "' and deleted " & toolDir)
  except CatchableError as e:
    return (false, "Error: failed to remove CLI tool: " & e.msg)
