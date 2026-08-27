# Squad agent profiles — deterministic model and effort pinning

Status: **IMPLEMENTED AND VERIFIED — 2026-08-27 (375 smoke checks).**

This slice extends S6's durable worker kind into a complete, reproducible
agent profile. A squad can pin provider kind, model, and reasoning effort for
its persistent leader, its default transient worker, individual worker
templates, and an exceptional assignment. It does not change assignment
ordering, capacity, advisor policy, daemon ownership, merge behavior, or pack
configuration.

The immediate consumer is Bujo's Tailwind v4 migration squad. The capability
is generic SwarmForge behavior and must remain backward compatible for every
existing kind-only squad.

## Problem

S6 made worker kind durable, but both squad launch paths still inherit model
and effort from mutable global CLI configuration:

- `swarm squad up [kind]` starts the leader with only `--kind`;
- worker allocation records only `:agent-kind`;
- `squad_spawn_request` can override only kind;
- `squad-spawn!` starts a worker with only `--kind`.

That makes a long-running mixed-model squad nondeterministic. Changing a
global Codex, Claude, or Grok default between assignments silently changes the
workforce, and the durable audit trail cannot say which model or effort was
requested.

## Terms

An **agent profile** is one of two shapes:

1. a legacy kind-only profile: `<kind>`;
2. a pinned profile: `<kind> <model> <effort>`.

Kind-only profiles preserve current behavior and intentionally inherit that
CLI's defaults. Pinned profiles are complete: model and effort are either both
present or both absent. A partial pair is invalid.

The fields become command arguments, EDN values, status text, and event-log
detail. Each must be one safe token:

- kind and effort match `[A-Za-z0-9][A-Za-z0-9._-]*`;
- model matches `[A-Za-z0-9][A-Za-z0-9._:/-]*`.

Pinned profiles are supported for `codex`, `claude`, and `grok`, the three
agent kinds whose model and effort CLI contracts are exercised by this
repository's model-pinned packs. A kind-only profile remains open to any
Herdr-supported safe kind, exactly as S6 allows today.

## Project configuration

`swarmforge/squad.conf` gains three additive settings:

```text
leader_profile <kind> <model> <effort>
worker_profile <kind> <model> <effort>
template_profile <template> <kind> <model> <effort>
```

Example:

```text
leader_profile codex gpt-5.6-sol max
worker_profile codex gpt-5.6-sol high
template_profile specifier codex gpt-5.6-sol max
template_profile cleaner grok grok-4.6 high
template_profile architect codex gpt-5.6-sol high
template_profile hardener grok grok-4.6 high
template_profile qa codex gpt-5.6-sol xhigh
```

Rules:

- at most one `leader_profile` and one `worker_profile` may be present;
- at most one `template_profile` may be present for a given template;
- a recognized profile line with the wrong arity, an unsafe value, a
  duplicate, or a pinned unsupported kind fails closed with
  `INVALID_AGENT_PROFILE`, exit 2, before a profile record, spawn request, or
  worker record is written;
- unrelated and comment lines retain existing behavior;
- existing `worker_kind <kind>` remains supported as the legacy worker
  fallback and retains S6's invalid-value fallthrough to `claude`;
- `worker_profile` takes precedence over `worker_kind`.

## Resolution

### Leader

For a leader that is not already running:

1. an explicit CLI profile from `swarm squad up [kind [model effort]]`;
2. `leader_profile` from `squad.conf`;
3. legacy default `claude` with no model or effort pin.

The command accepts exactly zero, one, or three profile values. Other arities
print usage and exit 1 without starting anything.

The resolved profile is written to
`.swarmforge/squad/leader.edn` before launch. When `swarm squad up` finds an
already-running leader, it keeps the durable/registered profile of that
process instead of relabeling it from newly supplied arguments or changed
configuration. A pre-profile running leader falls back to the kind already in
`roles.tsv`, with model and effort absent.

### Worker

Worker allocation remains the single resolution point. Precedence is:

1. explicit assignment profile;
2. matching `template_profile`;
3. `worker_profile`;
4. existing `worker_kind`;
5. legacy default `claude`.

An explicit kind-only assignment profile overrides the entire configured
profile and deliberately inherits that kind's CLI defaults. It never combines
an explicit kind with a configured model intended for another provider.

Once allocated, launch always reads the worker record. It never re-resolves
configuration, even if `squad.conf` changes between allocation and Herdr
startup.

## CLI and record changes

The following command forms are additive:

```text
swarm squad up [kind [model effort]]
swarm squad spawn <assignment-id> <template> [kind [model effort]] [--no-agent]
squad_worker.sh allocate <assignment-id> <template> [kind [model effort]]
squad_spawn_request.sh create <assignment-id> <template> [kind [model effort]]
```

All existing zero-profile and kind-only forms retain their output, state, and
exit behavior.

A pinned spawn request adds all three keys:

```clojure
{:kind "codex" :model "gpt-5.6-sol" :effort "high"}
```

A kind-only request still adds only `:kind`. A request without an explicit
profile retains its original three-field shape.

