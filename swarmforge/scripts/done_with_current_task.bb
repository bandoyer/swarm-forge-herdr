#!/usr/bin/env bb
;; done_with_current_task.bb — task-mode completion.
(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "handoff_lib.bb")))
(handoff-lib/run-entry handoff-lib/done-task!)
