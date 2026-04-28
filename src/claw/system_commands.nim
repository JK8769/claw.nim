## system_commands — channel-agnostic registry of `/slash` commands.
##
## Problem this solves: the gateway's slash-command dispatcher is a long
## if-elif chain. That works, but no other code can introspect "what
## commands exist" — so each channel (Feishu, Telegram, WhatsApp, …)
## would have to hardcode its own list to render a native menu. The
## registry decouples the command *metadata* (name, summary, args,
## permission, examples, docopt-style spec) from its *implementation*
## (still in the gateway) so every channel adapter can render a
## platform-native menu from the same source of truth, and every
## handler parses its args through the same docopt layer.
##
## Handlers stay in gateway.nim where they have natural access to
## gCtx / offices / config. Channels consume the registry read-only.

import std/[strutils, tables]
import docopt

type
  Permission* = enum
    pmAny           ## Anyone on any chat.
    pmInternal      ## Any internal-tier role (SuperAdmin, Admin, Staff,
                    ## Member, Employee). Customer/Guest are excluded.
    pmAdmin         ## Admin or SuperAdmin — operator tier. Most
                    ## previously-`pmSuperAdmin` call sites that meant
                    ## "admin or above" now use this.
    pmSuperAdmin    ## True SuperAdmin only (the apex of trust). Granting
                    ## another SuperAdmin requires being one.

  CmdArg* = object
    name*: string          ## "app_id"
    description*: string   ## What to fill in.
    required*: bool

  SystemCommand* = object
    name*: string           ## `/channel` — leading slash included.
    summary*: string        ## One-liner shown in `/help` and menus.
    usage*: string          ## Full syntax line, e.g. `/channel auth feishu <app_id> <app_secret> [<agent>]`.
    doc*: string            ## docopt-format spec — parsed via `parseArgs`.
                            ## Leave empty for argless commands.
    examples*: seq[string]  ## Ready-to-paste examples; first one typically safe to auto-send.
    args*: seq[CmdArg]      ## Structured args — for channels that render forms (Feishu cards, Discord slash-command options).
    permission*: Permission
    group*: string          ## "admin" | "utility" | "agent-control" — grouping for menus.
    menuHint*: string       ## Short human label ("添加渠道") for menu display if different from `name`.

  ParseResult* = object
    ok*: bool
    args*: Table[string, Value]  ## docopt-parsed args on success.
    error*: string               ## Formatted error + usage block on failure.

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

proc codeBlock*(body: string, lang = ""): string =
  ## Fenced markdown code block — renders as monospace in Feishu /
  ## Telegram / Discord / anything that honours CommonMark. Good for
  ## usage lines, examples, and error diagnostics that need to stay
  ## byte-exact.
  "```" & lang & "\n" & body.strip(leading = false, trailing = true) & "\n```"

proc renderHelp*(filterPermission: Permission = pmAny): string =
  ## Universal text-format help. Works on any channel. Platforms with
  ## richer UIs (Feishu cards, Telegram inline keyboards, Discord slash
  ## menus) build their own renderer from `gCommands` directly.
  result = "**Available commands**\n"
  let groups = commandsByGroup()
  for group, cmds in groups.pairs:
    result.add("\n**" & group.capitalizeAscii() & "**\n")
    var block_body = ""
    for c in cmds:
      # 🔒 marks commands the caller can't actually run — i.e. require
      # a strictly higher tier than the caller has.
      let lock = if c.permission > filterPermission: "🔒 " else: ""
      block_body.add(lock & c.name.alignLeft(14) & "  " & c.summary & "\n")
    result.add(codeBlock(block_body))
    result.add("\n")
  result.add("Type `/help <command>` for full usage + examples.")

proc renderCommandDetail*(name: string): string =
  let c = findCommand(name)
  if c.name.len == 0:
    return "No such command: `" & name & "`\nTry `/help`."
  result = "**" & c.name & "** — " & c.summary & "\n\n"
  if c.usage.len > 0:
    result.add("**Usage**\n" & codeBlock(c.usage) & "\n\n")
  if c.doc.len > 0:
    result.add("**Spec**\n" & codeBlock(c.doc) & "\n\n")
  if c.args.len > 0 and c.doc.len == 0:
    var body = ""
    for a in c.args:
      let req = if a.required: "required" else: "optional"
      body.add(a.name.alignLeft(16) & " " & req.alignLeft(9) & " " & a.description & "\n")
    result.add("**Arguments**\n" & codeBlock(body) & "\n\n")
  if c.examples.len > 0:
    result.add("**Examples**\n" & codeBlock(c.examples.join("\n")) & "\n")
  case c.permission
  of pmAny: discard
  of pmInternal:   result.add("\n🔒 Internal staff only.\n")
  of pmAdmin:      result.add("\n🔒 Admin or SuperAdmin only.\n")
  of pmSuperAdmin: result.add("\n🔒 SuperAdmin only.\n")

proc parseArgs*(cmdName, raw: string, argv: seq[string]): ParseResult =
  ## Run docopt against the command's registered `doc` spec. `argv`
  ## is the argument tokens AFTER the leading command(s) — e.g. for
  ## `/user invite Alice Atlas` pass `@["Alice", "Atlas"]`.
  ## Returns a structured result: `ok` means `args` is populated;
  ## `not ok` means `error` contains a formatted usage block ready
  ## to send back to the caller.
  let c = findCommand(cmdName)
  if c.name.len == 0:
    return ParseResult(ok: false, error: "Unknown command: " & cmdName)
  if c.doc.len == 0:
    return ParseResult(ok: true, args: initTable[string, Value]())
  try:
    let parsed = docopt(c.doc, argv = argv, quit = false)
    return ParseResult(ok: true, args: parsed)
  except DocoptExit as e:
    var err = "**Usage error**\n" & codeBlock(e.usage.strip)
    if c.examples.len > 0:
      err.add("\n\n**Examples**\n" & codeBlock(c.examples.join("\n")))
    return ParseResult(ok: false, error: err)
