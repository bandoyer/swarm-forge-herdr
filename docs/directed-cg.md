# Directed Codex + Grok workflow

`directed-cg` is the low-ceremony default recommendation for one coherent task
that benefits from independent review. It launches two isolated workers:

- **Builder:** Grok 4.6 High implements, verifies, commits, and reports.
- **Reviewer:** Codex Sol Max reviews an exact candidate read-only and returns
  `GO` or `NO-GO` with evidence.
- **Director:** the user's normal Codex session defines scope, prompts one worker
  at a time, checks evidence, and is the only coordinator.

The Director is not a Herdr role. This keeps coordination in the conversation
that already understands the user's intent and avoids a third paid agent whose
only job is relaying messages.

## State and limits

```text
BUILD -> REVIEW -> ACCEPT
            |
            +-> REPAIR -> DELTA REVIEW -> ACCEPT
                                      \-> BLOCKED
```

There is at most one repair. The default stage budgets are 45 minutes to build,
15 to review, 20 to repair, and 10 for delta review: 90 minutes total. A timeout
stops the swarm and preserves its worktrees. The Director waits on Herdr state
changes and reads settled output once; it does not poll transcripts.

The profile carries two upstream-compatible comment markers:

```text
# swarmforge-mode: directed
# swarmforge-max-handoffs-per-task: 0
```

In directed mode `swarm up` does not start `handoffd`, and worker bootstrap
prompts prohibit queue use and direct worker communication. The zero handoff
budget is defense in depth if a stale router is invoked manually.

## Communication contract

The Director sends compact assignments containing a unique task id, exact base
or candidate SHA, acceptance criteria, non-goals, allowed scope, verification,
and remaining repair budget. Git commits carry implementation and evidence.
Herdr messages carry only assignments and verdicts.

The reviewer never edits tracked files or commits. The builder never integrates
to a protected branch or pushes. On a second `NO-GO`, ambiguity, scope change,
or exhausted budget, the Director stops and asks the user instead of adding
agents, abstractions, or another loop.

## Use

```sh
swarm init directed-cg
# Customize and commit swarmforge/ as usual.
swarm up
swarm prompt builder "<bounded run contract>"
```

The repository includes the `skills/swarm-director` Codex skill to select the
smallest adequate profile and operate this state machine. See
[Choosing a mode](choosing-a-mode.md) for when to stay solo or escalate to a
fixed pipeline or squad.

## Fixed-pack circuit breaker

Pipeline profiles retain their handoff router, but every stock profile now sets
a persistent per-task delivery budget. The router also rejects a repeated Git
tree on the same sender/recipient route. Either condition opens a circuit,
moves the offending handoff to `failed`, and prevents further Git deliveries
for that task.

```sh
swarm guard status
swarm guard reset <task>   # only while handoffd is stopped, after inspection
```

The ledger lives at `.swarmforge/daemon/handoff-guard.edn` and survives daemon
restarts. Notes are not counted. A reset removes only the named task record.
