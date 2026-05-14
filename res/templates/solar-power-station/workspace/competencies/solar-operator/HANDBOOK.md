# Solar Operator

This competency teaches what solar plant data means and how to
handle it correctly — equipment topology, units and ranges,
acquisition discipline, verification heuristics, domain
terminology.

It does NOT teach modeling methodology, statistical reasoning, or
report writing. Those come from `data-analyst` and
`technical-communication` respectively. The competencies compose:
this one knows what the data IS; data-analyst knows what to DO
with it; technical-communication knows how to TELL the user.

If you have only this competency loaded, you can fetch and verify
plant data and answer factual questions about it. You should not
attempt modeling, statistical analysis, or methodology decisions —
defer or escalate.

---

## Equipment taxonomy

Solar plants are hierarchical:

```
Plant
└── Inverter (string inverter, central inverter, or hybrid)
    └── String (series-connected modules feeding one MPPT input)
        └── PV module (individual panel)
```

- **Plant** — the unit a customer subscribes to. Has a unique ID,
  capacity (kWp), location, commissioning date, equipment manifest.
  Customer questions ("how is my plant doing?") apply here.
- **Inverter** — converts DC from strings to AC for the grid. Each
  inverter has its own efficiency curve, telemetry, and failure
  modes. String inverters serve a single plant section; central
  inverters serve larger arrays. Failures often localise to one
  inverter while the rest of the plant runs fine.
- **String** — a series-connected chain of PV modules feeding one
  MPPT input on the inverter. A single bad module can drag a whole
  string's output to near-zero. The most common alarm class is
  "string offline" — single string returning zero while siblings
  produce normally.
- **PV module** — individual panel. We rarely diagnose at this
  level; module-level data isn't always available.

When a question is about "the plant," ask whether it should be
analysed at the plant level (aggregate output) or rolled up from
inverter / string telemetry. The answer is often "depends on what
you're looking for" — tell the user.

---

## Units and expected ranges

| Quantity | Unit | Sane range | Notes |
|---|---|---|---|
| Power | kW or MW | 0 to nameplate × 1.1 | >1.0× nameplate is plausible (overproduction near STC + cool weather); >1.2× usually a unit error |
| Energy | kWh or MWh | 0 to nameplate × hours | Daily energy ≈ nameplate × peak-sun-hours (3-6 hours typical for mid-latitude sites) |
| Voltage (string) | V (DC) | 200-1500 | Outside this range usually a sensor fault |
| Current (string) | A (DC) | 0-15 | >15A = sensor fault or module short |
| Capacity factor | dimensionless | 0.05-0.30 (annual avg) | <0.05 = troubled site; >0.35 = check for sensor calibration |
| Performance ratio | dimensionless | 0.7-0.9 (good plant) | <0.6 sustained = degradation or shading issue |
| Irradiance | W/m² | 0-1200 | >1200 unusual unless cloud-edge effect |
| Temperature (module) | °C | -20 to +75 | Module surface runs hotter than ambient by 15-25°C in sun |

**Universal rule: a `0` reading is ambiguous.** A string at zero
output at midnight is normal. The same string at zero at noon is
broken. **Always check the timestamp of a zero reading** before
flagging it as a fault.

---

## Data acquisition discipline

Prefer the **fleet adapter's vendor-agnostic tools** (`fleet_*`)
over vendor-specific tools (`mcp_<vendor>_*`) whenever the contract
covers what you need. The fleet adapter:

- Aggregates plants across all installed vendors in one response
- Routes per-plant queries to the correct vendor automatically via
  the plant→vendor mapping in the cortex graph
- Validates each vendor's output against the schema in
  `vendor/schemas/` and degrades gracefully on drift

When a question requires plant data:

1. **Identify the time window precisely.** "Yesterday" → which
   timezone? Each plant carries its `Plant.location.timezone`.
   Misalignment shows up as "plant produced 0 from 00:00-06:00"
   which looks like a fault but is actually pre-dawn.
2. **Identify the granularity.** 1-minute, 5-minute, 15-minute,
   hourly, daily? Different APIs return different cadences.
3. **Check freshness.** Real-time telemetry typically lags 5-30
   minutes from upstream APIs. "Why is my plant showing 0 right
   now?" might just be ingestion delay, not a fault. The
   `PlantNow.timestamp` field reports the vendor's actual sample
   time — use that, not the wall clock.
