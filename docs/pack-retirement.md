# Pack retirement

`swarm down` is a pause: it stops the daemons and closes the recorded Herdr
workspace while preserving every role branch and worktree for inspection or
recovery. `swarm retire` is the separate, terminal operation after a pack
candidate has been integrated.

## Integration target

Retirement uses the project root's currently checked-out branch and `HEAD` as
the integration target. It refuses a detached HEAD. Every linked role branch
named by `swarmforge/swarmforge.conf` must be an ancestor of that `HEAD` before
anything is removed.

Project-root roles (`master` or `none`) are never removed. Squad workers retain
their existing daemon-owned lifecycle; `swarm retire` is for fixed pack roles
only and refuses squad runtime state.

## Guarded preflight

For every configured role, retirement requires that no outbound, failed,
newly delivered, or in-process handoff remains. For each linked role, it also
requires:

- runtime role registration, when present, matches the installed pack config;
- its path is the expected direct child of `.worktrees/` and a registered Git
  worktree;
- its checked-out branch is `swarmforge-<worktree-name>`;
- that branch is merged into the current integration `HEAD`;
- no tracked change or unexpected untracked path remains (the launcher's
  generated `swarmforge/scripts/` copy is allowed).

The full preflight runs before shutdown. If it passes, retirement stops the
daemons and closes the recorded Herdr workspace, waits for the daemons to exit,
requires Herdr to confirm that every configured role agent is gone, and runs
the same preflight again. If Herdr cannot make that confirmation, retirement
fails closed. Any preflight or agent-verification failure leaves all role
worktrees and branches in place and prints every blocker found.

## Effects

After both preflights pass, `swarm retire`:

1. force-removes the verified linked worktrees, including their ignored test
   databases, logs, caches, and generated runtime scripts;
2. prunes Git worktree metadata;
3. deletes the verified merged local role branches with Git's safe `-d` mode;
4. clears `.swarmforge/roles.tsv`, so `swarm status` no longer advertises
   retired roles.

Launcher and daemon logs remain under `.swarmforge/` as the local audit trail.
Provider-owned Claude, Codex, and Grok session transcripts also remain. A later
`swarm up` recreates every configured linked role from the then-current `HEAD`.
