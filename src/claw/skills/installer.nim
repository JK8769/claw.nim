import std/[asyncdispatch, httpclient, os, json, strutils, osproc, options]
import ../config

type
  AvailableSkill* = object
    name*: string
    repository*: string
    description*: string
    author*: string
    tags*: seq[string]

  SkillRegistryEntry* = object
    name*: string
    description*: string
    repository*: string
    sub_path*: string
    source*: string          # "bundled" or "github"
    requires*: seq[string]   # binary dependencies (python3, node, etc.)
    env*: seq[string]        # required env vars (ANYGEN_API_KEY, etc.)
    plugins*: seq[string]    # plugin dependencies (resolved from plugins/plugins.json)
    install*: seq[string]    # install commands to run after cloning
    configure*: string       # configure command template ({skill_dir}, {ENV_VAR})

  BuiltinSkill* = object
    name*: string
    path*: string
    enabled*: bool

  SkillInstaller* = ref object
    workspace*: string

proc newSkillInstaller*(workspace: string): SkillInstaller =
  SkillInstaller(workspace: workspace)

proc loadRegistry*(): seq[SkillRegistryEntry] =
  ## Load skills.json — search CWD, then next to binary (nimble install).
  var localPath = getCurrentDir() / "skills" / "skills.json"
  if not fileExists(localPath):
    localPath = getAppDir() / "skills" / "skills.json"
  if fileExists(localPath):
    let data = parseJson(readFile(localPath))
    for item in data:
      var entry = SkillRegistryEntry()
      entry.name = item{"name"}.getStr("")
      entry.description = item{"description"}.getStr("")
      entry.repository = item{"repository"}.getStr("")
      entry.sub_path = item{"sub_path"}.getStr("")
      entry.source = item{"source"}.getStr("github")
      if item.hasKey("requires"):
        for r in item["requires"]: entry.requires.add(r.getStr())
      if item.hasKey("env"):
        for e in item["env"]: entry.env.add(e.getStr())
      if item.hasKey("plugins"):
        for p in item["plugins"]: entry.plugins.add(p.getStr())
      if item.hasKey("install"):
        for c in item["install"]: entry.install.add(c.getStr())
      entry.configure = item{"configure"}.getStr("")
      result.add(entry)

proc findInRegistry*(name: string): Option[SkillRegistryEntry] =
  ## Look up a skill by name in skills.json.
  for entry in loadRegistry():
    if entry.name == name:
      return some(entry)
  return none(SkillRegistryEntry)

proc installBundled*(si: SkillInstaller, skillName: string) =
  ## Install a skill from the bundled skills/ directory.
  var bundledDir = getCurrentDir() / "skills" / skillName
  if not dirExists(bundledDir):
    bundledDir = getAppDir() / "skills" / skillName
  let targetDir = si.workspace / "skills" / skillName
  if not dirExists(bundledDir):
    raise newException(IOError, "Bundled skill '$1' not found in skills/".format(skillName))
  if dirExists(targetDir):
    echo "Skill '$1' is already installed.".format(skillName)
    return
  createDir(si.workspace / "skills")
  copyDir(bundledDir, targetDir)
  echo "Installed bundled skill: ", skillName

proc runInstallDeps*(entry: SkillRegistryEntry): string =
  ## Run the install commands from the registry entry. Returns summary.
  if entry.install.len == 0: return ""
  var results: seq[string]
  for cmd in entry.install:
    echo "Running: ", cmd
    let code = execCmd(cmd)
    if code != 0:
      results.add("WARN: '" & cmd & "' exited with code " & $code)
    else:
      results.add("OK: " & cmd)
  return results.join("\n")

proc storeEnvVar*(envVar, value: string): bool =
  ## Append an env var to the nimclaw dir's .env file.
  let envFile = getNimClawDir() / ".env"
  var lines: seq[string]
  if fileExists(envFile):
    for line in readFile(envFile).splitLines():
      if not line.startsWith(envVar & "="):
        lines.add(line)
  lines.add(envVar & "=" & value)
  # Remove trailing empty lines
  while lines.len > 0 and lines[^1].strip() == "": discard lines.pop()
  writeFile(envFile, lines.join("\n") & "\n")
  putEnv(envVar, value)
  return true

proc runConfigure*(entry: SkillRegistryEntry, skillDir: string): string =
  ## Run the configure command template, substituting {skill_dir} and {ENV_VAR}.
  ## Skips if any required env var is missing (avoids overwriting existing config with empty).
  if entry.configure.len == 0: return ""
  var cmd = entry.configure.replace("{skill_dir}", skillDir)
  for envVar in entry.env:
    let val = getEnv(envVar)
    if val.len == 0:
      return "Skipped configure: " & envVar & " not set. Run manually:\n  " &
             entry.configure.replace("{skill_dir}", skillDir)
    cmd = cmd.replace("{" & envVar & "}", val)
  echo "Configuring: ", cmd
  let code = execCmd(cmd)
  if code != 0:
    return "Warning: configure command exited with code " & $code
  return "Configured successfully."

