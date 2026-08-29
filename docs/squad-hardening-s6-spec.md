# Squad hardening S6 — Worker agent kind is data specification

Status: **IMPLEMENTED AND VERIFIED — 2026-08-26.**

This slice implements S6 from [squad-hardening.md](squad-hardening.md):
the agent kind of a transient squad worker becomes recorded data that the
launcher honors, instead of the literal `"claude"` hard-coded in
`squad-spawn!`. It changes which kind a worker is started with and where
that kind is recorded — nothing about when or whether workers spawn.

## Definitions

- An **agent kind** is the value handed to `herdr agent start --kind`
  (today: always `claude` for workers). A **valid kind** matches
  `[A-Za-z0-9][A-Za-z0-9._-]*` — the same shape gate templates already
  pass, and for the same reason: a kind becomes a herdr CLI argument, a
  `roles.tsv` column, and event-log detail.
- The **kind resolution order** for one worker spawn, highest first:

  1. an **explicit kind** given on the spawn path for that assignment
     (the optional `[kind]` argument defined below);
  2. the **configured kind**: a `worker_kind <kind>` line in
     `swarmforge/squad.conf`;
  3. the literal `claude`.

  Resolution happens exactly once, at worker allocation; every later
  reader (the `roles.tsv` row, `herdr agent start --kind`) takes the
  resolved kind from the worker record, never re-resolves it.

## Behavior

### squad.conf: `worker_kind`

- `swarmforge/squad.conf` accepts a `worker_kind <kind>` line in
  upstream's one-setting-per-line format, alongside
  `max_transient_agents`, `max_merger_depth`, and `require_approval`.
- No file, no line, or a line whose value is not a valid kind all read
  as "unconfigured" and fall through to `claude` — the same silent
  fall-through posture `max_transient_agents` parsing already has.
- `worker_kind` affects transient workers only. It never affects the
  leader.

### squad_spawn_request: per-assignment override

- `squad_spawn_request.sh create <assignment-id> <template> [kind]`
  gains the optional third argument.
- The two-argument form behaves exactly as today; the request record
  keeps its existing shape (`:assignment`, `:template`,
  `:requested-at`, no kind key).
- With a kind argument:
  - an invalid kind dies exit 2 `INVALID_KIND: <kind>` before any file
    is touched (same posture as `INVALID_TEMPLATE`);
  - the request record additionally stores `:kind "<kind>"`;
  - the `spawn-requested` event detail appends ` kind=<kind>` after the
    existing `template=<template>`.
- `list` and `drop` output stays byte-for-byte as today.

### squadd: carrying the override

- The daemon's `spawn` action reads the request record as today. When
  the record carries `:kind`, the daemon invokes
  `swarm squad spawn <id> <template> <kind>` (plus `--no-agent` under
  `SWARMFORGE_NO_AGENT`); when it does not, the invocation is exactly
  today's two-argument call, so the launcher falls through to the
  configured kind.
- On success, the `squadd-spawn` event detail appends ` kind=<kind>`
  when the request carried one; otherwise the detail is unchanged.
- Retry-on-failure, request drop on success, and `spawn-skipped` for a
  missing/blank template are all unchanged.

### swarm squad spawn and squad_worker allocate

- `swarm squad spawn <assignment-id> <template> [kind] [--no-agent]`
  gains the optional kind argument and passes it through to allocation.
- `squad_worker.sh allocate <assignment-id> <template> [kind]` gains
  the same optional argument and is the single resolution point:
  - an invalid explicit kind dies exit 2 `INVALID_KIND: <kind>` before
    any record is written;
  - the worker record always stores the resolved kind as
    `:agent-kind "<kind>"` — including the default case, where the
    stored value is `"claude"`;
  - the `allocated` event detail appends ` kind=<kind>` after the
    existing `template=... assignment=...` fields.
- `squad-spawn!` in `bin/swarm` takes the kind for both of its
  downstream writes from the worker record's `:agent-kind`, not from a
  literal:
  - the appended `roles.tsv` row carries the resolved kind in the
    existing kind column (column 6 of the existing 7-column row; the
    column count and order do not change);
  - the herdr launch runs `herdr agent start <worker> --kind
    <resolved-kind> --pane ...`.
