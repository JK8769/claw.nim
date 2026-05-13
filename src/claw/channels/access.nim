## channels/access — singleton accessor for the running channel manager.
##
## The channel manager is constructed by the gateway and outlives most
## per-agent state. Tools that need read-only introspection (the `channel`
## tool, `social route` queries) reach it through these getters rather than
## importing channels/manager directly (which would pull in every channel
## impl and bloat per-tool compile units).
##
## The gateway calls `setManager` once after `initChannels`. Tools call the
## getters lazily — they tolerate `nil` (returning empty / none()) so the
## CLI/test paths that never boot a manager don't crash.

import std/options
import ./base as channel_base

# The module that owns the Manager type lives at channels/manager.nim and
# would create a circular import if pulled in here. We accept the manager
# as a duck-typed `RootRef` and downcast at the call site via closures
# the gateway sets up. Effectively the gateway hands us closures that close
# over the real manager — no type leak across the layer boundary.

type
  ListEnabledFn*  = proc(): seq[string] {.gcsafe.}
  GetCapsFn*      = proc(name: string): Option[channel_base.ChannelCapabilities] {.gcsafe.}
  IsRunningFn*    = proc(name: string): bool {.gcsafe.}

var
  listEnabledImpl: ListEnabledFn
  getCapsImpl:     GetCapsFn
  isRunningImpl:   IsRunningFn

proc bindChannelAccess*(le: ListEnabledFn, gc: GetCapsFn, ir: IsRunningFn) =
  ## Gateway calls this once after `initChannels` to wire the live manager.
  listEnabledImpl = le
  getCapsImpl     = gc
  isRunningImpl   = ir

proc listEnabledChannels*(): seq[string] =
  if listEnabledImpl.isNil: @[] else: listEnabledImpl()

proc getChannelCaps*(name: string): Option[channel_base.ChannelCapabilities] =
  if getCapsImpl.isNil: none(channel_base.ChannelCapabilities)
  else: getCapsImpl(name)

proc isChannelRunning*(name: string): bool =
  if isRunningImpl.isNil: false else: isRunningImpl(name)
