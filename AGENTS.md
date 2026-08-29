# swarm-forge-herdr — session guide

Herdr-native port + extension of unclebob/swarm-forge: AI agent swarms
with bounded coordination. Three modes: **directed** (the user's Codex
session directs one builder and one read-only reviewer), **packs** (fixed
handoff pipelines), and **squad** (persistent judgment-only leader,
transient contract-bound workers, deterministic advisor `squad_next`,
daemon `squadd` that owns spawning/retiring/ALL merges, optional human
approval gates). PLAN.md is the authoritative history.

## Map

| Path | What |
|---|---|
| `bin/swarm` | Launcher/CLI (Babashka): init/switch/toolset/up/bootstrap/prompt/squad/logs/down/retire/status/guard |
| `swarmforge/scripts/` | The runtime: `handoff_lib` (shared), ready/done helpers, `swarm_handoff` (outbound gate + contract enforcement), `handoffd` (router), `squad_*` (assign/worker/spawn_request/approval/theme/lib), `squad_next` (advisor), `squadd` (squad daemon) |
| `prompts/` | SOURCE OF TRUTH for constitution, articles, role prompts, contracts, worker-common. Installed copies live in projects under `swarmforge/`; edit `prompts/` and sync both |
| `packs/*.conf` + `*.prompt` | Pack presets + chain articles |
| `toolsets/*.edn` | Quality-tool profiles keyed by purpose (dotnet, clojure, ruby, rust) |
| `skills/swarm-director/` | Versioned Codex skill: profile selection + bounded Director runbook |
| `test/smoke.sh` | The executable spec. MUST be fully green before any commit |
| `docs/` | Designs and specs: directed-cg, choosing-a-mode, squad v2/S3-S7, agent profiles, quality bars, pack retirement |
| `AGENTS.md`, `CLAUDE.md` | Parallel session guides; keep their shared operational facts synchronized (Grok discovers both) |
| `PLAN.md`, `PORTING.md` | History; upstream parity vs original work |

Per-project runtime state (never committed): `.swarmforge/` — roles.tsv
(routing truth), handoff queues, the task guard ledger, `squad/` records + events.log, daemon
pids/logs. `.worktrees/` — one per role/worker.

## Invariants — do not break

- Protocol compatibility with upstream: output tokens (`TASK:`,
  `NO_TASK`, `HANDOFF QUEUED:`, `AMBIGUOUS_TASK_STATE`…), exit codes
  (1 = can't run here, 2 = protocol violation), file formats, script
  names. Upstream prompts must run unmodified.
- Only `squadd` merges to main in squad mode; only the daemon spawns and
  retires. The leader touches records only. `merge`/`merge-blocked` die 2
  `DAEMON_ONLY` without `SWARMFORGE_SQUADD=1`.
- The advisor is read-only and deterministic; every action it can emit
  is in the 14-row table (docs/squad-s3.md rows 1-10, docs/squad-s4.md
  rows 11-13, docs/squad-hardening-s5-spec.md row 14).
- Contracts hard-block at `swarm_handoff`; workers inherit their
  template's contract.
- Directed mode never starts `handoffd`: only the Director prompts workers,
  reviewer is read-only, and a run gets at most one repair.
- Fixed-pack Git handoffs have a durable task budget and same-tree/route
  duplicate guard. An open circuit survives restarts; reset only the named
  task with handoffd stopped after inspection.
- herdr agent names: lowercase, ≤32 chars, project-prefixed
  (`project-agent-name` in bin/swarm; left-trim keeps the tail).
- Upstream swarm-forge has NO license: never vendor its text; original
  prompts + `bin/import-upstream` is settled policy.

## Operating swarms

Run from a project root, inside a running `herdr`:
`swarm up` (directed/pack) / `swarm squad up`; `swarm prompt <role> "..."` sends
tasks; `swarm logs [n]` is the interleaved timeline (launcher + both
daemons + squad events + handoff lifecycles). `swarm down` is a recoverable
pause that retains pack worktrees and branches. After an approved terminal
candidate is integrated, `swarm retire` performs guarded fixed-pack cleanup;
it does not replace the daemon-owned squad lifecycle. Squad approvals:
`swarm squad approvals|approve|deny|report`. Circuit recovery:
`swarm guard status`; stop handoffd, inspect, then `swarm guard reset <task>`.

Verifying agent prompts landed: send only when the target is
idle/done (herdr states); read the pane (`herdr agent read <name>`) if
in doubt — prompts sent mid-restart can vanish. Background watchers:
pin `cd` explicitly (session cwd resets) and accept states idle OR done.

## Development workflow (this repo builds itself)

- Swarm-built slices: prefer `directed-cg`; adversaries remains available when
  a finding must ride back as a gated test, with one repair maximum. Start a
  project-root coder only from a `review/<task>` branch, or use a review-gated preset
  whose coder has a linked worktree. The launcher refuses a project-root
  coder on `main` or `master`. Operator acts as integrator: independently
  re-verify every claim (rerun smoke, probe the feature), obtain the human
  approval the project requires, then integrate and push.
- Design-first: substantial features get a docs/ design before code.
- Test env escapes: `SWARMFORGE_WAKE_CMD=none`, `SWARMFORGE_NO_AGENT=1`,
  `SWARMFORGE_SQUADD=1`, `SWARM_BIN=<path>`, `--once` on both daemons.
- Commits: plain succinct subjects, no role prefixes/tags, no trailers,
  evidence in the body.

## Related

- Historical hardening and provider-comparison briefs live in
  `docs/experiments/`.
- `~/Work/swarm-dogfood` — local-only .NET test project (packs + squad
  validated there). `~/Work/crap4net` → github.com/bandoyer/crap4net
  (split out; referenced by the dotnet toolset).
- Deferred by user choice: letter/issue to unclebob. Deferred by design:
  module maps, packets, web dashboard (docs/squad-s4.md).
