import std/unittest
import ../src/nimclaw/tools/shell
import std/[json, tables, asyncdispatch, os, strutils]

suite "Shell Tool Unit Tests":
  test "unwrapMarkdownFence properly strips markdown backticks":
    let input1 = "```bash\necho hello\n```"
    check normalizeCommandInput(input1) == "echo hello"

    let input2 = "   ```\nls -la\n```   "
    check normalizeCommandInput(input2) == "ls -la"

    let input3 = "ps aux"
    check normalizeCommandInput(input3) == "ps aux"

  test "execute explicitly strips dangerous environment variables":
    # 1. Setup our "malicious" environment
    putEnv("NIMCLAW_SECRET_KEY", "super_secret_123")
    
    # 2. Run standard `env` command through our tool (which should be safe)
    var st = newExecTool(".")
    let args = {"command": %"env"}.toTable
    
    let result = waitFor st.execute(args)

    # 3. TDD Expectation: NIMCLAW_SECRET_KEY should NOT be present in the output
    check not result.contains("NIMCLAW_SECRET_KEY=super_secret_123")
    # But safe ones like PATH or PWD should still be there ideally, or at least the secret is gone
    
    # Cleanup
    delEnv("NIMCLAW_SECRET_KEY")
