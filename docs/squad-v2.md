# Squad v2 — Design

> Status: complete — all four phases built and validated live 2026-08-15.
> Phase details: [S3](squad-s3.md), [S4](squad-s4.md); history in PLAN.md.
> Follow-on: [squad hardening](squad-hardening.md) S5–S7 is implemented;
> S8 remains pending.

Port of upstream swarm-forge's `squad` branch to the herdr runtime. Packs
are assembly lines of fixed peers; squad is a hub: one persistent
**squad-leader** talks to the user, and every other worker is **transient**
— spawned for a single assignment, worked, merged, retired.

## The three-brain separation (the part we must not lose)

Upstream's core insight: split orchestration into judgment, policy, and
mechanism, and let no component hold two of them.

| Brain | Component | Owns | Never does |
|---|---|---|---|
| Judgment | squad-leader (LLM) | user interaction, task clarification, assignment instructions, approval framing | author product artifacts; merge to main; decide workflow order |
| Policy | `squad-next` (deterministic bb) | the workflow state machine; "what happens next" | anything — it only reports |
| Mechanism | `squadd` (daemon) | spawn/retire, mechanical transitions, **sole main-git ownership** | judgment calls; talking to the user |

The leader *asks* the advisor and follows its `NEXT_ACTION`; the daemon
*applies* mechanical transitions the advisor emits. An LLM never freestyles
the process, and nothing but the daemon touches main.

## Herdr mappings

| Squad concern | Upstream (tmux) | Here |
|---|---|---|
| Spawn worker | tmux window + worktree | `git worktree add` + `herdr tab create --env` + `herdr agent start <name>` |
| Worker identity | session name | herdr agent name: `<template>-<assignment-id>` (lowercased) |
| Retire | kill window, remove worktree | `herdr tab close` + `git worktree remove` |
| Worker telemetry | `squad_event.sh` lifecycle states | herdr state detection (working/blocked/done/idle) **plus** a durable `events.log` (herdr states are live-only) |
| Approvals surface | web dashboard (`squadd/web.clj`) | CLI (`swarm squad approvals`) + `herdr notification show`; web UI deferred |
| Leader wake-ups | tmux send-keys | `herdr agent prompt squad-leader` (existing router) |

Worker profiles can be configured globally, per template, or per assignment;
see [deterministic agent profiles](squad-agent-profiles-spec.md). This retains
the useful upstream option of assigning reviewer-type work to a different
provider than implementation work.

## State model — `.swarmforge/squad/`

All durable, all file-based, same philosophy as the handoff queue
("file system state replaces the logbook"):

```
themes/<theme-id>/
  theme.md  status.edn               # lightweight assignment grouping
assignments/<assignment-id>/
  assignment.md                      # generated instructions handed to the worker
  status.edn  result.handoff         # lifecycle plus the worker result
workers/<worker-name>.edn            # durable worker identity and profile
spawn-requests/<assignment-id>.edn   # leader request consumed by squadd
approvals/<approval-id>.edn          # gate, target, state, detail
leader.edn                           # durable leader profile
events.log                           # append-only, timestamped (feeds `swarm logs`)
```

Module maps, implementation-order gating, and per-story packets were deferred
from v2. Themes are deliberately lightweight reporting groups.

## Contracts — `swarmforge/contracts/<role>.contract.edn`

```edn
{:artifact-roots ["src/" "tests/"]
 :required-evidence
 [{:name "tests-green" :pattern "(?i)tests? passed|dotnet test|bb test"}]}
```

Contracts are checked when a role queues a `git_handoff`:

1. changed paths must stay under `:artifact-roots`;
2. each `:required-evidence` regular expression must match the commit
   message;
3. a contract with `:forbid-git-handoff true` may re-deliver only a worker's
   recorded result commit.

Squad workers inherit their role template's contract. The stock leader
contract uses the third rule to block authored product handoffs while leaving
record operations and notes legal. The daemon alone performs accepted merges.
Spawn-time capability flags and direct verification that a named tool ran are
not implemented; see [the hardening status](squad-hardening.md).

## Delivery phases

**S1 — Contracts & evidence enforcement** *(hardens existing packs immediately)*
Contract schema + loader; path and commit-message evidence validation in the
handoff path; stock contracts for pack roles. No new agents or daemons.

**S2 — Transient workers + squad-leader**
`swarm squad` launcher (leader + troubleshooter, persistent);
`squad-assign` (create/status/result/accept/reject/replace; replacement is a link, not a state);
spawn/retire through herdr; worker-common protocol prompt; agent-name
capacity cap (default 10). Leader routes work manually at this stage —
usable, human-advised squad.

**S3 — Advisor + daemon git ownership**
`squad-next` state machine (port semantics from upstream;
`workflow-example.txt`, 1,947 lines, serves as the conformance spec);
`squadd` grows: apply mechanical transitions, merge-ready/accept-merge as
sole main-git owner; merger template + `max_merger_depth`.

**S4 — Themes, approvals, reporting**
Lightweight theme records; approval gates (CLI + herdr notifications);
`swarm squad report`. Story packets, module maps, and implementation-order
gating remain deferred.

Each phase landed runnable and was dogfooded before the next started — the
same cadence as v1.

## Testing strategy

- **Headless simulator** (upstream precedent: `squad_simulator`): scripted
  fake workers + `SWARMFORGE_WAKE_CMD=none` drive full workflows
  with zero LLM cost — the advisor and daemon are deterministic, so their
  behavior is exactly testable.
- The smoke suite covers contract rejection paths, capacity, every advisor
  row, daemon merge/conflict/retire behavior, approvals, and recovery.
- Live dogfood validated leader judgment, daemon-owned spawn/merge/retire,
  and a human-gated merge.

## Non-goals (v2)

- Web dashboard (herdr sidebar + CLI suffice; revisit if approvals feel
  clumsy in practice)
- Gherkin/APS acceptance pipeline integration (tracked separately)
- Multi-project squads

## Decisions

1. S1 enforcement: **hard-block** — a violating handoff is rejected with a
   repairable reason and never merges (decided 2026-08-15).
2. Approvals: **CLI + herdr notifications**; web UI stays deferred
   (decided 2026-08-15).
3. Transient capacity default: 10 (upstream's default).
