## skill_grant — path semantics for customer skill allowlists.
##
## Syntax: `[<account>@]<skill>[/<resource>[,<resource>...]]`
##   sungrow                                 unscoped
##   njmkuser@sungrow                        account-scoped, any resource
##   njmkuser@sungrow/627305                 account + single resource
##   njmkuser@sungrow/627305,627306          account + two resources
##   njmkuser@sungrow/*                      explicit "any resource"
##
## The `@` separates *identity* (which credentials to authenticate as)
## from *service* (which skill binary). The `/` separates the service
## from the *resource* scope within it. A customer's allowlist is a
## sequence of these strings; the tool dispatcher checks each call
## against them.

import std/[strutils]

type
  SkillGrant* = object
    account*: string       ## "njmkuser" — empty means unscoped / default creds
    skill*: string         ## "sungrow" — always set on a valid grant
    resources*: seq[string] ## ["627305"] — empty = any resource

proc parseSkillGrant*(s: string): tuple[ok: bool, grant: SkillGrant, error: string] =
  let raw = s.strip()
  if raw.len == 0:
    return (false, SkillGrant(), "empty skill grant")
  var rest = raw
  var account = ""
  let at = rest.find('@')
  if at > 0:
    account = rest[0 ..< at].strip()
    rest = rest[at + 1 .. ^1]
  elif at == 0:
    return (false, SkillGrant(), "grant cannot start with @")
  var skill = rest
  var resources: seq[string]
  let slash = rest.find('/')
  if slash >= 0:
    skill = rest[0 ..< slash].strip()
    let tail = rest[slash + 1 .. ^1].strip()
    if tail == "*" or tail.len == 0:
      resources = @[]
    else:
      for part in tail.split(','):
        let p = part.strip()
        if p.len > 0: resources.add(p)
  skill = skill.strip()
  if skill.len == 0:
    return (false, SkillGrant(), "missing skill name")
  (true, SkillGrant(account: account, skill: skill, resources: resources), "")

proc `$`*(g: SkillGrant): string =
  result = ""
  if g.account.len > 0:
    result.add(g.account & "@")
  result.add(g.skill)
  if g.resources.len > 0:
    result.add("/" & g.resources.join(","))

proc matches*(g: SkillGrant, skill, account, resource: string): bool =
  ## Check whether a tool call with the given (skill, account, resource)
  ## is permitted by this grant. Empty `resource` means a list-style
  ## call (e.g. `plants`) — passes any grant with a matching
  ## skill+account. Empty `account` on the call side matches unscoped
  ## grants only; named accounts need a grant with that exact account.
  if g.skill.toLowerAscii != skill.toLowerAscii: return false
  if g.account.len > 0 and g.account.toLowerAscii != account.toLowerAscii:
    return false
  if resource.len > 0 and g.resources.len > 0:
    for r in g.resources:
      if r == resource: return true
    return false
  true

proc allows*(grants: openArray[SkillGrant], skill, account, resource: string): bool =
  ## Any-of over a customer's allowlist.
  for g in grants:
    if g.matches(skill, account, resource): return true
  false

proc filterResourcesFor*(grants: openArray[SkillGrant], skill, account: string): seq[string] =
  ## Union of resources any matching grant allows. Useful for filtering
  ## a list response down to what the customer is entitled to see.
  ## Returns `@[]` when any grant is "any resource" (caller should not
  ## filter in that case — use `hasAnyResourceGrant` first).
  for g in grants:
    if g.skill.toLowerAscii == skill.toLowerAscii and
       (g.account.len == 0 or g.account.toLowerAscii == account.toLowerAscii):
      if g.resources.len == 0: return @[]  # unrestricted
      for r in g.resources:
        if r notin result: result.add(r)

proc hasAnyResourceGrant*(grants: openArray[SkillGrant], skill, account: string): bool =
  ## True if at least one matching grant has an empty resource list
  ## (meaning "any resource for this skill+account").
  for g in grants:
    if g.skill.toLowerAscii == skill.toLowerAscii and
       (g.account.len == 0 or g.account.toLowerAscii == account.toLowerAscii) and
       g.resources.len == 0:
      return true
  false
