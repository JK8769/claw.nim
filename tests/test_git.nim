import std/[unittest, json, tables, strutils, asyncdispatch]
import ../src/nimclaw/tools/types
import ../src/nimclaw/tools/git

suite "GitTool Tests":
  setup:
    let ws = "/tmp"
    let tool = newGitTool(ws, @[])
    
  test "tool name":
    check tool.name() == "git_operations"

  test "schema has operation required":
    let params = tool.parameters()
    check params["required"].getElems().contains(%"operation")
    check params["properties"].hasKey("operation")

  test "rejects missing operation":
    let args = {"cwd": %ws}.toTable
    let result = waitFor tool.execute(args)
    check not result.startsWith("Status:") and "operation" in result.toLowerAscii()

  test "rejects unknown operation":
    let args = {"operation": %"push"}.toTable
    let result = waitFor tool.execute(args)
    check "unknown operation" in result.toLowerAscii()

  test "blocks unsafe args in execution":
    let args = {"operation": %"commit", "message": %"$(evil)"}.toTable
    let result = waitFor tool.execute(args)
    check "unsafe" in result.toLowerAscii()

  test "blocks unsafe args in paths array":
    let args = {"operation": %"add", "paths": %["file.txt; rm -rf /"]}.toTable
    let result = waitFor tool.execute(args)
    check "unsafe" in result.toLowerAscii()

  test "blocks unsafe args in paths string":
    let args = {"operation": %"add", "paths": %"file.txt; rm -rf /"}.toTable
    let result = waitFor tool.execute(args)
    check "unsafe" in result.toLowerAscii()
    
suite "GitTool sanitizeGitArgs tests":
  test "blocks --exec=cmd":
    check not sanitizeGitArgs("--exec=rm -rf /")

  test "blocks --upload-pack=evil":
    check not sanitizeGitArgs("--upload-pack=evil")

  test "blocks --no-verify":
    check not sanitizeGitArgs("--no-verify")

  test "blocks command substitution $()":
    check not sanitizeGitArgs("$(evil)")

  test "blocks backtick":
    check not sanitizeGitArgs("`malicious`")

  test "blocks pipe":
    check not sanitizeGitArgs("arg | cat /etc/passwd")

  test "blocks semicolon":
    check not sanitizeGitArgs("arg; rm -rf /")

  test "blocks redirect":
    check not sanitizeGitArgs("file.txt > /tmp/out")

  test "blocks -c config injection":
    check not sanitizeGitArgs("-c core.sshCommand=evil")
    check not sanitizeGitArgs("-c=core.pager=less")
    check not sanitizeGitArgs("-C=core.pager=less")

  test "blocks --pager and --editor":
    check not sanitizeGitArgs("--pager=less")
    check not sanitizeGitArgs("--editor=vim")

  test "allows --oneline":
    check sanitizeGitArgs("--oneline")

  test "allows --stat":
    check sanitizeGitArgs("--stat")

  test "allows safe branch names":
    check sanitizeGitArgs("main")
    check sanitizeGitArgs("feature/test-branch")
    check sanitizeGitArgs("src/main.nim")
    check sanitizeGitArgs(".")

  test "allows --cached (not blocked by -c check)":
    check sanitizeGitArgs("--cached")
    check sanitizeGitArgs("-cached")

suite "GitTool truncateCommitMessage tests":
  test "short message unchanged":
    let msg = "short message"
    check truncateCommitMessage(msg, 2000) == msg

  test "truncates at UTF-8 boundary":
    let msg = "Éééééé ààà!"
    let truncated = truncateCommitMessage(msg, 10)
    check truncated.len <= 10

  test "exact boundary":
    let msg = "hello"
    check truncateCommitMessage(msg, 5) == "hello"
    check truncateCommitMessage(msg, 100) == "hello"
