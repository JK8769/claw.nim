## solar — agent-facing tool for the multi-vendor solar power station facade.
##
## Five actions (plant_list / plant_now / plant_history / inverter_list /
## inverter_alarms) all dispatch through `solar_adapter` helpers, which scan
## the registry for `mcp_<vendor>_<contract-tool>` entries and either fan out
## (list ops) or route by plant→vendor cache (per-plant ops). Vendor MCP
## contract lives in `res/templates/solar-power-station/vendor/CONTRACT.md`.

import std/[json, asyncdispatch, tables]
import ./types
import ./spec
import ./registry
import ./solar/solar_adapter
import ../logger  # warnCF — fan-out error paths in doPlantList

const ToolSpec* = spec(
  name = "solar",
  description = "Solar power station fleet — multi-vendor facade " &
                "(method=plant_list|plant_now|plant_history|" &
                "inverter_list|inverter_alarms). Fans out for list ops, " &
                "routes per-plant ops by plant→vendor cache.",
  tags = @["solar", "fleet", "domain"],
  searchKeywords = @["plant list", "fleet", "all plants",
                      "plant now", "current power", "real-time",
                      "today yield", "plant history", "yield",
                      "historical", "kwh", "inverter", "equipment",
                      "devices", "alarm", "fault", "alert"],
  domain = "solar",
  default = false,
  heartbeatSafe = false,
  category = "solar",
)

type
  SolarTool* = ref object of Tool
    reg*: ToolRegistry  ## live tool registry — scanned per-call to find
                        ## `mcp_<vendor>_<contract-tool>` entries (registered
                        ## when the vendor MCP servers loaded at boot)

proc newSolarTool*(reg: ToolRegistry): SolarTool =
  SolarTool(reg: reg)

method name*(t: SolarTool): string = "solar"

method description*(t: SolarTool): string =
  "Solar power station fleet — multi-vendor facade. Fans out across every installed " &
  "inverter-vendor MCP server for list operations, and routes per-plant " &
  "operations to the right vendor automatically via an in-memory plant→vendor " &
  "cache (primed on the first plant_list call).\n\n" &
  "Actions:\n" &
  "  plant_list       — list all plants across every installed vendor; " &
  "returns array of Plant objects each tagged with its vendor for routing.\n" &
  "  plant_now        — real-time state for one plant (current power, " &
  "today's yield, status). Required: id.\n" &
  "  plant_history    — daily yield history for one plant over a date range; " &
  "returns array of YieldPoint records with data_quality flags. " &
  "Required: id, from, to.\n" &
  "  inverter_list    — list inverters under one plant; returns array of " &
  "Inverter records with status. Required: plant_id.\n" &
  "  inverter_alarms  — active alarms on inverters under one plant; returns " &
  "array of Alarm records with severity classification. Required: plant_id."

method parameters*(t: SolarTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["plant_list", "plant_now", "plant_history",
                 "inverter_list", "inverter_alarms"],
        "description": "Operation to perform"
      },
      # --- method=plant_now / plant_history ---
      "id": {
        "type": "string",
        "description":
          "plant_now / plant_history: the plant's vendor-prefixed ID, " &
          "e.g. 'SG-12345'. Routes the call to the vendor that owns the plant."
      },
      # --- method=inverter_list / inverter_alarms ---
      "plant_id": {
        "type": "string",
        "description":
          "inverter_list / inverter_alarms: vendor-prefixed plant ID " &
          "(e.g. 'SG-12345')."
      },
      # --- method=plant_history ---
      "from": {
        "type": "string",
        "format": "date",
        "description":
          "plant_history only — ISO-8601 start date inclusive (e.g. '2026-05-01')."
      },
      "to": {
        "type": "string",
        "format": "date",
        "description":
          "plant_history only — ISO-8601 end date inclusive (e.g. '2026-05-13')."
      }
    },
    "required": %["method"]
  }.toTable

# ---------------------------------------------------------------------------
# method=plant_list — fan out across every vendor and merge the arrays.
# ---------------------------------------------------------------------------

proc doPlantList(t: SolarTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Scan registry for every `mcp_<vendor>_plant_list`, call each, prime the
  ## plant→vendor cache from the per-Plant `vendor` field (or fall back to the
  ## discovered vendor name), merge results into a single JSON array.
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
        warnCF("solar_adapter", "vendor plant_list returned error",
               {"vendor": v.vendor, "error": resp["error"].getStr()}.toTable)
    except CatchableError as e:
      warnCF("solar_adapter", "vendor plant_list raised",
             {"vendor": v.vendor, "error": e.msg}.toTable)
  return $merged

# ---------------------------------------------------------------------------
# Argument shaping for per-plant routes.
# The agent surface uses `id` for plant_now / plant_history (matching the
# README convention "the plant's vendor-prefixed ID"); `routeByPlantId`
# expects `plant_id`, so we translate.
# ---------------------------------------------------------------------------

proc forwardArgsAsPlantId(args: Table[string, JsonNode],
                           sourceKey: string): Table[string, JsonNode] =
  ## Copy args verbatim but ensure a `plant_id` key exists, sourced from
  ## `args[sourceKey]` if `plant_id` itself isn't already present. Lets
  ## the vendor MCP keep accepting `plant_id` regardless of which name the
  ## agent-facing surface uses.
  result = args
  if not result.hasKey("plant_id") and args.hasKey(sourceKey):
    result["plant_id"] = args[sourceKey]

# ---------------------------------------------------------------------------
# method=plant_now — route by plant → vendor.
# ---------------------------------------------------------------------------

proc doPlantNow(t: SolarTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let forwarded = forwardArgsAsPlantId(args, "id")
  return await routeByPlantId(t.reg, "plant_now", forwarded)

# ---------------------------------------------------------------------------
# method=plant_history — route by plant → vendor.
# ---------------------------------------------------------------------------

proc doPlantHistory(t: SolarTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## from / to date args ride along untouched in the args table.
  let forwarded = forwardArgsAsPlantId(args, "id")
  return await routeByPlantId(t.reg, "plant_history", forwarded)

# ---------------------------------------------------------------------------
# method=inverter_list — route by plant → vendor.
# ---------------------------------------------------------------------------

proc doInverterList(t: SolarTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  return await routeByPlantId(t.reg, "inverter_list", args)

# ---------------------------------------------------------------------------
# method=inverter_alarms — route by plant → vendor.
# ---------------------------------------------------------------------------

proc doInverterAlarms(t: SolarTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  return await routeByPlantId(t.reg, "inverter_alarms", args)

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

method execute*(t: SolarTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("method"):
    return "Error: 'method' is required " &
           "(plant_list | plant_now | plant_history | inverter_list | inverter_alarms)"
  let action = getMethodArg(args)
  case action
  of "plant_list":      return await doPlantList(t, args)
  of "plant_now":       return await doPlantNow(t, args)
  of "plant_history":   return await doPlantHistory(t, args)
  of "inverter_list":   return await doInverterList(t, args)
  of "inverter_alarms": return await doInverterAlarms(t, args)
  else:
    return "Error: Unknown action '" & action &
           "'. Use: plant_list | plant_now | plant_history | " &
           "inverter_list | inverter_alarms"
