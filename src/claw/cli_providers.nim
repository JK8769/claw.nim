import std/[os, json, strutils, tables, asyncdispatch]
import agent/cortex, config, providers/http, providers/types, logger, utils

proc modelName(m: JsonNode): string =
  ## Extract model name from either a string or {"name": "..."} object.
  if m.kind == JString: m.getStr()
  elif m.kind == JObject: m{"name"}.getStr("")
  else: ""

proc updateEnvFile(keyName, keyValue: string) =
  ## Appends or updates a key in the .env file
  let envPath = getNimClawDir() / ".env"
  var lines: seq[string] = @[]
  var found = false
  
  if fileExists(envPath):
    for line in readFile(envPath).splitLines():
      if line.startsWith(keyName & "="):
        lines.add(keyName & "=" & keyValue)
        found = true
      elif line.strip().len > 0:
        lines.add(line)
  
  if not found:
    lines.add(keyName & "=" & keyValue)
    
  writeFile(envPath, lines.join("\n") & "\n")
  putEnv(keyName, keyValue)
  infoCF("cli_providers", "Updated .env file", {"key": keyName}.toTable)

proc testConnection*(apiBase, apiKey, model: string): tuple[success: bool, error: string] =
  ## Attempts a minimal chat request to verify the provider configuration
  try:
    # Use expandEnv if it's an env var reference
    let expandedKey = expandEnv(apiKey)
    let p = newHTTPProvider(expandedKey, apiBase, model, 30)
    
    # We send a very minimal "hello" to check connectivity
    # Increasing tokens significantly to 500 for reasoning models.
    let resp = waitFor p.chat(@[Message(role: "user", content: "hi")], @[], model, {"max_tokens": %500}.toTable)
    
    # If we got a valid response with either content, tool calls, or even just a finish reason (like length),
    # then the provider is technically ONLINE and the key is valid.
    if resp.content.strip().len > 0 or resp.tool_calls.len > 0 or resp.finish_reason != "":
      return (true, "")
    else:
      return (false, "Empty response from provider (possible reasoning model or low token limit)")
  except Exception as e:
    return (false, e.msg)

