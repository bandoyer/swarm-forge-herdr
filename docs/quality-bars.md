# Quality bars — who runs what

> Status: stock articles and contracts updated. Per-project
> `project.prompt` files still need a pass (dogfood still lists
> coverage as universal).

The six-pack looks like five roles all “run the tests.” On a real
slice the fast unit suite is milliseconds. The cost is everyone
re-collecting coverage, CRAP, jscpd, and format, then hardener adding
mutation, then QA doing coverage again.

That duplication was policy, not protocol. Role prompts already give
hardener the evidence battery and QA the spec check. The project
article’s **universal** list, plus the cleaner contract’s CRAP/jscpd
receipts, made every handoff a tribunal.

## Law

| Bar | Who | When |
|---|---|---|
| Fast unit suite (project `Unit tests`) | Any role that merged or edited `src/` / `tests/` (or this repo’s smoke) | After the merge, and after their own edits. Specifier is exempt. |
| Format | Cleaner, or a later role that touched files | Once per slice if possible. `--verify-no-changes` only if you edited. |
| Coverage, CRAP, jscpd | Hardener produces the official numbers. Cleaner may run the same tools to *act* on findings. | Not a universal gate. QA does not re-collect lcov. |
| Mutation | Hardener only | Survivors killed or justified. |
| Acceptance + hands-on vs spec | QA only | Independent of hardener metrics. |

Architect with **no** production or test edits after merge: one unit
(or smoke) run to confirm the merge, then forward.

`swarm_handoff` still checks commit-message evidence. It does not run
Stryker. A later slice may run the fast suite at the gate; mutation
stays a role.

## Stock files

- `prompts/articles/project.prompt` — universal = fast suite only;
  metrics and acceptance are role-specific.
- `prompts/contracts/cleaner.contract.edn` — `tests-green` only
  (matches the cleaner prompt: evidence gates are not its job).
- Hardener and QA contracts unchanged (metrics vs spec-verification).

## Per-project

Edit `swarmforge/constitution/articles/project.prompt` the same way.
Dogfood still names coverage/jscpd as universal; that is the next
project-local edit, not a stock change.