- A worker record with no `:agent-kind` key (written before this
  slice) reads as `claude` wherever a kind is read.
- Capacity checks, worker naming, worktree preparation, the worker
  prompt text, `activate`, the assignment `spawn` transition, and all
  existing output tokens (`WORKER_ALLOCATED:`, `WORKER_SPAWNED:`) are
  unchanged.

### swarm squad up

- `swarm squad up <kind>` continues to set only the **leader** kind, as
  today. It neither reads nor writes `worker_kind`, and the leader kind
  never leaks into worker resolution: with no override and no
  `worker_kind` line, workers resolve to `claude` even when the leader
  was started with another kind.

## Prompt sync

`prompts/roles/squad-leader.prompt` documents the spawn-request command;
its `create <id> <template>` line gains `[kind]` with one clause saying
the optional agent kind defaults to `worker_kind` in
`swarmforge/squad.conf`, else `claude`. Edit `prompts/` as source of
truth and sync the installed copy
`swarmforge/roles/squad-leader.prompt` in the same commit. No other
prompt, and no AGENTS.md/CLAUDE.md invariant, mentions worker kinds; no
other doc sync is required.

## Acceptance criteria

Each criterion is a smoke check (new checks land in the same commit,
`./test/smoke.sh` ends `SMOKE PASSED (N checks)`), exercised headlessly
with `--no-agent` / `SWARMFORGE_NO_AGENT=1` and, for the daemon path,
`squadd --once`:

1. **Default.** With no `worker_kind` line, `swarm squad spawn <id>
   <template> --no-agent` writes a worker record containing
   `:agent-kind "claude"` and a `roles.tsv` row whose kind column is
   `claude`. (Today's behavior, now asserted.)
2. **Configured kind.** With `worker_kind grok` in
   `swarmforge/squad.conf`, the same spawn writes `:agent-kind "grok"`
   and a `roles.tsv` kind column of `grok`.
3. **Per-request override.** `squad_spawn_request.sh create <id>
   <template> codex` writes `:kind "codex"` into the request record and
   logs `spawn-requested template=<template> kind=codex`. A subsequent
   `squadd --once` spawn of that request — with `worker_kind grok` still
   configured — produces `:agent-kind "codex"` and a `roles.tsv` kind
   column of `codex`: the override beats the configured kind.
4. **Explicit argument.** `swarm squad spawn <id> <template> grok
   --no-agent` (no conf line) writes `:agent-kind "grok"` — the
   explicit argument works without a request record.
5. **Rejection.** `squad_spawn_request.sh create <id> <template>
   'bad kind!'` and `squad_worker.sh allocate <id> <template>
   'bad kind!'` both exit 2 with `INVALID_KIND: bad kind!` and write
   nothing.
6. **Two-argument compatibility.** The two-argument forms of `create`
   and `allocate` still succeed, and the request record written by
   two-argument `create` has no `:kind` key.
7. **Leader isolation.** No assertion may derive a worker kind from the
   leader kind; the existing `squad up` surface is untouched (no smoke
   change required beyond criteria 1–6 — this criterion bounds the
   implementation, not the suite).

## Out of scope

- S7 (daemon-owned transitions) and S8 (atomic records, stale locks).
- Any change to leader-kind handling in `swarm squad up`.
- Output-format changes to `squad_worker list`, `squad_spawn_request
  list`, `swarm squad status`, or any existing token, exit code, or
  file schema beyond the additive keys and columns named above.
- Pack-mode kinds (`swarmforge.conf` window lines already carry them).
- Validating that herdr supports a given kind: an unknown kind fails at
  `herdr agent start`, and the daemon's existing spawn-failed retry
  path surfaces it. No pre-flight check.
- Policy on when mixing providers is wise — operator choice, per the
  design.

## Files in scope

`bin/swarm`, `swarmforge/scripts/squad_lib.bb`,
`swarmforge/scripts/squad_spawn_request.bb`,
`swarmforge/scripts/squad_worker.bb`, `swarmforge/scripts/squadd.bb`,
`test/smoke.sh`, `prompts/roles/squad-leader.prompt`,
`swarmforge/roles/squad-leader.prompt` (installed sync), and this
document.
