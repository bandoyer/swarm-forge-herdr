# Pack blockers — Design

> Status: proposed. Nothing built yet.

A pack role that cannot proceed is told to stop and say so in its
terminal. Under unattended operation that terminal is a pane nobody is
reading, so the chain stalls with the reason visible only to whoever
thinks to look. This gives packs the record-and-buzz shape the squad
already has for approvals.

## The gap

`prompts/articles/workflow.prompt` — "When blocked":

> If a task is ambiguous, contradicts its specification, or cannot
> proceed, stop and say so in your terminal — plainly, with what you
> need.

That is the right instruction and the only one available: prose cannot
make a stall visible. The runtime cannot see it either.

- `bin/swarm:245,282` detects blocked agents **only at startup** ("open
  each blocked agent's pane, answer its startup dialog"). Nothing
  watches for a role that blocks mid-run.
- `handoffd` has no state detection and no notification path.
- `squadd` already fires `herdr notification show` once per pending
  approval, with durable dedup (`notify-pending-approvals!`) — the
  mechanism exists, packs just never got it.

The specifier is the most exposed role: resolving ambiguity is its
mandate, and it is the only role with nothing upstream to send a blocker
to, because the user *is* its upstream. But every role inherits the same
dead end.

## Why a record, not inferred state

An idle role with an empty queue is the normal resting state of a
finished pack. "Stuck" and "done" are indistinguishable from the
outside, so idleness cannot be the signal. herdr's own `blocked` state
means an unanswered startup dialog, not an agent deciding it cannot
proceed — wrong signal, and only observed at startup today.

An explicit record is the only unambiguous evidence, and it matches the
existing philosophy: file system state replaces the logbook.

## Records — `.swarmforge/blocked/<role>.edn`

```edn
{:role "specifier" :reason "..." :blocked-at "2026-08-19T15:04:11Z"}
```

One per role: a role is blocked or it is not, and re-blocking overwrites.
Never committed; lives beside the handoff queues in per-project runtime
state.

## Mechanism

| Step | Component | Behavior |
|---|---|---|
| Declare | `swarm_blocked.sh <reason...>` | Writes the record for the calling role, appends to the router log, prints `BLOCKER RECORDED: <role>`. Exit 1 if it cannot determine its role (not in `roles.tsv`), per the house convention. |
| Surface | `handoffd` poll pass | New record → `herdr notification show` exactly once, durable dedup keyed on role + `blocked-at` so a *new* blocker for the same role does buzz again. Honors `SWARMFORGE_WAKE_CMD=none`, logging `user-notify-skipped` like `squadd` does. |
| Clear | `done_with_current.sh` | The role completed something, so it is no longer stuck: clear its record. |
| Clear | `swarm unblock <role>` | The human dismisses it without the role having moved. |
| Report | `swarm status` | Lists blocked roles with reason and age, beside the existing role lines. |
| Report | `swarm logs` | Already interleaves the router log, so blocker lifecycle appears in the timeline for free. |

Clearing on `done_with_current.sh` rather than on task delivery is
deliberate: the most common resolution is the human answering in the
pane with `swarm prompt <role> "..."`, which `handoffd` never sees. The
role resuming its own lifecycle is the reliable signal.

## Prompt half

`workflow.prompt`'s "When blocked" gains the call alongside the existing
instruction — say it in the terminal *and* record it. One shared place;
no role prompt changes.

## Protocol compatibility

Additive only. New script name, new state directory, no change to any
existing output token, exit code, or file format. Upstream prompts run
unmodified — they simply never call `swarm_blocked.sh`, and a blocked
upstream role behaves exactly as it does today.

## Testing

The daemon half is deterministic and testable headlessly, like the rest:
`SWARMFORGE_NO_AGENT=1`, `SWARMFORGE_WAKE_CMD=none`, `--once` on
`handoffd`. Smoke checks to add:

- record written with the calling role's name; second call overwrites
- notification fires once per blocker; daemon restart does not re-buzz
- a *new* blocker for the same role does buzz again
- `done_with_current.sh` clears the record
- `swarm unblock` clears it; `swarm status` lists it while present
- `SWARMFORGE_WAKE_CMD=none` logs the skip rather than shelling out

## Non-goals

- Re-buzzing on an unresolved blocker. Once per blocker, matching
  approvals; escalation earns its complexity only if quiet stalls turn
  out to be common in practice.
- Squad workers. They already have a path — the worker protocol sends
  blockers to `squad-leader` as the assignment result. This is packs
  only, though `handoffd` runs in both modes, so nothing breaks.
- Any automatic resolution. A blocker is a human's decision to make;
  the runtime's whole job here is to make sure they learn it exists.

## Open questions

1. Should a blocked role also stop being woken by `handoffd` until
   cleared? Today it would be re-woken by any queue activity and would
   re-run `ready_for_next.sh`, get `NO_TASK`, and idle again — harmless,
   but noisy in the log.
2. Should `swarm status` exit non-zero when any role is blocked, so a
   watching script can detect a stalled swarm without parsing output?