Every newly allocated worker continues to store `:agent-kind` and additionally
stores `:agent-model` and `:agent-effort` when pinned. Legacy and kind-only
workers omit the two new keys. Pre-S6 records still read as kind `claude` with
no pins.

The leader record stores the same `:agent-kind`, optional `:agent-model`, and
optional `:agent-effort`, plus its name and timestamps. It is audit state, not
routing authority; `roles.tsv` retains its seven existing columns and continues
to carry kind only.

Full profiles append ` model=<model> effort=<effort>` after their existing
`kind=<kind>` event fields. Kind-only event lines stay byte-for-byte unchanged.

`swarm status` and `squad_worker list` append model and effort only for pinned
records. Their legacy output remains byte-for-byte unchanged when no pins are
present.

## Herdr launch translation

The launcher passes agent-specific arguments after Herdr's `--` separator:

| Kind | Arguments after `--` |
|---|---|
| `codex` | `--model <model> -c model_reasoning_effort=<effort>` |
| `claude` | `--model <model> --effort <effort>` |
| `grok` | `--model <model> --reasoning-effort <effort>` |

A kind-only profile passes no trailing agent arguments, preserving current
behavior. All calls use argv vectors; no shell command or interpolated command
string is introduced.

This slice does not add permission, sandbox, web-search, or provider credential
arguments. Those remain project/operator policy and must not be smuggled into
model fields.

## Daemon path

`squadd` reads the additive request keys and invokes the same launcher surface:

- no profile: existing two-argument spawn;
- kind only: existing kind override;
- pinned: kind, model, and effort in that order.

It appends model and effort to `squadd-spawn` detail only when the request
carried the complete pinned profile. Spawn failure leaves the request for retry
as today. A manually crafted partial request cannot degrade to a kind-only
launch: the launcher rejects its invalid arity and the request remains.

## Prompt and documentation sync

The source `prompts/roles/squad-leader.prompt` and installed
`swarmforge/roles/squad-leader.prompt` must both explain:

- ordinary requests should omit an explicit profile and let template policy
  choose the worker;
- the optional full override is `[kind [model effort]]`;
- a kind-only override intentionally uses that CLI's defaults.

README documents the three profile settings, precedence, supported pinned
kinds, exact launch mapping, and status/audit behavior.

## Acceptance criteria

The executable smoke suite must pin all of these behaviors:

1. **Baseline compatibility.** With no new configuration, leader and workers
   still launch as kind-only Claude; existing kind-only records, output, and
   request shapes remain unchanged.
2. **Leader configuration.** A configured Codex/Sol/Max leader writes a pinned
   leader record, keeps `codex` in `roles.tsv`, and the fake Herdr transcript
   contains the exact Codex model/effort argv after `--`.
3. **Leader explicit precedence.** A complete explicit leader profile beats
   `leader_profile`; kind-only explicit form remains legal.
4. **Running leader stability.** Rerunning `squad up` with a different profile
   while the leader is reported live does not rewrite or relabel its stored
   profile.
5. **Worker default.** `worker_profile` produces the expected three durable
   fields, full event detail, status/list detail, and exact Herdr argv.
6. **Template precedence.** A matching `template_profile` beats
   `worker_profile`; a different template still receives the default worker
   profile.
7. **Explicit precedence.** Direct full spawn and full spawn-request profiles
   beat template/default configuration. Existing kind-only explicit overrides
   still store only kind and pass no model/effort arguments.
8. **Daemon parity.** A full spawn request survives through `squadd --once`,
   produces the same worker record as direct spawn, and logs the complete
   profile.
9. **Provider translation.** Focused launcher checks cover exact Codex, Claude,
   and Grok argv with no shell evaluation.
10. **Failure atomicity.** Partial explicit profiles, unsafe values, pinned
    unsupported kinds, duplicate configuration, and malformed recognized
    configuration exit with the declared token before writing records or
    requests.
11. **Durable launch source.** A worker allocated under one configuration and
    launched after configuration changes still uses its recorded profile.
12. **Audit visibility.** Pinned leader and worker profiles appear in status
    output and durable records; unpinned status stays compatible.
13. **Prompt sync.** Source and installed leader prompts remain identical.
14. **Complete regression.** `./test/smoke.sh` passes in full.

## Out of scope

- Starting or configuring the Bujo squad; that occurs only after this tool
  change is verified.
- Changes to pack `window` syntax or pack model pins.
- Arbitrary free-form CLI arguments in `squad.conf`.
- Global CLI configuration changes.
- Provider authentication, permissions, sandbox, or web-search policy.
- Auto-selecting a model from a template name.
- Persisting product workflow state or changing the advisor table.
- S8 atomic-record work; this slice preserves the current record writer.

## Files in scope

- `bin/swarm`
- `swarmforge/scripts/squad_lib.bb`
- `swarmforge/scripts/squad_worker.bb`
- `swarmforge/scripts/squad_spawn_request.bb`
- `swarmforge/scripts/squadd.bb`
- `test/smoke.sh`
- `prompts/roles/squad-leader.prompt`
- `swarmforge/roles/squad-leader.prompt`
- `README.md`
- `PLAN.md`
- this specification
