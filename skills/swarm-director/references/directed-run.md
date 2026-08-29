# Directed run

`directed-cg` is a serial, mediated workflow:

`BUILD -> REVIEW -> ACCEPT`

or

`BUILD -> REVIEW -> REPAIR -> DELTA REVIEW -> ACCEPT/BLOCKED`

## Start safely

1. Record the target branch and base SHA. Require a clean target checkout.
2. Inspect `swarmforge/swarmforge.conf`. Initialize with
   `swarm init directed-cg` only when no profile exists. Do not overwrite a
   customized profile without the user's approval.
3. Run `swarm up`. Resolve the builder and reviewer names/worktrees from
   `.swarmforge/roles.tsv`; do not guess project-prefixed agent names.
4. Require both role worktrees to be clean except for launcher-generated
   `swarmforge/scripts/`, and based on the recorded base. If a previous run left
   divergent work, stop for an operator decision.

## Direct the run

- Give only builder the run contract. Require a commit SHA and verification
  evidence. Default hard wait: 45 minutes.
- Wait on Herdr's agent lifecycle event (`idle`, `done`, or `blocked`). Read the
  terminal once after settlement. Do not poll transcripts or repeatedly ask for
  status.
- Verify that the reported commit resolves in the builder worktree, descends
  from the recorded base, and contains only in-scope changes.
- Fast-forward the clean reviewer worktree to that exact candidate. Prompt
  reviewer with the base SHA, candidate SHA, acceptance criteria, and verification
  commands. Require one read-only `GO` or `NO-GO`. Default hard wait: 15 minutes.
- On `GO`, independently check the required evidence and accept.
- On the first `NO-GO`, send builder only the reproduced blocking findings as
  one repair assignment. Default hard wait: 20 minutes. Verify the new SHA,
  fast-forward reviewer, and request a review of the repair delta plus relevant
  regressions. Default hard wait: 10 minutes.
- A second `NO-GO` is terminal `BLOCKED`. Do not ask for another repair.

The default total wall budget is 90 minutes. The user may set smaller or larger
stage budgets before launch. A stage timeout is terminal `BLOCKED_TIMEOUT`:
run `swarm down` so work cannot continue consuming tokens, preserve the
worktrees, and report the last known SHA and state.

## Communication and authority

The Director is the hub. Builder and reviewer never message one another, use
handoff queues, or launch subagents. Prompts carry compact structured state:
task id, base/candidate SHA, acceptance criteria, allowed scope, verification,
and remaining repair budget. Git commits carry code and durable evidence;
Herdr carries only assignment and verdict messages.

At `ACCEPT`, `BLOCKED`, or `BLOCKED_TIMEOUT`, run `swarm down`; branches and
worktrees remain available. Present the candidate to the user. Integration and
push require explicit user authorization.
