## system_commands — channel-agnostic registry of `/slash` commands.
##
## Problem this solves: the gateway's slash-command dispatcher is a long
## if-elif chain. That works, but no other code can introspect "what
## commands exist" — so each channel (Feishu, Telegram, WhatsApp, …)
## would have to hardcode its own list to render a native menu. The
## registry decouples the command *metadata* (name, summary, args,
## permission, examples) from its *implementation* (still in the
## gateway) so every channel adapter can render a platform-native menu
## from the same source of truth.
##
## Handlers stay in gateway.nim where they have natural access to
## gCtx / offices / config. Channels consume the registry read-only.

import std/[strutils, tables]

type
  Permission* = enum
    pmAny           ## Anyone on any chat.
    pmSuperAdmin    ## Requires declared entity permission == SuperAdmin/Admin.

  CmdArg* = object
    name*: string          ## "app_id"
    description*: string   ## What to fill in.
    required*: bool

  SystemCommand* = object
    name*: string           ## `/channel` — leading slash included.
    summary*: string        ## One-liner shown in `/help` and menus.
    usage*: string          ## Full syntax line, e.g. `/channel auth feishu <app_id> <app_secret> [<agent>]`.
    examples*: seq[string]  ## Ready-to-paste examples; first one typically safe to auto-send.
    args*: seq[CmdArg]      ## Structured args — for channels that render forms (Feishu cards, Discord slash-command options).
    permission*: Permission
    group*: string          ## "admin" | "utility" | "agent-control" — grouping for menus.
    menuHint*: string       ## Short human label ("添加渠道") for menu display if different from `name`.

var gCommands*: seq[SystemCommand] = @[]

proc register*(cmd: SystemCommand) =
  ## Idempotent — re-registering the same `name` replaces the previous entry.
  for i in 0 ..< gCommands.len:
    if gCommands[i].name == cmd.name:
      gCommands[i] = cmd
      return
  gCommands.add(cmd)

proc findCommand*(name: string): SystemCommand =
  for c in gCommands:
    if c.name == name: return c
  SystemCommand()

proc commandsByGroup*(): OrderedTable[string, seq[SystemCommand]] =
  result = initOrderedTable[string, seq[SystemCommand]]()
  for c in gCommands:
    let g = if c.group.len > 0: c.group else: "other"
    if not result.hasKey(g):
      result[g] = @[]
    result[g].add(c)

proc renderHelp*(filterPermission: Permission = pmAny): string =
  ## Universal text-format help. Works on any channel. Platforms with
  ## richer UIs (Feishu cards, Telegram inline keyboards, Discord slash
  ## menus) build their own renderer from `gCommands` directly.
  result = "**Available commands**\n"
  let groups = commandsByGroup()
  for group, cmds in groups.pairs:
    result.add("\n**" & group.capitalizeAscii() & "**\n")
    for c in cmds:
      # Skip commands the caller isn't allowed to run (best-effort hint).
      if filterPermission == pmAny and c.permission == pmSuperAdmin:
        result.add("  🔒 `" & c.name & "` — " & c.summary & "\n")
      else:
        result.add("  `" & c.name & "` — " & c.summary & "\n")
  result.add("\nType a command's name alone to see its full usage and examples.")

proc renderCommandDetail*(name: string): string =
  let c = findCommand(name)
  if c.name.len == 0: return "No such command: `" & name & "`"
  result = "**" & c.name & "** — " & c.summary & "\n\n"
  if c.usage.len > 0:
    result.add("Usage: `" & c.usage & "`\n\n")
  if c.args.len > 0:
    result.add("Arguments:\n")
    for a in c.args:
      let req = if a.required: "required" else: "optional"
      result.add("  - `" & a.name & "` (" & req & ") — " & a.description & "\n")
    result.add("\n")
  if c.examples.len > 0:
    result.add("Examples:\n")
    for e in c.examples:
      result.add("  - `" & e & "`\n")
  if c.permission == pmSuperAdmin:
    result.add("\n🔒 SuperAdmin only.\n")
