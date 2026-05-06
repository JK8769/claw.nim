# MCP cache pattern (Layer 1 of context-bloat work)

**Status:** infrastructure landed in sungrow MCP (in user's company
workspace, not framework repo); 3 of 22 tools migrated as proof.
**Why:** address inline-data context bloat at the source rather than
defending downstream with size caps.

## The problem in one paragraph

MCP tools today return their full JSON payload as the tool message
content. Heavy tools (sungrow `solar_fleet_now`, `solar_history_query`,
`solar_alarms_now`, etc.) emit 50–100 KB of JSON per call. That data
lands in the agent's session and gets shipped to the LLM on every
subsequent turn. The 540K-tokens incident on 2026-05-05 was the
predictable result: 30 verbatim post-summarisation messages × ~18 KB
average tool result = 540K tokens, well past every provider's window.
We landed Layers 2 and 3 (per-message size cap, chunked-fallback
summariser) as defenses; Layer 1 addresses the cause.

## The pattern

For any tool whose response can grow large, return:

```json
{
  "summary": "12 plants, 47 inverters, today's yield 4823.4 kWh, ...",
  "key_metrics": { "plant_count": 12, "fleet_today_kwh": 4823.4, ... },
  "size_bytes": 78421,
  "ref_path": "/.../tool_cache/<account>/<tool>/<ts>_<sha>.json",
  "note": "Full payload at ref_path. read_file(ref_path) ..."
}
```

The full payload is written to disk under
`$NIMCLAW_DIR/support/sungrow/tool_cache/<account>/<tool_name>/<ts>_<sha8>.json`
and the agent reasons over the summary. If it needs the verbatim data
(e.g. to hand a row to anygen, or look up a specific inverter), it
calls `read_file(ref_path)` — no API re-call, no quota use, instant.

Small payloads (under `ToolCacheInlineThreshold = 4_000` bytes) skip
the cache file and emit inline (`{summary, key_metrics, inline}`) —
the indirection is pure overhead for tiny responses.

## Helper (in sungrow.nim, around line 230)

```nim
proc emitCachedResult*(toolName: string,
                        fullPayload: JsonNode,
                        summary: JsonNode): string
```

`summary` is a JSON object whose fields are merged into the returned
JSON verbatim. Caller decides what to surface (counts, key aggregates,
top-N pointers, etc.). The helper handles cache-file write,
`ref_path` / `size_bytes` fields, and the inline fast-path.

## Per-tool template

```nim
proc solar_<name>(...): string =
  ...build full payload as before...
  let fullPayload = %*{ ...everything... }
  # Layer 1: derive a useful summary so the agent doesn't need the
  # full payload for routine reasoning.
  let summary = %*{
    "summary": "<one-line prose>",
    "key_metrics": { ... }
  }
  result = emitCachedResult("solar_<name>", fullPayload, summary)
```

What goes in `summary`:

| Tool kind | Useful summary fields |
|---|---|
| Fleet snapshot (`solar_fleet_now`) | plant count, fleet kWh, fleet kW, alarm count, status breakdown |
| Plant snapshot (`solar_plant_now`) | plant name + capacity, current kW, today kWh, alarm count, inverter count |
| Device list (`solar_device_now`) | device count by status, top-3 by output, alarm count |
| Alarms (`solar_alarms_now`) | counts by type/severity/state, top plants by alarm count |
| Historical query (`solar_history_query`) | row count, value min/max/mean, distinct ps_keys, first+last row |
| Stats aggregate (`solar_history_stats`) | already small — emits inline path automatically |

The summary is what survives compaction / summarisation later — design
it so the agent can answer routine questions without reading the file.

## Tools migrated so far

- ✅ `solar_history_query` — 100KB rows → ~1KB summary + cache file
- ✅ `solar_fleet_now` — 30–60KB plants → ~800B summary + cache file
- ✅ `solar_alarms_now` — 5–20KB alarms → ~700B summary + cache file

## Remaining (incremental)

Each follows the template above; pick a useful summary per tool.

- `solar_plant_now`
- `solar_device_now` / `solar_device_history`
- `solar_optimizer_now` / `solar_optimizer_history`
- `solar_environment_now` / `solar_environment_history`
- `solar_plant_history`
- `solar_string_health`
- `solar_history_stats` (will emit inline; small payloads bypass cache)
- `solar_history_status`
- `solar_history_sync`
- `solar_report_*` (these already return file paths or task ids — review case-by-case)
- `solar_history_query` ← already done
- `solar_alarms_now` ← already done
- `solar_fleet_now` ← already done

## Future: extract to mcp library

The helpers (`toolCacheDirFor`, `emitCachedResult`,
`ToolCacheInlineThreshold`) live in `sungrow.nim` today. If anygen,
doc-parse, or any future MCP wants the same pattern, the cleanest
move is to extract them into the shared `mcp` library so each MCP
gets `import mcp; emitCachedResult(...)` without copy-paste.

The cache-directory layout would generalise from `support/sungrow/
tool_cache/<account>/...` to `support/<skill>/tool_cache/<account>/
...` — already follows the `support/<skill>/` convention used by the
rest of the framework.

Doing this extraction is a separate piece of work; the per-MCP copy
of the helpers in sungrow.nim is fine until a second MCP needs the
pattern.

## Cache-prune policy (TODO)

The `tool_cache/<account>/<tool>/` directories grow without bound.
Each call writes a new file (50–100 KB typical). With moderate
sungrow usage (10 calls/hour × 24h × 30 days), you'd accumulate ~1
GB per account in a month.

Pruning options (pick one):
- LRU at directory cap (e.g. 100 MB per tool, oldest files evicted)
- Time-based (delete files older than 30 days)
- Reference-counted (track which files are still referenced from
  active agent sessions; evict orphans)

Time-based is simplest. A scheduled cron task running
`find ~/.nimclaw-*/support/*/tool_cache -type f -mtime +30 -delete`
nightly handles it, no framework changes needed.
