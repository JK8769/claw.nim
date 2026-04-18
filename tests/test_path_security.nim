import std/[unittest, os, strutils]
import ../src/nimclaw/tools/path_security

suite "Path Security Tests":
  test "isPathSafe blocks null bytes":
    check not isPathSafe("file\x00.txt")

  test "isPathSafe allows safe relative":
    check isPathSafe("file.txt")
    check isPathSafe("src/main.nim")

  test "isPathSafe blocks traversal":
    check not isPathSafe("../../etc/passwd")
    check not isPathSafe("foo/../../../bar")

  test "isPathSafe blocks absolute":
    check not isPathSafe("/etc/passwd")

  test "isPathSafe blocks URL-encoded traversal":
    check not isPathSafe("..%2fetc/passwd")
    check not isPathSafe("%2f..%2fetc/passwd")
    check not isPathSafe("..%5c..%5cwindows")
    check not isPathSafe("..%2Fetc/passwd")

  test "isResolvedPathAllowed allows workspace path":
    check isResolvedPathAllowed("/home/user/workspace/file.txt", "/home/user/workspace", @[])

  test "isResolvedPathAllowed allows exact workspace":
    check isResolvedPathAllowed("/home/user/workspace", "/home/user/workspace", @[])

  test "isResolvedPathAllowed rejects outside workspace":
    check not isResolvedPathAllowed("/home/user/other/file.txt", "/home/user/workspace", @[])

  test "isResolvedPathAllowed rejects partial prefix match":
    check not isResolvedPathAllowed("/home/user/workspace-evil/file.txt", "/home/user/workspace", @[])

  test "isResolvedPathAllowed blocks unix system paths":
    when defined(unix):
      check not isResolvedPathAllowed("/etc/passwd", "/etc", @[])
      check not isResolvedPathAllowed("/System/Library/something", "/home/ws", @["/System"])
      check not isResolvedPathAllowed("/bin/sh", "/home/ws", @["/bin"])
      check not isResolvedPathAllowed("/usr/lib/foo", "/usr/lib", @[])

  test "isResolvedPathAllowed allows via allowedPaths":
    let altPrefix = "/opt/custom_allowed"
    let file = "/opt/custom_allowed/test.txt"
    let ws = "/nonexistent-workspace"
    check isResolvedPathAllowed(file, ws, @[altPrefix])

  test "isResolvedPathAllowed wildcard allows non-system paths":
    check isResolvedPathAllowed("/home/user/random/path.txt", "/nonexistent-workspace", @["*"])

  test "isResolvedPathAllowed wildcard does NOT bypass system blocklist":
    when defined(unix):
      check not isResolvedPathAllowed("/etc/passwd", "/home/user/workspace", @["*"])
    when defined(windows):
      check not isResolvedPathAllowed("C:\\Windows\\System32\\cmd.exe", "C:\\Users\\workspace", @["*"])

  test "pathStartsWith exact match":
    check pathStartsWith("/foo/bar", "/foo/bar")

  test "pathStartsWith with trailing component":
    check pathStartsWith("/foo/bar/baz", "/foo/bar")

  test "pathStartsWith rejects partial":
    check not pathStartsWith("/foo/barbaz", "/foo/bar")
