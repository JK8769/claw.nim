import std/unittest
import ../src/nimclaw/tools/filesystem
import std/[json, tables, asyncdispatch, os, strutils]

suite "Filesystem Tool Integration Tests":
  test "ReadFileTool blocks relative traversal outside workspace":
    var t = newReadFileTool("/tmp/safe_workspace")
    let args = {"path": %"../unsafe.txt"}.toTable
    let result = waitFor t.execute(args)
    check result.contains("not allowed (contains traversal")

  test "WriteFileTool blocks absolute path writes when allowedPaths is empty":
    var t = newWriteFileTool("/tmp/safe_workspace")
    let args = {"path": %"/etc/passwd", "content": %"hacked"}.toTable
    let result = waitFor t.execute(args)
    check result.contains("absolute paths not allowed")

  test "ListDirTool blocks system paths even if absolute paths loosely permitted":
    createDir("/tmp/safe_workspace")
    var t = newListDirTool("/tmp/safe_workspace", "", @["*"])
    let args = {"path": %"/etc"}.toTable
    let result = waitFor t.execute(args)
    check result.contains("outside allowed areas or blocked by security policy")
