# Build Plan

Porting the [swarm-forge](https://github.com/unclebob/swarm-forge) philosophy
to a [herdr](https://herdr.dev)-native runtime. Legend: **build** (new code),
**port** (reimplement upstream semantics), **adopt** (existing tool),
**delete** (obsoleted by herdr).

## Phase 0 — Foundation ✅

- [x] Repo, MIT license, README, this plan
- [ ] (Optional) upstream issue asking for a LICENSE file

## Phase 1 — Core runtime (critical path)

Implementation language: **Babashka**, same as upstream — port by transcription,
not translation. Herdr absorbs session/worktree/window management.

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

## Phase 2 — Prompt corpus

Original text (upstream is unlicensed), same methodology.

- Constitution: `constitution.prompt` + articles: `workflow`, `handoffs`, `engineering`, `project` (template)
- Roles: `specifier`, `architect`, `coder`, `refactorer`, `cleaner`, `hardener`, `qa`, `reviewer`
- Packs as config presets: `packs/two.conf`, `four.conf`, `six.conf`, `adversaries.conf`
- `import-upstream.sh` — fetch upstream's pack tarballs (their documented install path) for users wanting the originals

## Phase 3 — Toolset profiles

Tool table keyed by *purpose* (`test`, `coverage`, `mutation`, `crap`, `dry`,
`boundaries`, `acceptance`); role contracts require purposes; profiles bind
purposes to commands.

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
| crap | **crap4net** | **build**: Roslyn code metrics + lcov → CRAP = c²(1−cov)³+c, gate ≤ 6. Candidate standalone repo. |
| gherkin mutation | upstream APS `gherkin-mutator` + NDJSON worker driving Reqnroll | defer to v2 |

## Phase 4 — Validation (dogfood)

Small .NET target app with real logic. Run `two` pack end-to-end, then `six`
with the full evidence regime. Acceptance: feature request enters at
specifier, exits as reviewed, hardened, evidence-backed commits, pipeline
state visible live in herdr.

## Phase 5 — v2 (out of scope for v1)

- `squad` branch equivalent: squad-leader, dynamic worker spawning, 14 role
  templates, contract *enforcement* (required-evidence validation), merger
  role, web dashboard (~3–4× pack runtime surface)
- gherkin-mutator adapter; more toolsets (TypeScript, Python)

## Decisions log

- 2026-08-15: MIT license; Babashka runtime; packs as presets not branches;
  original prompts + upstream import script (upstream has no LICENSE).
