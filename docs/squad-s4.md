# Squad S4 — Approvals, themes, reporting

The final v2 phase: put the human in the loop as a first-class gate, and
make squad history legible without reading raw records.

## Approvals

The human decides; everything else only routes the decision.

### Records — `.swarmforge/squad/approvals/<approval-id>.edn`

```edn
{:id "..." :gate "merge" :target "<assignment-id>"
 :state :pending | :approved | :rejected
 :title "..." :reason "..."          ; written by the leader (judgment)
 :requested-at "..." :decided-at "..." :detail "..."}
```

### Policy — `swarmforge/squad.conf`

```
require_approval merge
```

When the `merge` gate is configured, an `:accepted` assignment does NOT
merge until an `:approved` approval record exists for it. No policy line
= no gates = S3 behavior unchanged.

### Advisor additions (rows 11–13; row 5 amended)

| # | Condition | Action | Class |
|---|---|---|---|
| 5* | assignment `:accepted` AND (gate unset OR its approval `:approved`) | `merge` | mechanical |
| 11 | assignment `:accepted`, merge gate set, no approval record for it | `request-approval` | residual (leader frames title/reason, creates the record) |
| 12 | approval `:pending` | `await-user-approval` | residual (informational; the user acts, nobody is waked for it) |
| 13 | approval `:rejected`, its assignment `:accepted` | `handle-approval-rejection` | residual (leader rejects/reworks the assignment) |

### Surfaces

- `squad_approval.bb` — request / approve / reject / list / status
  (leader uses request; approve/reject validate state transitions;
  every change hits events.log)
- `swarm squad approvals` / `approve <id> [detail]` / `deny <id>
  <reason>` — the human's CLI
- The daemon fires `herdr notification show` ONCE per newly-pending
  approval — the user's phone-buzz, not a leader wake

## Themes and reporting (lightweight)

- `squad_theme.bb` — create <theme-id> <theme-file>, attach <theme-id>
  <assignment-id>, status <theme-id>; records under
  `.swarmforge/squad/themes/<id>/{theme.md,status.edn}`
- `swarm squad report [theme-id]` — renders assignment states, commits,
  approvals, and the event timeline as readable markdown; whole squad
  when no theme given

## Explicitly deferred (upstream-parity items, not v2)

Module maps, implementation-order hard-gating, per-story packets with
stage records, and the web dashboard. These pair with upstream's
Gherkin/APS acceptance pipeline (a stated non-goal) and earn their
complexity only with it.

## Delivery

- A (swarm): `squad_approval.bb` + `squad_theme.bb` + advisor rows
  11–13/5* + table-driven smoke
- B (operator): daemon gating + one-shot user notification + `swarm
  squad approvals/approve/deny/report` CLI + leader prompt approval
  section
- C: live dogfood with `require_approval merge` — the user gets buzzed,
  approves from the CLI, and the merge lands only then
