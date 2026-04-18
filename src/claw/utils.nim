import std/[unicode, terminal]

const
  ESC* = '\x1B'
  CSI* = '['      # (0x5B)
  ENTER* = '\r'   # (0x0D)
  NL* = '\l'      # (0x0A) - Newline/Linefeed
  TAB* = '\t'     # (0x09)
  BS* = '\b'      # (0x08) - Backspace/Ctrl+H
  DEL* = '\x7F'   # (0x7F) - Delete/Backspace (macOS)
  CTRL_C* = '\x03'
  CTRL_H* = '\x08'
  CTRL_S* = '\x13'
  CTRL_Q* = '\x11'
  CTRL_R* = '\x12'
  CTRL_V* = '\x16'

proc selectInput*(title: string, options: seq[string], defaultVal = ""): string =
  ## Displays a list of options and a hybrid input field.
  ## Users can type manually or use Up/Down arrows to cycle through options.
  if options.len == 0: return stdin.readLine().strip()

  # Fallback for non-interactive environments (AI/Automation)
  if not isatty(stdin):
    if title != "": echo title
    for opt in options: echo " - ", opt
    stdout.write ": "
    stdout.flushFile()
    return stdin.readLine().strip()

  var buffer = defaultVal
  var selectedIdx = -1 # -1 means manual typing, >= 0 means cycled from arrows

  # Display the options list once
  if title != "": echo title
  for opt in options:
    echo " - ", opt
  
  stdout.write ": "
  stdout.flushFile()
  
  hideCursor()
  try:
    while true:
      # Clear from cursor to end of line and write buffer
      stdout.write("\r: \e[K", buffer)
      stdout.flushFile()

      let key = getch()
      case key:
      of ESC: # Escape sequence for arrows
        let next1 = getch()
        if next1 == CSI:
          let next2 = getch()
          if next2 == 'A': # Up arrow
            if selectedIdx == -1: selectedIdx = options.len - 1
            else: selectedIdx = (selectedIdx - 1 + options.len) mod options.len
            buffer = options[selectedIdx]
          elif next2 == 'B': # Down arrow
            if selectedIdx == -1: selectedIdx = 0
            else: selectedIdx = (selectedIdx + 1) mod options.len
            buffer = options[selectedIdx]
      of ENTER, NL: # Enter
        stdout.write("\n")
        stdout.flushFile()
        break
      of DEL, BS: # Backspace
        selectedIdx = -1 # Revert to manual if user edits
        if buffer.len > 0:
          buffer.setLen(buffer.len - 1)
      of CTRL_C: # Ctrl+C
        showCursor()
        quit(1)
      else:
        # Printable character
        if key.ord >= 32 and key.ord <= 126:
          selectedIdx = -1 # Revert to manual if user types
          buffer.add(key)

    result = buffer.strip()
  finally:
    showCursor()
    stdout.flushFile()

proc readMaskedInput*(prompt: string): string =
  ## Reads input from stdin while masking characters with '*'.
  ## Supports backspace and falls back to readLine if not a TTY.
  if prompt != "":
    stdout.write prompt
    stdout.flushFile()

  if not isatty(stdin):
    return stdin.readLine().strip()

  var buffer = ""
  while true:
    let key = getch()
    case key:
    of ESC: # Handle escape sequences (like Delete key)
      let next1 = getch()
      if next1 == CSI:
        let next2 = getch()
        if next2 == '3': # Part of ESC[3~ (Forward Delete)
          let next3 = getch()
          if next3 == '~':
            if buffer.len > 0:
              buffer.setLen(buffer.len - 1)
              stdout.write("\r" & prompt & "\e[K")
              for _ in 1..buffer.len: stdout.write("*")
              stdout.flushFile()
    of ENTER, NL: # Enter
      stdout.write("\n")
      stdout.flushFile()
      break
    of DEL, BS: # Backspace/Delete common on macOS/Unix
      if buffer.len > 0:
        buffer.setLen(buffer.len - 1)
        # Redraw strategy: return to start of line, clear, redraw prompt and mask
        stdout.write("\r" & prompt & "\e[K")
        for _ in 1..buffer.len: stdout.write("*")
        stdout.flushFile()
    of CTRL_C: # Ctrl+C
      quit(1)
    else:
      # Printable range
      if key.ord >= 32 and key.ord <= 126:
        buffer.add(key)
        stdout.write("*")
        stdout.flushFile()
  
  result = buffer

proc truncate*(s: string, maxLen: int): string =
  ## Truncates a string to a maximum length with Unicode support.
  ## If the string is longer than maxLen, it adds "..." at the end.
  ##
  runnableExamples:
    doAssert truncate("Hello World", 8) == "Hello..."
    doAssert truncate("Nim", 5) == "Nim"
    doAssert truncate("🦞🦞🦞🦞", 2) == "🦞🦞"
  ##
  let runes = s.toRunes
  if runes.len <= maxLen:
    return s
  if maxLen <= 3:
    return $runes[0 ..< maxLen]
  return $runes[0 ..< maxLen - 3] & "..."
