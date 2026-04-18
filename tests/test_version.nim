import std/unittest
import ../src/nimclaw/version

suite "CLI Version":
  test "version string is not empty":
    check versionString().len > 0
    echo "Current version: ", versionString()