proc installPluginDeps*(entry: SkillRegistryEntry): string =
  ## Install dep packages listed in the registry entry.
  ## Looks up each dep in deps/deps.json and runs its install command.
  if entry.plugins.len == 0: return ""
  var pluginsPath = getCurrentDir() / "deps" / "deps.json"
  if not fileExists(pluginsPath):
    pluginsPath = getAppDir() / "deps" / "deps.json"
  if not fileExists(pluginsPath):
    return "Warning: deps/deps.json not found, skipping deps"
  let pluginsData = parseJson(readFile(pluginsPath))
  var results: seq[string]
  for pluginName in entry.plugins:
    # Check if already installed via check command
    var found = false
    for pl in pluginsData:
      if pl{"name"}.getStr() == pluginName:
        found = true
        let check = pl{"check"}.getStr("")
        if check.len > 0:
          let (_, checkCode) = execCmdEx(check & " 2>/dev/null")
          if checkCode == 0:
            results.add("Plugin '" & pluginName & "' already installed")
            break
        # Not installed — run install command
        let installCmd = pl{"install"}.getStr("")
        if installCmd.len > 0:
          echo "Installing plugin dependency: ", pluginName
          let code = execCmd(installCmd)
          if code != 0:
            results.add("WARN: plugin '" & pluginName & "' install exited with code " & $code)
          else:
            results.add("Installed plugin: " & pluginName)
        break
    if not found:
      results.add("WARN: plugin '" & pluginName & "' not found in plugins.json")
  return results.join("\n")

proc installFromGitHub*(si: SkillInstaller, repo: string, mode: string = "auto", subPath: string = ""): Future[void] {.async.}

proc installByName*(si: SkillInstaller, name: string, envVars: seq[(string, string)] = @[]): Future[string] {.async.} =
  ## Unified install: registry lookup -> bundled/github -> env -> deps -> configure.
  ## Used by both CLI and agent tool.
  ## envVars: pre-supplied env var values (e.g. from agent tool args or CLI prompt).
  let regOpt = findInRegistry(name)
  let targetDir = si.workspace / "skills" / name

  if dirExists(targetDir):
    return "Skill '" & name & "' is already installed at " & targetDir

  # Store any provided env vars first
  for (k, v) in envVars:
    if v.len > 0:
      discard storeEnvVar(k, v)
      echo "Stored ", k, " in .env"

  # 1. Try bundled
  let bundledDir = getCurrentDir() / "skills" / name
  if dirExists(bundledDir) and fileExists(bundledDir / "SKILL.md"):
    si.installBundled(name)
  elif regOpt.isSome:
    # 2. Clone from registry repo
    let entry = regOpt.get()
    if entry.repository.len > 0:
      await si.installFromGitHub(entry.repository, "auto", entry.sub_path)
    else:
      return "Error: no repository URL for skill '" & name & "'"
  else:
    # 3. Try as GitHub URL/shorthand
    await si.installFromGitHub(name)

  # Post-install: plugins -> deps -> configure
  if regOpt.isSome:
    let entry = regOpt.get()
    let pluginResult = installPluginDeps(entry)
    if pluginResult.len > 0:
      echo pluginResult
    let depResult = runInstallDeps(entry)
    if depResult.len > 0:
      echo depResult
    let confResult = runConfigure(entry, targetDir)
    if confResult.len > 0:
      echo confResult

  return "Installed skill: " & name

