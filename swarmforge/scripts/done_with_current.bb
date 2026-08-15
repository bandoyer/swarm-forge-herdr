#!/usr/bin/env bb
;; done_with_current.bb — complete current work per the role's receive mode.
(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "handoff_lib.bb")))
(handoff-lib/run-entry
 #(handoff-lib/dispatch-by-mode! handoff-lib/done-task! handoff-lib/done-batch!))
