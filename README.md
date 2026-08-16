# swarm-forge-herdr

A [herdr](https://github.com/ogulcancelik/herdr)-native port and extension
of the [swarm-forge](https://github.com/unclebob/swarm-forge) philosophy:
disciplined, role-based AI agent swarms — each role in its own git
worktree, work moving only as validated commits — running on herdr's
agent-aware terminal runtime instead of tmux.

Two ways to run a swarm:

- **Packs** — fixed pipelines (`two`, `four`, `six`, `adversaries`):
  assembly lines you feed, sized to the evidence you need.
- **Squad** — a persistent judgment-only leader, transient contract-bound
  workers, a deterministic workflow advisor, a daemon that owns
  everything irreversible (spawning, retiring, **all merges to main**),
  and optional human approval gates before anything lands.

> **Status: v1 + squad v2 complete, all validated live** with real Claude
> agents on a .NET project — full handoff chains, batch mode, terminal
> broadcasts, the evidence regime (coverage, CRAP ≤ 6, mutation testing),
> machine-enforced role contracts, daemon-owned merges including a live
> conflict resolved by a transient merger agent, and approval-gated
> merges signed from the CLI. See [PLAN.md](PLAN.md) for the build
> history and [docs/](docs/) for design.

## Quickstart — packs

```sh
git clone https://github.com/bandoyer/swarm-forge-herdr
ln -s "$PWD/swarm-forge-herdr/bin/swarm" ~/.local/bin/swarm

cd your-project            # a git repo
swarm init two             # or four | six | adversaries; switch later with `swarm switch`
swarm toolset dotnet       # optional: quality-tool commands + doctor
# edit swarmforge/constitution/articles/project.prompt for your project
herdr                      # start herdr, then in any pane:
swarm up
swarm prompt coder "Task 'first-slice': ..."
swarm logs                 # one interleaved timeline of everything
```

Unsure which pack? See [docs/choosing-a-mode.md](docs/choosing-a-mode.md):
two-pack work ends up *tidy*, adversaries *attacked*, four-pack
*specified*, six-pack *proven*.

## Quickstart — squad

```sh
cd your-project
swarm init two                             # installs constitution/prompts (any pack)
echo 'require_approval merge' >> swarmforge/squad.conf   # optional human gate
swarm squad up                             # leader + routing + squad daemons
herdr agent prompt <project>-squad-leader "Build me X, Y and Z"
```

Then just talk to the squad-leader like a colleague. It decomposes work
into assignments, a daemon spawns capacity-capped workers to build them,
the leader judges results against your project's quality bars, and the
daemon merges what survives — unless an approval gate is set, in which
case your terminal buzzes and nothing lands until you sign:

```sh
swarm squad approvals                      # what's waiting, with the leader's framing
swarm squad approve <id>                   # or: swarm squad deny <id> "reason"
swarm squad report                         # assignments, approvals, event timeline
```

The leader authors no code and cannot spawn, retire, merge, or touch git:
judgment lives in the leader, workflow policy in a deterministic advisor
(`squad_next`), and mechanism in the daemon (`squadd`) — no component
holds two of them. Merge conflicts route automatically to a transient
merger agent; every state change lands in an append-only audit log.

## Why

[swarm-forge](https://github.com/unclebob/swarm-forge) (Robert C. Martin)
is a process discipline for agent swarms: roles with narrow mandates, one
git worktree per role, work moving only as commits through a small
validated handoff protocol, and an evidence regime that makes agents
*demonstrate* quality (coverage, mutation kills, complexity bounds)
instead of claiming it.

Its runtime, however, is welded to tmux — sessions, sockets, window
watchdogs, and per-platform terminal adapters. [herdr](https://herdr.dev)
already provides all of that as first-class features: persistent
sessions, native git worktree management, agent state detection
(working / blocked / done / idle), and a socket API for driving agents
programmatically.

This project keeps the philosophy and replaces the plumbing — two of
upstream's subsystems (window watchdog, terminal adapters) disappear
entirely — then extends it: machine-enforced contracts, the squad's
three-way separation of judgment, policy, and mechanism, and human
approval gates.

## Design

- **Packs as config presets, not branches** — `two`, `four`, `six`,
  `adversaries` are files here, not tarballs to extract; `swarm switch`
  moves between them in place.
- **Handoff protocol preserved exactly** — same message schema
  (`git_handoff` / `note`), same agent-facing script contract
  (`ready_for_next`, `swarm_handoff`, `done_with_current`), so upstream
  role prompts run unmodified if you choose to import them.
- **Contracts as law** — per-role `*.contract.edn` declares artifact
  roots and required evidence; `swarm_handoff` hard-blocks violating
  commits. Transient workers inherit their template's contract.
- **Toolset profiles** — upstream's quality tooling is Clojure-specific;
  here the tool table binds abstract purposes (`mutation`, `coverage`,
  `crap`, `dry`, `boundaries`, `acceptance`) to per-language profiles:
  `clojure` (upstream's own tools) and `dotnet` (Stryker.NET, coverlet,
  jscpd, NetArchTest, Reqnroll, and [crap4net](https://github.com/bandoyer/crap4net) — built
  for this project, now its own repo: per-method CRAP scores from
  Roslyn + lcov).
- **Observability** — `swarm logs` interleaves the launcher, both
  daemons, the squad event log, and every handoff's lifecycle headers
  into one timeline; agent transcripts and git history carry the rest.

Deeper design docs: [squad v2](docs/squad-v2.md) ·
[S3 advisor & daemon](docs/squad-s3.md) · [S4 approvals](docs/squad-s4.md)
· [porting notes](PORTING.md).

## Relationship to upstream

The role prompts and constitution in this repository are **original
text** implementing the same methodology; swarm-forge currently has no
license, so its files are not redistributed here. `bin/import-upstream`
fetches upstream's own packs directly from its repository — the same
install path upstream documents — for anyone who wants the originals.

All credit for the design — the roles, the handoff discipline, the
evidence regime, the squad's judgment/mechanism split — belongs to
[unclebob/swarm-forge](https://github.com/unclebob/swarm-forge).

## Requirements

- [herdr](https://herdr.dev) ≥ 0.8
- git, [Babashka](https://babashka.org) (`bb`)
- At least one agent CLI: `claude`, `codex`, `copilot`, or `grok`

## License

[MIT](LICENSE) — covers this repository's original code and prompts.
