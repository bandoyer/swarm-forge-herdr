# Prompt sync — Design

> Status: proposed. Nothing built yet.

Stock prompts fixed in `prompts/` never reach a project that already
installed them. Every project silently forks at first install and keeps
what it got, forever. Syncing is manual today, and the manual sync is
the only reason any project is current.

## The gap

`bin/swarm:335`:

```clojure
(defn- install! [source target]
  (when-not (fs/exists? target)
    ...))
```

Writes only when the target is absent. Nothing in `init`, `switch`, or
`squad up` ever refreshes an installed prompt.

| Installed file | init | switch | toolset |
|---|---|---|---|
| `swarmforge.conf` | if absent | **replaced** | — |
| `constitution/articles/pack.prompt` | if absent | **replaced** | — |
| `constitution/articles/toolset.prompt` | — | — | **regenerated** |
| `constitution.prompt` | if absent | kept | — |
| `articles/{engineering,handoffs,workflow}` | if absent | kept | — |
| `articles/project.prompt` | if absent | kept | — |
| `roles/*.prompt` | if absent | if absent | — |
| `contracts/*.contract.edn` | if absent | if absent | — |
| `worker-common.prompt`, `roles/squad-leader.prompt` | if absent (squad up) | — | — |

`switch!` prints "Project and toolset articles kept." It keeps stale role
prompts too, and says nothing about those. What it preserves on purpose
is announced; what it preserves by accident is not.

Evidence this bites: `~/Work/press-start` carries a commit titled *"Sync
the swarm roles from herdr's audit"* — a hand sync, because no command
does it. And this repo's own installed engineering article sat behind
source on the hook-aware attribution rule from `1388db6` until it was
found by hand.

## Why not simply overwrite

Because real customization exists, and checking confirmed it. This
repo's installed contracts are not stale copies — they carry its own
artifact roots (`swarmforge/scripts/`, `bin/`, `prompts/`, `packs/`) and
a `SMOKE PASSED (\d+ checks)` evidence pattern in place of the stock
`dotnet test|bb test`. `project.prompt` is written per project by
definition. Overwriting would destroy exactly the work a project is
supposed to do.

## The missing piece is provenance

Comparing an installed file to its source answers "are these the same?"
It cannot answer the question that matters: **did this project change
it, or did the tool move on without it?** Both look identical — a diff.

So record what was installed.

## Records — `swarmforge/.stock.edn`

```edn
{"roles/coder.prompt"      "sha256-..."
 "contracts/coder.contract.edn" "sha256-..."
 "constitution/articles/engineering.prompt" "sha256-..."}
```

The hash of the *stock* file at the moment it was installed. Committed
with the project, not runtime state: a fresh clone must still know.

## Classification

For each installed file, three cases and no others:

| Current file vs | Meaning | Action |
|---|---|---|
| == source | up to date | nothing |
| == recorded hash, != source | untouched here; tool moved on | safe to refresh |
| != both | locally modified | report, never auto-refresh |

This unifies the categories rather than hard-coding them. Contracts and
`project.prompt` need no special case: a project that customized them
lands in row three and is skipped, which is the behavior we want, for the
reason we want it — because it was changed, not because someone listed it
as exempt. A project that never touched its contracts gets stock fixes,
which today it cannot.

## Surfaces

- `swarm sync` — classify, apply row two, print row three as conflicts
  with the paths and a one-line diffstat. Never silently resolves.
- `swarm sync --check` — classify and report only, exit non-zero if
  anything is out of date. This is what a downstream project puts in its
  own test suite, the same job `test/smoke.sh` now does for this repo.
- `swarm status` — a line when any stock file is behind, so the state is
  visible without running a command that mutates.
- `swarm sync --force <path>` — take source for one file, for when the
  human has decided the local edit should go.

## Migration

Existing projects have no manifest, so nothing can be classified as
"untouched." Absent a manifest, `== source` is up to date and anything
else is **unknown**: reported, never auto-refreshed. Writing the manifest
happens on the next `init`/`sync`, after which classification is exact.
No project silently loses an edit on upgrade.

## Testing

File-based and deterministic, so it tests headlessly like the rest:
build a project tree, install, mutate source, mutate the installed copy,
and assert each of the three rows plus the no-manifest case. `--check`
exit codes are directly assertable.

## Non-goals

- Merging. A conflict is reported with both paths; the human resolves it.
  Three-way merging prompts is not a job worth automating.
- Auto-sync on `swarm up`. Changing prompts under a running swarm is
  exactly the surprise this design is meant to prevent; `up` may report,
  never rewrite.
- Reaching into other repositories. `swarm sync` runs in one project
  root, like every other subcommand.

## Open questions

1. Should `swarm switch` run the sync classification automatically and
   report, given it already replaces the conf and pack article? It is
   the moment a project is most likely to be stale.
2. Does the manifest belong at `swarmforge/.stock.edn` or inside
   `swarmforge.conf`? A dotfile is easy to miss in review; the conf is
   already per-project and committed, but mixing generated hashes into a
   hand-edited file invites merge noise.
