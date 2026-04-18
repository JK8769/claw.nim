import std/[unittest, json, tables, asyncdispatch, strutils, sequtils]
import ../src/nimclaw/tools/[types, browser_open]

suite "BrowserOpenTool IP & Security":
  test "isLocalOrPrivate blocks localhost variations":
    check isLocalOrPrivate("localhost")
    check isLocalOrPrivate("sub.localhost")
    check isLocalOrPrivate("machine.local")
  
  test "isLocalOrPrivate blocks classic loopback IPs":
    check isLocalOrPrivate("127.0.0.1")
    check isLocalOrPrivate("127.1.1.0")
    check isLocalOrPrivate("::1")
    
  test "isLocalOrPrivate blocks private subnets":
    check isLocalOrPrivate("10.0.0.1")
    check isLocalOrPrivate("192.168.1.100")
    check isLocalOrPrivate("169.254.169.254")
    
  test "isLocalOrPrivate accepts valid public hosts":
    check not isLocalOrPrivate("example.com")
    check not isLocalOrPrivate("google.com")
    check not isLocalOrPrivate("1.1.1.1")

suite "BrowserOpenTool Domain Allowlisting":
  test "hostMatchesAllowlist recognizes exact matches":
    let allowed = @["example.com", "github.com"]
    check hostMatchesAllowlist("example.com", allowed)
    check hostMatchesAllowlist("github.com", allowed)
    
  test "hostMatchesAllowlist recognizes valid subdomains":
    let allowed = @["example.com"]
    check hostMatchesAllowlist("api.example.com", allowed)
    check hostMatchesAllowlist("deep.nested.example.com", allowed)
    
  test "hostMatchesAllowlist rejects impersonation subdomains":
    let allowed = @["example.com"]
    check not hostMatchesAllowlist("notexample.com", allowed)
    check not hostMatchesAllowlist("myexample.com", allowed)
    
  test "hostMatchesAllowlist rejects omitted domains":
    let allowed = @["github.com"]
    check not hostMatchesAllowlist("gitlab.com", allowed)

suite "BrowserOpenTool Execution & Rules":
  test "schema validation":
    let tool = newBrowserOpenTool(@["example.com"])
    check tool.name() == "browser_open"
    let params = tool.parameters()
    check "url" in params["required"].getElems().mapIt(it.getStr())
    
  test "requires url argument":
    let tool = newBrowserOpenTool(@["example.com"])
    let args = initTable[string, JsonNode]()
    let res = waitFor tool.execute(args)
    check "Missing 'url'" in res
    
  test "rejects non-https urls":
    let tool = newBrowserOpenTool(@["example.com"])
    let args = {"url": %"http://example.com"}.toTable
    let res = waitFor tool.execute(args)
    check "Only https://" in res
    
  test "rejects missing host headers":
    let tool = newBrowserOpenTool(@["example.com"])
    let args = {"url": %"https://"}.toTable
    let res = waitFor tool.execute(args)
    check "URL must include" in res
    
  test "rejects missing allowlist configuration completely if empty":
    let tool = newBrowserOpenTool(newSeq[string](0))
    let args = {"url": %"https://example.com"}.toTable
    let res = waitFor tool.execute(args)
    check "No allowed_domains configured" in res
    
  test "rejects unlisted domains":
    let tool = newBrowserOpenTool(@["example.com"])
    let args = {"url": %"https://google.com/search"}.toTable
    let res = waitFor tool.execute(args)
    check "Host is not in browser allowed_domains" in res
    
  test "rejects private IP bindings":
    let tool = newBrowserOpenTool(@["192.168.1.1"])
    let args = {"url": %"https://192.168.1.1/admin"}.toTable
    let res = waitFor tool.execute(args)
    check "Blocked local/private" in res

  test "strips port before domain validation":
    let tool = newBrowserOpenTool(@["example.com"])
    let args = {"url": %"https://example.com:8443/auth"}.toTable
    let res = waitFor tool.execute(args)
    # in test environment we skip calling OS, check success payload bypass
    check "Opened in browser" in res
    
  test "executes bypass securely on standard URLs":
    let tool = newBrowserOpenTool(@["example.com"])
    let args = {"url": %"https://example.com/login?token=123"}.toTable
    let res = waitFor tool.execute(args)
    check "Opened in browser: https://example.com/login" in res
