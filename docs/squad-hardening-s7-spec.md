# Squad hardening S7 — Daemon-owned transitions specification

Status: **IMPLEMENTED AND VERIFIED — 2026-08-26.**

This slice implements S7a and S7b from
[squad-hardening.md](squad-hardening.md): the daemon-only assignment
transitions fail closed when anything but the daemon runs them (S7a),
and the squad-leader gets a stock contract that blocks it from handing
off product commits (S7b). S7c (git update hook) and S8 are out of
scope.

Both layers stop a prompt-following leader by mechanism instead of by
prompt alone. Neither stops an agent that deliberately exports the gate
variable or edits the contract file; that honesty is part of the design.

## S7a — env gate on merge transitions

### Definitions

- The **daemon gate** is the environment variable `SWARMFORGE_SQUADD`.
  It is **presented** when set to any non-blank value; unset or blank
  (empty or whitespace-only) is **absent**. The launcher and daemon set
  it to the literal `1`.
- The **gated subcommands** are `squad_assign merge` and
  `squad_assign merge-blocked` — the two transitions the lifecycle
  already documents as daemon-only.

### Behavior

1. When a gated subcommand runs with correct arity and the gate absent,
   it dies exit 2 with a message whose first line starts
   `DAEMON_ONLY: ` and names the subcommand (e.g. `DAEMON_ONLY: merge
   is daemon-only; squadd applies accepted verdicts itself`). The gate
   fires before any record is read or written: no state change, no
   `events.log` line, and `NO_SUCH_ASSIGNMENT` / `INVALID_TRANSITION`
   are never reached. Arity errors (usage, exit 1) may precede the
   gate.
2. With the gate presented, both subcommands behave byte-for-byte as
   today, including all existing tokens and exit codes.
3. All other `squad_assign` subcommands, and every other script, ignore
   the gate entirely.
4. `squadd` itself presents the gate on the `squad_assign` invocations
   it makes (implementation may set it on all its child invocations):
   `bb squadd.bb <root> --once` invoked with the variable **absent from
   the caller's environment** still performs merges and merge-blocked
   transitions. The existing daemon smoke checks must keep passing
   without exporting the variable — that absence is itself the
   assertion that the daemon carries its own gate.
5. The launcher's squadd daemon definition (`squadd-daemon` `:env` in
   `bin/swarm`) gains `"SWARMFORGE_SQUADD" "1"` alongside `SWARM_BIN`,
   so a live daemon started by `swarm squad up` runs with the gate in
   its process environment.
6. `DAEMON_ONLY` is a new, additive error token. No existing token,
   exit code, or file format changes.

## S7b — leader contract

### Definitions

- A **recorded result commit** is the value of the `commit` header in
  any `.swarmforge/squad/assignments/<id>/result.handoff` file,
  resolved to a full commit id with `git rev-parse` in the sender's
  worktree. A header that is missing or does not resolve is skipped —
  it can never match. Assignment state is not consulted: any stored
  result counts.
- Commit comparison is by full resolved commit id: the draft's
  canonical commit equals a recorded result commit or it does not.

### Contract schema (additive)

- A contract may carry `:forbid-git-handoff true`. For a sender whose
  contract has this key, `swarm_handoff` refuses any `type:
  git_handoff` draft **unless** the draft's commit is a recorded result
  commit. Refusal is the existing contract-error path: `HANDOFF
  INVALID`, an error line stating that the role's contract forbids
  handing off new commits and only a worker's recorded result commit
  may be re-sent, exit 2, draft retained.
- The rule is an identity check, deliberately blind to commit shape:
  merge commits and empty-diff commits from such a sender are refused
  like any other unrecorded commit. (Both would slip past an empty
  `:artifact-roots` ban — merge commits are skipped by the existing
  checker and empty diffs produce no paths — which is why empty roots
  is **not** the mechanism.)
- When the commit **is** a recorded result commit, the handoff passes
  the contract check outright; `:artifact-roots` and
  `:required-evidence` in the same contract are not consulted for
  git_handoffs — the sender is re-delivering work it did not author,
  and roots checks against the worker's paths would wrongly block it.
- `note` drafts are untouched by `:forbid-git-handoff`.
- Absence semantics are unchanged everywhere: no contract file means no
  enforcement, and a contract *without* the key keeps today's
  roots/evidence behavior exactly (a present contract is never treated
  as absent, and empty `:artifact-roots` does not acquire new meaning).

### Stock contract

- New stock contract `prompts/contracts/squad-leader.contract.edn`
  containing exactly `{:artifact-roots [] :forbid-git-handoff true}`
  (the empty roots are documentation of intent; the key is the
  mechanism), synced to the installed copy
  `swarmforge/contracts/squad-leader.contract.edn` in the same commit.
- `swarm squad up` installs the stock contract into the project
  (`swarmforge/contracts/squad-leader.contract.edn`) with the same
  don't-overwrite-existing posture `install!` already has for the
  leader prompt.
