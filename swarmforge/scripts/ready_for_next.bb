#!/usr/bin/env bb
;; ready_for_next.bb — accept or resume work per the role's receive mode.
(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "handoff_lib.bb")))
(handoff-lib/run-entry
 #(handoff-lib/dispatch-by-mode! handoff-lib/ready-task! handoff-lib/ready-batch!))
