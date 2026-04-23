## billing/welcome — language-aware welcome message on activation.
##
## The same proc is used by:
##   • `claw user subscription activate` (CLI) — prints to operator stdout.
##   • `claw user invite` (future auto-activate) — sent as first agent
##     message when the customer redeems.
##
## Text is hand-authored per language, NOT machine-translated — the
## first impression matters. Adding a new language = add a branch in
## `welcomeMessage`. For now: en (fallback) + zh-CN (primary for
## SunGrowCN).

import std/[strutils, strformat, options]
import subscription, company, gate_messages
import std/times

type
  WelcomeContext* = object
    customerName*:   string
    agentName*:      string
    lang*:           string       ## "en", "zh-CN", "zh", etc.
    sub*:            Subscription
    companyName*:    string       ## e.g. "SunGrow" — shown in the greeting
    contact*:        Option[ContactCard]
                                  ## Optional support contact appended to
                                  ## the welcome. None() = no contact line.
    plantNames*:     seq[string]  ## Real plant names pulled from the
                                  ## customer's Sungrow account cache.
                                  ## Used verbatim in example queries so
                                  ## customers see their own 荣鑫一期 /
                                  ## Acme Hayward, not placeholder text.
                                  ## Empty → generic "your plants" wording.

proc fmtDate(unix: int64): string =
  # Short human date in UTC.
  fromUnix(unix).utc.format("yyyy-MM-dd")

proc welcomeEn(ctx: WelcomeContext): string =
  let daysLeft = daysRemaining(ctx.sub, getTime().toUnix)
  let capHuman = &"{ctx.sub.dailyTokens div 1000}k"
  # Pick up to 3 real plant names; fall back to generic "your plant(s)"
  # phrasing when the customer's cache isn't populated yet. Using their
  # own names (荣鑫一期, Acme Hayward, etc.) makes the examples land —
  # generic placeholders like "plant Acme-01" read like a boilerplate.
  let p1 = if ctx.plantNames.len > 0: ctx.plantNames[0] else: "your plant"
  let p2 =
    if ctx.plantNames.len > 1: ctx.plantNames[1]
    elif ctx.plantNames.len > 0: ctx.plantNames[0]
    else: "another plant"
  let pAny = if ctx.plantNames.len > 0: ctx.plantNames[0] else: "a plant"
  result = &"""Welcome to {ctx.companyName} Solar Fleet Monitoring, {ctx.customerName}! 👋

You're now connected to {ctx.agentName}, your AI solar-ops assistant.
Ask questions in plain language — no SQL, no dashboards, no menus.

📊 Current status — real-time snapshots
  • "What's the current output of {p1}?"
  • "Show real-time status for all my plants"
  • "Which inverters are offline right now?"

📈 Historical analysis — trends and anomalies
  • "Yesterday's production for {p1}"
  • "Compare {p1} and {p2} this month"
  • "Why did {pAny} drop to 0 at 14:30 yesterday?"

📝 Reports — generated on demand
  • "Build me a monthly performance report for {p1}"
  • "Summarize this week's anomalies across my fleet"

📄 Document parsing — attach a PDF
  • "Parse this spec sheet and extract the key numbers"

Your trial
  • Plan:     {ctx.sub.plan} — starts today, {daysLeft} days left
  • Expires:  {fmtDate(ctx.sub.expires)}
  • Daily:    {capHuman} tokens (~roughly 50 conversations)
  • Check:    ask "what's my subscription status?" anytime"""
  let contactLine = renderContactCardEn(ctx.contact)
  if contactLine.len > 0:
    result.add("\n\n" & contactLine)
  else:
    result.add("\n\nQuestions or limit increases? Contact your account manager.")

proc welcomeZh(ctx: WelcomeContext): string =
  let daysLeft = daysRemaining(ctx.sub, getTime().toUnix)
  let capHuman = &"{ctx.sub.dailyTokens div 1000}k"
  # Translation note: use 您 (formal) throughout — customer-facing Chinese
  # business context. "tokens" is kept in English (industry standard).
  # Plant names: use the customer's real names if the cache has them,
  # else fall back to generic 您的电站 (your plant) phrasing.
  let p1 = if ctx.plantNames.len > 0: ctx.plantNames[0] else: "您的电站"
  let p2 =
    if ctx.plantNames.len > 1: ctx.plantNames[1]
    elif ctx.plantNames.len > 0: ctx.plantNames[0]
    else: "其它电站"
  let pAny = if ctx.plantNames.len > 0: ctx.plantNames[0] else: "某个电站"
  result = &"""欢迎使用 {ctx.companyName} 光伏电站智能运营服务,{ctx.customerName}!👋

您现在已连接到 {ctx.agentName},您的 AI 光伏运维助手。
直接用自然语言提问即可,无需 SQL、仪表盘或菜单操作。

📊 实时状态查询
  • "{p1}当前发电功率多少?"
  • "所有电站的实时状态"
  • "现在有哪些逆变器离线?"

📈 历史数据分析
  • "{p1}昨天的发电量"
  • "本月对比{p1}和{p2}的发电表现"
  • "{pAny}昨天 14:30 为什么功率掉到了 0?"

📝 报告生成
  • "帮我生成{p1}的月度发电分析报告"
  • "汇总本周所有电站的异常情况"

📄 文档解析 — 直接上传 PDF
  • "帮我提取这份数据手册的关键参数"

您的试用信息
  • 套餐:   {ctx.sub.plan} — 从今日开始,剩余 {daysLeft} 天
  • 到期:   {fmtDate(ctx.sub.expires)}
  • 每日额度: {capHuman} tokens(约 50 轮对话)
  • 查询:   直接问"我的订阅还剩多少额度?""""
  let contactLine = renderContactCardZh(ctx.contact)
  if contactLine.len > 0:
    result.add("\n\n" & contactLine)
  else:
    result.add("\n\n有任何疑问或需要调整额度,请联系您的客户经理。")

proc welcomeMessage*(ctx: WelcomeContext): string =
  ## Entry point — dispatches by language prefix. Unknown language
  ## falls back to English. `zh`, `zh-CN`, `zh-cn`, `zh_CN` all map to
  ## the Simplified Chinese version; `zh-TW`/`zh-HK` currently also get
  ## Simplified (better than English fallback; real Traditional support
  ## can be added later).
  let l = ctx.lang.toLowerAscii
  if l.startsWith("zh"): welcomeZh(ctx) else: welcomeEn(ctx)

proc inviteCodeMessage*(brand, code, lang: string): string =
  ## Clean, single-line shareable invite text for the operator to
  ## forward to the customer. Examples:
  ##   English: "SolarIQ Code: C3F-E7V"
  ##   Chinese: "SolarIQ 邀请码: C3F-E7V"
  ## The customer pastes this as their first message; the gateway
  ## intercept matches the code regardless of surrounding text, so the
  ## brand prefix is cosmetic but signals provenance to the customer.
  let l = lang.toLowerAscii
  if l.startsWith("zh"): brand & " 邀请码: " & code
  else: brand & " Code: " & code
