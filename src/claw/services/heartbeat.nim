import std/[os, times, strutils, locks, asyncdispatch]
import ../agent/context

type
  HeartbeatService* = ref object
    workspace*: string
    onHeartbeat*: proc (prompt: string): Future[void] {.async.}
    interval*: Duration
    enabled*: bool
    lock*: Lock
    running*: bool

proc newHeartbeatService*(workspace: string, onHeartbeat: proc (prompt: string): Future[void] {.async.}, intervalS: int, enabled: bool): HeartbeatService =
  var hs = HeartbeatService(
    workspace: workspace,
    onHeartbeat: onHeartbeat,
    interval: initDuration(seconds = intervalS),
    enabled: enabled,
    running: false
  )
  initLock(hs.lock)
  return hs

proc buildPrompt(hs: HeartbeatService): string =
  let notesFile = hs.workspace / "memory" / "HEARTBEAT.md"
  var notes = ""
  if fileExists(notesFile):
    notes = readFile(notesFile)

  # Check for unread mail
  var mailList = ""
  let mailFiles = scanMailbox(hs.workspace)
  if mailFiles.len > 0:
    mailList = "\n**MAILBOX ALERT**: You have new/unread files in your `mail/` directory: " & mailFiles.join(", ") & ". Please review them if they contain important instructions or coordination.\n"

  let now = now().format("yyyy-MM-dd HH:mm")

  return """# Heartbeat Check

Current time: $1
$2
Check if there are any tasks I should be aware of or actions I should take.
Review the memory file for any important updates or changes.
Be proactive in identifying potential issues or improvements.

**CRITICAL**: Do NOT use any communication tools (like `send_message`) to notify the user of this routine check unless a high-priority action is required. Keep your response internal.

$3
""".format(now, mailList, notes)

proc log(hs: HeartbeatService, message: string) =
  let logFile = hs.workspace / "memory" / "heartbeat.log"
  let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
  try:
    let f = open(logFile, fmAppend)
    f.writeLine("[$1] $2".format(timestamp, message))
    f.close()
  except:
    discard

proc runLoop(hs: HeartbeatService) {.async.} =
  while hs.running:
    if not hs.enabled: 
      await sleepAsync(1000)
      continue

    let prompt = hs.buildPrompt()
    if hs.onHeartbeat != nil:
      try:
        await hs.onHeartbeat(prompt)
      except Exception as e:
        hs.log("Heartbeat error: " & e.msg)
    
    await sleepAsync(hs.interval.inMilliseconds.int)

proc start*(hs: HeartbeatService) {.async.} =
  if hs.running: return
  if not hs.enabled: return
  hs.running = true
  discard runLoop(hs)

proc stop*(hs: HeartbeatService) =
  hs.running = false
