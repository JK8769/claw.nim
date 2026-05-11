# Vendor Contract — solar-power-station template

This document specifies what an inverter-vendor MCP server must
provide to plug into the solar-power-station template's fleet
adapter.

**Audience: anyone (coding agent or human) authoring a new vendor
adapter.** The contract is the source of truth — implementations
that don't conform won't be routable by the fleet adapter.

## How vendors plug in

1. Copy `vendor/_template/` to `vendor/<your-vendor>/`.
2. Rename references from `_template` to `<your-vendor>` in source
   + SKILL.md.
3. Implement the 5 required tools (below) per the JSON schemas in
   `vendor/schemas/`.
4. Validate output against `vendor/examples/`.
5. Document env vars in `vendor/<your-vendor>/README.md`.
6. Add `skill "vendor/<your-vendor>"` to the deployment's BASE.nims.

A coding agent should be able to produce a correct adapter from
this document + the schemas + the skeleton in one pass.

## Required tools (the floor)

Every vendor MUST expose these five tools. The fleet adapter
fans queries out to all installed vendors via these names (prefixed
with the vendor name at MCP registration — e.g. `sungrow_plant_list`).

| Tool | Input | Output schema | Purpose |
|---|---|---|---|
| `plant_list` | — | `[Plant]` | Enumerate plants in this vendor's fleet |
| `plant_now` | `plant_id: string` | `PlantNow` | Real-time state for one plant |
| `plant_history` | `plant_id: string, from: date, to: date` | `[YieldPoint]` | Daily yield over a date range |
| `inverter_list` | `plant_id: string` | `[Inverter]` | Equipment under one plant |
| `inverter_alarms` | `plant_id: string` | `[Alarm]` | Active alarms |

A vendor implementation missing any of these is incomplete; the
fleet adapter logs a warning at boot and skips that vendor for the
affected operation (graceful degradation, not removal).

## Optional tools (extensions)

Vendors MAY expose additional tools beyond the floor. These are NOT
fanned out by the fleet adapter, but skills can target them by their
fully-qualified name (e.g. `mcp_sungrow_solar_optimizer_now`).

Common extension areas:
- Detailed inverter-level history (per-string, per-MPPT)
- Battery / storage state for hybrid plants
- Environmental sensors (irradiance, ambient temp, module temp, wind)
- Vendor-specific diagnostic exports

Document any extensions in the vendor's own README.

## Schemas

See `vendor/schemas/`:

- **`plant.json`** — `Plant`: vendor-agnostic plant metadata
- **`plant_now.json`** — `PlantNow`: real-time state
- **`yield_point.json`** — `YieldPoint`: one date's yield reading
- `inverter.json` — `Inverter`: equipment under a plant *(TODO)*
- `alarm.json` — `Alarm`: active alarm record *(TODO)*

Each schema declares REQUIRED fields and tolerates OPTIONAL
extension fields. Vendors MUST emit all required fields; MAY add
their own.

## Vendor extension fields

The fleet adapter preserves vendor-specific fields in merged
output. Example response from `plant_list`:

```json
{
  "id": "SG-123",
  "vendor": "sungrow",
  "name": "无锡中亚",
  "capacity_kwp": 815.35,
  "install_date": "2023-06-15",
  "sungrow_ps_id": "12345",          // vendor-specific extension
  "sungrow_mlpe_enabled": true       // vendor-specific extension
}
```

Vendor-agnostic skills (`daily-yield-sync`, `monthly-report`) depend
ONLY on the required fields. Vendor-specific skills can access
extensions via the fully-qualified tool name.

## Environment variable conventions

Use `<VENDOR_UPPER>_` prefix for every env var your vendor needs:

- `<VENDOR>_APIKEY` — primary credential
- `<VENDOR>_REGION` — if API has regional endpoints
- `<VENDOR>_USER_ACCOUNT` / `<VENDOR>_USER_PASSWORD` — for OAuth-style
- `<VENDOR>_BASE_URL` — if the endpoint isn't hardcoded

Examples:
- SunGrow: `SUNGROW_APPKEY`, `SUNGROW_ACCESS_KEY`, `SUNGROW_USER_ACCOUNT`, `SUNGROW_USER_PASSWORD`
- Huawei FusionSolar: `HUAWEI_USERNAME`, `HUAWEI_PASSWORD`
- GoodWe: `GOODWE_APIKEY`, `GOODWE_REGION`

Document the exact set in your vendor's README.

## Error conventions

The MCP tool responses follow these conventions for failure modes:

| Condition | Response shape |
|---|---|
| Empty result (no plants, no alarms) | `[]` for list tools |
| Plant not found (single-plant tool) | `{"error": "plant_not_found", "plant_id": "<id>"}` |
| API unreachable | `{"error": "vendor_unreachable", "vendor": "<name>", "retry_after_seconds": 30}` |
| Authentication failure | `{"error": "auth_failed", "vendor": "<name>"}` |
| Rate limit hit | `{"error": "rate_limited", "vendor": "<name>", "retry_after_seconds": 60}` |
| Schema-shape error in the response | NEVER happens — vendor bug |

The fleet adapter handles `error` responses by logging the issue
and excluding that vendor's result from the merged output for that
specific call. Other vendors' results still flow through.

## Boot-time validation

At gateway startup, the fleet adapter samples each installed vendor's
first response and validates against the schemas. Drift is logged
clearly:

```
[WARN] fleet_adapter: vendor `huawei` schema drift —
       plant_list response item missing required field `capacity_kwp`
[WARN] fleet_adapter: vendor `huawei` schema drift —
       plant_now `status` field value `running` not in enum
       [online, offline, fault, maintenance, unknown]
```

Vendors with required-field drift are skipped for the affected
operation. Vendors with enum-value drift are accepted but the
out-of-spec value flows through (the agent can still reason about
it; just won't match downstream switches).

## Plant ID conventions

Vendors mint their own plant IDs but **MUST prefix them with their
vendor name** to avoid collision in multi-vendor fleets:

- ✅ `SG-12345` (SunGrow)
- ✅ `HW-67890` (Huawei)
- ✅ `GW-99999` (GoodWe)
- ❌ `12345` (no prefix → could collide across vendors)

The fleet adapter relies on prefix uniqueness for fast vendor-routing
lookup before falling back to the cortex graph.

## Skeleton + first implementation

- **`vendor/_template/`** — minimal skeleton with mock data. Copy
  this as your starting point. Compiles and runs but returns
  hardcoded responses so you can validate the contract end-to-end
  before wiring real API calls.
- **`vendor/sungrow/`** — first complete reference implementation.
  Read it alongside this contract; it's the canonical example of
  what an idiomatic vendor implementation looks like.

## Versioning

The contract version is in the YAML header of this file:

```yaml
contract_version: 1
```

Bumped when REQUIRED fields are added, REMOVED, or renamed. The
fleet adapter logs the contract version it expects against each
vendor's `SKILL.md` `contract_version:` field at boot.

OPTIONAL field additions don't bump the version — vendors that
don't emit them are fine; vendors that do are forward-compatible.
