## vendor_dispatch — generic helpers for tools that route to per-vendor
## MCP-server implementations.
##
## The pattern: a vendor MCP server registers tools named
## `mcp_<vendor>_<operation>` at gateway boot. A unified facade tool
## (solar, channel, etc.) scans the registry for matches and dispatches.
##
## Used by:
##   solar_adapter (solar_unified) — vendor = sungrow / huawei / goodwe / …
##   channel_unified              — vendor = feishu / lark / … for vendor-
##                                   unique features (docs / sheets / …)
##
## Operations specific to a particular facade (e.g. solar's plant→vendor
## cache + routeByPlantId) stay in that facade's own adapter file —
## this module is for the universally-applicable scan + dispatch.

import std/[asyncdispatch, json, tables, strutils]
import ./types
import ./registry
import ../logger

proc findVendorTools*(reg: ToolRegistry,
                      contractTool: string): seq[tuple[vendor: string, tool: Tool]] =
  ## Scan the registry for tools matching `mcp_<vendor>_<contractTool>`.
  ## Returns (vendor, tool) pairs in registration order. Vendor is the
  ## leftmost name segment between `mcp_` and `_<contractTool>`.
  result = @[]
  let suffix = "_" & contractTool
  for name in reg.list():
    if not name.startsWith("mcp_"): continue
    if not name.endsWith(suffix): continue
    let inner = name[4 ..< name.len - suffix.len]
    let underscoreIdx = inner.find('_')
    let vendor = if underscoreIdx > 0: inner[0 ..< underscoreIdx] else: inner
    if vendor.len == 0: continue
    let (tool, ok) = reg.get(name)
    if ok: result.add((vendor: vendor, tool: tool))

proc dispatchToVendor*(reg: ToolRegistry, vendor, contractTool: string,
                       args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Locate and call the named vendor's tool. Returns the vendor's raw
  ## response. Logs + returns a JSON error envelope when no match.
  let vendorTools = findVendorTools(reg, contractTool)
  for vt in vendorTools:
    if vt.vendor == vendor:
      return await vt.tool.execute(args)
  warnCF("vendor_dispatch", "vendor not installed for contract tool",
         {"vendor": vendor, "contract": contractTool}.toTable)
  return """{"error":"vendor_not_installed","vendor":"""" & vendor &
         """","contract":"""" & contractTool & """"}"""
