# Profile rubric

Choose from evidence and coordination needs, not task size labels alone.

| Profile | Choose it when | Do not choose it when |
|---|---|---|
| Solo | One bounded change is clear and existing verification is an adequate gate | Independent review is materially valuable |
| `directed-cg` | One coherent implementation needs an independent, skeptical review; serial work is sufficient | The work has truly independent slices or needs a formal multi-gate evidence pipeline |
| `four` | Requirements or architectural boundaries are the primary uncertainty | The requirement is already crisp and one reviewer can judge it |
| `six-cg` | Failure is costly and the project has meaningful acceptance, mutation, coverage, or architecture tooling | The tools cannot produce useful evidence or the change is routine |
| Squad | Several independent assignments can make real progress concurrently, or decomposition must adapt during a longer program | The work is one slice; a persistent leader and worker lifecycle would be ceremony |

Assess these dimensions directly:

- Requirement ambiguity: can acceptance be stated now?
- Consequence of a wrong change: routine, costly, or safety/security critical?
- Evidence burden: existing focused tests, independent review, architecture
  judgment, or a full quality-tool battery?
- Parallelism: name the independent workstreams. If they cannot be named, do
  not use squad.
- Coordination risk: shared files and sequential dependencies favor solo or
  `directed-cg`.

`two` and `adversaries` remain compatibility/special-purpose packs. Recommend
them only when the user explicitly wants their exact historical pipeline.
Bare `swarm init` remains `six-cg`; that launcher default does not override this
task-specific recommendation.

Escalate only one level at a time when uncertainty can be resolved cheaply.
Do not run multiple profiles for comparison unless the user asks for an
experiment.
