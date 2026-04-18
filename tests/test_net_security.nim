import std/unittest
import ../src/nimclaw/net_security

suite "net_security Tests":
  test "extractHost basic":
    check extractHost("https://example.com/path") == "example.com"
    check extractHost("http://example.com") == "example.com"
    check extractHost("https://api.example.com/v1") == "api.example.com"

  test "extractHost with port":
    check extractHost("http://localhost:8080/api") == "localhost"

  test "extractHost strips userinfo safely":
    check extractHost("http://user:pass@127.0.0.1/admin") == "127.0.0.1"
    check extractHost("https://user@example.com/path") == "example.com"

  test "extractHost handles bracketed ipv6":
    check extractHost("http://[::1]:8080/api") == "[::1]"
    check extractHost("https://[2607:f8b0::1]/") == "[2607:f8b0::1]"

  test "extractHost parses unbracketed ipv6 authority with port":
    check extractHost("http://::1:8080/api") == "::1"

  test "extractHost rejects invalid bracketed authority":
    check extractHost("http://[::1") == ""

  test "extractHost rejects percent-encoded host bypass":
    check extractHost("http://%31%32%37%2e%30%2e%30%2e%31/secret") == ""
    check extractHost("http://%6c%6f%63%61%6c%68%6f%73%74/admin") == ""

  test "extractHost returns empty for non-http scheme":
    check extractHost("ftp://example.com") == ""
    check extractHost("file:///etc/passwd") == ""

  test "extractHost returns empty for empty host":
    check extractHost("http:///path") == ""
    check extractHost("https:///") == ""

  test "isLocalHost detects localhost":
    check isLocalHost("localhost")
    check isLocalHost("foo.localhost")
    check isLocalHost("127.0.0.1")
    check isLocalHost("0.0.0.0")
    check isLocalHost("::1")

  test "isLocalHost detects private ranges":
    check isLocalHost("10.0.0.1")
    check isLocalHost("192.168.1.1")
    check isLocalHost("172.16.0.1")
    check isLocalHost("172.31.255.255")

  test "isLocalHost ignores public ranges":
    check not isLocalHost("8.8.8.8")
    check not isLocalHost("example.com")
    check not isLocalHost("1.1.1.1")

  test "isLocalHost ignores non-private 172 ranges":
    check not isLocalHost("172.15.0.1")
    check not isLocalHost("172.32.0.1")

  test "isLocalHost detects bracketed IPv6":
    check isLocalHost("[::1]")

  test "isLocalHost detects 127.x.x.x range":
    check isLocalHost("127.0.0.1")
    check isLocalHost("127.0.0.2")
    check isLocalHost("127.255.255.255")

  test "isLocalHost detects .local TLD":
    check isLocalHost("myhost.local")

  test "isLocalHost blocks IPv6 with zone id suffix":
    check isLocalHost("fe80::1%lo0")
    check isLocalHost("fe80::1%25lo0")
    check isLocalHost("[fe80::1%25lo0]")

  test "isLocalHost blocks link-local and unique local IPv6":
    check isLocalHost("fd00::1")
    check isLocalHost("fe80::1")

  test "parseIpv4IntegerAlias parses decimal alias":
    check isLocalHost("2130706433") # 127.0.0.1

  test "parseIpv4IntegerAlias parses hex alias":
    check isLocalHost("0x7f000001") # 127.0.0.1
