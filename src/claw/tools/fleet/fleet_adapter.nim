## fleet_adapter.nim — Fleet aggregation facade for multi-vendor solar deployments.
##
## Implements the 5 fleet_* virtual tools per the contract in
## `res/templates/solar-power-station/vendor/CONTRACT.md`:
##
##   fleet_plant_list()                            → fan out + merge
##   fleet_plant_now(plant_id)                     → route by plant→vendor mapping
##   fleet_plant_history(plant_id, from, to)       → route by plant→vendor mapping
##   fleet_inverter_list(plant_id)                 → route by plant→vendor mapping
##   fleet_inverter_alarms(plant_id)               → route by plant→vendor mapping
##
## Each tool scans the live tool registry for matching `mcp_<vendor>_<tool>`
## entries (registered when a vendor's MCP server is loaded at gateway boot),
## fans out to all installed vendors for list operations, and routes per-plant
## operations to the right vendor via an in-memory plant→vendor cache that's
## populated lazily on the first `fleet_plant_list` call.
##
## Why framework-shipped and not template-shipped: the fan-out + route-by-cache
## pattern needs runtime registry access. An MCP-server-implementation living
## in `workspace/skills/fleet-adapter/bin/` would need MCP-to-MCP plumbing to
## reach the vendor servers — strictly more complexity. The fleet adapter
## as framework Nim code uses the registry directly. The solar terminology
## here is the price of having a flagship template; if a second template
## emerges with a similar fan-out pattern, this code can be generalized into
## a `tool_group` framework feature.
##
## Plant→vendor routing convention:
##
##   1. First `fleet_plant_list()` populates `plantVendorCache` from each
##      Plant.vendor field in the merged response.
##   2. Per-plant tools consult the cache. Cache miss → call plant_list
##      transparently to populate, then retry.
##   3. Plant IDs are vendor-prefixed per the contract (SG-, HW-, GW-, …),
##      so cold-start routing can fall back to prefix-matching against
##      known installed vendors as a backup.

import std/[asyncdispatch, json, tables, strutils, locks]
import ../types, ../registry
import ../spec
import ../../logger

# ── Plant → vendor mapping (in-memory, populated lazily) ──────────

var plantVendorLock: Lock
initLock(plantVendorLock)
var plantVendorCache: Table[string, string]

proc cachePlant(plantId, vendor: string) =
  if plantId.len == 0 or vendor.len == 0: return
  acquire(plantVendorLock)
  defer: release(plantVendorLock)
  plantVendorCache[plantId] = vendor

proc lookupVendor(plantId: string): string =
  acquire(plantVendorLock)
  defer: release(plantVendorLock)
  if plantVendorCache.hasKey(plantId): plantVendorCache[plantId] else: ""

# ── Helpers for fanout + routing ──────────────────────────────────

proc findVendorTools(reg: ToolRegistry,
                      contractTool: string): seq[tuple[vendor: string, tool: Tool]] =
  ## Scan the registry for tools matching `mcp_<vendor>_<contractTool>`.
  ## Returns (vendor, tool) pairs sorted by registration order.
  ## The contract tool name (e.g. "plant_list") is matched as a suffix on
  ## the registered tool name. Vendor name is whatever sits between
  ## `mcp_` and `_<contractTool>`.
  result = @[]
  let suffix = "_" & contractTool
  for name in reg.list():
    if not name.startsWith("mcp_"): continue
    if not name.endsWith(suffix): continue
    # Extract vendor: strip mcp_ prefix and _<contractTool> suffix
    let inner = name[4 ..< name.len - suffix.len]
    # Inner may still have a server-prefix component (e.g. mcp_sungrow_sungrow_plant_list
    # if the MCP server prefixes its own tools). For the fleet adapter, treat
    # the leftmost segment as the vendor name.
    let underscoreIdx = inner.find('_')
    let vendor = if underscoreIdx > 0: inner[0 ..< underscoreIdx] else: inner
    if vendor.len == 0: continue
    let (tool, ok) = reg.get(name)
    if ok: result.add((vendor: vendor, tool: tool))