proc installFromGitHub*(si: SkillInstaller, repo: string, mode: string = "auto", subPath: string = ""): Future[void] {.async.} =
  var repoUrl = repo
  var actualSubPath = subPath
  var skillName = ""

  # Handle --skill flag in the repo string if present
  if " --skill " in repo:
    let parts = repo.split(" --skill ")
    repoUrl = parts[0].strip()
    actualSubPath = parts[1].strip()

  var isGithubFile = repoUrl.contains("blob/") or repoUrl.contains("raw/")

  if repoUrl.startsWith("https://github.com/") and not isGithubFile:
    skillName = lastPathPart(repoUrl)
    if skillName.endsWith(".git"): skillName = skillName[0..^5]
    if actualSubPath.len > 0:
      skillName = skillName & "-" & lastPathPart(actualSubPath)
  elif "/" in repoUrl and not repoUrl.contains("://"):
    repoUrl = "https://github.com/" & repoUrl
    skillName = lastPathPart(repoUrl)
    if actualSubPath.len > 0:
      skillName = skillName & "-" & lastPathPart(actualSubPath)
  else:
    let parts = repoUrl.split("://")
    if parts.len > 1:
      let pathParts = parts[1].split("/")
      if pathParts.len > 1:
        let host = pathParts[0].replace(".", "-")
        let filename = pathParts[^1].replace(".md", "").replace(".zip", "")
        if filename == "skill" or filename == "SKILL":
          skillName = host & "-" & filename
        else:
          skillName = filename
      else:
        skillName = lastPathPart(repoUrl).replace(".md", "")
    else:
      skillName = lastPathPart(repoUrl).replace(".md", "")

  let skillDir = si.workspace / "skills" / skillName

  if dirExists(skillDir):
    echo "Skill '$1' is already installed.".format(skillName)
    return

  if not dirExists(si.workspace / "skills"):
    createDir(si.workspace / "skills")

  var currentMode = mode
  if isGithubFile and currentMode == "auto":
    currentMode = "download"

  var gitSuccess = false
  if currentMode == "auto" or currentMode == "git":
    echo "Attempting to clone repository: ", repoUrl
    let gitExitCode = execCmd("git clone --depth 1 $1 $2".format(repoUrl, skillDir))

    if gitExitCode == 0:
      echo "Skill cloned via Git."
      gitSuccess = true

      if actualSubPath.len > 0:
        let fullSubPath = skillDir / actualSubPath
        if dirExists(fullSubPath):
          echo "Extracting sub-path: ", actualSubPath
          let tempDir = getTempDir() / "nimclaw_skill_extract_" & $getCurrentProcessId()
          createDir(tempDir)
          copyDir(fullSubPath, tempDir)
          removeDir(skillDir)
          createDir(skillDir)
          copyDir(tempDir, skillDir)
          removeDir(tempDir)
        elif fileExists(fullSubPath):
          echo "Extracting single file from sub-path: ", actualSubPath
          let tempFile = getTempDir() / "SKILL.md"
          copyFile(fullSubPath, tempFile)
          removeDir(skillDir)
          createDir(skillDir)
          moveFile(tempFile, skillDir / "SKILL.md")
        else:
          echo "Warning: sub_path '$1' not found in repository.".format(actualSubPath)
    elif currentMode == "git":
      raise newException(IOError, "Git clone failed for repository: " & repoUrl)
    else:
      echo "Git clone failed or git missing. Falling back to direct download..."

  if not gitSuccess and (currentMode == "auto" or currentMode == "download"):
    var downloadUrl = repoUrl
    if not repoUrl.contains("://"):
      downloadUrl = "https://raw.githubusercontent.com/$1/main/SKILL.md".format(repoUrl)
    elif repoUrl.startsWith("https://github.com/"):
      downloadUrl = repoUrl.replace("github.com", "raw.githubusercontent.com") & "/main/SKILL.md"

    let client = newAsyncHttpClient()
    try:
      let response = await client.get(downloadUrl)
      if response.status != $Http200:
        let masterUrl = downloadUrl.replace("/main/", "/master/")
        let masterResp = await client.get(masterUrl)
        if masterResp.status != $Http200:
          raise newException(IOError, "Failed to fetch skill (tried main and master): " & response.status)

        let body = await masterResp.body
        createDir(skillDir)
        writeFile(skillDir / "SKILL.md", body)
      else:
        let body = await response.body
        createDir(skillDir)
        writeFile(skillDir / "SKILL.md", body)

      echo "Skill downloaded directly."
    finally:
      client.close()

proc uninstall*(si: SkillInstaller, skillName: string) =
  let skillDir = si.workspace / "skills" / skillName
  if not dirExists(skillDir):
    raise newException(IOError, "Skill '$1' not found".format(skillName))
  removeDir(skillDir)

proc listAvailableSkills*(si: SkillInstaller): Future[seq[AvailableSkill]] {.async.} =
  ## List available skills from local skills.json, falling back to remote.
  let localPath = getCurrentDir() / "skills" / "skills.json"
  if fileExists(localPath):
    let body = readFile(localPath)
    return parseJson(body).to(seq[AvailableSkill])

  let url = "https://raw.githubusercontent.com/sipeed/nimclaw-skills/main/skills.json"
  let client = newAsyncHttpClient()
  try:
    let response = await client.get(url)
    if response.status != $Http200:
      raise newException(IOError, "Failed to fetch skills list: " & response.status)
    let body = await response.body
    return parseJson(body).to(seq[AvailableSkill])
  finally:
    client.close()
