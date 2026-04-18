import std/[os, strutils]
import path_security

type
  AccessKind* = enum
    akRead,
    akWrite,
    akExecute

proc checkAccess*(role, agentName, path, ws_resolved: string, access: AccessKind): bool =
  ## Core IAM policy engine mapping Roles to Filesystem paths.
  ## Imitates Linux rwx permissions.
  
  # 1. SuperAdmin (Root) bypass
  if role == "SuperAdmin":
    return true

  # 2. Normalize path and roots
  var resolved = ""
  try:
    # Always normalize the incoming path
    resolved = absolutePath(path).normalizedPath()
  except OSError:
    return false

  let normalizedWS = ws_resolved.normalizedPath()
  
  let officesRoot = if dirExists(normalizedWS / "offices"):
      normalizedWS / "offices"
    elif dirExists(normalizedWS / ".nimclaw" / "workspace" / "offices"):
      normalizedWS / ".nimclaw" / "workspace" / "offices"
    else:
      normalizedWS / "offices" # Fallback
  
  let myOffice = officesRoot / agentName.toLowerAscii()
  let collaborationDir = normalizedWS / "collaboration"
  let stagingDir = collaborationDir / "staging"
  let handbookDir = ws_resolved / "competencies" / "core" / "handbook"
  let competenciesDir = ws_resolved / "competencies"
  let memosDir = ws_resolved / "memos"
  let portalDir = ws_resolved / "portal"
  let legacyHandbook = ws_resolved / "handbook"
  
  let globalNimClaw = getHomeDir() / ".nimclaw"
  let globalOpenClaw = getHomeDir() / ".openclaw"

  # 3. Rule Enforcement Matrix
  
  case access
  of akWrite:
    # Everyone can write to their own office, collaboration, or staging
    if pathStartsWith(resolved, myOffice): return true
    if pathStartsWith(resolved, collaborationDir): return true
    # staging is under collaboration, so the above rule covers it, 
    # but we can keep it explicit if we want specific sub-rules later.
    
    # Admins can also write to global areas within workspace
    if role == "Admin":
      if pathStartsWith(resolved, handbookDir): return true
      if pathStartsWith(resolved, competenciesDir): return true
      if pathStartsWith(resolved, legacyHandbook): return true
      if pathStartsWith(resolved, portalDir): return true
      if pathStartsWith(resolved, memosDir): return true 
      
    return false

  of akRead:
    # Explicitly block global automation directory for all roles below SuperAdmin
    let automationDir = ws_resolved / "automation"
    if pathStartsWith(resolved, automationDir):
      return false
    # Everyone can read their office, collaboration, handbook, portal, memos
    if pathStartsWith(resolved, myOffice): return true
    if pathStartsWith(resolved, collaborationDir): return true
    if pathStartsWith(resolved, handbookDir): return true
    if pathStartsWith(resolved, competenciesDir): return true
    if pathStartsWith(resolved, legacyHandbook): return true
    if pathStartsWith(resolved, portalDir): return true
    if pathStartsWith(resolved, memosDir): return true

    # Global skill registries are readable by all agents
    if pathStartsWith(resolved, globalNimClaw): return true
    if pathStartsWith(resolved, globalOpenClaw): return true
    
    # Staff can read common workspace
    if role in ["Admin", "Employee", "Secretary", "Tech Lead", "Security Analyst"]:
      if pathStartsWith(resolved, ws_resolved):
        # block access to OTHER offices
        if pathStartsWith(resolved, officesRoot) and not pathStartsWith(resolved, myOffice):
          if role != "Admin": # Admins can read other offices
            return false
        return true
    
    return false

  of akExecute:
    if role in ["SuperAdmin", "Admin"]: return true
    return false

