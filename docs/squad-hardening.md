# Squad hardening — Design

> Status: proposed. Nothing built yet.
> Continues [squad v2](squad-v2.md) (S1–S4 complete). Does not reopen
> the three-brain split.

Squad v2 works when every agent stays alive and every actor stays inside
its lane. Live runs have shown two classes of failure that the state
machine cannot currently see: a worker that dies, and a leader (or
worker) that *can* operate mechanism even though the prompts say it
must not. This document is the follow-on plan.

## Findings (squad-specific)

The pack runtime has its own gaps ([prompt sync](prompt-sync.md),
[pack blockers](pack-blockers.md), contract evidence as commit-message
regex). Those are real, and they are not this plan. What follows is
what actually breaks **squad**.

### 1. Dead workers stall the squad silently

GitHub issue
[#2](https://github.com/bandoyer/swarm-forge-herdr/issues/2). Highest
priority.

Worker records only move through `:allocated -> :active -> :retired`.
Nothing observes agent death. After a herdr restart, crash, or reboot:

- the worker record stays `:active`
- its assignment stays `:spawned`, a state the advisor treats as "a
  live worker is on it" (no row in the S3/S4 table fires)
- `swarm squad spawn` correctly refuses (`is 'spawned', not 'created'`)
- nothing wakes the leader; `squad_next` is empty; the squad goes quiet

Confirmed on Windows (herdr has no live server handoff, so every upgrade
kills in-flight agents). The same gap exists on Linux for a crashed
worker. Manual recovery already works: retire the dead worker, reject
the orphaned assignment (`reject` accepts `:spawned` for this reason),
replace, spawn. The state machine is sound. Detection is missing.

### 2. "Daemon-only" is a comment

`squad_assign` documents `merge` / `merge-blocked` as daemon-only
(`swarmforge/scripts/squad_assign.bb`). They are ordinary scripts. Any
pane with a shell can mark an assignment `:merged` without `git merge`,
or `:merge-blocked` without a conflict. `squadd` is the *intended* sole
owner of main; it is not the *enforced* one.

The same honor system covers the leader's other bans: it sits in the
project root (`bin/swarm` `squad-up!`), has no contract, and is one
`git commit` away from authoring product artifacts. S3 removed the
*habit* of the leader merging. It did not remove the *ability*.

This is not the same severity as (1). Prompt-following leaders behave.
A confused or jailbroken leader is how every live governance gap in
early squad runs started.

### 3. Transient workers always launch as Claude

`squad-spawn!` in `bin/swarm` starts every worker with `--kind claude`,
regardless of the leader's kind or the template. A Codex or Grok
leader therefore runs a mixed-provider squad that cannot be configured.
The six-pack work can pick Grok and Codex per role; squad cannot.

### 4. Crash durability of records is weaker than the handoff queue

Handoffs write through a temp file and rename
(`handoff_lib/atomic-write!`). Assignment, worker, approval, and
spawn-request records `spit` in place (`squad_lib/write-record!`). A
killed process can leave a truncated EDN file that `edn/read-string`
cannot parse, which takes the advisor and daemon down with it.

`next-sequence` uses a lock directory with no stale recovery. A crash
during `swarm_handoff` leaves `sequence.lock` in that worktree; the
next outbound handoff spins forever. Packs share this; squad workers
hit it on every result.

### 5. Design overclaim: contracts vs capability flags

[squad-v2.md](squad-v2.md) describes spawn-time flags
(`:may-web-search`, `:may-spawn`, `:required-tools`) and result-time
checks that required tools actually ran. Implemented contracts are
`:artifact-roots` plus regexes over the commit message, enforced at
`swarm_handoff`. Empty `:artifact-roots` is not a "writes nothing"
sentinel — an absent contract means no enforcement at all, so the
leader cannot be gated by installing an empty one.

Out of scope for the first slices (it changes S1's evidence
philosophy). Recorded so the design doc stops claiming it.

## Invariants this plan must not break

From `AGENTS.md` and [squad-s3.md](squad-s3.md):

- The advisor stays read-only and deterministic.
- Only `squadd` applies mechanical actions; the leader writes records
  only.
- Detection of a dead worker is mechanism (daemon). Replacement is
  judgment (leader).
- Protocol tokens, exit codes, and file formats stay compatible.
- Never reconcile against `herdr agent list` when that call *fails* —
  a herdr outage must not mass-retire a healthy squad.

## Delivery phases

Each slice lands runnable, smoke-tested, and (for S5) dogfoodable
before the next starts — same cadence as S1–S4.

### S5 — Dead-worker reconciliation

The issue #2 proposal, unchanged in substance.

**Mechanism** (`squadd` poll, after mechanical actions, before residual
wake):

1. Call `herdr agent list`. If it is not ok, count this poll as
   nothing and return. Log `reconcile-skipped herdr-unreachable`.
2. Compare live agent names against workers in `:allocated` or
   `:active`.
3. A worker missing for **K consecutive successful polls** (K=3, ~3s
   at the current 1s poll, long enough to race a respawn, short enough
   to beat a human noticing) is dead:
   - retire it through the existing `swarm squad retire` path (record
     → `:retired`, `roles.tsv` row removed, worktree removed)
   - log `worker-lost <name> agent absent` to `events.log`
   - wake the leader with a notice that names the orphaned assignment

**Policy** (advisor, additive row 14):

| # | Condition | Action | Class |
|---|---|---|---|
| 14 | assignment `:spawned`, no non-retired worker bound to it | `report-orphan` | residual |

Row 14 makes the stall visible in `squad_next --residual-only` even if
the daemon has not yet retired the worker (or cannot, because herdr is
down). The leader already knows how to reject-and-replace; the prompt
gains one sentence pointing at this row.

K and the herdr-unreachable rule are the whole design. Do not resume
uncommitted work. Slices restart by design.

### S6 — Worker agent kind is data

Spawn records the agent kind; the launcher honors it.

- `swarmforge/squad.conf` gains `worker_kind <kind>` (default
  `claude`, matching today's behavior).
- `squad_spawn_request` may override per assignment
  (`create <id> <template> [kind]`).
- The worker EDN record stores `:agent-kind`.
- `squad-spawn!` starts `--kind` from the record, not the literal
  `"claude"`.
- `swarm squad up <kind>` continues to set only the **leader** kind.

Smoke: a `--no-agent` spawn with `worker_kind grok` writes `:agent-kind
"grok"` and the roles.tsv kind column; default remains `claude`.

This unblocks a Grok/Codex squad. It does not by itself make mixed
providers wise — that is an operator choice, same as pack conf.

### S7 — Make daemon-owned transitions actually daemon-owned

Two layers. Land the first; the second is optional hardening.

**S7a — env gate (accidents).** `squadd` already sets `SWARM_BIN` in
its extra env. Add `SWARMFORGE_SQUADD=1` to that map. `squad_assign
merge` and `merge-blocked` die 2 `DAEMON_ONLY` unless that env is set.
The leader's prompt already forbids these commands; now they also fail
closed if it tries.

This stops a prompt-following leader. It does not stop a leader that
exports the variable. Honest about that.

**S7b — leader contract (authoring).** Give `squad-leader` a stock
contract whose artifact roots are empty *and* whose meaning is "no
git_handoff of a product commit." That requires a schema change:
today a missing contract means "no enforcement." Add
`:forbid-git-handoff true` (or treat a present contract with empty
`:artifact-roots` as a total write ban, and never treat absence that
way). The leader can still write assignment records; those are not
git_handoffs.

**S7c — git hook (optional, later).** An `update` hook on the main
branch that refuses merges unless the committer matches the daemon's
identity. Real unforgeability. Defer until S7a/S7b are lived with;
hooks are per-clone and easy to skip with `--no-verify`.

### S8 — Atomic records and stale locks

Shared with packs; cheapest to do from the squad side because
`write-record!` is the common writer.

- `write-record!` uses the same temp-file + rename as handoffs, in the
  record's directory.
- `next-sequence`'s lock directory stores the locker pid; a lock whose
  pid is dead is stolen. If pid files are unreliable (the Windows
  port), fall back to mtime older than 30s.

Smoke: a truncated status.edn from a previous crash does not take down
`--once` (create recovers, matching theme-create recovery already in
the suite); a planted stale `sequence.lock` with a dead pid does not
block the next handoff.

## Testing

All of this is file-state plus `herdr-try`, so it tests headlessly:

- S5: fake `herdr` on PATH that omits a worker for K polls, then
  assert retire + `worker-lost` + leader wake. A failing `agent list`
  must change nothing. Row 14 fires on a `:spawned` assignment with
  no active worker and does not fire when one exists.
- S6: kind default and override, as above.
- S7a: `merge` without the env exits 2; `squadd --once` can still
  merge.
- S8: lock steal and atomic write, as above.

Live dogfood for S5: kill herdr mid-assignment (the #2 drill) and
confirm the leader is woken with `report-orphan` rather than sitting
idle.

## Non-goals

- Prompt sync, pack blockers, CI for the smoke suite, splitting
  `bin/swarm`. Real, tracked elsewhere.
- Executing quality tools inside `swarm_handoff`. That is an S1
  follow-up and a philosophy change (receipts vs invocation).
- Skipping contract checks on merge commits. Pack+squad, not S5.
- Resuming a dead worker's uncommitted files.
- Web dashboard, module maps, multi-project squads (still deferred).

## Open questions

1. K=3 at a 1s poll is ~3s. Is that long enough that a slow
   `agent start` cannot look dead? If spawn itself takes >3s of "agent
   not in the list yet," S5 will retire a worker it just launched.
   Mitigation: do not reconcile a worker whose `:state` is `:allocated`
   and whose `:updated-at` is younger than 15s; only `:active` workers
   enter the K-counter immediately.
2. Should row 14 also cover `:created` with a spawn-request whose
   worker vanished between allocate and activate? S5's retire path
   already frees the slot; the leader would see `needs-spawn-request`
   or a fresh `spawn` once the stale request is dropped. Probably no
   extra row.
3. S7a env var name: `SWARMFORGE_SQUADD` vs reusing a more general
   `SWARMFORGE_MECHANISM`. Prefer the specific name; there is only one
   mechanism owner.

## Suggested order of work

S5 first (live failure). S6 next if the Grok/Codex six-pack is going
to have a squad counterpart; otherwise S7a is the cheaper correctness
win. S8 whenever a crash-corruption shows up, not before — it is
real but has not been the live incident.
