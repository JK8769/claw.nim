## Skill identification, versioning, and enumeration across the 3-tier model.
##
## Docker-style references: each skill has a stable content-hashed ID (short form,
## 12 hex chars) plus a human-readable `name:version` pair from SKILL.md frontmatter.
## The same SKILL.md content always produces the same ID — deterministic across
## machines and times. Like `docker image list`, you read the table to see what's
## installed, where it came from, and how much space it takes.

import std/[os, strutils, json]
import nimcrypto/[sha2, hash]

type
  SkillMeta* = object
    tier*: string            ## "foundation" | "company" | "workstation/<agent>"
    name*: string            ## from frontmatter `name:` (falls back to dir name)
    version*: string         ## from frontmatter `version:` (falls back to "-")
    id*: string              ## 12-char hex SHA256 of SKILL.md content
    description*: string     ## from frontmatter
    path*: string            ## absolute dir path
    size*: int64             ## bytes on disk (SKILL.md + everything in the skill dir)

# ─── ID and frontmatter ─────────────────────────────────────────

proc computeSkillId*(skillMdPath: string): string =
  ## Returns the 12-char hex SHA256 prefix of the SKILL.md contents. Deterministic.
  if not fileExists(skillMdPath): return "------------"
  let content = readFile(skillMdPath)
  var ctx: sha256
  ctx.init()
  ctx.update(cast[ptr byte](content[0].addr), uint(content.len))
  let digest = ctx.finish()
  var hex = ""
  for b in digest.data:
    hex.add(toHex(b.int, 2).toLowerAscii)
  return hex[0..11]

proc parseFrontmatterBasics*(content: string): tuple[name, version, description: string] =
  ## Best-effort extraction — only top-level name/version/description keys.
  if not content.startsWith("---\n"): return
  let endIdx = content.find("\n---\n", 4)
  if endIdx == -1: return
  for line in content[4 .. endIdx].splitLines():
    let parts = line.split(":", 1)
    if parts.len != 2: continue
    let key = parts[0].strip().toLowerAscii()
    var val = parts[1].strip()
    # Strip surrounding quotes if present
    if val.len >= 2 and ((val[0] == '"' and val[^1] == '"') or
                         (val[0] == '\'' and val[^1] == '\'')):
      val = val[1 .. ^2]
    case key
    of "name":        result.name = val
    of "version":     result.version = val
    of "description": result.description = val
    else: discard

# ─── Disk helpers ──────────────────────────────────────────────

proc dirSize(path: string): int64 =
  if not dirExists(path): return 0
  for p in walkDirRec(path):
    if fileExists(p):
      try: result += getFileSize(p)
      except: discard

# ─── Scanning ──────────────────────────────────────────────────

proc scanSkillsDir(dir: string, tier: string): seq[SkillMeta] =
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind != pcDir: continue
    let skillMd = path / "SKILL.md"
    if not fileExists(skillMd): continue
    let content = readFile(skillMd)
    let (fmName, fmVersion, fmDescr) = parseFrontmatterBasics(content)
    let dirName = path.lastPathPart()
    result.add(SkillMeta(
      tier: tier,
      name: (if fmName.len > 0: fmName else: dirName),
      version: (if fmVersion.len > 0: fmVersion else: "-"),
      id: computeSkillId(skillMd),
      description: fmDescr,
      path: path,
      size: dirSize(path)
    ))

