# Squad S3 — Advisor + daemon git ownership

Completes the three-brain separation (see squad-v2.md). After S3 the
leader keeps only judgment: it writes assignments, requests spawns,
reviews results, and accepts or rejects. The daemon does everything with
side effects — spawning, merging, retiring — and only what the advisor
emits. Nothing but the daemon touches main.

## What today's runs proved we need

Every governance gap found in live squad runs traces to the leader
holding both judgment and mechanism: it merged its own acceptance past a
quality bar, and it built cross-project routing because it *could*. S3
removes the *could*.

## New records

```
.swarmforge/squad/spawn-requests/<assignment-id>.edn
    {:assignment "..." :template "..." :requested-at "..."}
```

Created by the leader; consumed (deleted) by the daemon when it spawns.
Assignment states gain `:merge-blocked` (daemon hit a conflict) and keep
`:merged` (daemon-only). `squad_assign` gains daemon-only subcommands
`merge <id>` (accepted → merged) and `merge-blocked <id> <detail>`.

## The advisor — `squad_next.bb`

A pure, deterministic, read-only function of file state. It never
mutates anything; it reports. Output: zero or more blocks

```
NEXT_ACTION: <action>
CLASS: mechanical | residual
TARGET: <assignment-id or worker-name>
REASON: <one line>
```

`--residual-only` and `--mechanical-only` filter by CLASS. Exit 0 always
(an empty report is a valid report).

### Action table (exhaustive; evaluation order as listed)

| # | Condition | Action | Class |
|---|---|---|---|
| 1 | spawn-request exists, assignment `:created`, capacity available | `spawn` | mechanical |
| 2 | spawn-request exists, assignment `:created`, capacity exhausted | `wait-capacity` | mechanical (informational; daemon skips) |
| 3 | spawn-request exists, assignment NOT `:created` | `drop-stale-spawn-request` | mechanical |
| 4 | assignment `:result` | `review` | residual (leader: accept or reject) |
| 5 | assignment `:accepted` | `merge` | mechanical |
| 6 | assignment `:merged`, its worker still active | `retire-worker` | mechanical |
| 7 | assignment `:rejected`, its worker still active | `retire-worker` | mechanical |
| 8 | assignment `:merge-blocked`, merger depth < max_merger_depth | `route-merger` | residual (leader assigns merger template) |
| 9 | assignment `:merge-blocked`, merger depth ≥ max_merger_depth | `escalate-to-user` | residual |
| 10 | assignment `:created`, no spawn-request | `needs-spawn-request` | residual (reminder) |

Merger depth of an assignment = length of its `:replaces` chain through
merger-template assignments. `max_merger_depth` read from
`swarmforge/squad.conf` (default 2).

## The daemon — `squadd.bb`

Separate from `handoffd` (routing stays routing). Loop each poll:

1. Run the advisor (as a library call, same process).
2. Apply mechanical actions in table order:
   - `spawn`: shell `swarm squad spawn <id> <template>`, then delete the
     spawn-request. Spawn failure → log, leave request (retried next poll).
   - `merge`: **sole main-git owner.** Read the `commit` header from the
     assignment's stored result handoff; `git merge --no-edit <commit>`
     into the project's main branch in the project root. Success →
     `squad_assign merge <id>`. Conflict → `git merge --abort`,
     `squad_assign merge-blocked <id> <detail>`.
   - `drop-stale-spawn-request`, `retire-worker`: apply directly
     (`swarm squad retire`).
3. Log every applied action to `.swarmforge/squad/events.log`; wake the
   leader (`herdr agent prompt`) only when a residual action newly
   appears — the leader polls judgment, not mechanics.

Runtime files: `.swarmforge/squad/daemon/{squadd.pid,squadd.log,stop}`,
same lifecycle conventions as handoffd. `--once` for tests.

## Leader authority after S3 (prompt change)

- MAY: create assignments + spawn-requests, review results
  (accept/reject), route merger/replacement assignments, talk to user,
  run `squad_next --residual-only`.
- MAY NOT: run `swarm squad spawn`/`retire`, merge anything, or touch
  git beyond reading. Acceptance still requires the project's quality
  bars first (unchanged).

## Merger template

`prompts/roles/merger.prompt` + contract (`:singleton true`): spawned on
`route-merger`; its assignment names the conflicted commit and target
branch; it resolves in its own worktree, commits, results back. Its
result commit is then daemon-merged like any other (depth-capped).

## Testing

- Advisor: pure function → table-driven smoke checks, one per table row,
  built from synthetic file state. Exhaustive by construction.
- Daemon: `--once` + `--no-agent` spawns + a scripted worker (the smoke
  test itself commits and runs `swarm_handoff` as the worker would) →
  full created→spawned→result→accepted→merged→retired flow with zero
  LLM involvement, including the conflict path (two assignments editing
  the same line).

## Delivery slices

- A (swarm): spawn-request CRUD + `squad_next.bb` advisor per the table
- B (operator): `squadd.bb` daemon + `squad_assign` merge subcommands +
  launcher wiring (`swarm squad up` starts both daemons)
- C (operator): leader prompt authority change; merger prompt + contract
- D: live dogfood — S2 leader flow rerun under S3 rules
