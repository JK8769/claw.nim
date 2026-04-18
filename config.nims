# claw build settings
switch("define", "ssl")
switch("define", "release")

# ggml (TTS engine)
switch("passC", "-I" & thisDir() & "/src/claw/tts/ggml/include")
switch("passL", "-L" & thisDir() & "/src/claw/tts/lib -lggml -lggml-base -lggml-cpu")
when defined(macosx):
  switch("passL", "-lc++ -framework Accelerate -framework Metal -framework Foundation -framework MetalKit")
else:
  switch("passL", "-lstdc++ -lm")

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
