## Vendor template — skeleton MCP server implementation.
##
## Copy this file's containing directory to `vendor/<your-vendor>/`,
## rename `vendor_template` references to your vendor name, and
## replace the mock data with real API calls.
##
## Compiles + registers as an MCP stdio server. Returns hardcoded
## mock responses so the fleet adapter contract can be validated
## end-to-end before wiring an actual inverter API.

import std/[json, times, strutils]

# Replace this constant with your vendor's lowercase name.
# MUST match the dir name under vendor/ AND the prefix used for
# plant IDs (`<vendor-upper>-<numeric>` — e.g. `MYV-123`).
const VendorName = "vendor-template"
const PlantIdPrefix = "TPL"

mcpServer(VendorName):

  # ── Required: plant_list ──────────────────────────────────────

  mcpTool:
    proc plant_list(): JsonNode =
      ## Enumerate every plant in this vendor's fleet.
      ## Returns array of Plant per schemas/plant.json.
      result = %*[
        {
          "id": PlantIdPrefix & "-001",
          "vendor": VendorName,
          "name": "Mock Plant Alpha",
          "capacity_kwp": 500.0,
          "install_date": "2024-01-01",
          "location": {
            "latitude": 0.0,
            "longitude": 0.0,
            "timezone": "UTC"
          },
          "status": "online"
        },
        {
          "id": PlantIdPrefix & "-002",
          "vendor": VendorName,
          "name": "Mock Plant Beta",
          "capacity_kwp": 1000.0,
          "install_date": "2024-06-15",
          "location": {
            "latitude": 0.0,
            "longitude": 0.0,
            "timezone": "UTC"
          },
          "status": "online"
        }
      ]

  # ── Required: plant_now ───────────────────────────────────────

  mcpTool:
    proc plant_now(plant_id: string): JsonNode =
      ## Real-time state for one plant.
      ## Returns PlantNow per schemas/plant_now.json.
      if not plant_id.startsWith(PlantIdPrefix):
        return %*{"error": "plant_not_found", "plant_id": plant_id}
      result = %*{
        "plant_id": plant_id,
        "vendor": VendorName,
        "current_kw": 250.0,
        "today_kwh": 1200.0,
        "status": "online",
        "alarms_count": 0,
        "timestamp": $now().utc
      }

  # ── Required: plant_history ───────────────────────────────────

  mcpTool:
    proc plant_history(plant_id: string,
                        `from`: string,
                        `to`: string): JsonNode =
      ## Daily yield over a date range (inclusive).
      ## Returns array of YieldPoint per schemas/yield_point.json.
      ## NOTE: the parameter names `from` and `to` are reserved in Nim;
      ## quote them with backticks. The MCP exposes them as `from` / `to`.
      if not plant_id.startsWith(PlantIdPrefix):
        return %*[]
      # In a real implementation, iterate the date range and call
      # the vendor's per-day API. Here we return one mock point.
      result = %*[
        {
          "plant_id": plant_id,
          "vendor": VendorName,
          "date": `from`,
          "yield_kwh": 1200.0,
          "peak_kw": 380.0,
          "equivalent_hours": 2.4,
          "data_quality": "final"
        }
      ]

  # ── Required: inverter_list ───────────────────────────────────

  mcpTool:
    proc inverter_list(plant_id: string): JsonNode =
      ## Equipment under one plant.
      ## TODO: schema not yet defined — see CONTRACT.md.
      if not plant_id.startsWith(PlantIdPrefix):
        return %*[]
      result = %*[
        {
          "id": plant_id & "-INV-1",
          "plant_id": plant_id,
          "vendor": VendorName,
          "model": "Mock Inverter 100kW",
          "capacity_kw": 100.0,
          "status": "online"
        }
      ]

  # ── Required: inverter_alarms ─────────────────────────────────

  mcpTool:
    proc inverter_alarms(plant_id: string): JsonNode =
      ## Active alarms on inverters under one plant.
      ## TODO: schema not yet defined — see CONTRACT.md.
      if not plant_id.startsWith(PlantIdPrefix):
        return %*[]
      result = %*[]  # No active alarms in the mock
