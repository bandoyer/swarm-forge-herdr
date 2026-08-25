# Build Plan

Porting the [swarm-forge](https://github.com/unclebob/swarm-forge) philosophy
to a [herdr](https://herdr.dev)-native runtime. Legend: **build** (new code),
**port** (reimplement upstream semantics), **adopt** (existing tool),
**delete** (obsoleted by herdr).

## Phase 0 — Foundation ✅

- [x] Repo, MIT license, README, this plan
- [ ] (Optional) upstream issue asking for a LICENSE file

## Phase 1 — Core runtime (critical path) ✅

Implementation language: **Babashka**, same as upstream. Herdr absorbs
session/worktree/window management. Done 2026-08-15: shared `handoff_lib.bb`
+ 7 entry scripts, `handoffd.bb` (herdr wake-ups, `--once` test mode),
`bin/swarm` (init/up/down/status), `packs/*.conf`, 19-check `test/smoke.sh`
green. Deviations documented in PORTING.md. Live `swarm up` against running
agents still unvalidated — that is Phase 4.

| Component | Upstream | Verdict |
|---|---|---|
| `swarm` launcher | `swarm`, `swarmforge.sh` | port — parse pack conf; `herdr worktree create`, `agent start`, `agent rename` |
| Handoff library | `handoff_lib.bb` | port — schema, validation, queue state, task/batch modes, exact semantics |
| Router daemon | `handoffd.bb` | port — watch queue → validate → `herdr agent wait --state idle` → `herdr agent prompt` |
| Agent-facing scripts | `ready_for_next*`, `done_with_current*`, `swarm_handoff` | port — keep names and output contract (`NO_TASK` / `TASK:` / `BATCH:`) verbatim |
| `close-swarm`, cleanup | same | port (trivial) |
| Window watchdog | `swarm-window-watchdog.*` | **delete** — herdr sessions persist |
| Terminal adapters | 5 adapters + dispatcher | **delete** — herdr is the terminal layer |

Estimate: ~800–1200 lines (upstream ~2–3k minus deletions).

## Phase 2 — Prompt corpus ✅

Original text (upstream is unlicensed), same methodology. Done 2026-08-15.

- Constitution + articles: `workflow`, `handoffs`, `engineering`, `project`
  (template), plus a per-pack `pack.prompt` chain article
- Roles: `specifier`, `architect`, `coder`, `refactorer`, `cleaner`,
  `hardener`, `QA`, `reviewer`
- Packs as config presets; `swarm init <pack>` installs conf + prompts
- `bin/import-upstream` — fetch upstream's originals for users who want them

## Phase 3 — Toolset profiles ✅

Done 2026-08-15. `toolsets/*.edn` keyed by purpose; `swarm toolset <name>`
renders a constitution article with exact commands and runs a doctor pass.
`crap4net` built under `tools/crap4net` (Roslyn + lcov, 16 tests green,
installable via `bin/install-crap4net`, dogfooded on itself). dotnet doctor
fully green on this machine (dotnet, stryker, crap4net, jscpd).

Ruby added 2026-08-23 with Rails-default Minitest, SimpleCov lcov, Mutant,
crap4rb, jscpd, Packwerk, and Rails system-test lanes. Rust added 2026-08-25
with workspace tests, cargo-llvm-cov, cargo-mutants, crap4rs, jscpd, Cargo
dependency inspection, and ignored-test acceptance lanes.

### `toolsets/clojure` — upstream's own tools

Import mode: clone unclebob/{clj-mutate, crap4clj, dry4clj,
Acceptance-Pipeline-Specification, dependency-checker}, generate `bb` shims
(parameterized paths — upstream's tool-table hardcodes the author's machine).

### `toolsets/dotnet`

| Purpose | Tool | Verdict |
|---|---|---|
| test | `dotnet test` (xUnit) | adopt |
| coverage | coverlet → lcov | adopt |
| mutation | Stryker.NET, survivors=0 | adopt |
| dry | jscpd | adopt (JetBrains dupFinder is deprecated) |
| boundaries | NetArchTest.Rules arch-test project | adopt |
| acceptance | Reqnroll (NOT SpecFlow — discontinued) | adopt |
| crap | **crap4net** | **build**: Roslyn code metrics + lcov → CRAP = c²(1−cov)³+c, gate ≤ 6. Split to github.com/bandoyer/crap4net 2026-08-15. |
| gherkin mutation | upstream APS `gherkin-mutator` + NDJSON worker driving Reqnroll | defer to v2 |

## Phase 4 — Validation (dogfood) ✅

Done 2026-08-15 on ~/Work/swarm-dogfood (two-pack, live Claude agents).
Full loop closed: task → coder TDD slice → validated handoff → router
delivery + wake → cleaner batch accept (two handoffs, one batch) → audit
pass with real, independently reverified evidence (10/10 tests, 100%
coverage, crap4net 7/7 within bar, jscpd 0 clones) → terminal return
handoffs → coder merge → all idle. Launcher fixes found and shipped:
blocked-at-startup agents non-fatal, rerunnable `up`, `swarm bootstrap`.
Six-pack validated same day: full chain + terminal broadcast, hardener
reached 100% mutation score with justified survivors, QA mapped all 11
acceptance criteria; every number independently reverified. Four-pack
(refactorer did real DRY work) and adversaries (reviewer hand-applied
mutants, added interaction tests) validated 2026-08-15 — all four packs
proven live. Adversaries run surfaced and fixed the stale-worktree trap:
WRONG_WORKTREE guard in all queue commands, worktree stated in bootstrap,
stale-worktree warning in `swarm switch`.

## Phase 5 — v2 (in progress; design: docs/squad-v2.md)

- [x] S1 contracts & evidence enforcement (2026-08-15): per-role
  `*.contract.edn` (artifact roots + required evidence), hard-block
  validation in `swarm_handoff`, contracts for all 8 pack roles,
  installed by init/switch, smoke-tested (22 checks)
- [x] S2 transient workers + squad-leader (2026-08-15): swarm-built
  `squad_assign` + `squad_worker` + `squad_lib` (lifecycle, registry,
  capacity, events); operator-built spawn/retire driver (`swarm squad
  spawn/retire`, cross-registry validation, dynamic roles.tsv routing so
  the router serves workers automatically), `swarm squad up` (persistent
  leader), worker-common + squad-leader prompts. 76 smoke checks. Live
  squad dogfood pending.
- [x] S3 advisor + daemon git ownership (2026-08-15): swarm-built
  `squad_spawn_request` + `squad_next` (10-row action table, exhaustive
  smoke) and `squadd` (mechanical transitions, sole main-git owner,
  branch guard, argv hardening) — both through findings-loop-backs
  (stale requests, events.log injection, wrong-branch merge, commit-header
  injection); operator-built leader authority downgrade + merger
  template/contract. 158 smoke checks. Live S3 dogfood passed 2026-08-15: leader records-only, daemon spawned/merged/retired; universal-bars fix applied.
- [x] S4 approvals, themes, reporting (2026-08-15): swarm-built
  `squad_approval` + `squad_theme` + advisor rows 11-13/5*; operator-built
  daemon one-shot user notifications, `swarm squad
  approvals/approve/deny/report`, leader approval protocol. 222 smoke
  checks. Validated live: accepted work held un-merged until the human
  approved from the CLI; merge landed 200ms after signature.
  **Squad v2 complete.**
- Later: gherkin-mutator adapter; more toolsets (TypeScript, Python)

## Decisions log

- 2026-08-15: MIT license; Babashka runtime; packs as presets not branches;
  original prompts + upstream import script (upstream has no LICENSE).
