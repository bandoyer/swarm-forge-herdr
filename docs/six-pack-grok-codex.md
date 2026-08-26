# Grok + Codex six-pack — Design

> Status: scored. Recommended mix is `six-codex-grok-review`. Optional
> Fable seat is `six-codex-grok-fable-review` (architect only).
> The six-pack chain itself does not change. This is a provider map.

`six-all-models-review` is the current flagship evidence pipeline:
Opus 5 on spec/clean/architecture, Sol on code and QA, Grok 4.6 on
hardening. This document is the Claude-free alternate.

Live undo comparison (2026-08-26, serial, `swarm-dogfood`): both packs
reached a QA terminal with independently re-run green suites and zero
findings loops. Invert won: Sol specifier wrote the tighter law, Grok
coder isolated Evaluate on the first implementation, Grok hardener made
Undo mutation-testable. Codex specifier still needs a chain-start
nudge (`NO_TASK` is expected). Optional leftover Fable 5 High goes on
**architect** only — the one adjacent-judgment seat still shared with
Sol in the invert, and a review-sized token spend.

## What we already know from this repo

The live mix in `packs/six-all-models-review.conf` is stronger evidence
for *this protocol* than any public leaderboard. It already answered
three slots without Claude in them:

| Role | Current flagship | Effort | Keep? |
|---|---|---|---|
| coder | Codex `gpt-5.6-sol` | high | yes, until an invert experiment loses |
| hardener | Grok `grok-4.6` | high | yes |
| qa | Codex `gpt-5.6-sol` | xhigh | yes |

The Claude-shaped hole is specifier, cleaner, and architect. That is
the whole design problem.

Existing Grok/Codex packs are not a substitute:

- `six-grok-review` pins Grok 4.6 **high** on every role. No xhigh, no
  cross-model check.
- `six-codex-review` is all Sol with **no reasoning-effort pins**
  (Codex default is medium). Candidate B is not a fair baseline.
- `six-codex-grok-review` is "Grok coder, Codex everything else," also
  without Codex effort pins, and with Codex on hardener — which the
  all-models mix already rejected.

So we do not yet have a Grok+Codex flagship. We have two under-specified
experiments and one all-Grok pack at a single effort.

## What public benches add (directional, not gospel)

Grok 4.6 and GPT-5.6 Sol tie on the Artificial Analysis Intelligence
Index (61). They split on the rows that map onto six-pack roles:

- **Sol leads long-horizon engineering:** DeepSWE, Terminal-Bench.
  That is the coder's job (TDD in a worktree, tests as the loop).
- **Grok leads coding-agent loops and knowledge work:** CursorBench,
  FrontierCode, APEX-Agents, GDPVal, AA-Briefcase. That is closer to
  specifier / architect / a cleaner that has to *read* a slice and
  restrain itself.
- **Sol's system card reports cheating and fabricated results.**
  Dangerous in a role whose job is to *attest*. QA stays behind the
  human integration gate for that reason, not because Sol is a weak
  verifier.
- **Grok 4.6 adds `xhigh`.** Current Grok packs never use it. In xAI's
  own Grok Build harness, effort is monotone (xhigh best); against the
  raw API it is not. Herdr's grok kind is the CLI harness, so xhigh is
  worth spending on judgment roles and not on the cleaner.

Codex `ultra` / `multi_agent` stay off. The swarm *is* the multi-agent
system. Same rule as today's Sol windows.

## Proposed flagship — `six-grok-codex-review`

Replace Claude with Grok in the judgment slots. Keep Sol where the
all-models mix already picked it. Keep Grok on hardening. Cross-model
at the spec→code and code→QA boundaries.

| Role | Kind | Model | Effort | Why |
|---|---|---|---|---|
| specifier | grok | grok-4.6 | **xhigh** | The Claude hole. Spec errors are the most expensive. xhigh is the new 4.6 ceiling; knowledge-work benches favor Grok. Different provider than coder. |
| coder | codex | gpt-5.6-sol | **high** | Unchanged from all-models. DeepSWE / Terminal-Bench. high, not xhigh: the coder iterates; the mix already used high. |
| cleaner | grok | grok-4.6 | **high** | Different provider than the coder so it cannot rubber-stamp Sol's taste. high, not xhigh: a cleaner that overthinks starts redesigning. |
| architect | grok | grok-4.6 | **xhigh** | Same family as specifier, matching how all-models put *both* spec and architecture on Opus. Structure is a judgment role. |
| hardener | grok | grok-4.6 | **high** | Unchanged. Tool-heavy mutation/coverage campaigns; already won the slot; cheaper than Sol for long receipts. |
| qa | codex | gpt-5.6-sol | **xhigh** | Unchanged. Independent of the Grok-heavy middle. xhigh because QA is the terminal attestation, not an implementation loop. |

