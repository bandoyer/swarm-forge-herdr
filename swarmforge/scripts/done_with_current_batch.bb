#!/usr/bin/env bb
;; done_with_current_batch.bb — batch-mode completion.
(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "handoff_lib.bb")))
(handoff-lib/run-entry handoff-lib/done-batch!)
