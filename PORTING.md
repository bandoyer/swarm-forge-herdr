# Porting notes

Protocol compatibility target: upstream swarm-forge's `handoff-protocol.md`.
File formats, script names, output tokens (`TASK:`, `BATCH:`, `NO_TASK`,
`COMPLETED:`, `AMBIGUOUS_TASK_STATE`, …), exit codes, and the roles.tsv
location are preserved so upstream role prompts run unmodified.

## Deliberate differences from upstream

| Area | Upstream | Here | Why |
|---|---|---|---|
| Wake-ups | tmux `send-keys` to a role session | `herdr agent prompt <role>` | herdr is the runtime |
| Wake-up failure | fails the delivery (handoff → `failed/`) | logged, delivery still succeeds | wake-ups are lossy by design; a notification problem should not quarantine a valid handoff |
| Window watchdog | reopens closed terminal windows | none | herdr sessions persist; reattach at will |
| Terminal adapters | AppleScript / wt.exe / Ghostty scripts | none | herdr runs in any terminal |
| tmux socket file | `.swarmforge/tmux-socket` | not written | replaced by herdr's own socket |
| roles.tsv column 4 | tmux session name | herdr agent name (= role) | same purpose, new runtime |
| Queue/lib code | helpers duplicated per script | one shared `handoff_lib.bb` | maintainability |
| Packs | one git branch per pack | `packs/*.conf` presets + `swarm init` | no tarball-overlay installs |
| `handoffd --once` | n/a | single poll pass | testability (`test/smoke.sh`) |
| `SWARMFORGE_WAKE_CMD` | n/a | override/disable wake command | testability |
| Role spelling | `hardender` | `hardener` | upstream typo |
| Agent selection | `codex` default | explicit per pack role or squad profile | supports stock Codex and mixed-provider packs plus independently configured squad workers |

## What agents see (unchanged)

- `SWARMFORGE_ROLE` set in their pane environment
- scripts at `swarmforge/scripts/` inside their worktree
- the loop: wake-up → `ready_for_next.sh` → work → commit →
  `swarm_handoff.sh <draft>` → `done_with_current.sh`

## Beyond upstream (v2)

Everything above concerns protocol parity with upstream's pack branches.
This repository then extends the design past upstream's implemented
surface: machine-enforced role contracts (S1), a herdr-native squad with
project-scoped agent naming (S2), the deterministic advisor + sole-git-
owner daemon (S3), human approval gates with CLI + notifications (S4),
dead-worker reconciliation (S5), durable worker provider selection (S6),
daemon-owned transition gates and a leader write boundary (S7), and pinned
squad model-and-effort profiles. Upstream's squad branch inspired S2–S4;
the contract enforcement, approval gating, worker contract inheritance,
and later hardening are original here. The upstream squad features
deliberately not ported are module maps, implementation-order gating,
per-story packets, and the web dashboard (see docs/squad-s4.md).
