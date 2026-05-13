## fleet — single tool for the multi-vendor solar deployment facade.
##
## Consolidates five previously-split tools, all backed by the runtime
## registry scan + plant→vendor cache machinery in
## `tools/fleet/fleet_adapter.nim`:
##
##   action=plant_list        — fan out across every installed vendor
##                              and merge the Plant arrays. Replaces
##                              `fleet_plant_list`.
##   action=plant_now         — real-time state for one plant. Routes
##                              by plant→vendor mapping. Replaces
##                              `fleet_plant_now`. Required arg: id.
##   action=plant_history     — daily yield history for one plant over
##                              a date range. Replaces
##                              `fleet_plant_history`. Required args:
##                              id, from, to.
##   action=inverter_list     — list inverters under one plant.
##                              Replaces `fleet_inverter_list`.
##                              Required arg: plant_id.
##   action=inverter_alarms   — active alarms on inverters under one
##                              plant. Replaces `fleet_inverter_alarms`.
##                              Required arg: plant_id.
##
## The vendor MCP contract (per
## `res/templates/solar-power-station/vendor/CONTRACT.md`) is unchanged:
## vendor servers still implement five tools named `plant_list`,
## `plant_now`, `plant_history`, `inverter_list`, `inverter_alarms`
## (registered as `mcp_<vendor>_<contract-tool>` at gateway boot).
## Consolidation is at the AGENT-FACING surface only — internally each
## action still dispatches to `mcp_<vendor>_<contract-tool>` per the
## existing fleet_adapter helpers.
##
## ─── Registration changes ──────────────────────────────────────────────
##
## src/claw/agent/loop.nim
##
##   DELETE (line 17):
##     import ../tools/fleet/fleet_adapter
##   ADD (replaces the line above):
##     import ../tools/fleet_unified
##     # The fleet_adapter module still hosts the registry-scan / cache /
##     # routing helpers, but the five virtual-tool wrappers are gone.
##     # If the helpers stay in fleet_adapter, keep the import — the
##     # FleetTool below imports them from that module.
##
##   DELETE (lines 3006–3021, the entire fleet block):
##     # Fleet adapter — vendor-agnostic facade for multi-vendor solar deployments.
##     # Registers five fleet_* virtual tools that fan out across whichever
##     # mcp_<vendor>_* tools were registered when the gateway loaded each
##     # vendor MCP server. Default off; the solar-power-station template's
##     # fleet-adapter skill declares them in requires.tools so agents that
##     # opt in receive the grant.
##     regTagged(newFleetPlantListTool(toolsRegistry),
##       ["fleet", "solar", "domain"], "list plants across all installed vendors")
##     regTagged(newFleetPlantNowTool(toolsRegistry),
##       ["fleet", "solar", "domain"], "real-time state for one plant")
##     regTagged(newFleetPlantHistoryTool(toolsRegistry),
##       ["fleet", "solar", "domain"], "daily yield history for one plant")
##     regTagged(newFleetInverterListTool(toolsRegistry),
##       ["fleet", "solar", "domain"], "list inverters under one plant")
##     regTagged(newFleetInverterAlarmsTool(toolsRegistry),
##       ["fleet", "solar", "domain"], "active alarms on one plant")
##
##   ADD (single block, in place of the deleted block):
##     # Fleet adapter — vendor-agnostic facade for multi-vendor solar
##     # deployments. One unified `fleet` tool with five actions
##     # (plant_list / plant_now / plant_history / inverter_list /
##     # inverter_alarms). Internally fans out across whichever
##     # mcp_<vendor>_* tools were registered when the gateway loaded
##     # each vendor MCP server. Default off; the solar-power-station
##     # template's fleet-adapter skill declares it in requires.tools so
##     # agents that opt in receive the grant.
##     regTagged(newFleetTool(toolsRegistry),
##       ["fleet", "solar", "domain"],
##       "fleet facade: list plants real-time state history inverters alarms across vendors")
##
## src/claw/tools/registry/manifest.nim
##
##   DELETE (lines 322–351, the five fleet_* spec entries):
##     spec(name = "fleet_plant_list",
##          description = "List all plants across every installed inverter vendor",
##          tags = @["fleet", "solar", "domain"],
##          searchKeywords = @["plant list", "fleet", "all plants"],
##          domain = "fleet",
##          default = false, heartbeatSafe = false, category = "fleet"),
##     spec(name = "fleet_plant_now",
##          description = "Real-time state for one plant (current power, today yield, status)",
##          tags = @["fleet", "solar", "domain"],
##          searchKeywords = @["plant now", "current power", "real-time"],
##          domain = "fleet",
##          default = false, heartbeatSafe = false, category = "fleet"),
##     spec(name = "fleet_plant_history",
##          description = "Daily yield history for one plant over a date range",
##          tags = @["fleet", "solar", "domain"],
##          searchKeywords = @["plant history", "yield history", "kwh history"],
##          domain = "fleet",
##          default = false, heartbeatSafe = false, category = "fleet"),
##     spec(name = "fleet_inverter_list",
##          description = "List inverters under one plant",
##          tags = @["fleet", "solar", "domain"],
##          searchKeywords = @["inverter list", "equipment"],
##          domain = "fleet",
##          default = false, heartbeatSafe = false, category = "fleet"),
##     spec(name = "fleet_inverter_alarms",
##          description = "Active alarms on inverters under one plant",
##          tags = @["fleet", "solar", "domain"],
##          searchKeywords = @["alarm list", "alarms", "active faults"],
##          domain = "fleet",
##          default = false, heartbeatSafe = false, category = "fleet"),
##
##   ADD (single block, in place of the deleted block):
##     spec(name = "fleet",
##          description = "Multi-vendor solar fleet facade " &
##                        "(action=plant_list|plant_now|plant_history|" &
##                        "inverter_list|inverter_alarms). Fans out for " &
##                        "list ops, routes per-plant ops by " &
##                        "plant→vendor cache.",
##          tags = @["fleet", "solar", "domain"],
##          searchKeywords = @["plant list", "fleet", "all plants",
##                              "plant now", "current power", "real-time",
##                              "today yield", "plant history", "yield",
##                              "historical", "kwh", "inverter", "equipment",
##                              "devices", "alarm", "fault", "alert"],
##          domain = "fleet",
##          default = false, heartbeatSafe = false, category = "fleet"),

