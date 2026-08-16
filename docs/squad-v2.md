# Squad v2 — Design

> Status: complete — all four phases built and validated live 2026-08-15.
> Phase details: [S3](squad-s3.md), [S4](squad-s4.md); history in PLAN.md.

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

Worker backend per template stays configurable (upstream defaults
reviewer-type templates to a different model than implementers —
cross-model checking worth keeping).

## State model — `.swarmforge/squad/`

All durable, all file-based, same philosophy as the handoff queue
("file system state replaces the logbook"):

```
themes/<theme-id>/
  theme.md  module-map.md  implementation-order.md  status.edn
stories/<story-id>/packet.edn        # stage records: {stage, assignment, branch, sha}
assignments/<assignment-id>/
  assignment.md                      # generated instructions handed to the worker
  status.edn                         # created|spawned|result|accepted|rejected|merged
approvals/<approval-id>.edn          # gate, target, state, detail
events.log                           # append-only, timestamped (feeds `swarm logs`)
```

## Contracts — `role-templates/<t>.contract.edn`

```edn
{:role "implementer"
 :may-web-search false  :may-spawn false  :may-talk-to-user false
 :required-tools ["boundaries"]          ; toolset purposes, not tool names
 :writes ["production-code" "unit-tests"]
 :artifact-roots ["src/" "tests/"]
 :required-evidence [:unit-tests :acceptance-or-na]
 :singleton false}                       ; merger: true, plus depth cap
```

Enforcement points (this is what upgrades discipline from prose to law):

1. **Spawn time** — the worker's bootstrap is assembled from
   worker-common protocol + role template + contract + generated
   assignment; capability flags become explicit prohibitions.
2. **Result time** — when a worker's handoff lands, the daemon validates:
   diff touches only `artifact-roots`; `required-evidence` fields present
   in the result manifest; required tools actually invoked (evidence
   headers name commands + outputs). Violation → assignment rejected with
   a repairable reason, not merged.
3. **Merge time** — daemon-only `merge-ready`/`accept-merge`; the leader
   physically cannot merge.

Contract enforcement also back-ports to the packs (phase S1): pack roles
get optional contracts, and `done_with_current` gains evidence checking.

## Delivery phases

**S1 — Contracts & evidence enforcement** *(hardens existing packs immediately)*
Contract schema + loader; evidence manifest format; validation in the
result path; contracts for the 8 pack roles. No new agents or daemons.

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
Theme/story/packet records; module map + implementation-order gating;
approval gates (CLI + herdr notifications); `swarm squad report`.

Each phase lands runnable and dogfooded before the next starts — same
cadence as v1.

## Testing strategy

- **Headless simulator** (upstream precedent: `squad_simulator`): scripted
  fake workers + `SWARMFORGE_WAKE_CMD=none` drive full workflows in CI
  with zero LLM cost — the advisor and daemon are deterministic, so their
  behavior is exactly testable.
- Smoke-test extensions per phase (contracts: rejection paths; spawn:
  capacity caps; advisor: conformance against workflow-example traces).
- Dogfood: a theme of 2–3 stories on the calculator app, live agents.

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
