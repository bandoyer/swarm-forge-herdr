#!/usr/bin/env bb
;; ready_for_next_task.bb — task-mode accept/resume.
(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "handoff_lib.bb")))
(handoff-lib/run-entry handoff-lib/ready-task!)
