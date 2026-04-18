import std/[asyncdispatch, json, tables, times]
import types

type
  ClockTool* = ref object of Tool

proc newClockTool*(): ClockTool =
  ClockTool()

method name*(t: ClockTool): string = "clock"
method description*(t: ClockTool): string = "Returns the current system time with timezone. Use this tool whenever you need to know or verify the current time, especially before telling the user what time it is or calculating reminder times."
method parameters*(t: ClockTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{},
    "required": %*[]
  }.toTable

method execute*(t: ClockTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let now = now()
  let iso = now.format("yyyy-MM-dd'T'HH:mm:sszzz")
  let human = now.format("yyyy-MM-dd HH:mm:ss (dddd) zzz")
  let epoch = getTime().toUnix()
  return "Current time: " & human & "\nISO 8601: " & iso & "\nUnix epoch: " & $epoch