proc listAllSkills*(companyDir: string): seq[SkillMeta] =
  ## Enumerate every skill visible in this company, across all three tiers.
  ## Also checks a few legacy locations so old-layout deployments show up
  ## (tagged as e.g. "company-legacy") before they're migrated.

  # Tier 1 Foundation — from the claw distribution snapshot
  result.add(scanSkillsDir(companyDir / "foundation" / "skills", "foundation"))
  # Legacy foundation path (pre-rename): <co>/base/skills/
  result.add(scanSkillsDir(companyDir / "base" / "skills", "foundation-legacy"))

  # Tier 2 Company — this company's curated opt-ins (skill-as-package)
  result.add(scanSkillsDir(companyDir / "workspace" / "skills", "company"))
  # Legacy company paths (scanned for back-compat):
  #   <co>/workspace/lab/skills/  — before the lab/ → workspace/skills/ rename
  #   <co>/lab/skills/            — before workspace/ existed at top level
  #   <co>/skills/                — before lab/ existed at all
  result.add(scanSkillsDir(companyDir / "workspace" / "lab" / "skills", "company-legacy"))
  result.add(scanSkillsDir(companyDir / "lab" / "skills", "company-legacy"))
  result.add(scanSkillsDir(companyDir / "skills", "company-legacy"))

  # Tier 3 Workstation — one per agent office
  let officesDir = companyDir / "workspace" / "offices"
  if dirExists(officesDir):
    for kind, officePath in walkDir(officesDir):
      if kind != pcDir: continue
      let agentName = officePath.lastPathPart()
      result.add(scanSkillsDir(
        officePath / "workstation" / "skills",
        "workstation/" & agentName
      ))

# ─── Display ───────────────────────────────────────────────────

proc formatSize*(bytes: int64): string =
  ## Human-readable size — KB/MB with one decimal.
  if bytes < 1024: return $bytes & " B"
  if bytes < 1024 * 1024:
    let kb = bytes.float / 1024.0
    return formatFloat(kb, ffDecimal, 1) & " KB"
  let mb = bytes.float / (1024.0 * 1024.0)
  return formatFloat(mb, ffDecimal, 1) & " MB"

proc skillReference*(s: SkillMeta, companyName: string): string =
  ## Render the `claw:` reference that identifies this skill for cross-company install.
  ## Foundation skills don't have a company — they're universal.
  case s.tier
  of "foundation", "foundation-legacy":
    "claw:foundation/" & s.name & "@" & s.version
  of "company", "company-legacy":
    "claw:" & companyName & "/" & s.name & "@" & s.version
  else:
    # workstation/<agent> — show the path but it's not a first-class install target
    "claw:" & companyName & "/" & s.tier & "/" & s.name & "@" & s.version

proc formatSkillJson*(skills: seq[SkillMeta], companyName: string = ""): string =
  ## Scripting-friendly JSON array. Raw numeric size_bytes, not the "4.7 KB" form.
  var arr = newJArray()
  for s in skills:
    arr.add(%*{
      "tier": s.tier,
      "name": s.name,
      "version": s.version,
      "id": s.id,
      "description": s.description,
      "path": s.path,
      "size_bytes": s.size,
      "reference": skillReference(s, companyName)
    })
  return pretty(arr, 2)

proc formatSkillTable*(skills: seq[SkillMeta], companyName: string = ""): string =
  ## Docker-image-style tabular output: TIER NAME VERSION ID SIZE REFERENCE
  if skills.len == 0:
    return "No skills found.\n"

  # Compute column widths from the data
  var maxTier = "TIER".len
  var maxName = "NAME".len
  var maxVer = "VERSION".len
  for s in skills:
    if s.tier.len > maxTier: maxTier = s.tier.len
    if s.name.len > maxName: maxName = s.name.len
    if s.version.len > maxVer: maxVer = s.version.len

  let tierW = maxTier + 2
  let nameW = maxName + 2
  let verW = maxVer + 2
  let idW = 14  # 12 chars + 2 padding
  let sizeW = 12

  var lines: seq[string] = @[]
  lines.add(alignLeft("TIER", tierW) &
            alignLeft("NAME", nameW) &
            alignLeft("VERSION", verW) &
            alignLeft("ID", idW) &
            alignLeft("SIZE", sizeW) &
            "REFERENCE")
  for s in skills:
    lines.add(alignLeft(s.tier, tierW) &
              alignLeft(s.name, nameW) &
              alignLeft(s.version, verW) &
              alignLeft(s.id, idW) &
              alignLeft(formatSize(s.size), sizeW) &
              skillReference(s, companyName))
  return lines.join("\n") & "\n"
