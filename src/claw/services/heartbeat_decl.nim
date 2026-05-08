## Heartbeat duty declarations parsed from `competencies/<name>/COMPETENCY.json`.
##
## Each competency may declare a `heartbeat[]` block — an ordered list
## of duties the agent performs at every heartbeat tick. Each duty has
## a `read` step (optional, gathers data) and an `act` step (optional,
## suggests or auto-fires an action). The framework's heartbeat_tick
## dispatcher composes duties from all the agent's loaded competencies
## and runs the gather→auto-act→prompt phases.
##
## See the heartbeat-redesign discussion for the architecture rationale
## (in&out paired per duty, hint vs auto modes, why notes.org / mail /
## todo.jsonl stay separate framework-default sources).
##
## This module is read-only: parses JSON, returns typed structs. The
## actual dispatch (tool invocation, when evaluation, auto-fire,
## prompt assembly) lives in gateway.nim's cronHandlerLogic.

import std/[os, json, strutils, tables]
import ../logger

type
  HeartbeatRead* = object
    tool*: string                     ## tool name in registry; empty = no read
    args*: JsonNode                   ## JObject; nil ok
    sectionTitle*: string             ## prompt section header for this read's result

  HeartbeatActMode* = enum
    hamNone        ## no act on this duty (read-only / informational)
    hamHint        ## include text in prompt; LLM decides
    hamAuto        ## fire tool deterministically without LLM

  HeartbeatAct* = object
    mode*: HeartbeatActMode
    `when`*: string                   ## "always" | "result_not_empty" (default
                                      ## "result_not_empty" when read.tool set,
                                      ## "always" when read.tool empty)
    hint*: string                     ## text for hamHint mode
    autoTool*: string                 ## tool name for hamAuto mode
    autoArgs*: JsonNode               ## args for hamAuto; supports `{result.X}` substitution

  HeartbeatDuty* = object
    sourceCompetency*: string         ## which competency declared this duty
    id*: string                       ## stable id within the competency
    title*: string                    ## human label for prompt section
    read*: HeartbeatRead              ## may have empty tool (act-only duty)
    act*: HeartbeatAct                ## may have mode=hamNone (read-only duty)

proc parseRead(j: JsonNode): HeartbeatRead =
  if j == nil or j.kind != JObject: return
  result.tool = j{"tool"}.getStr("")
  result.sectionTitle = j{"section_title"}.getStr("")
  if j.hasKey("args") and j["args"].kind == JObject:
    result.args = j["args"]

proc parseAct(j: JsonNode): HeartbeatAct =
  if j == nil or j.kind != JObject:
    result.mode = hamNone
    return
  result.`when` = j{"when"}.getStr("")
  if j.hasKey("auto") and j["auto"].kind == JObject:
    result.mode = hamAuto
    result.autoTool = j["auto"]{"tool"}.getStr("")
    if j["auto"].hasKey("args") and j["auto"]["args"].kind == JObject:
      result.autoArgs = j["auto"]["args"]
  elif j{"hint"}.getStr("").len > 0:
    result.mode = hamHint
    result.hint = j["hint"].getStr()
  else:
    result.mode = hamNone

proc parseHeartbeatDuties*(competencyDir, competencyName: string):
                            seq[HeartbeatDuty] =
  ## Read `<competencyDir>/COMPETENCY.json`, parse the `heartbeat[]`
  ## block. Returns empty seq when the file's missing, malformed, or
  ## has no heartbeat block — never raises. Bad entries are logged
  ## and skipped individually so one bad duty doesn't poison the
  ## whole competency.
  let path = competencyDir / "COMPETENCY.json"
  if not fileExists(path): return
  var raw: JsonNode
  try:
    raw = parseFile(path)
  except CatchableError as e:
    warnCF("heartbeat_decl", "Failed to parse COMPETENCY.json",
           {"path": path, "error": e.msg}.toTable)
    return
  if raw.kind != JObject: return
  if not raw.hasKey("heartbeat"): return
  let arr = raw["heartbeat"]
  if arr.kind != JArray: return
  for entry in arr:
    if entry.kind != JObject: continue
    let id = entry{"id"}.getStr("")
    if id.len == 0:
      warnCF("heartbeat_decl", "Skipping duty without id",
             {"competency": competencyName}.toTable)
      continue
    var d = HeartbeatDuty(
      sourceCompetency: competencyName,
      id: id,
      title: entry{"title"}.getStr(id),
    )
    if entry.hasKey("read"):
      d.read = parseRead(entry["read"])
    if entry.hasKey("act"):
      d.act = parseAct(entry["act"])
    # Default `when` resolution: a read-only duty defaults to "always"
    # (always show its result); a duty with both read+act defaults to
    # "result_not_empty" (don't bother the agent if there's nothing
    # to act on); an act-only duty defaults to "always".
    if d.act.`when`.len == 0:
      d.act.`when` =
        if d.read.tool.len > 0 and d.act.mode != hamNone: "result_not_empty"
        else: "always"
    if d.read.tool.len == 0 and d.act.mode == hamNone:
      warnCF("heartbeat_decl", "Skipping no-op duty (no read, no act)",
             {"competency": competencyName, "id": id}.toTable)
      continue
    result.add(d)

proc dutiesForAgent*(competenciesRoot: string,
                      competencyNames: seq[string]): seq[HeartbeatDuty] =
  ## Aggregate duties from every named competency. Order preserved:
  ## competencies in the agent's `practices` order, duties in their
  ## declaration order. Stable for prompt-section ordering.
  for name in competencyNames:
    let dir = competenciesRoot / name
    if not dirExists(dir): continue
    result.add(parseHeartbeatDuties(dir, name))