proc dispatchToVendor(reg: ToolRegistry, vendor, contractTool: string,
                      args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Locate and call the named vendor's tool. Returns the vendor's raw
  ## response. Empty string + warning log on miss.
  let vendorTools = findVendorTools(reg, contractTool)
  for vt in vendorTools:
    if vt.vendor == vendor:
      return await vt.tool.execute(args)
  warnCF("fleet_adapter", "vendor not installed for contract tool",
         {"vendor": vendor, "contract": contractTool}.toTable)
  return """{"error":"vendor_not_installed","vendor":"""" & vendor & """","contract":"""" & contractTool & """"}"""

proc routeByPlantId(reg: ToolRegistry, contractTool: string,
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
        warnCF("fleet_adapter", "vendor plant_list failed during cold-start cache",
               {"vendor": vt.vendor, "error": e.msg}.toTable)
    vendor = lookupVendor(plantId)
  if vendor.len == 0:
    return """{"error":"plant_not_found","plant_id":"""" & plantId & """"}"""
  return await dispatchToVendor(reg, vendor, contractTool, args)

# ── Tool implementations ──────────────────────────────────────────

const PlantListSpec* = spec(
  name = "fleet_plant_list",
  description = "List all plants across every installed inverter vendor. Returns array of Plant objects, each tagged with its vendor for routing. Multi-vendor capable.",
  tags = @["fleet", "solar", "domain"],
  searchKeywords = @["plant list", "fleet", "all plants", "list plants"],
  domain = "fleet",
  default = false, heartbeatSafe = false, category = "fleet",
)

const PlantNowSpec* = spec(
  name = "fleet_plant_now",
  description = "Real-time state for one plant (current power, today's yield, status). Routes to the correct vendor automatically via plant→vendor mapping.",
  tags = @["fleet", "solar", "domain"],
  searchKeywords = @["plant now", "current power", "real-time", "today yield"],
  domain = "fleet",
  default = false, heartbeatSafe = false, category = "fleet",
)

const PlantHistorySpec* = spec(
  name = "fleet_plant_history",
  description = "Daily yield history for one plant over a date range. Returns array of YieldPoint records with data_quality flags.",
  tags = @["fleet", "solar", "domain"],
  searchKeywords = @["plant history", "yield", "historical", "kwh"],
  domain = "fleet",
  default = false, heartbeatSafe = false, category = "fleet",
)

const InverterListSpec* = spec(
  name = "fleet_inverter_list",
  description = "List inverters under one plant. Returns array of Inverter records with status.",
  tags = @["fleet", "solar", "domain"],
  searchKeywords = @["inverter", "equipment", "devices"],
  domain = "fleet",
  default = false, heartbeatSafe = false, category = "fleet",
)

const InverterAlarmsSpec* = spec(
  name = "fleet_inverter_alarms",
  description = "Active alarms on inverters under one plant. Returns array of Alarm records with severity classification.",
  tags = @["fleet", "solar", "domain"],
  searchKeywords = @["alarm", "fault", "alert", "alarm list"],
  domain = "fleet",
  default = false, heartbeatSafe = false, category = "fleet",
)

type
  FleetPlantListTool* = ref object of Tool
    reg: ToolRegistry
  FleetPlantNowTool* = ref object of Tool
    reg: ToolRegistry
  FleetPlantHistoryTool* = ref object of Tool
    reg: ToolRegistry
  FleetInverterListTool* = ref object of Tool
    reg: ToolRegistry
  FleetInverterAlarmsTool* = ref object of Tool
    reg: ToolRegistry

proc newFleetPlantListTool*(reg: ToolRegistry): FleetPlantListTool = FleetPlantListTool(reg: reg)
proc newFleetPlantNowTool*(reg: ToolRegistry): FleetPlantNowTool = FleetPlantNowTool(reg: reg)
proc newFleetPlantHistoryTool*(reg: ToolRegistry): FleetPlantHistoryTool = FleetPlantHistoryTool(reg: reg)
proc newFleetInverterListTool*(reg: ToolRegistry): FleetInverterListTool = FleetInverterListTool(reg: reg)
proc newFleetInverterAlarmsTool*(reg: ToolRegistry): FleetInverterAlarmsTool = FleetInverterAlarmsTool(reg: reg)

# fleet_plant_list — fan out across vendors, merge arrays
method name*(t: FleetPlantListTool): string = "fleet_plant_list"
method description*(t: FleetPlantListTool): string = PlantListSpec.description
method parameters*(t: FleetPlantListTool): Table[string, JsonNode] =
  {"type": %"object", "properties": %*{}, "required": %*[]}.toTable

method execute*(t: FleetPlantListTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let vendors = findVendorTools(t.reg, "plant_list")
  if vendors.len == 0: return "[]"
  var merged = newJArray()
  for v in vendors:
    try:
      let respStr = await v.tool.execute(initTable[string, JsonNode]())
      let resp = parseJson(respStr)
      if resp.kind == JArray:
        for plant in resp:
          if plant.kind == JObject and plant.hasKey("id"):
            let pid = plant["id"].getStr()
            let pvendor = if plant.hasKey("vendor"): plant["vendor"].getStr() else: v.vendor
            cachePlant(pid, pvendor)
          merged.add(plant)
      elif resp.kind == JObject and resp.hasKey("error"):
        warnCF("fleet_adapter", "vendor plant_list returned error",
               {"vendor": v.vendor, "error": resp["error"].getStr()}.toTable)
    except CatchableError as e:
      warnCF("fleet_adapter", "vendor plant_list raised",
             {"vendor": v.vendor, "error": e.msg}.toTable)
  return $merged

# Per-plant tools — route by plant_id
method name*(t: FleetPlantNowTool): string = "fleet_plant_now"
method description*(t: FleetPlantNowTool): string = PlantNowSpec.description
method parameters*(t: FleetPlantNowTool): Table[string, JsonNode] =
  {"type": %"object",
   "properties": %*{"plant_id": {"type": "string", "description": "The plant's vendor-prefixed ID, e.g. SG-12345"}},
   "required": %*["plant_id"]}.toTable
method execute*(t: FleetPlantNowTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  return await routeByPlantId(t.reg, "plant_now", args)

method name*(t: FleetPlantHistoryTool): string = "fleet_plant_history"
method description*(t: FleetPlantHistoryTool): string = PlantHistorySpec.description
method parameters*(t: FleetPlantHistoryTool): Table[string, JsonNode] =
  {"type": %"object",
   "properties": %*{
     "plant_id": {"type": "string", "description": "Vendor-prefixed plant ID"},
     "from": {"type": "string", "format": "date", "description": "ISO-8601 start date inclusive"},
     "to": {"type": "string", "format": "date", "description": "ISO-8601 end date inclusive"}},
   "required": %*["plant_id", "from", "to"]}.toTable
method execute*(t: FleetPlantHistoryTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  return await routeByPlantId(t.reg, "plant_history", args)

method name*(t: FleetInverterListTool): string = "fleet_inverter_list"
method description*(t: FleetInverterListTool): string = InverterListSpec.description
method parameters*(t: FleetInverterListTool): Table[string, JsonNode] =
  {"type": %"object",
   "properties": %*{"plant_id": {"type": "string", "description": "Vendor-prefixed plant ID"}},
   "required": %*["plant_id"]}.toTable
method execute*(t: FleetInverterListTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  return await routeByPlantId(t.reg, "inverter_list", args)

method name*(t: FleetInverterAlarmsTool): string = "fleet_inverter_alarms"
method description*(t: FleetInverterAlarmsTool): string = InverterAlarmsSpec.description
method parameters*(t: FleetInverterAlarmsTool): Table[string, JsonNode] =
  {"type": %"object",
   "properties": %*{"plant_id": {"type": "string", "description": "Vendor-prefixed plant ID"}},
   "required": %*["plant_id"]}.toTable
method execute*(t: FleetInverterAlarmsTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  return await routeByPlantId(t.reg, "inverter_alarms", args)
