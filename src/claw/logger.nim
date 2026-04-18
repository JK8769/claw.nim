import std/[times, strutils, json, syncio, tables, os]
import jsony

type
  LogLevel* = enum
    DEBUG, INFO, WARN, ERROR, FATAL

const
  logLevelNames: Table[LogLevel, string] = {
    DEBUG: "DEBUG",
    INFO:  "INFO",
    WARN:  "WARN",
    ERROR: "ERROR",
    FATAL: "FATAL"
  }.toTable
  maxLogSize = 5 * 1024 * 1024  # 5MB

var
  currentLevel = INFO
  logFile: File
  logFilePath {.global.}: array[1024, char]
  logFilePathLen: int
  logFileSize: int64
  fileLoggingEnabled = false
  stdioMode* = false  ## When true, console output goes to stderr (stdout reserved for JSONL)

proc getLogPath(): string =
  result = newString(logFilePathLen)
  for i in 0..<logFilePathLen:
    result[i] = logFilePath[i]

type
  LogEntry* = object
    level*: string
    timestamp*: string
    component*: string
    message*: string
    fields*: Table[string, string]
    caller*: string

proc setLevel*(level: LogLevel) =
  currentLevel = level

proc getLevel*(): LogLevel =
  currentLevel

proc enableFileLogging*(filePath: string): bool =
  try:
    if fileLoggingEnabled:
      logFile.close()
    logFile = open(filePath, fmAppend)
    logFilePathLen = min(filePath.len, logFilePath.len)
    for i in 0..<logFilePathLen:
      logFilePath[i] = filePath[i]
    logFileSize = getFileSize(filePath)
    fileLoggingEnabled = true
    if stdioMode: stderr.writeLine "File logging enabled: " & filePath
    else: echo "File logging enabled: ", filePath
    return true
  except:
    if stdioMode: stderr.writeLine "Failed to open log file: " & filePath
    else: echo "Failed to open log file: ", filePath
    return false

proc rotateLogFile() {.gcsafe.} =
  ## Rotate when log exceeds maxLogSize. Keeps one backup (.1).
  let path = getLogPath()
  try:
    logFile.close()
    let backup = path & ".1"
    if fileExists(backup): removeFile(backup)
    moveFile(path, backup)
    logFile = open(path, fmAppend)
    logFileSize = 0
  except:
    try: logFile = open(path, fmAppend)
    except: fileLoggingEnabled = false

proc disableFileLogging*() =
  if fileLoggingEnabled:
    logFile.close()
    fileLoggingEnabled = false
    echo "File logging disabled"

proc formatFields(fields: Table[string, string]): string =
  if fields.len == 0: return ""
  var parts: seq[string] = @[]
  for k, v in fields:
    parts.add(k & "=" & v)
  return " {" & parts.join(", ") & "}"

proc logMessage(level: LogLevel, component: string, message: string, fields: Table[string, string] = initTable[string, string]()) =
  if level < currentLevel:
    return

  let now = now().utc
  let timestamp = now.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

  var entry = LogEntry(
    level: logLevelNames[level],
    timestamp: timestamp,
    component: component,
    message: message,
    fields: fields
  )

  # In Nim, getting caller info is a bit different, we can use getStackTrace() or similar if needed
  # but for now let's keep it simple.

  if fileLoggingEnabled:
    try:
      let line = entry.toJson() & "\n"
      logFile.writeLine(line)
      logFile.flushFile()
      logFileSize += line.len + 1
      if logFileSize >= maxLogSize:
        rotateLogFile()
    except:
      discard

  let componentStr = if component != "": " " & component & ":" else: ""
  let fieldStr = formatFields(fields)

  let consoleLine = "[$1] [$2]$3 $4$5".format(timestamp, logLevelNames[level], componentStr, message, fieldStr)
  if stdioMode:
    stderr.writeLine consoleLine
  else:
    echo consoleLine

  if level == FATAL:
    quit(1)

proc debug*(message: string) = logMessage(DEBUG, "", message)
proc debugC*(component, message: string) = logMessage(DEBUG, component, message)
proc debugF*(message: string, fields: Table[string, string]) = logMessage(DEBUG, "", message, fields)
proc debugCF*(component, message: string, fields: Table[string, string]) = logMessage(DEBUG, component, message, fields)

proc info*(message: string) = logMessage(INFO, "", message)
proc infoC*(component, message: string) = logMessage(INFO, component, message)
proc infoF*(message: string, fields: Table[string, string]) = logMessage(INFO, "", message, fields)
proc infoCF*(component, message: string, fields: Table[string, string]) = logMessage(INFO, component, message, fields)

proc warn*(message: string) = logMessage(WARN, "", message)
proc warnC*(component, message: string) = logMessage(WARN, component, message)
proc warnF*(message: string, fields: Table[string, string]) = logMessage(WARN, "", message, fields)
proc warnCF*(component, message: string, fields: Table[string, string]) = logMessage(WARN, component, message, fields)

proc error*(message: string) = logMessage(ERROR, "", message)
proc errorC*(component, message: string) = logMessage(ERROR, component, message)
proc errorF*(message: string, fields: Table[string, string]) = logMessage(ERROR, "", message, fields)
proc errorCF*(component, message: string, fields: Table[string, string]) = logMessage(ERROR, component, message, fields)

proc fatal*(message: string) = logMessage(FATAL, "", message)
proc fatalC*(component, message: string) = logMessage(FATAL, component, message)
proc fatalF*(message: string, fields: Table[string, string]) = logMessage(FATAL, "", message, fields)
proc fatalCF*(component, message: string, fields: Table[string, string]) = logMessage(FATAL, component, message, fields)