Exact windows (isolated worktrees, human integration gate, same
unattended flags as the other review packs):

```
window specifier grok gc-specifier task --model grok-4.6 --reasoning-effort xhigh --permission-mode bypassPermissions --no-subagents --disable-web-search
window coder     codex gc-coder     task --model gpt-5.6-sol -c model_reasoning_effort=high -c web_search=disabled --disable multi_agent --disable multi_agent_v2 --dangerously-bypass-approvals-and-sandbox
window cleaner   grok gc-cleaner    batch --model grok-4.6 --reasoning-effort high --permission-mode bypassPermissions --no-subagents --disable-web-search
window architect grok gc-architect  batch --model grok-4.6 --reasoning-effort xhigh --permission-mode bypassPermissions --no-subagents --disable-web-search
window hardener  grok gc-hardener   batch --model grok-4.6 --reasoning-effort high --permission-mode bypassPermissions --no-subagents --disable-web-search
window qa        codex gc-qa        batch --model gpt-5.6-sol -c model_reasoning_effort=xhigh -c web_search=disabled --disable multi_agent --disable multi_agent_v2 --dangerously-bypass-approvals-and-sandbox
```

The pack article is the six-pack human-integration article plus the
hardener/QA probe sentence from `six-claude-codex-review.prompt`
(declared output and security probes must actually run). Unattended
sandbox bypass stays a trusted-checkout warning, same as the other
Grok/Codex presets.

Shape in one line: **Grok judges and hardens; Codex builds and
verifies.**

## Should there be experiments? Yes — one invert, not a matrix

Two providers × six roles × four effort knobs is  how this repo grew
twenty pack files. Do not do that. One scientific contrast is enough
to tell whether the Claude-hole guess is wrong.

### The invert — upgrade `six-codex-grok-review` in place

Today's candidate A asks "what if Grok codes?" but leaves Codex at
default effort and puts Codex on hardener. Upgrade it to the actual
invert of the flagship: **Codex judges and verifies; Grok builds and
hardens.**

| Role | Flagship (`six-grok-codex-review`) | Invert (`six-codex-grok-review`) |
|---|---|---|
| specifier | Grok xhigh | **Sol xhigh** |
| coder | Sol high | **Grok high** |
| cleaner | Grok high | **Sol high** |
| architect | Grok xhigh | **Sol xhigh** |
| hardener | Grok high | Grok high (not inverted — all-models already picked Grok here) |
| qa | Sol xhigh | Sol xhigh (not inverted — attestation stays on the independent verifier) |

Hardener and QA stay put so the experiment isolates *who specs and who
codes*, which is the claim being tested. Inverting hardener or QA at
the same time would confound the result.

Exact invert windows:

```
window specifier codex exp-a-specifier task --model gpt-5.6-sol -c model_reasoning_effort=xhigh -c web_search=disabled --disable multi_agent --disable multi_agent_v2 --dangerously-bypass-approvals-and-sandbox
window coder     grok  exp-a-coder     task --model grok-4.6 --reasoning-effort high --permission-mode bypassPermissions --no-subagents --disable-web-search
window cleaner   codex exp-a-cleaner   batch --model gpt-5.6-sol -c model_reasoning_effort=high -c web_search=disabled --disable multi_agent --disable multi_agent_v2 --dangerously-bypass-approvals-and-sandbox
window architect codex exp-a-architect batch --model gpt-5.6-sol -c model_reasoning_effort=xhigh -c web_search=disabled --disable multi_agent --disable multi_agent_v2 --dangerously-bypass-approvals-and-sandbox
window hardener  grok  exp-a-hardener  batch --model grok-4.6 --reasoning-effort high --permission-mode bypassPermissions --no-subagents --disable-web-search
window qa        codex exp-a-qa        batch --model gpt-5.6-sol -c model_reasoning_effort=xhigh -c web_search=disabled --disable multi_agent --disable multi_agent_v2 --dangerously-bypass-approvals-and-sandbox
```

### Baselines — pin, don't multiply

`six-codex-review` should pin Sol high on coder/cleaner/hardener and
Sol xhigh on specifier/architect/qa, so "all Codex" is comparable
rather than an accidental medium-effort run. `six-grok-review` stays
at high everywhere for now: it is the known all-Grok quantity. Do not
silently bump it to xhigh or a later comparison against the flagship
is confounded.

Do **not** add an all-Grok-xhigh pack, a Sol-max pack, or a
cleaner-swap pack until the flagship-vs-invert slice has a winner.
If the mixed pack loses to a baseline on that slice, *then* run the
matching all-Grok or all-Codex pack on the same slice.

## How to run the comparison

