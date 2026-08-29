# Choosing a mode

Choose the smallest process that can prove the task is done. Agent count is
not a complexity score: requirement ambiguity, consequence of failure,
available evidence, and genuinely independent workstreams are what matter.

## Solo

Use one normal Codex session when the change is bounded, intent is clear, and
existing focused verification is an adequate gate. This is the cheapest and
usually fastest path.

Escalate when a second independent judgment or a specific evidence regime has
clear value, not merely because the task touches several files.

## Directed — Director → builder → reviewer

`directed-cg` is the normal swarm recommendation for one coherent task. The
user's Codex session acts as Director, Grok 4.6 High builds, and Codex Sol Max
reviews the exact candidate read-only. Workers never talk directly. The
Director allows one repair, then accepts or stops blocked.

Use when: an implementation is serial but an independent skeptical review is
worth its cost; scope can be stated up front; you want stronger judgment
without a fixed multi-role ceremony.

Do not use when: one agent plus existing tests is enough, or when several
independent slices can truly progress at the same time.

Cost: 2 workers, at most 2 build turns and 2 review turns, with a 90-minute
default wall limit. No handoff router. See [directed-cg.md](directed-cg.md).

## Fixed packs

Fixed packs encode a review sequence. Their router persists a per-task handoff
budget and opens a circuit on a repeated same-tree route, so prompt mistakes
cannot create an unbounded loop.

### two — coder → cleaner

Use when: the user explicitly wants the historical implementation-plus-cleanup
pipeline. Cost: 2 agents and 2 handoffs.

### adversaries — coder → reviewer

Use when: the user explicitly wants a hostile reviewer that can commit a
reproduced failing test back to the coder. One finding authorizes one repair; a
second failed review stops. Cost: 2 agents and at most 4 handoffs.

### four — specifier → coder → refactorer → architect

Use when: ambiguity in what to build or architectural boundaries is the main
risk, and pinning a specification before implementation is valuable. Cost: 4
agents and 4 handoffs.

### six — specifier → coder → cleaner → architect → hardener → qa

Use when: correctness is expensive to get wrong and the project has meaningful
acceptance, coverage, mutation, complexity, and architecture tools. A first QA
finding authorizes one full repair pass; a second stops. Cost: 6 agents, up to
12 deliveries with one repair and terminal broadcast.

Bare `swarm init` selects `six-cg`, the isolated Codex + Grok six-pack. Use
`six-all` when the same human-integration boundary should add Fable for
specification and architecture. The launcher default is not a recommendation
that every task needs six agents.

## Squad

Squad is one persistent judgment-only leader plus transient contract-bound
workers, a deterministic advisor, and a daemon that owns spawning, retirement,
and merges.

Use when: you can name multiple independent workstreams, decomposition must
adapt during a longer program, or an ongoing stream of work justifies a
persistent leader.

Do not use when: the work is one slice. Shared files or sequential dependencies
erase the benefit of parallel workers while retaining all coordination cost.

Cost: elastic, capped by `max_transient_agents`.

## Decision table

| Situation | Recommendation |
|---|---|
| Clear bounded change; existing tests are a sufficient gate | Solo |
| One implementation; independent review is valuable | `directed-cg` |
| Requirements or boundaries are the primary uncertainty | `four` |
| Release-grade proof with a useful quality toolchain | `six-cg` |
| Named independent workstreams or ongoing adaptive decomposition | Squad |
| User specifically wants the legacy cleanup or hostile-review loop | `two` or `adversaries` |
| Unsure | Start solo; escalate one level when a concrete risk proves the need |

The included `skills/swarm-director` Codex skill applies this rubric after
reading the target code and verification rather than guessing from the request
alone.
