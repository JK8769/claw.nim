## skill_grant — path semantics for customer skill allowlists.
##
## Two grant syntaxes:
##
## 1. `[<account>@]<skill>` — legacy, account label as prefix
##      sungrow                unscoped (uses the skill's default credentials)
##      acme-co@sungrow       account-scoped via literal account name
##
## 2. `<skill>::<credential>` — credential-scoped, invite-friendly
##      sungrow::acme-solar    routes to the sungrow "acme-solar" credential
##                             (the skill's accounts/acme-solar.json). On
##                             redemption the invite flow materializes a
##                             member record linking the customer's nc:id
##                             to this credential — so multiple customers
##                             can share one Sungrow login cleanly.
##
## The `@` separates *identity* (which credentials to authenticate as)
## from *service* (which skill binary). The `::` separates *skill* from
## *credential slug* — nicer for invites because the slug never collides
## with a Sungrow username (it's internal to our deployment).
##
## A customer's allowlist is a sequence of these strings; the dispatcher
## checks each tool call against them. The `credential` field is used
## by the invite-redeem flow to materialize per-skill member records
## (routing glue) and by the dispatcher's per-request context injection.

import std/[strutils]

type
  SkillGrant* = object
    account*: string     ## "acme-co" — empty means unscoped / default creds (legacy `@` syntax)
    skill*: string       ## "sungrow" — always set on a valid grant
    credential*: string  ## "acme-solar" — `::` syntax; populated by invite flow into a member record

proc parseSkillGrant*(s: string): tuple[ok: bool, grant: SkillGrant, error: string] =
  let raw = s.strip()
  if raw.len == 0:
    return (false, SkillGrant(), "empty skill grant")
  var account, skill, credential: string

  # `::` credential binding takes precedence. Looks like `<skill>::<cred>`.
  let dd = raw.find("::")
  if dd > 0:
    skill = raw[0 ..< dd].strip()
    credential = raw[dd + 2 .. ^1].strip()
    if credential.len == 0:
      return (false, SkillGrant(), "credential after '::' cannot be empty")
  else:
    # Legacy `account@skill` syntax.
    skill = raw
    let at = raw.find('@')
    if at > 0:
      account = raw[0 ..< at].strip()
      skill = raw[at + 1 .. ^1].strip()
    elif at == 0:
      return (false, SkillGrant(), "grant cannot start with @")

  if skill.len == 0:
    return (false, SkillGrant(), "missing skill name")
  (true, SkillGrant(account: account, skill: skill, credential: credential), "")

proc `$`*(g: SkillGrant): string =
  if g.credential.len > 0: g.skill & "::" & g.credential
  elif g.account.len > 0: g.account & "@" & g.skill
  else: g.skill

proc matches*(g: SkillGrant, skill, account: string): bool =
  ## True if a tool call on (skill, account) is permitted by this grant.
  ## An `account` call-side matches: an unscoped grant, a legacy
  ## `<account>@skill` grant whose account matches exactly, or any
  ## `skill::<credential>` grant (credential routing is enforced via
  ## the member record, not the grant string, so the grant just gates
  ## access to the skill regardless of which credential).
  if g.skill.toLowerAscii != skill.toLowerAscii: return false
  if g.account.len > 0 and g.account.toLowerAscii != account.toLowerAscii:
    return false
  true

proc allows*(grants: openArray[SkillGrant], skill, account: string): bool =
  ## Any-of over a customer's allowlist.
  for g in grants:
    if g.matches(skill, account): return true
  false