4. **Pick the right tool**:
   - Fleet-level current → `solar method=plant_list` + per-plant `solar method=plant_now`
   - Historical yield → `solar method=plant_history(plant_id, from, to)`
   - Inverter-level detail → `solar method=inverter_list(plant_id)`
   - Active alarms → `solar method=inverter_alarms(plant_id)`
   - Vendor-specific extras (e.g. battery SOC for hybrid plants,
     per-MPPT detail, irradiance sensors) → fall through to the
     vendor's namespaced tool: `mcp_<vendor>_<extra-tool>`
5. **Verify before analysing.** A summary statistic from corrupt
   data is worse than no answer. Run a sanity check pass first:
   any obvious nulls, any out-of-range values, any timestamp gaps.

---

## Verification heuristics

Cheap checks to run before trusting any data series:

- **Diurnal shape**: solar output should be near-zero at night,
  rise in the morning, peak around solar noon, fall in the
  evening. A flat output during daylight hours is a fault. A
  bell-shape is normal.
- **Seasonal magnitude**: summer days produce ~1.5-2× winter days
  in mid-latitude sites. If "yesterday's energy" is suspiciously
  low for the season, check for soiling, snow, or partial outages.
- **Inverter-vs-inverter parity**: at the same plant, neighbouring
  inverters under the same conditions should produce within ~10%
  of each other. A single inverter producing 50% of its peers is
  a flag, not noise.
- **String-vs-string parity**: same idea, finer scale. One string
  at 80% of its siblings = soiling or partial shading; one string
  at 0% = offline.
- **Cumulative monotonicity**: lifetime energy and lifetime CO₂
  saved should never decrease. If they do, the API has reset or
  the plant ID got remapped — flag rather than report the new
  smaller number.

---

## Domain terminology

Avoid mistranslating these — they have specific meanings:

- **Capacity factor** — actual energy / theoretical max energy if
  running at nameplate 24/7. Not the same as efficiency.
- **Performance ratio (PR)** — actual energy / expected energy
  given measured irradiance. Closer to "how well is the plant
  performing relative to the sun it actually got."
- **Clipping** — when inverter output is artificially capped
  (grid-side curtailment, anti-PID measures, or DC oversizing).
  Looks like a flat-top in the diurnal curve.
- **Soiling** — gradual output loss from dust on modules.
  Detectable as slow downward trend in PR over weeks.
- **MPPT** — maximum power point tracking, the inverter's input
  channel. Inverters typically have multiple MPPTs (3-12); a
  "string" usually maps to one MPPT input.
- **String offline** — a single string returning zero output while
  siblings produce normally. Most common alarm class.
- **Residual load / net load** — total load minus renewable
  generation. Used in market-side analysis (clearing prices etc.),
  not plant operations directly.

---

## What to do when a question crosses domains

A question can sound solar-flavoured but actually be data-analyst
work, or vice versa. Examples:

- *"Build a model to predict next-day output"* — solar gives the
  inputs (which features make physical sense, what time alignment
  to use); data-analyst gives the method (split, validate, eval).
  Both must be loaded.
- *"What's the average capacity factor this month?"* — solar
  alone. No modeling needed; just fetch and aggregate via
  `solar method=plant_history`.
- *"Should we add a battery to plant X?"* — solar gives the load
  shape and current curtailment patterns; data-analyst gives the
  economic methodology; technical-communication gives the report
  format. Three competencies needed for a complete answer.

When the request fits both lenses or neither cleanly, **don't
guess** — that's exactly what `technical-communication`'s Phase 0
intake rule is for. Ask one focused clarifying question.

---

## What this competency does NOT cover

- **Modeling methodology** — train/eval/test, model selection,
  evaluation metrics, uncertainty. Use `data-analyst`.
- **Output format and delivery** — when to use cards, docs, code
  blocks; how to structure progress updates. Use
  `technical-communication`.
- **Per-customer relationship history** — preferences, prior
  cancellations. That's per-partner memory (`memory` tool).
- **Market-side analysis** — clearing algorithms, bid stacks,
  electricity-market rules. This is `data-analyst` territory or a
  future `market-analyst` competency.
- **Vendor-specific quirks** — auth-token refresh windows,
  pagination, specific API gotchas. Those live in the vendor's
  own SKILL.md / README.md.

If you find yourself reaching for one of these and don't have the
right competency loaded, surface that to the operator rather than
faking it.
