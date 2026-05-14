# Workstation Keeper

This competency tends the agent's **workstation** — the GitHub-like local
platform under `<office>/workstation/`. The agent without
`workstation-keeper` still HAS a workstation (the `workstation` tool
works fine on demand), but tidiness drifts over time. This competency
adds the periodic discipline that keeps it clean.

Same pattern as `thinker`: the cognitive store TOOLS exist as primitives;
the COMPETENCY adds the heartbeat-driven discipline that keeps them from
rotting.

## What this competency tends

The workstation has three concerns that need periodic attention:

| Concern | Tool primitive | Heartbeat duty |
|---|---|---|
| Cross-project drift (README↔disk, dirty git, broken symlinks, empty scaffolds) | `workstation audit scope=workstation` | weekly |
| Stale done items (clutter in active project views) | `shell run` filter on items/*.json | weekly |
| Stale repos (90d+ no commits) | `shell run` git log scan | monthly |
| Link health (project metadata refs broken or stale) | `shell run` find scan | monthly |

## Cognitive store discipline (when to use which workstation action)

The shape of what you're noticing dictates where it lands:

| Shape | Goes to | Action |
|---|---|---|
| "I need a code container for this" | `<office>/workstation/repos/<name>/` | `workstation method=repo.create name=...` |
| "I need to track work that may span multiple sessions" | `<office>/workstation/projects/<name>/` | `workstation method=project.create name=...` |
| "Specific work item with status / fields" | `<office>/workstation/projects/<name>/items/<id>.json` | `workstation method=item.add project=... title=... fields={...}` |
| "Untimed personal queue item, no project" | `<office>/notes/todo.jsonl` | `todo defer summary=...` (different tool) |
| "Time-anchored reminder" | cron service or notes.org | `schedule add ...` (different tool) |

**Crisp test when capturing work:**
1. Is this for me (ephemeral) or for a project tracker (persistent)? → `todo` vs `workstation item`
2. Is this a fact or a task? → `knowledge` vs `workstation item`
3. Does this need its own code container? → `workstation repo`

## The four duties (heartbeat-driven)

### 1. weekly_workstation_audit

Runs `workstation audit scope=workstation` weekly. Returns a per-project
health report. For each `needs_attention` project:
- Read the drift list (readme_drift, broken_symlinks, git_dirty, empty_dirs)
- Investigate root cause
- Either fix the drift OR archive the project if it's dead

**Don't let drift accumulate.** A project with 3 broken symlinks today
will have 30 in six months.

### 2. weekly_clean_done_items

Items stuck in `status=done` for >14 days are surfaced for cleanup
decision. Two paths:
- The done item is a meaningful historical record → leave it
- The done item is just clutter → `workstation method=item.remove` (Phase 2)
  or move to an `archived/` subfolder under items/

A project with 200 done items + 5 active items has poor visibility into
what's actually being worked on.

### 3. monthly_archive_stale_repos

Repos with no commits in 90+ days are surfaced. For each:
- Confirm it's a finished/abandoned project
- Either `workstation method=repo.archive` (Phase 2) or move to `_archive/`
  manually
- Or do nothing — sometimes long-quiet repos hold reference work the
  agent will return to

**Always confirm before archiving.** Don't blindly process the list.

### 4. monthly_link_health

Surfaces projects with anomalous item counts:
- 0 items → dead draft, candidate for close
- >50 items → may need splitting or pruning

For each, decide: prune, split, or accept.

## Anti-patterns

- **Skipping audits.** The audit catches drift before it compounds. If
  you skip three audits, the workstation has accumulated 3× the cleanup
  work, not 1×.
- **Reflex archiving.** Archiving a repo without confirming it's truly
  done is a way to lose work. Always check the last commit's content and
  ask whether it represents a parking-spot or a finished state.
- **Treating items as messages.** Items are persistent project records.
  Don't use `workstation method=item.add` for "remind me to ask Jerry about
  X" — that's a `todo` or a `chat` follow-up. Items are work the project
  is tracking long-term.
- **Conflating projects with todos.** A project is multi-item, multi-
  session work. A todo is "do this thing once." Don't create a project
  for every individual task — projects are for tracking work that has
  shape over time.

## What this competency does NOT cover

- **Tool-level CRUD.** That's the `workstation` tool. This competency
  uses it; doesn't implement it.
- **Cross-agent coordination.** The workstation is per-agent. For
  multi-agent project work, see `collaborate` (eager push) and
  `collaborate.assign` (late-binding pool).
- **Project-substantive decisions.** The competency surfaces drift and
  staleness; the agent decides what to do about it. Auto-archive without
  confirmation is OUT.
- **Forgetting old projects.** Archive ≠ delete. The workstation
  preserves history; cleanup is about visibility, not deletion.

## Why "workstation-keeper"

Mirrors `thinker` (which tends memory + knowledge + heart). Same shape:
- Tool primitive exists separately
- Competency adds heartbeat-driven hygiene

The agent with this competency loaded notices when their workstation is
drifting and tends it. The agent without notices nothing — and after
six months, opens `workstation overview` to find 30 stale repos and
dozens of items rotting in `done`.
