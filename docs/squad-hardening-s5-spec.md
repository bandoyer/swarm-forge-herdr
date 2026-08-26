# Squad hardening S5 — Dead-worker reconciliation specification

This slice implements S5 from [squad-hardening.md](squad-hardening.md):
the squad daemon detects worker agents that have disappeared, retires
them through the existing mechanism, and exposes their orphaned
assignments to the leader through advisor row 14. It does not recover or
resume anything from a dead worker's worktree.

## Definitions

- An **authoritative agent observation** is a successful `herdr agent
  list` call whose response yields the live agent-name collection. A
  command that cannot start, exits nonzero, or does not yield a usable
  agent list is **herdr-unreachable**. A successful empty list is
  authoritative.
- A usable agent list has an `agents` collection in the existing Herdr
  response location, and every member resolves to a nonblank string name:
  either the member itself is a string, or its `name`/compatible `label`
  field supplies that string. A missing collection, a collection of the
  wrong type, or any member that has no usable string name makes the
  entire observation herdr-unreachable. The daemon must not silently
  drop malformed members and reconcile against the remaining partial
  list.
- A **reconciliation candidate** is a worker record in `:active`, or an
  `:allocated` worker whose `:updated-at` is at least 15 seconds old.
  An `:allocated` worker younger than 15 seconds is in its launch grace
  period. `:retired` workers are never candidates.
- A candidate is **present** when its exact `:name` occurs in the
  authoritative agent observation and **missing** otherwise.
- A worker's **miss streak** is the number of consecutive authoritative
  observations in which that eligible worker was missing. The loss
  threshold is exactly K=3.
- A **bound non-retired worker** is a worker whose `:assignment` equals
  the assignment id and whose state is `:allocated` or `:active`.

## Daemon behavior

Reconciliation runs once per `squadd` poll after the existing mechanical
actions and before residual detection and leader wake-up.

1. The daemon obtains one authoritative agent observation per poll.
   When herdr is unreachable, it:

   - appends `reconcile-skipped herdr-unreachable` to `squadd.log`;
   - does not increment, reset, or otherwise alter any worker's miss
     streak;
   - does not retire a worker or append a `worker-lost` event because of
     reconciliation; and
   - continues the poll into residual detection, so an orphan already
     represented by file state remains reportable.

2. On an authoritative observation, each reconciliation candidate is
   evaluated independently:

   - observing the worker present resets its miss streak to zero;
   - observing it missing increments its miss streak by one;
   - misses one and two leave all worker, assignment, routing, and
     worktree state unchanged; and
   - miss three declares the worker lost. A fourth miss is not required.

3. Launch grace is state-specific:

   - an `:active` worker enters the counter immediately, regardless of
     the age of `:updated-at`;
   - an `:allocated` worker younger than 15 seconds does not enter or
     advance the counter; and
   - beginning at age 15 seconds, an absent `:allocated` worker follows
     the same K=3 rule as an `:active` worker.

4. A lost worker is retired by the existing `swarm squad retire` path,
   not by a second cleanup implementation. Its worker record becomes
   `:retired`, its `roles.tsv` row is removed, and its worktree is
   removed according to that path's existing behavior. Existing retire
   tokens, exit codes, sidecar handling, and `--no-agent` behavior remain
   compatible.

5. Successful loss handling appends one timestamped event whose message
   fields are `worker-lost <worker-name> agent absent` to
   `.swarmforge/squad/events.log`. It then allows residual detection in
   the same poll. The new `report-orphan` residual wakes the leader once
   under the existing residual-dedup rules, and the wake notice names the
   orphaned assignment id (all newly orphaned ids when one poll finds
   more than one).

Miss history need not survive a daemon restart. It must not change the
existing assignment, worker, handoff, routing, or configuration file
formats.

## Advisor row 14

The existing deterministic, read-only advisor table gains this final
row, after rows 1–13:

| # | Condition | Action | Class | Target |
|---|---|---|---|---|
| 14 | non-replaced assignment is `:spawned` and has no bound non-retired worker | `report-orphan` | `residual` | assignment id |

The block keeps the existing four-line protocol:

```text
NEXT_ACTION: report-orphan
CLASS: residual
TARGET: <assignment-id>
REASON: spawned assignment has no non-retired worker; leader must reject and replace it
```

