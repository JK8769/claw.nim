---
name: alarm-response
version: 1.0.0
description: "Classify active plant alarms by severity, group by plant for operator efficiency, escalate critical ones immediately. Workflow over fleet action=inverter_alarms + delegate."
loading: lazy
operations:
  - scan
  - classify
  - escalate
  - summarize
keywords:
  - alarm
  - fault
  - 告警
  - 故障
  - 报警
  - escalate
  - critical
requires:
  tools:
    - fleet
    - reply
    - reply_progress
    - delegate
    - memory
---

Workflow for handling active plant alarms. Triaged by severity,
grouped for operator efficiency, escalated when critical.

## When to load this skill

- **Scheduled**: heartbeat-driven, e.g. every hour during daylight.
- **On-demand**: when the operator asks "any alarms?" or a
  customer reports an issue.
- **Reactive**: when a `fleet action=plant_now` call returns
  `alarms_count > 0` and the agent decides to investigate.

## Workflow

1. Call `fleet action=plant_list()` — get all plants with their current
   `alarms_count`. Filter to plants where count > 0.
2. For each plant with active alarms, call
   `fleet action=inverter_alarms(plant_id)` to get alarm details.
3. **Classify each alarm**:
   - **Critical**: plant offline, fault preventing production,
     fire/safety code. Escalate immediately.
   - **High**: string offline, inverter offline, significant
     yield impact (>20%). Notify within the hour.
   - **Medium**: degraded performance, intermittent fault, minor
     yield impact. Include in next operator summary.
   - **Low**: warnings, advisories, sensor noise. Log only;
     don't notify.
4. **Group by plant**, not by alarm. Operators think "what's
   wrong with Plant Alpha" more than "what's wrong across all
   plants." Show one row per plant, with severity rollup +
   alarm count.
5. **For critical alarms**:
   - Send immediate notification via the channel's high-priority
     primitive if available (Lark interactive Card, Telegram
     pinned message, etc.)
   - Delegate to the Analyst for diagnosis (include plant_id,
     alarm details, brief context)
6. **For high+medium**: include in the next scheduled operator
   summary.
7. **Low**: log via `memory action=store scope=self` for audit;
   no notification.

## Output (operator-facing summary)

```
🚨 Critical (1):
  Plant Alpha — inverter offline 2h, 0 kWh today (expected 600+).
                Delegated to Analyst for diagnosis.

⚠️ High (1):
  Plant Beta — string S3 offline; ~12% yield impact.

ℹ️ Medium (3):
  Plant Gamma — 3 inverters showing degraded performance.

(2 Low alarms suppressed — see <office>/audit/alarms-log.jsonl)
```

## Severity rules (suggested defaults — tune per deployment)

| Vendor alarm code class | Default severity |
|---|---|
| `plant_offline`, `comms_lost` >30min | Critical |
| `inverter_fault`, `inverter_offline` | High |
| `string_offline`, `string_fault` | High |
| `performance_degraded`, `pr_below_threshold` | Medium |
| `sensor_noise`, `temperature_warning` | Low |
| `info`, `notice`, `commissioning` | Low |

Vendor-specific alarm codes may not match these classes verbatim.
The fleet adapter's `Alarm.severity` field (per
`vendor/schemas/alarm.json` once defined) carries the vendor's
own classification; map to your deployment's policy.

## Anti-patterns

- **Notify on every low alarm** → operator inbox blindness.
  Group, summarize, and only push the high-severity rows.
- **Suppress critical alarms because they happened earlier.**
  De-dupe by alarm-id, not by plant. A plant having one persistent
  alarm and one new alarm needs both reported.
- **Escalate to Analyst without context.** The delegate prompt
  must include plant_id, alarm details, and "what I tried"
  (even if "what I tried" is nothing — say so).
- **Suppress an alarm because it might be a sensor fault.**
  If you can't tell, escalate. Operator decides; you don't.
- **Quote alarm counts without quoting the alarms themselves.**
  "3 alarms" without naming any of them tells the operator nothing.
