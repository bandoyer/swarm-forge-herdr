---
name: swarm-director
description: Assess a software task, recommend the smallest adequate SwarmForge profile, and after authorization direct a bounded Herdr-backed run. Use when the user says "swarm this," asks which swarm profile or mode fits a task, or wants a Director-led Builder/Reviewer workflow. Do not use for ordinary coding without swarm intent.
---

# Swarm Director

Choose the least costly workflow that can produce the evidence the task needs.
The Director remains the only user-facing coordinator.

## Workflow

1. Inspect the target repository instructions, relevant code, and existing
   verification before judging complexity.
2. Write a compact run contract: goal, acceptance criteria, non-goals, files or
   subsystem in scope, verification, and hard time/iteration budget.
3. Read [references/profile-rubric.md](references/profile-rubric.md), recommend
   the smallest adequate profile, and explain the deciding risk in one or two
   sentences. Do not manufacture a numeric complexity score.
4. Do not launch merely because a recommendation was requested. Launch when the
   user explicitly asks to run, start, or swarm the task; that wording is
   authorization for the reversible run, not for integration or push.
5. If `directed-cg` is selected, read and follow
   [references/directed-run.md](references/directed-run.md). For another profile,
   obey its pack article and configured circuit budget.
6. Stop when acceptance is proved, the configured budget is reached, a circuit
   opens, or progress requires a material scope decision. Report the terminal
   state instead of inventing more work.

If Herdr is unavailable, the target repository is unclear, or changing an
existing customized profile would overwrite user policy, stop after the
recommendation and provide the exact next command or decision needed.

Never merge into a protected branch or push unless the user explicitly asks.
Finish with the candidate SHA, verification evidence, review verdict, changed
scope, and remaining risk. Keep the report compact.
