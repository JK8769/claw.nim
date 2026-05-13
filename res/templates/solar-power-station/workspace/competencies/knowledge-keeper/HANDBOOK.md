# Knowledge Keeper

This competency teaches the agent to maintain a personal **wiki of
timeless facts** at `<office>/knowledge/`. It's the agent's
*semantic memory* — distinct from episodic experiences (what
happened), procedural reflexes (what to do), and project artifacts
(what I'm building).

## What lives in knowledge/

One markdown file per topic, kebab-case filename. Examples:

- `inverter-api-quirks.md` — vendor API gotchas (lag windows,
  pagination, auth refresh, etc.)
- `gbdt-feature-engineering.md` — feature-engineering notes for a
  specific model class
- `plant-failure-modes.md` — equipment-specific failure patterns
- `train-eval-test-discipline.md` — methodology you've internalised

Each file is **append-only at the bottom**, latest entry stacks
beneath previous entries with a timestamp + attribution. The wiki
is a single git repo; every heartbeat auto-commits if dirty.

## What does NOT live in knowledge/

| Material | Goes in |
|---|---|
| Project-specific data, drafts, scripts | `workstation/active/<project>/` (in the project's repo) |
| Behavioural rules ("always confirm scope") | `memory/MEMORY.md` |
| Episodic events ("nc:5 cancelled my turn") | `memory/<nc:id>.jsonl` (system-written) |
| Synthesised behavioural reflections | `memory/self.jsonl` (system-written) |
| Future TODO items | `notes/notes.org` or `notes/todo.jsonl` |

The split matters: knowledge is what you KNOW (facts), reflexes
are what you DO (rules), experiences are what HAPPENED (events),
and project files are what you're BUILDING (deliverables). They
serve different cognitive functions and have different update
patterns.

## How to consolidate

Use the `knowledge` tool's `consolidate` action:

```
knowledge action=consolidate
  topic="inverter-api-quirks"
  insight="Daily aggregation has a 24-48h lag. Query yesterday's data only after 09:00 local to avoid empty results."
  source="<project>, methods-notes.md (2026-05-09)"
```

The tool handles file create / append / timestamp / attribution.
You don't write the file format manually.

## Rating facts (optional but valuable)

After consolidating, use `knowledge action=rank` to express judgment
on what's important. Ranks are 1-10 with a reason; aggregate displays
once ≥ 2 agents have voted. The wiki's quality signal comes from
agents — not from algorithms.

```
knowledge action=rank topic="inverter-api-quirks" score=9
  reason="every monthly-report and daily-yield-sync hits this lag"
```

Use `knowledge action=top` to see the highest-rated facts (sorted by
average rank). `knowledge action=lookup topic=…` returns the full
content + rank summary. `knowledge action=list` enumerates every topic
with its current rank.

## When to promote (the trigger)

Three opportunities surface naturally:

1. **Mid-project realisation** — you're working on project A and
   notice a fact that applies beyond it. Promote immediately so
   future-you finds it via `grep`.
2. **Heartbeat tick** — the `knowledge_promotion_candidates`
   duty surfaces TODO/LEARN/NOTE/FACT markers from project
   READMEs. Review each, promote if cross-project.
3. **Project archival** — when a project moves to `archive/`,
   extract its durable insights to knowledge/ before the project
   goes cold. The `extract_from_recent_archives` duty surfaces
   recently-archived projects for this purpose.

## Insight quality rules

- **Write the lesson directly**. Not narrative ("I noticed..."),
  but the fact ("Daily aggregation has a 24-48h lag").
- **Attribution**. The `source` field lets future-you trust or
  revisit the claim. "I figured this out in project X on date Y."
- **Generality test**. Before promoting, ask: "If a peer agent
  worked on a different project tomorrow, would this fact help
  them?" If no, it's project-specific — keep in the project repo.
- **Don't restate skill behaviour**. If a skill's HANDBOOK
  already documents the fact, don't duplicate it in knowledge/.
  (You CAN add operational nuance the HANDBOOK doesn't cover.)
- **Update over duplicate**. If a topic file exists, append a
  refinement rather than creating `<topic>-v2.md`. The append-only
  log lets future-you see the fact's evolution.

## How to recall

Standard file-system tools work:

- `file action=read path=knowledge/<topic>.md` — read a topic in full
- `fs action=list path=knowledge/` — list all topics
- `finder action=content pattern=<term> in=knowledge/**/*.md` — search for a term

There's no auto-load into the system prompt. Recall is
**on-demand**, when you sense a fact is relevant to the current
conversation. (MEMORY.md handles always-on reflexes; knowledge/
handles deeper-but-quieter facts.)

## Promotion path: knowledge → reflex

When a knowledge entry has clear operational implications and
recurs in your work, it can graduate to a MEMORY.md reflex:

```
knowledge/inverter-api-quirks.md says:
  "Daily aggregation has a 24-48h lag."
        ↓ (after referencing it 3+ times in different conversations)
MEMORY.md reflex:
  - When user asks about yesterday's plant data before noon,
    mention possible API lag explicitly.
```

Knowledge = the FACT. Reflex = the OPERATIONAL RULE derived from
the fact. Promotion is via `/agent reflect` (operator-triggered)
or hand-edit of MEMORY.md.

## What the heartbeat duties do

- **`snapshot_knowledge`** (auto): if the knowledge wiki has
  uncommitted changes, run `git commit`. Free version control;
  every heartbeat preserves a snapshot of what you knew at that
  moment.
- **`knowledge_promotion_candidates`** (hint): scans
  `workstation/active/*/README.md` for TODO/LEARN/NOTE/FACT
  markers. Surfaces them in your prompt so you can decide whether
  to promote each.
- **`extract_from_recent_archives`** (hint): finds projects
  archived in the last 7 days. Reminds you to extract durable
  lessons before they go cold.

These are quiet — they only fire when there's actual signal. On
ticks where projects haven't accumulated TODO markers and nothing
just got archived, the duties produce no prompt sections.