proc runProviderCommand*(cfg: Config, args: seq[string], api_key = "", api_base = "", model = "", asJson: bool = false): string =
  ## Manage LLM providers in the World Graph
  let action = if args.len > 0: args[0] else: "list"
  let graph = loadWorld(cfg.workspacePath())
  let graphFile = getConfigPath().parentDir() / "BASE.json"

  case action
  of "list":
    if asJson:
      var arr = newJArray()
      for name, p in graph.providers.fields:
        arr.add(%*{
          "name": name,
          "apiBase": p{"apiBase"}.getStr(""),
          "apiKey": p{"apiKey"}.getStr(""),
          "defaultModel": p{"defaultModel"}.getStr(""),
          "models": p{"models"}
        })
      return $arr
    var output = "Configured Providers in Vault:\n"
    for name, p in graph.providers.fields:
      let base = p{"apiBase"}.getStr("N/A")
      let key = p{"apiKey"}.getStr("N/A")
      output.add("- $1: $2 (Key: $3)\n".format(name, base, key))
    return output

  of "add":
    var name = if args.len > 1: args[1] else: ""
    var finalBase = api_base
    var finalKey = api_key
    var finalModel = model
    var finalModels: seq[string] = @[]

    let templateDir = getTemplateDir() / "provider"
    var availableTemplates: seq[string] = @[]
    if dirExists(templateDir):
      for file in walkDir(templateDir):
        if file.kind == pcFile and file.path.endsWith(".json"):
          availableTemplates.add(file.path.lastPathPart().changeFileExt(""))
    
    # 1. Interactive Selection if no name
    if name == "":
      name = selectInput("Please Select ↕ Or Enter a provider below.", availableTemplates)
    
    if name == "": return "Error: Provider name required."

    # 2. Load Template if exists
    let templatePath = templateDir / name.toLowerAscii() & ".json"
    if fileExists(templatePath):
      try:
        let tData = parseFile(templatePath)
        if finalBase == "": finalBase = tData{"apiBase"}.getStr("")
        if finalModel == "": finalModel = tData{"defaultModel"}.getStr("")
        if tData.hasKey("models"):
          for m in tData["models"]:
            let mn = modelName(m)
            if mn.len > 0: finalModels.add(mn)
        echo "📂 Loaded provider template for $1 with \"defaultModel\": \"$2\"".format(name, finalModel)
      except:
        echo "⚠️ Error loading template: ", getCurrentExceptionMsg()

    # 3. Collaborative Guided Prompts
    if finalBase == "":
      stdout.write "Base URL (e.g., https://api.deepseek.com): "
      finalBase = stdin.readLine().strip()

    var setupDone = false
    while not setupDone:
      if finalKey == "":
        stdout.write "Enter your API key for $1 (or nothing to cancel).\n".format(name)
        finalKey = readMaskedInput(": ")

      if finalKey == "": 
        echo "❌ Cancelled. Provider '$1' not added.".format(name)
        return "Cancelled."

      # Secret Management Logic (ENV preservation)
      var envVarName = ""
      var testKey = finalKey
      if finalKey.startsWith("${") and finalKey.endsWith("}"):
        envVarName = finalKey[2..^2]
        testKey = expandEnv(finalKey)
      else:
        envVarName = name.toUpperAscii() & "_API_KEY"

      if finalModel == "":
        if finalModels.len > 0:
          echo "Suggested models: ", finalModels.join(", ")
          finalModel = finalModels[0]
        
        stdout.write "Default Model [$1]: ".format(if finalModel != "": finalModel else: "auto")
        let inputModel = stdin.readLine().strip()
        if inputModel != "": finalModel = inputModel

      # Automatic Verification
      if finalModel != "":
        echo "🧪 Testing connection to $1...".format(name)
        let (success, error) = testConnection(finalBase, testKey, finalModel)
        if success:
          echo "✨ Connection successful! Provider is ready to use."
          if not finalKey.startsWith("${"):
            updateEnvFile(envVarName, finalKey)
            finalKey = "${" & envVarName & "}"
            echo "🛡️  Raw key detected. Stored in .env as ", envVarName
          setupDone = true
        else:
          echo "⚠️  Connection test failed: ", error
          stdout.write "\nEnter your API key for $1 again (or nothing to cancel).\n".format(name)
          let nextKey = readMaskedInput(": ")
          if nextKey == "":
            echo "❌ Cancelled. Provider '$1' not added.".format(name)
            return "Cancelled."
          else:
            finalKey = nextKey
            testKey = nextKey # Update test key for next iteration
      else:
        if not finalKey.startsWith("${"):
          let evn = name.toUpperAscii() & "_API_KEY"
          updateEnvFile(evn, finalKey)
          finalKey = "${" & evn & "}"
        setupDone = true

    ## Update Vault
    var providerNode = %*{
      "name": name.capitalizeAscii(),
      "apiBase": finalBase,
      "apiKey": finalKey
    }
    if finalModel != "": providerNode["defaultModel"] = %finalModel
    if finalModels.len > 0:
      var mNodes: seq[JsonNode] = @[]
      for m in finalModels: mNodes.add(%m)
      # Ensure default model is in the list
      if finalModel != "" and finalModel notin finalModels:
        mNodes.add(%finalModel)
      providerNode["models"] = %mNodes
    
    graph.providers[name] = providerNode
    
    # Update Graph File
    let node = toLD(graph)
    writeFile(graphFile, node.pretty())
    
    echo "✅ Provider '$1' added successfully.".format(name)
    return "Done."

  of "remove":
    if args.len < 2: return "Error: Usage: provider remove <name>"
    let name = args[1]
    if not graph.providers.hasKey(name): return "Error: Provider '$1' not found in Vault.".format(name)
    
    graph.providers.delete(name)
    let node = toLD(graph)
    writeFile(graphFile, node.pretty())
    return "🗑️ Provider '$1' removed.".format(name)

  of "health":
    let checkAll = args.contains("--all")
    var results = "Checking Health of Configured Providers" & (if checkAll: " (All Models):\n" else: ":\n")
    
    for name, p in graph.providers.fields:
      let base = p{"apiBase"}.getStr("")
      let key = p{"apiKey"}.getStr("")
      let defaultModel = p{"defaultModel"}.getStr("")
      let models = p{"models"}.getElems()
      
      if base == "" or key == "":
        results.add("- ⚠️  $1: Missing configuration (Base or Key)\n".format(name))
        continue

      var modelsToTest: seq[string] = @[]
      if checkAll and models.len > 0:
        for m in models:
          let mn = modelName(m)
          if mn.len > 0: modelsToTest.add(mn)
      elif defaultModel != "":
        modelsToTest.add(defaultModel)
      elif models.len > 0:
        modelsToTest.add(modelName(models[0]))
      else:
        # Final fallback, though we should prefer configured ones
        modelsToTest.add("gpt-4o-mini")

      results.add("- $1:\n".format(name))
      for testModel in modelsToTest:
        stdout.write "  🧪 Checking $1... ".format(testModel)
        stdout.flushFile()
        
        let (success, error) = testConnection(base, key, testModel)
        if success:
          results.add("  - ✨ $1: Online\n".format(testModel))
          echo "✨ Online"
        else:
          results.add("  - ❌ $1: Offline ($2)\n".format(testModel, error))
          echo "❌ Offline"
    
    return results

  else:
    return "Unknown provider subcommand: " & action
