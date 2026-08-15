# swarm-forge-herdr

A [herdr](https://github.com/ogulcancelik/herdr)-native port of the
[swarm-forge](https://github.com/unclebob/swarm-forge) philosophy: disciplined,
role-based AI agent swarms — specifier → architect → coder → refactorer —
each in its own git worktree, handing work down the chain as validated commits,
running on herdr's agent-aware terminal runtime instead of tmux.

> **Status: early development.** Phase 0 (scaffolding). Nothing runs yet.
> See [PLAN.md](PLAN.md) for the roadmap.

## Why

[swarm-forge](https://github.com/unclebob/swarm-forge) (Robert C. Martin) is a
process discipline for agent swarms: roles with narrow mandates, one git
worktree per role, work moving only as commits through a small validated
handoff protocol, and an evidence regime that makes agents *demonstrate*
quality (coverage, mutation kills, complexity bounds) instead of claiming it.

Its runtime, however, is welded to tmux — sessions, sockets, window watchdogs,
and per-platform terminal adapters. [herdr](https://herdr.dev) already provides
all of that as first-class features: persistent sessions, native git worktree
management, agent state detection (working / blocked / done / idle), and a
socket API for driving agents programmatically.

This project keeps the philosophy and replaces the plumbing. Two of upstream's
subsystems (window watchdog, terminal adapters) disappear entirely; what
remains is smaller than the original and gains a live dashboard.

## Design

- **Packs as config presets, not branches** — `two`, `four`, `six`,
  `adversaries` are files here, not tarballs to extract.
- **Handoff protocol preserved exactly** — same message schema
  (`git_handoff` / `note`), same agent-facing script contract
  (`ready_for_next`, `swarm_handoff`, `done_with_current`), so upstream role
  prompts run unmodified if you choose to import them.
- **Toolset profiles** — upstream's quality tooling is Clojure-specific; here
  the tool table binds abstract purposes (`mutation`, `coverage`, `crap`,
  `dry`, `boundaries`, `acceptance`) to per-language profiles. First targets:
  `clojure` (upstream's own tools) and `dotnet` (Stryker.NET, coverlet,
  jscpd, NetArchTest, Reqnroll).

## Relationship to upstream

The role prompts and constitution in this repository are **original text**
implementing the same methodology; swarm-forge currently has no license, so
its files are not redistributed here. An import script (planned) fetches
upstream's own packs and tools directly from its repository — the same
install path upstream documents — for anyone who wants the originals.

All credit for the design — the roles, the handoff discipline, the evidence
regime — belongs to [unclebob/swarm-forge](https://github.com/unclebob/swarm-forge).

## Requirements

- [herdr](https://herdr.dev) ≥ 0.8
- git, [Babashka](https://babashka.org) (`bb`)
- At least one agent CLI: `claude`, `codex`, `copilot`, or `grok`

## License

[MIT](LICENSE) — covers this repository's original code and prompts.
