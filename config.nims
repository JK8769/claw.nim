# claw build settings
switch("define", "ssl")
switch("define", "release")

# Local dev override for ttml + tui — point at the sibling working
# trees so claw can use:
#   • ttml/build (the typed builder API for standard tags)
#   • tui/spec/* (typed smart constructors for extension tags like
#     <ContextMenu>; producers import just the spec, never the renderer)
# When these packages publish releases with these surfaces, the
# overrides become no-ops and the `requires ...` lines in claw.nimble
# take over.
import std/[os, strutils]
const ttmlDevPath = thisDir() / ".." / ".." / "Zen" / "nim-pkgs" / "ttml" / "src"
when fileExists(ttmlDevPath / "ttml" / "build.nim"):
  switch("path", ttmlDevPath)
const tuiDevPath = thisDir() / ".." / ".." / "Zen" / "nim-pkgs" / "tui" / "src"
when fileExists(tuiDevPath / "tui" / "spec" / "context_menu.nim"):
  switch("path", tuiDevPath)

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
