import std/[unittest, strutils, options]
import ../src/nimclaw/[doctor, config]

suite "Doctor Diagnostics":
  test "DiagItem.ok creates ok item":
    let item = ok("test", "all good")
    check item.severity == Severity.ok
    check item.category == "test"
    check item.message == "all good"
    check item.icon() == "[ok]"

  test "DiagItem.warn creates warn item":
    let item = warn("test", "watch out")
    check item.severity == Severity.warn
    check item.category == "test"
    check item.message == "watch out"
    check item.icon() == "[warn]"

  test "DiagItem.err creates err item":
    let item = err("test", "broken")
    check item.severity == Severity.err
    check item.category == "test"
    check item.message == "broken"
    check item.icon() == "[ERR]"

  test "DiagItem.iconColored returns ANSI-colored strings":
    let okIcon = ok("t", "m").iconColored()
    check okIcon.contains("\x1b[32m")
    check okIcon.contains("[ok]")
    check okIcon.contains("\x1b[0m")

    let warnIcon = warn("t", "m").iconColored()
    check warnIcon.contains("\x1b[33m")
    check warnIcon.contains("[warn]")

    let errIcon = err("t", "m").iconColored()
    check errIcon.contains("\x1b[31m")
    check errIcon.contains("[ERR]")

  test "parseDfAvailableMb extracts correct column":
    const dfOutput = """
Filesystem   1048576-blocks   Used Available Capacity iused      ifree %iused  Mounted on
/dev/disk3s1         476839 230752    246086    49%  923010 9760081030    0%   /
"""
    let availMb = parseDfAvailableMb(dfOutput)
    check availMb.isSome
    check availMb.get == 246086'u64

  test "parseDfAvailableMb handles empty or invalid output":
    check parseDfAvailableMb("").isNone
  test "checkConfigSemantics catches temperature out of range":
    var items = newSeq[DiagItem]()
    var cfg = defaultConfig()
    cfg.default_temperature = 5.0
    checkConfigSemantics(cfg, items)
    
    var foundTempErr = false
    for item in items:
      if item.message.contains("temperature") and item.severity == Severity.err:
        foundTempErr = true
    check foundTempErr

  test "checkConfigSemantics accepts valid temperature":
    var items = newSeq[DiagItem]()
    var cfg = defaultConfig()
    cfg.default_temperature = 0.7
    checkConfigSemantics(cfg, items)
    
  test "checkEnvironment detects shell and home":
    var items = newSeq[DiagItem]()
    checkEnvironment(items)
    
    var foundShell = false
    var foundHome = false
    
    for item in items:
      if item.message.contains("shell") or item.message.contains("$SHELL"): foundShell = true
      if item.message.contains("home"): foundHome = true
      
    check foundShell
    check foundHome
