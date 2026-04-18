import std/json
import registry {.all.}  # fnv32a

type
  LoopResult* = enum
    lrOk    ## No issue, proceed normally
    lrWarn  ## Repeat threshold hit, inject a nudge
    lrStop  ## Hard stop, break the loop

  LoopDetector* = object
    lastName: string
    lastArgsHash: uint32
    streak*: int
    warnAt: int
    stopAt: int

const
  DefaultWarnAt* = 3
  DefaultStopAt* = 5

proc newLoopDetector*(warnAt: int = DefaultWarnAt, stopAt: int = DefaultStopAt): LoopDetector =
  LoopDetector(warnAt: warnAt, stopAt: stopAt)

proc record*(d: var LoopDetector, toolName: string, args: JsonNode): LoopResult =
  let argsHash = fnv32a($args)
  if toolName == d.lastName and argsHash == d.lastArgsHash:
    d.streak += 1
  else:
    d.lastName = toolName
    d.lastArgsHash = argsHash
    d.streak = 1

  if d.streak >= d.stopAt:
    return lrStop
  elif d.streak >= d.warnAt:
    return lrWarn
  else:
    return lrOk

proc message*(d: LoopDetector): string =
  if d.streak >= d.stopAt:
    "STOP: You have called `" & d.lastName & "` with identical arguments " &
      $d.streak & " times. This is a loop. Try a completely different approach or explain what is blocking you."
  elif d.streak >= d.warnAt:
    "Warning: You have called `" & d.lastName & "` with identical arguments " &
      $d.streak & " times in a row. Try a different approach or different arguments."
  else:
    ""
