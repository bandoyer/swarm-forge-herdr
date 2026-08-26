#!/usr/bin/env bb
;; squad_spawn_request.bb — leader-side spawn requests (docs/squad-s3.md, S3
;; slice A).
;;
;; A spawn-request is the leader asking the daemon to spawn a worker for a
;; :created assignment: .swarmforge/squad/spawn-requests/<assignment-id>.edn
;; holding {:assignment :template :requested-at} plus an optional :kind.
;; This tool creates, lists, and drops requests; the daemon consumes a request
;; when it spawns. Requests for missing or non-:created assignments are
;; refused with exit 2, so a stale request can only arise from lifecycle
;; movement after the fact, which the advisor then reports as
;; drop-stale-spawn-request.

(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "squad_lib.bb")))

(ns squad-spawn-request
  (:require [babashka.fs :as fs]
            [clojure.edn :as edn]))

(def usage-text
  (str "Usage: squad_spawn_request.sh <subcommand> ...\n\n"
       "  create <assignment-id> <template> [kind]\n"
       "  list\n"
       "  drop <assignment-id>"))

(defn request-file
  "Resolve a spawn-request path. Ids are validated against the assignment-id
  shape before touching the filesystem, so a hostile id can never escape
  the spawn-requests directory."
  [assignment-id]
  (when-not (re-matches #"[A-Za-z0-9][A-Za-z0-9_-]*" (str assignment-id))
    (handoff-lib/die 2 (str "INVALID_ASSIGNMENT_ID: " assignment-id)))
  (fs/path (squad-lib/spawn-requests-dir) (str assignment-id ".edn")))

;; --- subcommands ----------------------------------------------------------

(defn create! [assignment-id template explicit-kind]
  (squad-lib/require-valid-agent-kind! explicit-kind)
  (let [file (request-file assignment-id)
        status-file (squad-lib/status-file assignment-id)]
    ;; Templates become audit-log detail and daemon spawn arguments —
    ;; gate their shape like assignment ids (reviewer finding,
    ;; squad-advisor: a newline in the template could forge log lines).
    (when-not (squad-lib/safe-token? template)
      (handoff-lib/die 2 (str "INVALID_TEMPLATE: " template)))
    (when (fs/exists? file)
      (handoff-lib/die 2 (str "SPAWN_REQUEST_EXISTS: " assignment-id)))
    (when-not (fs/exists? status-file)
      (handoff-lib/die 2 (str "NO_SUCH_ASSIGNMENT: " assignment-id)))
    (let [{:keys [state replaced-by]} (edn/read-string (slurp (str status-file)))]
      ;; replace! keeps the old record's state, so a replaced assignment
      ;; can still read :created; it is retired work and must not spawn
      ;; (reviewer finding, squad-advisor).
      (when replaced-by
        (handoff-lib/die 2 (format "ASSIGNMENT_REPLACED: '%s' was replaced by %s; request a spawn for the replacement"
                                   assignment-id replaced-by)))
      (when-not (= :created state)
        (handoff-lib/die 2 (format "ASSIGNMENT_NOT_CREATED: '%s' is %s; only a created assignment can request a spawn"
                                   assignment-id (name state)))))
    (fs/create-dirs (squad-lib/spawn-requests-dir))
    ;; Preserve the original three-field shape unless the leader supplied an
    ;; override; the file's presence or absence is the request lifecycle.
    (spit (str file) (str (pr-str (cond-> {:assignment assignment-id
                                          :template template
                                          :requested-at (handoff-lib/iso-now)}
                                   explicit-kind (assoc :kind explicit-kind)))
                          "\n"))
    (squad-lib/log-event! assignment-id "spawn-requested"
                          (str "template=" template
                               (when explicit-kind (str " kind=" explicit-kind))))
    (println (str "SPAWN_REQUEST_CREATED: " assignment-id))))

(defn list! []
  (doseq [{:keys [assignment template requested-at]} (squad-lib/all-spawn-requests)]
    (println assignment template requested-at)))

(defn drop! [assignment-id]
  (let [file (request-file assignment-id)]
    (when-not (fs/exists? file)
      (handoff-lib/die 1 (str "NO_SUCH_SPAWN_REQUEST: " assignment-id)))
    (fs/delete file)
    (squad-lib/log-event! assignment-id "spawn-request-dropped" "")
    (println (str "SPAWN_REQUEST_DROPPED: " assignment-id))))

;; --- entry ----------------------------------------------------------------

(defn- usage-die []
  (handoff-lib/die 1 usage-text))

(defn -main [args]
  (let [[command & params] args
        params (vec params)]
    (case command
      "create" (if (<= 2 (count params) 3)
                 (create! (nth params 0) (nth params 1) (nth params 2 nil))
                 (usage-die))
      "list" (if (= [] params) (list!) (usage-die))
      "drop" (if (= 1 (count params)) (drop! (first params)) (usage-die))
      (usage-die))))

(handoff-lib/run-entry #(-main *command-line-args*))