- Contract lookup needs no change: `role-contract` already resolves
  `squad-leader` by direct file name.

### What stays legal for the leader

- **Record writes**: `squad_assign` create/status/result/accept/reject/
  replace, `squad_spawn_request`, `squad_approval`, `squad_theme` are
  not handoffs and are unaffected by the contract.
- **The rework git_handoff**: the leader prompt's "fixable by the same
  worker" path remains legal because the rework handoff carries the
  worker's own recorded result commit. `prompts/roles/squad-leader.prompt`
  line for rework gains one clause saying exactly that — the rework
  handoff's `commit:` is the worker's recorded result commit; the
  leader contract blocks every other commit — synced to
  `swarmforge/roles/squad-leader.prompt` in the same commit.
- **note handoffs**.

## Session guides

The daemon-only-merge invariant lives in AGENTS.md and CLAUDE.md; both
gain, in their synchronized shared facts: the invariant's enforcement
(`merge`/`merge-blocked` die 2 `DAEMON_ONLY` without
`SWARMFORGE_SQUADD=1`) and `SWARMFORGE_SQUADD=1` in the test-env
escapes list. Keep the two files' shared operational facts identical in
substance.

## Acceptance criteria

Each criterion is asserted by smoke (new checks land in the same
commit; `./test/smoke.sh` ends `SMOKE PASSED (N checks)`), headless via
the existing file-state + `--once` harness:

1. **Gate refusal.** On an `:accepted` assignment, `squad_assign.sh
   merge <id>` with `SWARMFORGE_SQUADD` unset exits 2 with a first line
   starting `DAEMON_ONLY: `; the record is still `:accepted` and
   `events.log` gained no line. Likewise `merge-blocked <id> <detail>`.
2. **Blank is absent.** The same refusal with `SWARMFORGE_SQUADD=""`.
3. **Gate pass.** With `SWARMFORGE_SQUADD=1`, `merge` and
   `merge-blocked` produce today's transitions and tokens unchanged.
4. **Daemon self-gates.** The existing `squadd --once` merge and
   merge-blocked checks pass with the variable absent from the smoke
   process's environment — the suite must not export it around the
   daemon invocation.
5. **Live daemon env.** A smoke assertion that the launcher-started
   squadd runs with `SWARMFORGE_SQUADD=1` — via `/proc/<pid>/environ`
   of a daemon started through the launcher path, or an equivalent
   automated check on the started process.
6. **Forbid: new commit.** A role whose contract is the stock
   squad-leader contract drafts a git_handoff of a freshly authored
   commit: `HANDOFF INVALID`, exit 2, draft file retained, error
   mentions the contract forbids new commits.
7. **Forbid: merge and empty commits.** The same refusal for a merge
   commit and for an empty-diff commit, neither recorded as a result —
   the two shapes that slip past roots-based checks.
8. **Rework exception.** After `squad_assign result <id> <handoff>`
   records a worker handoff whose `commit` header is X, the contracted
   sender's git_handoff with commit X is `HANDOFF QUEUED`.
9. **Records stay legal.** With the stock contract installed, the
   contracted role still runs `squad_assign create` (and by
   construction the other record commands) successfully.
10. **Notes stay legal.** The contracted role can still queue a `note`
    handoff.
11. **Absence unchanged.** A role with no contract file still queues a
    git_handoff of a fresh commit (no enforcement), and a contract
    without `:forbid-git-handoff` keeps today's roots/evidence
    behavior.
12. **Stock contract installed.** `prompts/contracts/` and
    `swarmforge/contracts/` both contain the squad-leader contract with
    `:forbid-git-handoff true`, and the `swarm squad up` path installs
    it into a project that lacks it.

## Out of scope

- S7c (git `update` hook) and S8 (atomic records, stale locks).
- Defeating a deliberately adversarial leader: exporting
  `SWARMFORGE_SQUADD=1` or editing/deleting the contract file defeats
  both layers by design; unforgeability is S7c.
- Correlating a rework handoff's recipient or task name with the
  assignment whose result commit it carries.
- Any change to assignment lifecycle transitions, the advisor table,
  worker contracts, or pack-role contracts.
- Changing `:artifact-roots` semantics (empty roots does not become a
  ban; merge-commit skip in the existing checker stays).
- Restricting non-gated `squad_assign` subcommands.

## Files in scope

`bin/swarm`, `swarmforge/scripts/squad_assign.bb`,
`swarmforge/scripts/squadd.bb`, `swarmforge/scripts/handoff_lib.bb`,
`swarmforge/scripts/swarm_handoff.bb` (as the forbid check requires),
`test/smoke.sh`, `prompts/contracts/squad-leader.contract.edn` (new),
`swarmforge/contracts/squad-leader.contract.edn` (installed sync),
`prompts/roles/squad-leader.prompt`,
`swarmforge/roles/squad-leader.prompt` (installed sync), `AGENTS.md`,
`CLAUDE.md`, and this document.
