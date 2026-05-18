# claw build settings
switch("define", "ssl")
switch("define", "release")

# Local dev override for ttml — point at the sibling working tree so
# claw can use the builder API (ttml/build) before it's published to a
# tag that nimble can resolve. When ttml releases a version containing
# `build.nim`, this override can be removed and the `requires "ttml"`
# line in claw.nimble takes over.
import std/[os, strutils]
const ttmlDevPath = thisDir() / ".." / ".." / "Zen" / "nim-pkgs" / "ttml" / "src"
when fileExists(ttmlDevPath / "ttml" / "build.nim"):
  switch("path", ttmlDevPath)

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
