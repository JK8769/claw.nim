---
name: solar-adapter
version: 1.0.0
description: "Vendor-agnostic facade over installed inverter-vendor MCP servers. Exposes the `solar` tool's five actions (plant_list, plant_now, plant_history, inverter_list, inverter_alarms) — fans out across vendors and routes per-plant queries automatically. Multi-vendor capable: install any combination of vendor/<name> skills and the adapter handles routing."
operations:
  - list
  - now
  - history
  - inverters
  - alarms
keywords:
  - solar
  - plant
  - inverter
  - alarm
  - vendor-neutral
  - multi-vendor
requires:
  tools:
    - solar
---

The vendor-agnostic facade. Sits between agent-side workflow skills
(daily-yield-sync, monthly-report, alarm-response) and per-vendor
MCP servers (vendor/sungrow, vendor/huawei, vendor/goodwe, …).

Agents that practice `solar-operator` or `solar-frontdesk` should
`uses "solar-adapter"` to acquire the `solar` tool.

## What it does

The `solar` tool exposes five actions that mirror the contract every
vendor implementation must satisfy (see `vendor/CONTRACT.md`):

| Action | Behavior |
|---|---|
| `solar method=plant_list` | Fan out to every installed vendor's `<vendor>_plant_list`; merge results into one array; each plant tagged with `vendor` for routing. |
| `solar method=plant_now plant_id=…` | Look up plant→vendor mapping; dispatch to `<vendor>_plant_now`. |
| `solar method=plant_history plant_id=… from=… to=…` | Same routing; vendor's history call. |
| `solar method=inverter_list plant_id=…` | Same routing. |
| `solar method=inverter_alarms plant_id=…` | Same routing. |

## Plant → vendor routing

Lazy-populated in-memory cache:

1. First `solar method=plant_list` call fans out across vendors and
   stamps `plant_id → vendor` for every returned plant.
2. Subsequent per-plant calls consult the cache. Miss → call
   `solar method=plant_list` transparently to populate, then retry.
3. Plant IDs are vendor-prefixed per the contract (`SG-`, `HW-`,
   `GW-`, …), so the lookup is unambiguous.

## Failure modes

- **Vendor unreachable during fan-out** → log a warning naming the
  vendor; continue with the rest. The merged response contains
  only the vendors that responded.
- **Plant not found** → tool returns `{"error": "plant_not_found",
  "plant_id": "<id>"}`. The calling skill decides how to handle it.
- **Vendor returns an error object** instead of array → log warning;
  exclude the vendor's data from the merge.
- **Schema drift** (vendor's response doesn't match expected
  shape) → caller (skill) can validate against `vendor/schemas/`.
  The adapter passes responses through without validation by
  default; that's the schema check's responsibility per CONTRACT.md.

## When to use

This skill is a **dependency** of the workflow skills, not an
end-user skill. Agents typically don't `skill method=load
name=solar-adapter` directly — they load the workflow skill
(`daily-yield-sync`, `monthly-report`, etc.) which depends on the
`solar` tool that the adapter provides.

Prefer the `solar` tool over vendor-specific tools whenever the
contract covers your operation. Drop down to `mcp_<vendor>_*`
ONLY for vendor-specific features (battery SOC, per-MPPT detail,
irradiance sensors — things outside the universal contract).

## Vendor-specific extensions

The adapter preserves vendor-specific fields in merged output. A
SunGrow plant response might include `sungrow_ps_id`,
`sungrow_mlpe_enabled` alongside the contract fields — those flow
through. Skills that care about vendor extensions can read them
from the merged response; vendor-agnostic skills depend only on
the contract-required fields.

## Implementation

Framework-shipped (`src/claw/tools/solar/solar_adapter.nim`). One
framework `Tool` (`solar`) with action dispatch, fanning out via
the runtime tool registry. No separate MCP server process — the
adapter is in-process with the gateway, so registry lookups are
O(1) and fan-out happens via direct tool dispatch.

If a second domain template emerges with a similar fan-out
pattern (e.g. `multi-warehouse-inventory`, `multi-region-billing`),
the implementation can be generalized into a framework
`tool_group` feature. For now it's solar-specific by convention,
not by architecture.
