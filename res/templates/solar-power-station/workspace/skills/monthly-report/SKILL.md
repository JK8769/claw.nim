---
name: monthly-report
version: 1.0.0
description: "Generate a monthly performance report for a customer's plants: pull cached yield, compute performance ratios + baselines, submit to a content-generation service for slide/doc output, reply with the deliverable URL."
loading: lazy
operations:
  - generate
  - draft
  - schedule
keywords:
  - monthly
  - report
  - 月报
  - performance
  - 性能
  - slides
  - doc
requires:
  tools:
    - solar
    - file
    - chat
---

Workflow for producing a customer's monthly plant-performance report.
Composes cached yield data + a content-generation service (anygen
or similar). Sits on top of `daily-yield-sync`'s cache when
possible; falls through to the live API for gaps.

## When to load this skill

- **Scheduled**: 1st of each month, for each customer's previous
  month's data.
- **On-demand**: when a customer or operator asks for a monthly
  recap, comparison, or executive summary.
- **Ad-hoc**: when an analytical question would benefit from a
  shareable artifact (e.g., "show me last month's performance").

## Workflow

1. Identify the customer and their `plant_ids` from the cortex
   graph (`social action=query` or `social action=who id=nc:N`)
   or the operator's prompt.
2. Send `chat reply text="Generating <month> report for <customer>
   — pulling cached data..." interim=true` (capability-driven: rich
   plan-state card on Feishu/Telegram, plain checklist elsewhere).
3. For each plant, pull historical yield:
   - First try the cache (`<office>/data/yield/<plant_id>.csv`)
   - Fill gaps via `solar action=plant_history(plant_id, from, to)`
4. Compute key metrics:
   - **Total month yield** (kWh)
   - **Average daily yield** (kWh/day)
   - **Equivalent peak-sun-hours** (yield / capacity_kwp)
   - **Performance ratio** if irradiance data available
   - **Best day / worst day** with dates
   - **YoY comparison** if previous-year data available
5. Send `chat reply text="Data assembled — submitting to generation
   service..." interim=true`.
6. Submit to the available content-generation service (anygen or
   equivalent) with the metrics as input. This is an **async tool**
   — surface the `task_id` per TC-9 (technical-communication's
   async-tool-handoff rule).
7. Either poll for completion or set up a follow-up:
   - If the generation service has a paired `fetch` tool, call it
   - Otherwise, tell the operator the deliverable URL and the
     typical wait time
8. Reply with the deliverable + a brief markdown executive
   summary + three next-step options.

## Output (final reply)

```
## <Month> Performance Report — <Customer>

📄 Full report: <deliverable URL>

Executive summary:
- Total yield: 142,394 kWh across 3 plants
- Average daily: 4,593 kWh/day
- Performance ratio: 0.83 (within band 0.7–0.9)
- Best day: 2026-05-08 (5,612 kWh)
- Worst day: 2026-05-22 (412 kWh, plant Beta string-offline)

Three options for next step:
1. Schedule recurring monthly delivery for this customer
2. Drill into 2026-05-22 underperformance
3. Compare this month against peer customers
```

## Failure modes

- **Cache missing days** → query `solar action=plant_history` for the
  gap. If the API also can't fill it, note the missing range in
  the report (don't fabricate).
- **Generation service down** → reply with the markdown summary
  ONLY; tell the operator the rich format is unavailable. Don't
  substitute hand-rolled "slides" — the operator asked for slides.
- **Customer has no plants** → reply with "nothing to report";
  don't generate an empty deliverable.
- **Asymmetric data quality** (some plants final, others
  provisional) → flag in the report; the customer should know.

## Anti-patterns

- **Computing metrics from incomplete data without flagging it.**
  A "month total" missing 5 days needs an asterisk.
- **Substituting your markdown for the requested deliverable**
  when the generation service failed. TC-9 — when an async tool
  was supposed to produce an artifact, surface the failure
  honestly. The operator can decide whether the markdown is
  enough.
- **Quoting performance ratios without context.** "PR = 0.83"
  means little; "PR = 0.83 (within band 0.7–0.9 for this site
  class)" means something.
- **Synthesizing trends from too few data points.** "Yield is
  trending down" needs more than one comparison month.
