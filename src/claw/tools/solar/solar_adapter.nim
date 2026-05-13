## solar_adapter.nim — substrate for the multi-vendor solar facade.
##
## Exports helpers consumed by `tools/solar_unified.nim` (the agent-facing
## `solar` tool). Each contract op (plant_list, plant_now, plant_history,
## inverter_list, inverter_alarms) is implemented at the agent surface, which
## either fans out via `findVendorTools` (list ops) or routes per-plant via
## `routeByPlantId` (per-plant ops) — both backed by an in-memory
## plantId → vendor cache populated lazily on the first plant_list call.
##
## Why framework-shipped and not template-shipped: the fan-out + route-by-cache
## pattern needs runtime registry access. An MCP-server living in
## `workspace/skills/solar-adapter/bin/` would need MCP-to-MCP plumbing to
## reach the vendor servers — strictly more complexity. If a second template
## emerges with a similar fan-out pattern, this code can be generalized into
## a `tool_group` framework feature.
##
## Plant → vendor routing:
##   1. First plant_list call populates `plantVendorCache` from each
##      Plant.vendor field in the merged response.
##   2. Per-plant ops consult the cache. Cache miss → call plant_list
##      transparently to populate, then retry.
##   3. Plant IDs are vendor-prefixed per the contract (SG-, HW-, GW-, …),
##      so cold-start routing can fall back to prefix-matching against
##      known installed vendors as a backup.

import std/[asyncdispatch, json, tables, locks]
import ../types, ../registry
import ../vendor_dispatch
import ../../logger
export findVendorTools, dispatchToVendor  # back-compat for callers that
                                          # imported these from solar_adapter

# ── Plant → vendor mapping (in-memory, populated lazily) ──────────

var plantVendorLock: Lock
initLock(plantVendorLock)
var plantVendorCache: Table[string, string]

proc cachePlant*(plantId, vendor: string) =
  if plantId.len == 0 or vendor.len == 0: return
  acquire(plantVendorLock)
  defer: release(plantVendorLock)
  plantVendorCache[plantId] = vendor

proc lookupVendor*(plantId: string): string =
  acquire(plantVendorLock)
  defer: release(plantVendorLock)
  if plantVendorCache.hasKey(plantId): plantVendorCache[plantId] else: ""

# ── Helpers for fanout + routing ──────────────────────────────────
# Exported (cachePlant, lookupVendor, findVendorTools, dispatchToVendor,
# routeByPlantId) so `tools/solar_unified.nim` can compose them into the
# agent-facing `solar` tool. Substrate stays here as `solar_adapter` per
# the substrate-vs-capability naming rule.

proc routeByPlantId*(reg: ToolRegistry, contractTool: string,
                     args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Per-plant routing: look up plant_id in the cache; if missing, prime
  ## the cache by calling plant_list; then dispatch to the resolved vendor.
  if not args.hasKey("plant_id"):
    return """{"error":"missing_plant_id"}"""
  let plantId = args["plant_id"].getStr()
  if plantId.len == 0:
    return """{"error":"empty_plant_id"}"""
  var vendor = lookupVendor(plantId)
  if vendor.len == 0:
    # Cold start: prime cache by fanning out plant_list across vendors
    let vendorTools = findVendorTools(reg, "plant_list")
    for vt in vendorTools:
      try:
        let respStr = await vt.tool.execute(initTable[string, JsonNode]())
        let resp = parseJson(respStr)
        if resp.kind == JArray:
          for plant in resp:
            if plant.kind == JObject and plant.hasKey("id"):
              let pid = plant["id"].getStr()
              let pvendor = if plant.hasKey("vendor"): plant["vendor"].getStr() else: vt.vendor
              cachePlant(pid, pvendor)
      except CatchableError as e:
        warnCF("solar_adapter", "vendor plant_list failed during cold-start cache",
               {"vendor": vt.vendor, "error": e.msg}.toTable)
