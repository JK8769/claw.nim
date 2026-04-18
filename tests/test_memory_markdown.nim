import std/[unittest, os, strutils]
import ../src/nimclaw/tools/[memory, memory_markdown]

suite "MarkdownMemory Tests":
  var baseDir: string

  setup:
    baseDir = getTempDir() / "nimclaw_test_memory"
    if dirExists(baseDir): removeDir(baseDir)
    createDir(baseDir)

  teardown:
    if dirExists(baseDir): removeDir(baseDir)

  test "stores core memory into MEMORY.md":
    let tmpDir = baseDir / "test_store_core"
    createDir(tmpDir)
    let mem = newMarkdownMemory(tmpDir)
    mem.store("fact1", "The sky is blue", toMemoryCategory("core"))
    
    let mdPath = tmpDir / "MEMORY.md"
    check fileExists(mdPath)
    
    let content = readFile(mdPath)
    check content.contains("- **fact1**: The sky is blue")

  test "stores daily memory into memory/YYYY-MM-DD.md":
    let tmpDir = baseDir / "test_store_daily"
    createDir(tmpDir)
    let mem = newMarkdownMemory(tmpDir)
    mem.store("note1", "Learning Nim", toMemoryCategory("daily"))
    
    let memDir = tmpDir / "memory"
    check dirExists(memDir)
    
    var foundFile = false
    for kind, path in walkDir(memDir):
      if kind == pcFile and path.endsWith(".md"):
        foundFile = true
        let content = readFile(path)
        check content.contains("- **note1**: Learning Nim")
    check foundFile

  test "recall and get work on physical files":
    let tmpDir = baseDir / "test_recall_get"
    createDir(tmpDir)
    let mdPath = tmpDir / "MEMORY.md"
    writeFile(mdPath, "- **test_key**: Test content 123\n- **other**: Something else")
    
    let mem = newMarkdownMemory(tmpDir)
    
    let entry = mem.get("test_key")
    check entry.id != ""
    check entry.content == "Test content 123"
    
    let results = mem.recall("test content")
    check results.len > 0
    check results[0].key == "test_key"

  test "list categorizes correctly":
    let tmpDir = baseDir / "test_list"
    createDir(tmpDir)
    let mem = newMarkdownMemory(tmpDir)
    mem.store("kernel", "Linux", toMemoryCategory("core"))
    mem.store("todays_task", "Port Tools", toMemoryCategory("daily"))
    
    let coreListed = mem.list(toMemoryCategory("core"))
    check coreListed.len == 1
    check coreListed[0].content == "Linux"
    
    let dailyListed = mem.list(toMemoryCategory("daily"))
    check dailyListed.len == 1
    check dailyListed[0].content == "Port Tools"

  test "count includes all categories":
    let tmpDir = baseDir / "test_count"
    createDir(tmpDir)
    let mem = newMarkdownMemory(tmpDir)
    check mem.count() == 0
    
    mem.store("a", "1", toMemoryCategory("core"))
    mem.store("b", "2", toMemoryCategory("daily"))
    
    check mem.count() == 2