Consequently:

- no worker record and only `:retired` bound worker records both produce
  `report-orphan`;
- any bound `:allocated` or `:active` worker suppresses the row, without
  consulting herdr;
- assignments in states other than `:spawned`, and assignments already
  marked as replaced, do not produce the row;
- `--residual-only` includes it and `--mechanical-only` excludes it; and
- repeated reads of unchanged file state are byte-identical and do not
  mutate state.

The advisor remains a function of file state only. A herdr outage does
not suppress row 14, but an actually absent agent is not an advisor-level
orphan until the file state has no non-retired worker bound to the
assignment.

## Leader recovery instruction

The squad-leader prompt gains one instruction for `report-orphan`: the
leader rejects the orphaned `:spawned` assignment, replaces it, and
creates the replacement's spawn request through the existing record
commands. The replacement starts from committed project state. Neither
the leader nor the replacement worker attempts to recover, copy, or
resume the retired worker's uncommitted files.

`prompts/roles/squad-leader.prompt` remains the source of truth. If that
prompt changes, its installed `swarmforge/roles/squad-leader.prompt`
copy must be synchronized in the same commit.

## Worked poll sequences

For an eligible worker, `M` is an authoritative observation where it is
missing, `P` is one where it is present, and `U` is herdr-unreachable.

| Observations | Required result |
|---|---|
| `M, M` | worker remains non-retired; no `worker-lost` event |
| `M, M, M` | retire on the third observation and report its assignment |
| `M, M, P, M, M` | worker remains non-retired because `P` reset the streak |
| `M, M, U, M` | `U` changes nothing; the next authoritative miss is miss three |
| `U, U, U` | no reconciliation retirement, even though three polls occurred |

For a missing `:allocated` worker, authoritative polls while
`:updated-at` is younger than 15 seconds do not contribute any `M` to
these sequences. Once the worker reaches 15 seconds old, its first
authoritative absent observation is miss one.

## Acceptance checks

`test/smoke.sh` adds headless coverage using a fake `herdr` on `PATH`:

1. A successful list that contains an `:active` worker keeps it active
   and resets an earlier miss streak.
2. A missing eligible worker survives two consecutive successful polls
   and is retired on the third, with its record, routing row, and
   worktree checked after each boundary.
3. A failed or unusable `agent list` after two misses logs
   `reconcile-skipped herdr-unreachable`, changes none of those artifacts,
   and neither advances nor resets the streak; the next successful miss
   completes the streak. The unusable-response matrix includes a missing
   `agents` collection, a non-collection value, a nameless member, a
   non-string or blank name, and a mixture of valid and malformed members.
   Every case fails closed as one unusable observation; none may be
   converted to an empty or partially filtered authoritative set. The
   adjacent control proves that an exact successful `agents: []` remains
   authoritative and advances the streak.
4. A young `:allocated` worker survives at least three successful absent
   observations, while an otherwise equivalent `:allocated` record at
   least 15 seconds old retires only on its third successful absence.
5. Loss appends exactly one `worker-lost <name> agent absent` event and
   prompts the configured leader with the orphaned assignment id.
6. Table-driven advisor checks prove row 14 for both a missing worker
   record and a retired bound worker, its suppression by `:allocated`
   and `:active` bound workers, its state/replacement exclusions, its
   table position, and both class filters.
7. Existing advisor determinism/read-only checks and existing daemon
   mechanical, residual-wake, approval, protocol-token, and exit-code
   checks continue to pass.

The completed slice must run `./test/smoke.sh` and end with
`SMOKE PASSED (N checks)`. Every changed `.bb` entry must also parse.

## Scope boundaries

- S5 may change only `docs/`, `swarmforge/scripts/`, `bin/`, and `test/`,
  except for the required source-and-installed squad-leader prompt pair
  described above.
- Do not implement S6 worker kinds, S7 authority gates, or S8 atomic
  records/stale-lock recovery.
- Do not add a new public command, resume dead-worker work, preserve its
  uncommitted changes, or change the one-second poll interval.
- Existing output tokens, exit codes, record schemas, handoff formats,
  and file locations remain compatible; S5 only adds the documented
  advisor action and log messages.