One bounded slice, both packs, human integration, same project article
and contracts. Dogfood is the right shape; a synthetic "hello tests"
slice will not distinguish these models.

1. `swarm init six-grok-codex-review` on a review-gated checkout of
   the dogfood project (or `swarm switch` if it already has a six-pack
   constitution). Commit conf + contracts. `swarm up`. Drive one
   slice to a terminal QA candidate. `swarm down`. Keep the worktrees.
2. `swarm switch six-codex-grok-review` (or a second clone, if you
   want both candidates on disk at once — `switch` replaces conf and
   the pack article). Same slice text. Same human. Do not let the
   second run see the first's role branches.
3. Independently re-verify every evidence claim in both terminals
   (rerun the declared tests, coverage, mutation, probes). That is
   existing operator law, not a new rubric.
4. Compare, in this order — later rows only matter if earlier ones
   tie:

   | Rank | Question | What "better" means |
   |---|---|---|
   | 1 | Did QA attest something false? | Disqualify. |
   | 2 | Spec quality | Ambiguities that later roles had to send back; missing acceptance criteria. |
   | 3 | Finding loops | qa→specifier roundtrips. Fewer genuine findings that the spec should have caught is a spec win; fewer loops because QA was asleep is a disqualify. |
   | 4 | Hardener honesty | Survivors justified in writing, or killed. Invented numbers lose. |
   | 5 | Terminal diff | Would a human merge this? Clean Code / this repo's engineering article. |
   | 6 | Cost and wall clock | Only after 1–5. Grok is cheaper per token; Sol is slower and dearer; xhigh on two Grok roles will close some of that gap. |

The operator presents **both** terminal candidates for human review,
the way `six-codex-grok-review.prompt` already describes. The winner
becomes the recommended Grok+Codex six-pack in the README table;
the loser stays as the invert preset so the experiment remains
reproducible.

A single slice can lie. If the two terminals are close, run a second
slice in the other direction (hardener-heavy vs specifier-heavy) before
declaring a flagship.

## What not to experiment with yet

- **Grok xhigh on coder or cleaner.** Coder high is the all-models
  choice; cleaner xhigh tends to invent scope. Revisit only if the
  invert's Grok coder looks under-reasoned.
- **Sol `max` or `ultra`.** max is a cost knob we have not calibrated
  in this runtime; ultra is subagents, which the swarm forbids.
- **Grok QA.** Tempting given Sol's fabrication note, but it would
  put spec, architecture, hardening, *and* QA on one provider and
  destroy the independent-verifier slot. The human integration gate
  is the mitigation; keep it.
- **Squad workers as Grok/Codex.** Pack roles are pack conf. Squad
  workers are still hardcoded Claude; that is [squad hardening
  S6](squad-hardening.md), not a pack preset.

## Optional Fable seat — `six-codex-grok-fable-review`

Same windows as the recommended invert, except architect:

```
window architect claude cgf-architect batch --model claude-fable-5 --effort high
```

Do not put Fable on specifier (replaces the invert winner, long-form
tokens) or coder (Grok already won). High, not xhigh: architect reads a
diff.

## Implementation when we land this

Design-first, then a small config PR — no runtime changes:

1. Add `packs/six-grok-codex-review.conf` + matching `.prompt`.
2. Rewrite `packs/six-codex-grok-review.conf` to the invert windows
   above; keep the pair's "compare both candidates" pack article.
3. Pin effort on `packs/six-codex-review.conf` as the all-Codex
   baseline.
4. README table row + `docs/choosing-a-mode.md` one-liner: six-pack
   work on Grok+Codex uses `six-grok-codex-review` until the invert
   beats it.
5. Smoke: the same pin-and-isolate checks `six-all-models-review`
   already has (every window, human-integration sentence, no
   project-root coder). The "every pack initializes" loop picks up
   the new pair automatically.

No launcher changes. No prompt-corpus changes beyond the pack
article. Contracts stay project-local.

## Open questions

1. Architect on Grok xhigh vs Sol xhigh inside the *flagship* (not
   the invert). All-models put spec and architecture on the same
   provider. If Grok-as-specifier is accepted but Grok-as-architect
   rubber-stamps Grok's own spec, move architect to Sol xhigh without
   otherwise changing the mix. That is a one-line conf edit after the
   first live run, not a third pack.
2. Hardener at Grok high vs xhigh when a mutation campaign stalls.
   Do not pin xhigh up front; the current high setting is the one
   that already survived a six-pack dogfood.
3. Keep `six-codex-grok-review` as the invert name (history, README
   already mentions it) or rename to `six-codex-grok-invert` so the
   old un-pinned candidate A cannot be confused with the new one.
   Recommendation: keep the name, change the conf, mention the
   effort-pin in the conf header comment.
