# swarm-forge-herdr

A [Herdr](https://github.com/ogulcancelik/herdr)-native port and extension
of the [swarm-forge](https://github.com/unclebob/swarm-forge) methodology:
role-based AI agent swarms, one Git worktree per production role, with work
moving between agents only through validated commit handoffs.

This repository replaces swarm-forge's tmux-specific runtime with Herdr and
adds machine-enforced role contracts, deterministic squad workflow, daemon-
owned merges, an append-only event log, and optional human approval gates.

Two operating modes are available:

| Mode | Shape | Best for |
|---|---|---|
| **Packs** | Fixed pipelines of two, four, or six roles | Work whose review process is already known |
| **Squad** | One persistent leader with transient, assignment-bound workers | Work that needs decomposition, parallelism, or ongoing judgment |

The Herdr port, pack runtime, and squad v2 are complete. The protocol has a
250+ check headless smoke suite and has also been validated with live agents.

## Requirements

- Linux with [Herdr](https://herdr.dev) 0.8 or newer
- [Git](https://git-scm.com) and [Babashka](https://babashka.org) (`bb`)
- A supported, installed, and authenticated agent CLI
- A target Git repository with at least one commit

The bundled presets select their agent CLI explicitly:

- The standard `two`, `four`, `six`, and `adversaries` presets use Codex.
- `six-all` uses Fable for specification and architecture, Codex for coding
  and QA, and Grok for cleaning and hardening.
- `six-cg` is the Claude-free alternative: Codex specifies, codes, and QAs;
  Grok cleans, architects, and hardens.
- Any pack's `swarmforge.conf` can be edited after initialization to use an
  agent kind supported by Herdr.
- Squad leaders accept an optional agent kind, but transient squad workers
  currently launch as Claude. A full squad run therefore requires Claude.

Some Codex and Grok presets deliberately disable their normal approval or
sandbox boundaries so unattended workers do not stall. Read the selected
file in `packs/` and use those presets only in a trusted development checkout.

## Install

Keep the clone in a stable location because the `swarm` command is normally a
symlink back into it:

```sh
git clone https://github.com/bandoyer/swarm-forge-herdr \
  "$HOME/.local/share/swarm-forge-herdr"
mkdir -p "$HOME/.local/bin"
ln -s "$HOME/.local/share/swarm-forge-herdr/bin/swarm" \
  "$HOME/.local/bin/swarm"
```

Make sure `$HOME/.local/bin` is on `PATH`, then confirm the launcher is
available:

```sh
swarm status
```

The checkout is the installation. There is no build step and nothing is
copied globally except the symlink.

To update the launcher and stock templates later:

```sh
git -C "$HOME/.local/share/swarm-forge-herdr" pull --ff-only
```

Existing projects keep their project-local prompts and contracts because they
may contain deliberate customization; pulling this repository does not
overwrite them.

## Quickstart: a pack

Run the launcher from the root of the project the agents will change, not
from this tool's checkout.

The default two-pack places its coder in the project root. As a safety rule,
the launcher refuses to start a project-root coder while that checkout is on
`main` or `master`. Create a review branch first:

```sh
cd /path/to/your-project
git switch -c review/first-slice

swarm init two
# Or use the isolated mixed-provider default:
swarm init
```

Initialization writes a project-local `swarmforge/` configuration. Before
starting agents:

1. Fill in `swarmforge/constitution/articles/project.prompt` with the real
   unit-test, acceptance, coverage, and formatting commands.
2. Review `swarmforge/swarmforge.conf` for agent kinds, worktrees, and extra
   CLI arguments.
3. Review `swarmforge/contracts/*.contract.edn`. Adjust artifact roots and
   required commit evidence to match the project. Contracts are enforced at
   handoff time and intentionally reject nonconforming commits.
4. Optionally install a quality-tool profile:

```sh
swarm toolset dotnet    # or: swarm toolset clojure | ruby | rust
```

The toolset command writes the declared commands into the constitution and
runs a doctor report. It reports missing tools; it does not install every
third-party quality tool for you.

Commit the project configuration before the first `swarm up`. Linked
worktrees are created from `HEAD` and cannot see uncommitted prompts or
contracts from the project root:

```sh
git add swarmforge
git commit -m "Configure agent swarm"
```

Start Herdr from the project, then run the swarm from a Herdr pane:

```sh
herdr
```

```sh
swarm up
swarm prompt coder "Task 'first-slice': describe one bounded change and its acceptance criteria"
swarm logs
```

When the chain finishes, independently inspect the terminal commit and its
evidence before integrating it. Stop the agents and both daemons while keeping
their branches and worktrees available for inspection with:

```sh
swarm down
```

`swarm down` closes the Herdr workspace but leaves Git worktrees and their
branches intact for inspection.

After the terminal candidate is integrated into the currently checked-out
branch, retire the completed pack with:

```sh
swarm retire
```

Retirement refuses to delete anything unless every configured role branch is
merged into the current `HEAD`, worktrees contain no tracked or unexpected
untracked changes, runtime registration matches the pack, and every handoff
queue is drained. It then stops the swarm, confirms through Herdr that the
configured agents are gone, repeats the preflight, removes the linked worktrees
and merged local role branches, and clears stale role registration. Launcher
logs and provider session histories remain. See
[`docs/pack-retirement.md`](docs/pack-retirement.md) for the complete safety
contract.

### Choosing a pack

| Preset | Entry role | Pipeline | Provider/layout |
|---|---|---|---|
| `two` | `coder` | coder → cleaner → coder | Codex; coder uses project root |
| `adversaries` | `coder` | coder ↔ hostile reviewer until clean | Codex; coder uses project root |
| `four` | `specifier` | specifier → coder → refactorer → architect | Codex; specifier uses root, later roles are isolated |
| `six` | `specifier` | specifier → coder → cleaner → architect → hardener → QA | Codex; specifier uses root, later roles are isolated |
| `six-all` | `specifier` | Isolated six-role evidence pipeline | Fable + Codex + Grok; human integration |
| `six-cg` | `specifier` | Isolated six-role evidence pipeline | Codex + Grok; human integration |

For `two`, `adversaries`, and any other configuration whose
coder worktree is `master` or `none`, work on a `review/...` branch. The
two review-gated six-packs keep every role out of the project root.

```sh
swarm init six-all    # Fable + Codex + Grok
swarm init six-cg     # Codex + Grok
```

Both are terminal review pipelines: QA produces a candidate for explicit human
approval rather than integrating it into the protected branch.

See [Choosing a mode](docs/choosing-a-mode.md) for the evidence and cost
tradeoffs: two-pack work ends up *tidy*, adversaries work *attacked*, four-pack
work *specified and structurally reviewed*, and six-pack work *proven*.

## Quickstart: a squad

A squad has one persistent, judgment-only leader. The leader decomposes the
request and reviews results; transient workers produce one assignment each;
the deterministic advisor selects valid next actions; and `squadd` alone
spawns workers, retires them, and merges accepted commits.

Initialize any pack once to seed the project constitution and role templates.
Using `six` installs the broadest standard template set:

```sh
cd /path/to/your-project
swarm init six
```

Customize and commit the project article and contracts as described in the
pack quickstart. Optional squad policy lives in `swarmforge/squad.conf`; for
example:

```text
max_transient_agents 4
max_merger_depth 2
require_approval merge
```

`max_transient_agents` defaults to 10 and `max_merger_depth` defaults to 2.
Omit `require_approval merge` for automatic daemon-owned merges. If the
project's integration branch is not `main`, add `main_branch <name>`.

Start Herdr first, then start the squad from a Herdr pane:

```sh
herdr
```

```sh
swarm squad up            # defaults the leader to Claude
# or: swarm squad up codex # Codex leader; transient workers still use Claude
```

Talk to the squad-leader pane like a colleague. `swarm squad up` also prints
the exact `herdr agent prompt ...` command if you prefer to seed it from the
shell.

Useful operator commands:

```sh
swarm squad status
swarm squad report
swarm squad approvals
swarm squad approve <approval-id> "verified locally"
swarm squad deny <approval-id> "reason"
swarm logs 100
swarm down
```

With a merge approval gate, accepted work stays pending until a human approves
it. A denial returns the decision to the leader; it does not silently discard
the assignment.

## Project-owned files and runtime state

`swarm init` creates files intended to be reviewed and normally committed with
the target project:

```text
swarmforge/
  swarmforge.conf
  constitution.prompt
  constitution/articles/
  roles/
  contracts/
```

Commit these files before starting the swarm so every linked worktree inherits
the same policy from `HEAD`. `swarm up` then refreshes operational copies of
the runtime scripts inside the active role worktrees.

Ephemeral state is separate and should never be committed:

```text
.swarmforge/   # queues, routing, assignment records, events, daemon logs/PIDs
.worktrees/    # linked Git worktrees for roles and transient workers
```

The launcher adds both paths to the target project's `.gitignore` when it
starts.

## Command reference

| Command | Purpose |
|---|---|
| `swarm init <pack>` | Install one pack's config, constitution, prompts, and contracts |
| `swarm switch <pack>` | Replace the pack config/article while retaining project customization |
| `swarm toolset <dotnet\|clojure\|ruby\|rust>` | Write the quality-tool article and report missing tools |
| `swarm up` | Create worktrees, start pack agents, and start the handoff router |
| `swarm bootstrap [role]` | Resend role instructions after a startup dialog or restart |
| `swarm prompt <role> <text>` | Send a task to a pack role |
| `swarm status` | Show config, daemons, roles, agent kinds, and worktree paths |
| `swarm logs [n]` | Interleave launcher, daemon, squad, and handoff lifecycle events |
| `swarm squad ...` | Start and operate squad mode |
| `swarm down` | Stop daemons and close the recorded Herdr workspace |
| `swarm retire` | Guard and remove a fully integrated fixed-pack swarm |

## Troubleshooting

### `Refusing to start coder ... on protected branch`

The selected preset puts its coder in the project root. Switch to a dedicated
review branch, or use `six-all` or `six-cg`, which isolate every role.

### An agent is blocked immediately after startup

Open its Herdr pane and answer the CLI's folder-trust or authentication prompt,
then resend its role instructions:

```sh
swarm bootstrap <role>
```

### `herdr ... failed` or connection refused

Start Herdr in the target project with `herdr` (or `herdr server`), then retry.

### A handoff is rejected

The rejection is intentional protocol output. Read every listed contract or
schema error, correct the commit or handoff draft, and retry. Do not bypass the
gate. The most common first-run cause is an uncustomized artifact root or
evidence pattern in `swarmforge/contracts/`.

### A quality command is missing

Run `swarm toolset` with your profile (`dotnet`, `clojure`, `ruby`, or `rust`)
again to see the doctor report and installation hints. Project-specific
commands still belong in `swarmforge/constitution/articles/project.prompt`.

### The timeline is not enough

Use `swarm logs 100` for the interleaved lifecycle, then inspect a particular
agent with `herdr agent read <agent-name>`.

## Design

- **Packs are config presets, not branches.** `swarm switch` changes the fixed
  pipeline without reinstalling the project.
- **The upstream handoff protocol is preserved.** Message types, helper-script
  contracts, output tokens, and exit codes remain compatible so unmodified
  upstream prompts can be imported deliberately.
- **Contracts are executable policy.** Each role declares writable artifact
  roots and required evidence; `swarm_handoff` blocks violations before work
  enters another agent's queue.
- **Squad separates judgment, policy, and mechanism.** The leader judges,
  `squad_next` deterministically advises, and `squadd` owns irreversible
  actions. No component holds two of those responsibilities.
- **Everything important is inspectable.** `swarm logs`, handoff files, squad
  records, the append-only event log, agent transcripts, and Git history form
  the audit trail.

Deeper reading:

- [Choosing a mode](docs/choosing-a-mode.md)
- [Pack retirement](docs/pack-retirement.md)
- [Squad v2](docs/squad-v2.md)
- [Squad advisor and daemon](docs/squad-s3.md)
- [Squad approvals](docs/squad-s4.md)
- [Squad hardening](docs/squad-hardening.md)
- [Grok + Codex six-pack](docs/six-pack-grok-codex.md)
- [Quality bars](docs/quality-bars.md)
- [Porting notes](PORTING.md)
- [Build history](PLAN.md)

## Relationship to upstream

[swarm-forge](https://github.com/unclebob/swarm-forge), created by Robert C.
Martin, established the roles, handoff discipline, and evidence regime this
project ports. Its runtime is built around tmux; Herdr already provides
persistent sessions, Git worktree management, agent state detection, and a
socket API, so this project replaces that plumbing and extends the process.

The prompts and constitution committed here are original text implementing the
same methodology. Upstream currently has no license, so its files are not
redistributed. `bin/import-upstream` downloads upstream packs directly from
their repository for users who choose to import them.

## License

[MIT](LICENSE) covers this repository's original code and prompts. Retain the
license and upstream attribution when redistributing it.
