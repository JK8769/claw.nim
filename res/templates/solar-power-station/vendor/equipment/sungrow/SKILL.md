---
name: vendor-sungrow
version: 0.1.0
description: "SunGrow iSolarCloud vendor implementation. Conforms to the solar-power-station vendor contract (5 required tools per vendor/CONTRACT.md). Ships as a stub with SunGrow-flavored mock data — production deployments wire the real iSolarCloud API by replacing src/sungrow.nim with the full implementation."
contract_version: 1
requires:
  tools: []
  deps:
    - package: nim
      manager: system
  env:
    - SUNGROW_APPKEY
    - SUNGROW_ACCESS_KEY
    - SUNGROW_USER_ACCOUNT
    - SUNGROW_USER_PASSWORD
    - SUNGROW_REGION
---

# vendor/sungrow

SunGrow iSolarCloud implementation of the solar-power-station vendor
contract. Exposes the 5 required tools (`plant_list`, `plant_now`,
`plant_history`, `inverter_list`, `inverter_alarms`) so the fleet
adapter can route plant queries to SunGrow plants.

## Status: stub

This SKILL ships with a **stub implementation** (`src/sungrow.nim`)
that returns SunGrow-flavored mock data. The mock:
- Returns 3 mock plants with `SG-` prefixed IDs
- Conforms to the schemas in `vendor/schemas/`
- Compiles standalone without external dependencies
- Useful for testing the fleet adapter routing end-to-end without
  needing real iSolarCloud credentials

## Production wiring

To wire real SunGrow API access:

1. Set the required environment variables in your deployment's
   `.env`:
   ```
   SUNGROW_APPKEY=<your-app-key>
   SUNGROW_ACCESS_KEY=<your-access-key>
   SUNGROW_USER_ACCOUNT=<your-account>
   SUNGROW_USER_PASSWORD=<your-password>
   SUNGROW_REGION=cn|us|eu  # regional endpoint selector
   ```
2. Replace `src/sungrow.nim` with the full production
   implementation. Sources:
   - Existing SunGrow deployments carry a mature
     ~170KB implementation at
     `<deployment>/workspace/skills/sungrow/src/sungrow.nim`
   - Or install via separate `sungrow-mcp` community repo:
     `claw skill install github:<owner>/sungrow-mcp`
3. Run `claw co update` then `claw gateway` — the MCP server
   compiles to `bin/sungrow` and registers automatically.

## Contract conformance

The stub exposes exactly the 5 required tools matching
`vendor/CONTRACT.md`:

| Tool name | What the stub returns |
|---|---|
| `plant_list()` | 3 mock plants (`SG-12345`, `SG-12346`, `SG-12347`) |
| `plant_now(plant_id)` | Mock current state if plant_id matches; else `plant_not_found` error |
| `plant_history(plant_id, from, to)` | Mock daily yield rows in the requested range |
| `inverter_list(plant_id)` | 2 mock inverters per plant |
| `inverter_alarms(plant_id)` | Empty array (no active alarms) |

Vendor extension fields included for realism: `sungrow_ps_id`,
`sungrow_region`, `sungrow_mlpe_enabled`. Production
implementations should preserve these for vendor-specific skills
that depend on SunGrow-only features.

## Plant ID prefix

SunGrow plant IDs in this implementation are prefixed `SG-` per the
contract. The fleet adapter uses this prefix as a fast routing
fallback when the plant→vendor cache is cold.

## What this does NOT cover (yet — production extras)

The full SunGrow API surface includes ~22 tools across:
- Fleet rollups (`solar_fleet_now`)
- Per-MPPT optimizer data (`solar_optimizer_*`)
- Environmental sensors (`solar_environment_*`)
- History sync + local cache (`solar_history_sync`, `solar_history_query`)
- Customer-facing report generation (`solar_report_*`)

These are vendor-specific extensions, not contract requirements.
Production deployments that need them install the full
implementation and access them via `mcp_sungrow_<tool>` directly,
bypassing the fleet adapter for vendor-specific features.
