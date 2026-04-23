## billing/company — customer-facing company state resolvers.
##
## Two queries against the WorldGraph that multiple customer-facing
## surfaces (welcome, gate messages, CLI invite output) all need:
##
##   • resolveBrand            — display name ("SolarIQ", not "SunGrowCN")
##   • resolveSupportContact   — who to contact for help (Person + channels)
##
## Keeping them in one module avoids scattering the "corporate entity
## lookup" logic across cli_admin.nim / gateway.nim / billing/welcome.nim.

import std/[options, os, strutils, tables, json]
import ../agent/cortex
import ../config
import ../skill_grant

type
  ContactChannel* = enum
    ccFeishu = "feishu"
    ccEmail = "email"
    ccPhone = "phone"
    ccOther = "other"

  ContactCard* = object
    name*:     string                  ## display name (e.g. "Jerry")
    channels*: seq[(ContactChannel, string)]
                                        ## (kind, handle) pairs for rendering.
                                        ## handle is the raw identifier from
                                        ## the graph; rendering is per-channel.

proc resolveBrand*(graph: WorldGraph, override = ""): string =
  ## Customer-facing service name. Cascade:
  ##   explicit override > corporate entity's `custom.brand` >
  ##   corporate entity `name` > NIMCLAW_DIR basename > "our".
  if override.len > 0: return override
  if graph != nil:
    for _, e in graph.entities.pairs:
      if e.kind != ekCorporate: continue
      if e.custom != nil and e.custom.hasKey("brand"):
        let b = e.custom["brand"].getStr("").strip()
        if b.len > 0: return b
      if e.name.len > 0: return e.name
  let base = getNimClawDir().lastPathPart
  if base.startsWith(".nimclaw-"): return base[".nimclaw-".len .. ^1]
  "our"

proc classifyChannel(channelKey: string): ContactChannel =
  ## Graph identifiers use keys like "feishu:cli_a93085...", "feishu:user",
  ## "feishu:union", "email", "phone", "nkn", etc. Collapse to a coarse
  ## enum for rendering.
  let k = channelKey.toLowerAscii
  if k.startsWith("feishu"): ccFeishu
  elif k == "email": ccEmail
  elif k == "phone" or k == "tel": ccPhone
  else: ccOther

proc parseGroupDefaults*(description: string):
    tuple[skills: seq[string], lang: string] =
  ## Scan a Feishu group description for structured defaults that the
  ## group-chat invite flow should pick up automatically.
  ##
  ## Tokens recognized (one per line, or whitespace-separated):
  ##   sungrow::<account>       — preferred credential-scoped syntax
  ##   <account>@<skill>        — legacy account-prefix syntax (e.g. `njmkuser@sungrow`)
  ##   skill=sungrow::<account> — alias keyword form
  ##   lang=zh                  — language default
  ##
  ## Skill tokens are validated with `parseSkillGrant` — same grammar
  ## the CLI uses, so typos here fail the same way typos on the command
  ## line do. A `foo@bar.com` email is explicitly filtered (dot on the
  ## right side of `@`) so group descriptions can contain contact info
  ## without being mis-parsed as grants.
  ##
  ## Returns empty seq + empty string when nothing matches; caller
  ## falls back to asking the operator to be explicit.
  if description.len == 0: return
  for raw in description.splitWhitespace():
    let tok = raw.strip(chars = {' ', '\t', '\n', ',', ';', '.'})
    if tok.len == 0: continue
    let lc = tok.toLowerAscii
    if lc.startsWith("lang="):
      result.lang = tok[5 .. ^1].strip().toLowerAscii
      continue
    let candidate =
      if lc.startsWith("skill="): tok[6 .. ^1].strip()
      elif "::" in tok and not tok.startsWith("::"): tok
      elif '@' in tok and '=' notin tok and ':' notin tok and
           '.' notin tok[tok.find('@') + 1 .. ^1]: tok
      else: ""
    if candidate.len == 0: continue
    let (ok, _, _) = parseSkillGrant(candidate)
    if ok: result.skills.add(candidate)

proc resolveSupportContact*(graph: WorldGraph): Option[ContactCard] =
  ## Look up the designated support Person (via the corporate entity's
  ## `custom.support` name) and collect their identifiers into a
  ## renderable card. Returns none() if no support person is declared
  ## or if the named Person doesn't exist in the graph.
  if graph == nil: return none(ContactCard)
  var supportName = ""
  for _, e in graph.entities.pairs:
    if e.kind != ekCorporate: continue
    if e.custom != nil and e.custom.hasKey("support"):
      supportName = e.custom["support"].getStr("").strip()
    break
  if supportName.len == 0: return none(ContactCard)
  if not graph.nameIndex.hasKey(supportName): return none(ContactCard)
  let id = graph.nameIndex[supportName]
  if not graph.entities.hasKey(id): return none(ContactCard)
  let ent = graph.entities[id]
  var card = ContactCard(name: ent.name)
  # Dedupe by channel class — if multiple feishu:* identifiers are
  # stamped (app_id, user_id, union_id), only surface one "Feishu"
  # entry. Same for email and phone.
  var seen: set[ContactChannel] = {}
  for k, _ in ent.identifiers.pairs:
    let ck = classifyChannel(k)
    if ck in seen or ck == ccOther: continue
    seen.incl(ck)
    card.channels.add((ck, k))
  some(card)
