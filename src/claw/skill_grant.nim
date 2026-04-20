## skill_grant — path semantics for customer skill allowlists.
##
## Syntax: `[<account>@]<skill>`
##   sungrow              unscoped (uses the skill's default credentials)
##   njmkuser@sungrow     account-scoped (routes to the sungrow instance
##                        authenticated with njmkuser's credentials)
##
## The `@` separates *identity* (which credentials to authenticate as)
## from *service* (which skill binary). A customer's allowlist is a
## sequence of these strings; the dispatcher checks each tool call
## against them.
##
## Resources grouped under one account are treated as a single unit —
## if a customer has a grant for an account, they can see everything
## that account owns. If finer granularity is needed in the future,
## add it at the account (credential) layer rather than the grant
## layer.

import std/[strutils]

type
  SkillGrant* = object
    account*: string  ## "njmkuser" — empty means unscoped / default creds
    skill*: string    ## "sungrow" — always set on a valid grant

proc parseSkillGrant*(s: string): tuple[ok: bool, grant: SkillGrant, error: string] =
  let raw = s.strip()
  if raw.len == 0:
    return (false, SkillGrant(), "empty skill grant")
  var account = ""
  var skill = raw
  let at = raw.find('@')
  if at > 0:
    account = raw[0 ..< at].strip()
    skill = raw[at + 1 .. ^1].strip()
  elif at == 0:
    return (false, SkillGrant(), "grant cannot start with @")
  if skill.len == 0:
    return (false, SkillGrant(), "missing skill name")
  (true, SkillGrant(account: account, skill: skill), "")

proc `$`*(g: SkillGrant): string =
  if g.account.len > 0: g.account & "@" & g.skill
  else: g.skill

proc matches*(g: SkillGrant, skill, account: string): bool =
  ## True if a tool call on (skill, account) is permitted by this grant.
  ## Empty `account` on the call side matches unscoped grants only;
  ## named accounts need a grant with that exact account.
  if g.skill.toLowerAscii != skill.toLowerAscii: return false
  if g.account.len > 0 and g.account.toLowerAscii != account.toLowerAscii:
    return false
  true

proc allows*(grants: openArray[SkillGrant], skill, account: string): bool =
  ## Any-of over a customer's allowlist.
  for g in grants:
    if g.matches(skill, account): return true
  false
