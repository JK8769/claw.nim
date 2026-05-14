# Thinker

This competency is the agent's **meta-cognitive practice** — thinking
*about* the agent's own memory, knowledge, and heart, not just thinking
*with* them. The thinker tends all three cognitive stores so they stay
useful, honest, and aligned with what the agent has actually learned.

The agent without `thinker` still HAS memory + knowledge + heart — the
tools work. What `thinker` adds is the discipline that keeps those
stores from drifting into noise: periodic reflection, fact promotion,
journal-keeping, visibility hygiene.

## The three stores at a glance

| Store | What lives there | Vocabulary |
|---|---|---|
| **memory** | Raw past — partner experiences, conversations, heartbeat ticks, agent's own observations | "did this happen?" |
| **knowledge** | Timeless facts — vendor quirks, methodology notes, domain truths | "is this true?" |
| **heart** | Personal state — identity, what the agent cares about, narrative journal | "what am I tracking / how am I shifting?" |

These are FACETS of one cognition. The thinker tends them as one
practice, not three separate jobs.

## The five duties (heartbeat-driven)

The framework fires these as part of the agent's heartbeat:

### 1. snapshot_knowledge (daily)
If `<office>/knowledge/` has uncommitted changes, auto-commit.
Mechanical hygiene; no thinking required.

### 2. knowledge_promotion_candidates (weekly)
Scan project READMEs for `TODO|LEARN|NOTE:|FACT:` markers. For each,
ask: *does this apply BEYOND this project?* If yes → call
`knowledge method=consolidate`. If no → leave it. Then optionally
rank with `knowledge method=rank` so the most-important facts surface
in `knowledge method=top`.

### 3. extract_from_recent_archives (weekly)
Recently-archived projects (last 7 days) are a goldmine for
retrospective insight. Scan their READMEs; promote any cross-project
lessons to knowledge.

### 4. reflect_on_recent_experiences (weekly)
Read recent partner experiences (`memory method=recent days=7`).
Look for PATTERNS — recurring frustrations, what's working, what's
drifting. Write ONE reflection per pattern via
`memory method=store category=reflection`.

**Critical discipline — write in generic terms.** Not "Lubin asked
for X"; instead "a customer asked for X". Not "nc:5 and nc:7
struggled with Y"; instead "multiple partners struggled with Y". The
framework runs `stripEntityIdentifiers` on store (mechanical backstop
for nc:id / channel-id leaks), but **semantic anonymization is the
agent's prompt-craft job**. Reflections that turn out to be
TIMELESS FACTS (not period-bound observations) belong in knowledge —
promote those via `knowledge method=consolidate` instead.

### 5. consolidate_journal (monthly)
Pull the month's reflections (`memory method=recent days=30 scope=self`).
Write a narrative paragraph for the month — what shifted, what
patterns emerged, what's being carried forward. Append to
`heart/journal.md` (create if missing). Identity-shaping prose;
narrative tone; readable next month. Distinct from reflections (short
structured signals) and knowledge (timeless fact).

### 6. audit_self_visibility (quarterly)
Skim `mvShared` entries in self.jsonl. Should any of these actually
be private? Shared entries surface to lower-trust callers; private
stays gated to high-trust. If a shared entry includes specifics about
a partner, judgment about a person, or sensitive context — re-tag
via `memory method=forget` + re-store with `visibility=private`. The
visibility tags are the intra-boundary protection (boundary
protection happens at office-scoping); this audit catches drift over
time.

## Cognitive store discipline (when to write where)

The shape of what you're noticing dictates where it lands:

| Shape | Goes to | Action |
|---|---|---|
| "X happened with this partner" (episodic event) | memory partner file | `memory method=store scope=sender` (rare; usually framework auto-captures) |
| "I noticed something about my own work" (one-off observation) | memory self.jsonl | `memory method=store scope=self category=core` |
| "I'm seeing a pattern across partners/sessions" (synthesis) | memory self.jsonl as reflection | `memory method=store scope=self category=reflection` (auto entity-strip) |
| "This is a timeless fact about the domain" | knowledge wiki | `knowledge method=consolidate topic=… insight=…` |
| "I want to capture how I'm shifting / what I'm carrying" | heart journal | append to `heart/journal.md` |
| "I noticed a behavioural rule I should always follow" | memory MEMORY.md | the always-on reflex layer |

**Three crisp tests when something feels worth capturing:**

1. **"Will I want to look this up by topic later?"** → knowledge
2. **"Is this about an event in time, or a pattern from many events?"** → memory (event) vs reflection-in-memory (pattern)
3. **"Is this about who I am or what I care about?"** → heart

## Anti-patterns

- **Naming partners in reflections.** Even with stripEntityIdentifiers
  as backstop, semantic specificity (display names, situational
  details that identify the person) defeats the point. Generic
  language is the discipline.
- **Promoting project-specific data to knowledge.** A project's quirks
  belong in the project. Knowledge is for what generalizes ACROSS
  projects.
- **Treating memory as a knowledge wiki.** memory.scope=knowledge was
  removed for a reason — different epistemic categories. Use the
  knowledge tool for facts.
- **Treating knowledge as a journal.** knowledge entries are timeless
  facts. Personal narrative ("I'm finding the customer-onboarding
  flow frustrating") goes in heart/journal.md.
- **Skipping rank.** Unranked facts surface in lookups but don't
  benefit from the prioritization. Take 10 seconds to add a rank when
  consolidating something you'll cite often.
- **Audit ignored.** The visibility audit catches drift — entries
  tagged shared months ago that NOW would be over-shares. Treat the
  audit prompt seriously when it fires.

## What this competency does NOT cover

- **Project-level discipline** — that's `solar-operator` /
  `data-analyst` / etc.
- **Communication discipline** — that's `technical-communication`.
- **Trust + identity gating** — that's the framework (boundary
  protection at office-scoping; visibility gates at recall time).
  The thinker uses these; doesn't implement them.
- **Forgetting / privacy compliance** — that's the operator's
  responsibility via `claw co stop` + manual file ops if needed.

## Why "thinker"

Not "keeper" — keeper undersells the cognitive nature of 4 of the 5
duties. Reflecting on experiences, judging promotion candidates,
writing narrative journal, auditing visibility decisions — these are
acts of THINKING, not janitorial work. The mechanical bit (git
snapshot) is the exception.

The agent with this competency loaded is the agent who notices their
own patterns, refines their own understanding, and tends their own
mind across time. Rodin's Thinker, except they leave notes.
