# Squad hardening — Design

> Status: partially complete. S5, S6, S7a, and S7b are implemented and
> smoke-verified; deterministic agent profiles extend S6. S7c is deferred
> and S8 remains pending.
> Continues [squad v2](squad-v2.md) (S1–S4 complete) without reopening
> the three-brain split.

Live squad runs exposed failure modes beyond v2: dead workers were invisible
to the state machine, provider choice was not durable, and mechanism ownership
depended too heavily on prompts. This document records the resulting
hardening plan and its current implementation status.

## Findings (squad-specific)

The pack runtime has its own gaps ([prompt sync](prompt-sync.md),
[pack blockers](pack-blockers.md), contract evidence as commit-message
regex). Those are real, and they are not this plan. What follows is
what actually breaks **squad**.

### 1. Dead workers stalled the squad silently — resolved by S5

GitHub issue
[#2](https://github.com/bandoyer/swarm-forge-herdr/issues/2). Highest
priority.

Before S5, worker records moved only through
`:allocated -> :active -> :retired`; nothing observed agent death. After a
herdr restart, crash, or reboot:

- the worker record stays `:active`
- its assignment stays `:spawned`, a state the advisor treats as "a
  live worker is on it" (no row in the S3/S4 table fires)
- `swarm squad spawn` correctly refuses (`is 'spawned', not 'created'`)
- nothing wakes the leader; `squad_next` is empty; the squad goes quiet

Confirmed on Windows (herdr has no live server handoff, so every upgrade
kills in-flight agents). The same gap exists on Linux for a crashed
worker. Manual recovery already worked: retire the dead worker, reject
the orphaned assignment (`reject` accepts `:spawned` for this reason),
replace, spawn. S5 added fail-closed Herdr reconciliation, a three-poll
absence threshold with launch grace, and advisor row 14 (`report-orphan`).

### 2. "Daemon-only" was a comment — guarded by S7a and S7b

Before S7, `squad_assign` documented `merge` / `merge-blocked` as daemon-only
(`swarmforge/scripts/squad_assign.bb`), but they were ordinary scripts. Any
pane with a shell could mark an assignment `:merged` without `git merge`,
or `:merge-blocked` without a conflict. `squadd` was the intended sole owner
of main without a mechanism-level accident boundary.

The same honor system covered the leader's other bans: it sat in the
project root (`bin/swarm` `squad-up!`), had no contract, and was one
`git commit` away from authoring product artifacts. S3 removed the
*habit* of the leader merging. It did not remove the *ability*.

S7a now gates daemon-owned assignment transitions with
`SWARMFORGE_SQUADD`; S7b installs a leader contract that forbids new product
commit handoffs while allowing record work and re-delivery of a worker's
recorded result. These are accident boundaries, not an unforgeable security
boundary; the optional S7c hook remains deferred.

### 3. Transient workers always launched as Claude — resolved by S6

Before S6, `squad-spawn!` started every worker with `--kind claude`,
regardless of the leader's kind or the template. S6 made worker kind durable
configuration and assignment data. The later
[agent-profile slice](squad-agent-profiles-spec.md) added deterministic model
and effort pins for leaders, defaults, templates, and individual assignments.

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

### 5. Design overclaim: contracts vs capability flags — partly resolved

Earlier revisions of [squad-v2.md](squad-v2.md) described spawn-time flags
(`:may-web-search`, `:may-spawn`, `:required-tools`) and result-time
checks that required tools actually ran. Implemented contracts are
`:artifact-roots` plus regexes over the commit message, enforced at
`swarm_handoff`. Empty `:artifact-roots` is not a "writes nothing"
sentinel and an absent contract still means no enforcement. S7b added the
explicit `:forbid-git-handoff` leader boundary. Spawn-time capability flags
and proof that named tools actually ran remain unimplemented; current
evidence checks match commit-message receipts.

The remaining capability work is out of scope for S5–S8 because it changes
S1's evidence philosophy.

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

S5, S6, S7a, and S7b landed as independently specified, smoke-tested slices.
S8 remains planned; S7c remains optional and deferred.

### S5 — Dead-worker reconciliation ✅

Implemented 2026-08-25 from issue #2. The final acceptance contract is in
[the S5 specification](squad-hardening-s5-spec.md).

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

### S6 — Worker agent kind is data ✅

Implemented 2026-08-26. Spawn records the agent kind and the launcher honors
it; [deterministic agent profiles](squad-agent-profiles-spec.md) now extend
that record with optional model and effort pins.

- `swarmforge/squad.conf` supports `worker_kind <kind>` (default
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

S7a and S7b were implemented 2026-08-26. S7c remains optional and deferred.

**S7a — env gate (accidents) ✅.** `squadd` sets
`SWARMFORGE_SQUADD=1` in its child environment. `squad_assign
merge` and `merge-blocked` die 2 `DAEMON_ONLY` unless that env is set.
The leader's prompt forbids these commands, and they also fail
closed if it tries.

This stops a prompt-following leader. It does not stop a leader that
exports the variable. Honest about that.

**S7b — leader contract (authoring) ✅.** The stock `squad-leader`
contract sets `:forbid-git-handoff true`. It blocks new product commit
handoffs while preserving assignment-record work, notes, and rework handoffs
that carry a worker's recorded result commit.

**S7c — stronger local Git guard (optional, later).** A
`reference-transaction` hook could refuse protected-branch ref changes that
do not come through the daemon. A normal `update` hook is receive-pack-only
and would not guard local merges. This would still be an accident boundary,
not true unforgeability against another process running as the same user;
specify the threat model before implementing it.

### S8 — Atomic records and stale locks — pending

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

The implemented slices are covered headlessly by the smoke suite:

- S5: fake `herdr` on PATH that omits a worker for K polls, then
  assert retire + `worker-lost` + leader wake. A failing `agent list`
  must change nothing. Row 14 fires on a `:spawned` assignment with
  no active worker and does not fire when one exists.
- S6: kind default and override, as above.
- S7a: `merge` without the env exits 2; `squadd --once` can still
  merge.
- S8 remains planned: lock steal and atomic-write checks land with that slice.

S5's fake-Herdr matrix covers missing, present, malformed, and unreachable
agent-list responses, independent miss streaks, launch grace, retirement, and
leader wake-up behavior.

## Non-goals

- Prompt sync, pack blockers, CI for the smoke suite, splitting
  `bin/swarm`. Real, tracked elsewhere.
- Executing quality tools inside `swarm_handoff`. That is an S1
  follow-up and a philosophy change (receipts vs invocation).
- Skipping contract checks on merge commits. Pack+squad, not S5.
- Resuming a dead worker's uncommitted files.
- Web dashboard, module maps, multi-project squads (still deferred).

## Resolved design questions

1. S5 uses K=3 successful misses. A newly allocated worker receives 15
   seconds of launch grace; active workers enter the counter immediately.
2. Advisor row 14 covers only `:spawned` orphan assignments. Existing
   created/spawn-request actions already cover pre-activation failures.
3. The S7a gate is the mechanism-specific `SWARMFORGE_SQUADD`.

## Remaining work

- S8: atomic squad records and stale `sequence.lock` recovery.
- S7c: an optional local ref guard if the project later needs a stronger
  accident boundary than S7a/S7b.
- Prompt sync and pack blockers remain separate designs rather than squad
  hardening slices.
