# Choosing a mode

Five modes, one continuum: from **fixed process** (packs) to **delegated
judgment** (squad). Packs are assembly lines you feed; the squad is a
foreman you brief. Pick a pack when you already know what process the
work needs; pick the squad when deciding-the-process is itself the work.

Among the packs, size the pipeline to the *evidence* you need: two-pack
work ends up **tidy**, adversaries work ends up **attacked**, four-pack
work ends up **specified and structurally reviewed**, six-pack work ends
up **proven**.

## The packs (static pipelines)

### two-pack — coder → cleaner
*The fast loop.* Implementation plus an audit pass: dedup, naming,
honest numbers from whatever quality tools the project declares.

Use when: small well-understood features; prototyping; projects with a
strong test culture where the suite is the real gate; you want speed and
a second set of eyes, not a tribunal.

Cost: 2 agents, 2 handoffs per slice. Cheapest.

### adversaries — coder → reviewer
*The cheapest strong gate.* One hostile reviewer replaces a pipeline:
it re-runs everything itself, attacks edge cases, hand-applies mutants,
and sends findings back as failing (gated) tests until the work survives.

Use when: infrastructure, runtime, or security-adjacent code; languages
where metric tooling (coverage/mutation) is weak or absent — review
substitutes for tools; anywhere the dominant risk is a *subtle bug*
rather than a process failure. This repo builds itself in this mode; its
reviewer has caught durability bugs, log injection, and argv injection.

Cost: 2 agents; loops until clean, so hard tasks cost more — that's the
feature.

### four-pack — specifier → coder → refactorer → architect
*The spec-driven loop.* Requirements are pinned before code exists;
structure is reviewed after.

Use when: ambiguity in *what to build* is the main risk; design and
boundaries matter (the architect rules on structure); you want the
discipline of specification without heavyweight verification tooling.

Cost: 4 agents, ~4 handoffs per slice.

### six-pack — specifier → coder → cleaner → architect → hardener → qa
*The evidence regime.* Everything four-pack does, plus a hardener that
must produce coverage/complexity/mutation receipts (kill the mutants or
justify each survivor, in writing) and a qa that verifies delivered
behavior against the specification, not the diff.

Use when: correctness is the product; regressions are expensive; the
project has real tooling (see `toolsets/`) so evidence can be
*demonstrated* rather than asserted; release-quality work.

Cost: 6 agents, 5 chain handoffs + a terminal broadcast. Most expensive
pack — reserve it for work that deserves proof.

## The squad (dynamic hub)

squad-leader (persistent judgment) + transient contract-bound workers +
a deterministic advisor + a daemon that owns everything irreversible.

Use when: the work doesn't arrive pre-sliced — multi-part features,
parallel independent tasks, an ongoing stream of product work; when you
want to *delegate decomposition* ("make this usable from the command
line") and talk to one colleague instead of feeding a pipeline; when
runs should be long-lived with a bounded, elastic workforce.

Don't use when: the task is one obvious slice (a pack is less machinery
for the same result), or when you want the guarantees of a *specific*
fixed gate sequence — a pack IS that guarantee.

Cost: elastic — leader plus as many workers as the work warrants, capped
by `max_transient_agents`.

## They compose

The modes share one protocol, so the boundaries blur deliberately:
squad workers are built from pack role templates; a leader routing
implementer-then-reviewer assignments is running adversaries *inside*
the squad; the six-pack's evidence bars reappear as the leader's
acceptance checklist and as machine-enforced contracts. Mastering the
packs teaches you what to ask the squad for.

## Decision table

| Situation | Mode |
|---|---|
| Small known feature, fast iteration | two-pack |
| Infrastructure / runtime / security-ish code | adversaries |
| Requirements fuzzy; structure matters | four-pack |
| Must *prove* quality; rich tooling exists | six-pack |
| Needs decomposition, parallelism, or ongoing delegation | squad |
| Unsure | start two-pack; escalate when a slice proves it needs more eyes |
