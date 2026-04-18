## Safe, minimally-invasive .env file editing.
##
## Reads KEY=VALUE lines; preserves order, comments, blank lines, and any
## pre-existing content that isn't the target key. On write, an existing
## entry is updated in-place; a missing entry is appended.

import std/[os, strutils]

proc readEnvValue*(envPath, key: string): string =
  ## Returns the value for KEY= in the .env file, or "" if missing.
  if not fileExists(envPath): return ""
  try:
    for line in lines(envPath):
      let l = line.strip()
      if l.len == 0 or l[0] == '#': continue
      let eq = l.find('=')
      if eq <= 0: continue
      let k = l[0 ..< eq].strip()
      if k == key:
        var v = l[eq + 1 .. ^1]
        # Strip surrounding quotes if present
        if v.len >= 2 and ((v[0] == '"' and v[^1] == '"') or
                           (v[0] == '\'' and v[^1] == '\'')):
          v = v[1 .. ^2]
        return v
  except: discard
  return ""

proc writeEnvValue*(envPath, key, value: string) =
  ## Update or append KEY=VALUE. Preserves all other lines exactly — only
  ## the matching key's value is rewritten. Creates the file (and parent dir)
  ## if missing.
  let parent = envPath.parentDir
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)

  # If file doesn't exist, create it with just this key
  if not fileExists(envPath):
    writeFile(envPath, key & "=" & value & "\n")
    return

  # Walk existing lines; rewrite matching key, preserve rest verbatim
  var out_lines: seq[string] = @[]
  var replaced = false
  for line in lines(envPath):
    let l = line.strip()
    if l.len == 0 or l[0] == '#':
      out_lines.add(line)
      continue
    let eq = l.find('=')
    if eq <= 0:
      out_lines.add(line)
      continue
    let k = l[0 ..< eq].strip()
    if k == key and not replaced:
      out_lines.add(key & "=" & value)
      replaced = true
    else:
      out_lines.add(line)

  if not replaced:
    out_lines.add(key & "=" & value)

  # Trailing newline convention
  var content = out_lines.join("\n")
  if not content.endsWith("\n"): content.add("\n")
  writeFile(envPath, content)
