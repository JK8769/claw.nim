---
name: daily-yield-sync
version: 1.0.0
description: "Daily workflow: pull yield from each plant via the fleet adapter, cache locally, emit operational summary. Vendor-neutral — works across any combination of installed inverter brands."
loading: lazy
operations:
  - sync
  - status
  - catch-up
keywords:
  - daily
  - sync
  - yield
  - 同步
  - 发电
  - cache
  - history
requires:
  tools:
    - solar
    - memory
---

Workflow for pulling each plant's daily yield and caching it locally.
Reduces vendor-API load and makes historical queries faster
(local cache > remote round-trip).

## When to load this skill

- **Scheduled**: once daily, ~09:00 local at each plant (after vendor
  data has settled — typical 24h settlement window).
- **On-demand**: when the operator asks for a specific date's data
  and it's not in the cache.
- **Catch-up**: after gateway downtime, re-sync the missed days.

## Workflow

1. Call `solar action=plant_list()` — get all plants with timezones.
2. For each plant, determine the date range to sync:
   - If cache exists at `<office>/data/yield/<plant_id>.csv`:
     from `last_synced_date + 1` to `today - 1`
   - If no cache: from `Plant.install_date` (or a sensible
     start) to `today - 1` (initial backfill)
3. Call `solar action=plant_history(plant_id, from, to)` per plant.
4. Validate the response against the YieldPoint schema. Pay
   attention to `data_quality`:
   - `final` → cache it
   - `provisional` → cache but flag for refresh
   - `estimated` → cache with a flag
   - `missing` → record the gap; don't fabricate
5. Append to the per-plant cache file. Update manifest at
   `<office>/data/yield/manifest.json` with `last_synced` per
   plant.
6. Emit summary via `memory action=store scope=self` so the next
   turn can recall sync status.

## Output summary

```json
{
  "synced_at": "2026-05-12T09:00:00+08:00",
  "plants": [
    {"id": "SG-123", "rows_added": 1, "total_kwh": 4794.9, "data_quality": "provisional"},
    {"id": "HW-456", "rows_added": 1, "total_kwh": 2890.3, "data_quality": "final"}
  ],
  "missing": [],
  "errors": []
}
```

## Failure modes

- **Vendor unreachable** → record error per-plant, continue with
  the rest. Don't fail the whole sync.
- **`data_quality: "missing"` for a date** → record the gap;
  surface in the next operator interaction as a candidate to
  investigate (vendor outage? plant downtime?).
- **Cache file corrupted** → move to `<office>/data/yield/.bad/`,
  start fresh from `Plant.install_date`, log a clear warning.
- **Clock drift** (sync attempt before yesterday has settled) →
  skip the dubious day; retry next run.

## Anti-patterns

- Don't call `mcp_<vendor>_plant_history` directly — use
  `solar action=plant_history`. The fleet adapter handles vendor routing
  and gives you cross-vendor uniformity.
- Don't sync today's data — it's still provisional. Wait until
  settlement (typically next day's morning local).
- Don't overwrite the cache — append. The cache is a historical
  record; revisions should be tagged, not silent.
- Don't quote provisional yield numbers to a customer without
  flagging the quality. "Yesterday: 4794.9 kWh (provisional)" is
  honest; "Yesterday: 4794.9 kWh" implies final.
