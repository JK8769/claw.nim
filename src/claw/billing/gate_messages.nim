## billing/gate_messages — canned, language-aware responses when the
## subscription gate blocks (or warns) a customer message.
##
## All four message kinds follow the same shape:
##   1. Brand header (e.g. "SolarIQ — ")
##   2. Specific reason (expired / daily cap / suspended / no plan)
##   3. Contact card ("Contact Jerry on Feishu")
##
## Text is hand-authored per language, NOT machine-translated. Adding a
## new language = add a branch in each function. Keep the wording
## neutral and formal for zh (use 您), friendly and direct for en.

import std/[strutils, strformat, options]
import std/times
import company

# ── Small helpers for UTC reset-time math and contact-card rendering ─

proc secsUntilMidnightUtc(now: int64): int =
  ## Seconds from `now` (unix) until the next UTC 00:00. Unix timestamps
  ## are UTC-seconds-since-epoch, so `now mod 86400` is the seconds-past-
  ## midnight. Subtract from a day to get the remainder.
  86_400 - int(now mod 86_400)

proc fmtResetHuman(secs: int): string =
  ## "3h 42m" or "27m" — compact form used inline in reset notices.
  let h = secs div 3600
  let m = (secs mod 3600) div 60
  if h > 0: &"{h}h {m}m" else: &"{m}m"

proc channelLabelEn(c: ContactChannel): string =
  case c
  of ccFeishu: "Feishu"
  of ccEmail:  "email"
  of ccPhone:  "phone"
  of ccOther:  "other"

proc channelLabelZh(c: ContactChannel): string =
  case c
  of ccFeishu: "飞书"
  of ccEmail:  "邮箱"
  of ccPhone:  "电话"
  of ccOther:  "其他"

proc renderContactCardEn*(cardOpt: Option[ContactCard]): string =
  ## English contact line — single sentence, no extra formatting. Empty
  ## string if no support contact is declared (gate messages still work
  ## without one, they just don't tell the customer who to ask).
  if cardOpt.isNone: return ""
  let c = cardOpt.get()
  if c.channels.len == 0:
    return &"Need help? Contact {c.name}."
  var labels: seq[string]
  for (ch, _) in c.channels: labels.add(channelLabelEn(ch))
  &"Need help? Contact {c.name} on {labels.join(\" or \")}."

proc renderContactCardZh*(cardOpt: Option[ContactCard]): string =
  if cardOpt.isNone: return ""
  let c = cardOpt.get()
  if c.channels.len == 0:
    return &"如需帮助,请联系 {c.name}。"
  var labels: seq[string]
  for (ch, _) in c.channels: labels.add(channelLabelZh(ch))
  &"如需帮助,请通过{labels.join(\"或\")}联系 {c.name}。"

proc renderContactCard*(cardOpt: Option[ContactCard], lang: string): string =
  if lang.toLowerAscii.startsWith("zh"): renderContactCardZh(cardOpt)
  else: renderContactCardEn(cardOpt)

# ── Blocked-message renderers ─────────────────────────────────────────

proc msgDailyLimit*(brand: string, dailyCap, used: int, now: int64,
                   contact: Option[ContactCard], lang: string): string =
  let reset = fmtResetHuman(secsUntilMidnightUtc(now))
  let contactLine = renderContactCard(contact, lang)
  if lang.toLowerAscii.startsWith("zh"):
    var s = &"{brand} — 您今日的 token 额度已用完({dailyCap} tokens)。\n" &
            &"将于 UTC 00:00 重置(还有 {reset})。"
    if contactLine.len > 0: s.add("\n\n" & contactLine)
    s
  else:
    var s = &"{brand} — You've reached today's token allowance " &
            &"({dailyCap} tokens). Resets at 00:00 UTC in {reset}."
    if contactLine.len > 0: s.add("\n\n" & contactLine)
    s

proc msgExpired*(brand: string, expiresUnix: int64,
                contact: Option[ContactCard], lang: string): string =
  let date = fromUnix(expiresUnix).utc.format("yyyy-MM-dd")
  let contactLine = renderContactCard(contact, lang)
  if lang.toLowerAscii.startsWith("zh"):
    var s = &"{brand} — 您的试用已于 {date} 到期。\n" &
            "如需继续使用,请联系客户经理开通正式订阅。"
    if contactLine.len > 0: s.add("\n\n" & contactLine)
    s
  else:
    var s = &"{brand} — Your trial ended on {date}.\n" &
            "To continue, contact your account manager to activate a paid plan."
    if contactLine.len > 0: s.add("\n\n" & contactLine)
    s

proc msgSuspended*(brand: string, reason: string,
                  contact: Option[ContactCard], lang: string): string =
  let contactLine = renderContactCard(contact, lang)
  if lang.toLowerAscii.startsWith("zh"):
    var s = &"{brand} — 您的账号已暂停服务"
    if reason.len > 0: s.add(&"(原因: {reason})")
    s.add("。\n如需恢复,请联系客户经理。")
    if contactLine.len > 0: s.add("\n\n" & contactLine)
    s
  else:
    var s = &"{brand} — Your account is paused"
    if reason.len > 0: s.add(&" (reason: {reason})")
    s.add(".\nContact your account manager to reactivate.")
    if contactLine.len > 0: s.add("\n\n" & contactLine)
    s

proc msgRecycled*(brand: string, contact: Option[ContactCard],
                 lang: string): string =
  ## Soft-removed account — Atlas will see any of their messages and
  ## reply with this. Operator can restore via `claw user restore`.
  let contactLine = renderContactCard(contact, lang)
  if lang.toLowerAscii.startsWith("zh"):
    var s = &"{brand} — 此账号已停用。\n" &
            "如需恢复,请联系客户经理。"
    if contactLine.len > 0: s.add("\n\n" & contactLine)
    s
  else:
    var s = &"{brand} — This account has been deactivated.\n" &
            "Contact your account manager to reactivate."
    if contactLine.len > 0: s.add("\n\n" & contactLine)
    s

proc msgNoPlan*(brand: string, contact: Option[ContactCard],
               lang: string): string =
  ## Shown when an external customer has no subscription stamped — the
  ## strict "unstamped = blocked" policy. Prompts the operator to run
  ## `subscription activate` (customer-facing wording nudges them to
  ## contact whoever onboarded them).
  let contactLine = renderContactCard(contact, lang)
  if lang.toLowerAscii.startsWith("zh"):
    var s = &"{brand} — 您的账号尚未开通订阅。\n" &
            "请联系客户经理完成激活。"
    if contactLine.len > 0: s.add("\n\n" & contactLine)
    s
  else:
    var s = &"{brand} — Your account doesn't have an active plan yet.\n" &
            "Please contact your account manager to activate your service."
    if contactLine.len > 0: s.add("\n\n" & contactLine)
    s

proc bannerGraceWarning*(brand: string, daysLeft: int,
                        contact: Option[ContactCard], lang: string): string =
  ## Single-line warning prepended to the normal agent response in the
  ## final 3 days of a trial. Cadence (once per day) is enforced at the
  ## call site via `markWarned` — this proc just produces the text.
  let contactLine = renderContactCard(contact, lang)
  if lang.toLowerAscii.startsWith("zh"):
    var s = &"⚠ {brand} — 试用期还剩 {daysLeft} 天。"
    if contactLine.len > 0: s.add(" " & contactLine)
    s & "\n\n"
  else:
    var s = &"⚠ {brand} — Trial ends in {daysLeft} days."
    if contactLine.len > 0: s.add(" " & contactLine)
    s & "\n\n"
