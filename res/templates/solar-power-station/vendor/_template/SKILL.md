---
name: vendor-template
version: 0.1.0
description: "Skeleton vendor implementation for the solar-power-station solar adapter. Copy this directory to vendor/<your-vendor>/, rename references, replace mock data with real API calls. Returns hardcoded mock plants/readings so the solar adapter contract can be validated end-to-end before wiring up an actual inverter API."
contract_version: 1
requires:
  tools: []
  deps: []
  env: []
---

# Vendor Template (Skeleton)

This is the starting point for adding a new inverter brand to the
solar-power-station template. Read `vendor/CONTRACT.md` first, then
copy this directory and replace the mock data with real API calls.

## What this skeleton does

- Implements the 5 required tools per CONTRACT.md:
  `plant_list`, `plant_now`, `plant_history`, `inverter_list`,
  `inverter_alarms`
- Returns hardcoded mock data matching the schemas
- Compiles + registers as an MCP stdio server
- Is registered at `mcp_vendor_template_*` by claw on install

## Adding your vendor

```bash
cp -r vendor/_template vendor/<your-vendor>
# Rename `_template` → `<your-vendor>` in src/stub.nim, SKILL.md, README.md
# Implement the real API calls in src/<your-vendor>.nim
# Document env vars in your README.md
# In BASE.nims:
#   skill "vendor/<your-vendor>"
```

Then validate:

```bash
# Boot the gateway and check the validation log:
claw gateway --debug 2>&1 | grep solar_adapter
# Should see:
#   [INFO] solar_adapter: vendor `<your-vendor>` registered, contract v1 OK
# Drift produces:
#   [WARN] solar_adapter: vendor `<your-vendor>` schema drift — ...
```

## Implementation tips

- Match exact field names from the schemas. Optional fields are
  fine to omit; required ones must be present in every response.
- Plant IDs MUST be prefixed with your vendor name (e.g. `MY-123`)
  to avoid collision in multi-vendor fleets.

- Clamp negative `current_kw` to 0 — vendor APIs sometimes report
  small negative values at dawn/dusk due to sensor noise.
- For `plant_history`, return one `YieldPoint` per calendar day
  in the requested range. Missing dates → `data_quality: "missing"`
  with `yield_kwh: 0`, not an empty array (preserves date sequence
  for consumer).
- Use the vendor's freshness signal (`updateTime` / `lastUpdate`)
  for `timestamp`, not the wall clock. Honest staleness reporting
  matters for downstream decisions.

## Error handling

See `CONTRACT.md` section "Error conventions". The skeleton returns
mock success responses; your real implementation needs to handle
API failures gracefully (return error JSON, don't crash the MCP
server).

## Reference

- `vendor/CONTRACT.md` — formal contract
- `vendor/schemas/` — JSON Schema for each response type
- `vendor/examples/` — canonical example outputs
- `vendor/sungrow/` — first complete implementation (read alongside)