import std/[json, asyncdispatch, tables]
import ./types
import ./spec
import ./registry
import ./fleet/fleet_adapter
import ../logger  # warnCF — used in doPlantList's fan-out error paths.
                  # Once fleet_adapter is trimmed to "helpers only", make sure
                  # findVendorTools / cachePlant / routeByPlantId carry the `*`
                  # export marker; they're currently module-private.

const ToolSpec* = spec(
  name = "fleet",
  description = "Multi-vendor solar fleet facade " &
                "(action=plant_list|plant_now|plant_history|" &
                "inverter_list|inverter_alarms). Fans out for list ops, " &
                "routes per-plant ops by plant→vendor cache.",
  tags = @["fleet", "solar", "domain"],
  searchKeywords = @["plant list", "fleet", "all plants",
                      "plant now", "current power", "real-time",
                      "today yield", "plant history", "yield",
                      "historical", "kwh", "inverter", "equipment",
                      "devices", "alarm", "fault", "alert"],
  domain = "fleet",
  default = false,
  heartbeatSafe = false,
  category = "fleet",
)

type
  FleetTool* = ref object of Tool
    reg*: ToolRegistry  ## live tool registry — scanned per-call to find
                        ## `mcp_<vendor>_<contract-tool>` entries (registered
                        ## when the vendor MCP servers loaded at boot)

proc newFleetTool*(reg: ToolRegistry): FleetTool =
  FleetTool(reg: reg)

method name*(t: FleetTool): string = "fleet"

method description*(t: FleetTool): string =
  "Multi-vendor solar fleet facade. Fans out across every installed " &
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

method parameters*(t: FleetTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["plant_list", "plant_now", "plant_history",
                 "inverter_list", "inverter_alarms"],
        "description": "Operation to perform"
      },
      # --- action=plant_now / plant_history ---
      "id": {
        "type": "string",
        "description":
          "plant_now / plant_history: the plant's vendor-prefixed ID, " &
          "e.g. 'SG-12345'. Routes the call to the vendor that owns the plant."
      },
      # --- action=inverter_list / inverter_alarms ---
      "plant_id": {
        "type": "string",
        "description":
          "inverter_list / inverter_alarms: vendor-prefixed plant ID " &
          "(e.g. 'SG-12345')."
      },
      # --- action=plant_history ---
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
    "required": %["action"]
  }.toTable

# ---------------------------------------------------------------------------
# action=plant_list — fan out across every vendor and merge the arrays.
# ---------------------------------------------------------------------------

proc doPlantList(t: FleetTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Verbatim from FleetPlantListTool.execute. Scans the registry for every
  ## `mcp_<vendor>_plant_list`, calls each, primes the plant→vendor cache from
  ## the per-Plant `vendor` field (or falls back to the discovered vendor
  ## name), and merges the results into a single JSON array.
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

# ---------------------------------------------------------------------------
# Argument shaping for per-plant routes.
#
# The five legacy tools used `plant_id` uniformly in their arg dicts, but
# the unified surface uses `id` for plant_now / plant_history (matching the
# README convention "the plant's vendor-prefixed ID"). Internally we still
# need to pass `plant_id` to `routeByPlantId`, so we translate.
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
# action=plant_now — route by plant → vendor.
# ---------------------------------------------------------------------------

proc doPlantNow(t: FleetTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Verbatim from FleetPlantNowTool.execute — routes via routeByPlantId.
  let forwarded = forwardArgsAsPlantId(args, "id")
  return await routeByPlantId(t.reg, "plant_now", forwarded)

# ---------------------------------------------------------------------------
# action=plant_history — route by plant → vendor.
# ---------------------------------------------------------------------------

proc doPlantHistory(t: FleetTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Verbatim from FleetPlantHistoryTool.execute — routes via routeByPlantId.
  ## from / to date args ride along untouched in the args table.
  let forwarded = forwardArgsAsPlantId(args, "id")
  return await routeByPlantId(t.reg, "plant_history", forwarded)

# ---------------------------------------------------------------------------
# action=inverter_list — route by plant → vendor.
# ---------------------------------------------------------------------------

proc doInverterList(t: FleetTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Verbatim from FleetInverterListTool.execute — routes via routeByPlantId.
  return await routeByPlantId(t.reg, "inverter_list", args)

# ---------------------------------------------------------------------------
# action=inverter_alarms — route by plant → vendor.
# ---------------------------------------------------------------------------

proc doInverterAlarms(t: FleetTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  ## Verbatim from FleetInverterAlarmsTool.execute — routes via routeByPlantId.
  return await routeByPlantId(t.reg, "inverter_alarms", args)

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

method execute*(t: FleetTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required " &
           "(plant_list | plant_now | plant_history | inverter_list | inverter_alarms)"
  let action = args["action"].getStr()
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
