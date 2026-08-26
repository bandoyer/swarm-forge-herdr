#!/usr/bin/env bb
;; squad_assign.bb — the squad v2 assignment lifecycle (docs/squad-v2.md, S2).
;;
;; Durable, file-based assignment records under .swarmforge/squad/:
;;   assignments/<id>/assignment.md   instructions handed to the worker
;;   assignments/<id>/status.edn      lifecycle state + metadata
;;   assignments/<id>/result.handoff  the worker's result, once recorded
;;   events.log                       append-only timestamped state changes
;;
;; Lifecycle: created -> spawned -> result -> accepted -> merged, with
;; rejected and merge-blocked as the review/merge failure exits. This tool
;; owns created/spawned/result/accepted/rejected and replacement links; the
;; `merge` and `merge-blocked` subcommands are daemon-only (squadd, S3) —
;; nothing but the daemon moves an assignment past accepted. Illegal
;; transitions exit 2 with an INVALID_TRANSITION token.

(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "squad_lib.bb")))

(ns squad-assign
  (:require [babashka.fs :as fs]
            [clojure.string :as str]))

(def usage-text
  (str "Usage: squad_assign.sh <subcommand> ...\n\n"
       "  create <id> <template> <instructions-file>\n"
       "  status <id>\n"
       "  spawn <id>\n"
       "  result <id> <handoff-file>\n"
       "  accept <id>\n"
       "  reject <id> <reason...>\n"
       "  replace <old-id> <new-id> <template> <instructions-file>\n"
       "  merge <id>                    (daemon-only)\n"
       "  merge-blocked <id> <detail...> (daemon-only)"))

;; --- assignment records ---------------------------------------------------

(defn read-status [id]
  (squad-lib/read-record (squad-lib/status-file id) "NO_SUCH_ASSIGNMENT" id))

(defn write-status! [id status]
  (squad-lib/write-record! (squad-lib/status-file id) status))

;; --- transitions ----------------------------------------------------------

(def allowed-transitions
  "Prior states each transition may leave from. result accepts :spawned
  (the normal path) and :created (leader-routed work before spawn exists);
  reject accepts :spawned so a worker that dies without a result can still
  be closed out."
  {:spawned       #{:created}
   :result        #{:created :spawned}
   :accepted      #{:result}
   :rejected      #{:result :spawned}
   :merged        #{:accepted}
   :merge-blocked #{:accepted}})

(defn- transition! [id new-state opts]
  (squad-lib/transition! (merge {:file (squad-lib/status-file id)
                                 :missing-token "NO_SUCH_ASSIGNMENT"
                                 :announce-token "ASSIGNMENT_STATE"
                                 :label "assignment"
                                 :id id
                                 :allowed (get allowed-transitions new-state #{})
                                 :new-state new-state}
                                opts)))

;; --- subcommands ----------------------------------------------------------

(defn create!
  ([id template instructions-file] (create! id template instructions-file nil))
  ([id template instructions-file replaces]
   (when-not (re-matches #"[A-Za-z0-9][A-Za-z0-9_-]*" id)
     (handoff-lib/die 2 (str "INVALID_ASSIGNMENT_ID: " id)))
   (when (fs/exists? (squad-lib/assignment-dir id))
     (handoff-lib/die 2 (str "ASSIGNMENT_EXISTS: " id)))
   (when-not (fs/regular-file? instructions-file)
     (handoff-lib/die 1 (str "Instructions file not found: " instructions-file)))
   (fs/create-dirs (squad-lib/assignment-dir id))
   (fs/copy instructions-file (fs/path (squad-lib/assignment-dir id) "assignment.md"))
   (write-status! id (cond-> {:id id
                              :template template
                              :state :created
                              :created-at (handoff-lib/iso-now)}
                       replaces (assoc :replaces replaces)))
   (squad-lib/log-event! id "created" (str "template=" template
                                           (when replaces (str " replaces=" replaces))))
   (println (str "ASSIGNMENT_CREATED: " id))))

(defn status! [id]
  (let [{:keys [state template reason replaces replaced-by]} (read-status id)]
    (println "ASSIGNMENT:" id)
    (println "STATE:" (name state))
    (println "TEMPLATE:" template)
    (when reason (println "REASON:" reason))
    (when replaces (println "REPLACES:" replaces))
    (when replaced-by (println "REPLACED_BY:" replaced-by))))

(defn spawn! [id]
  (transition! id :spawned {}))

(defn result! [id handoff-file]
  (when-not (fs/regular-file? handoff-file)
    (handoff-lib/die 1 (str "Handoff file not found: " handoff-file)))
  (let [stored (fs/path (squad-lib/assignment-dir id) "result.handoff")]
    (transition! id :result
                 ;; replace-existing: a crashed prior attempt may have copied
                 ;; the file before the status write; the retry must succeed.
                 {:effect! #(fs/copy handoff-file stored {:replace-existing true})
                  ;; Stored relative to the assignment dir so the record
                  ;; survives the repository moving.
                  :extra {:result-file "result.handoff"}
                  :detail (str "handoff=" (fs/file-name (fs/path handoff-file)))})))

(defn accept! [id]
  (transition! id :accepted {}))

(defn reject! [id reason]
  (transition! id :rejected {:extra {:reason reason}
                             :detail (str "reason=" reason)}))

(defn- require-daemon! [subcommand]
  (when (str/blank? (System/getenv "SWARMFORGE_SQUADD"))
    (handoff-lib/die 2
                     (str "DAEMON_ONLY: " subcommand
                          " is daemon-only; squadd applies accepted verdicts itself"))))

(defn merge! [id]
  (require-daemon! "merge")
  (transition! id :merged {}))

(defn merge-blocked! [id detail]
  (require-daemon! "merge-blocked")
  (transition! id :merge-blocked {:extra {:reason detail}
                                  :detail (str "detail=" detail)}))

(def replaceable-states
  "An accepted (or merged) assignment is finished work; only unfinished
  ones can be replaced. :merge-blocked is replaceable so the leader can
  route a merger assignment for the conflicted work (S3 route-merger)."
  #{:created :spawned :result :rejected :merge-blocked})

(defn replace!
  "Retire old-id's assignment and reissue it as new-id, linking the two
  (:replaced-by / :replaces) so history stays traceable. The old record
  keeps its state — replacement is a link, not a lifecycle state."
  [old-id new-id template instructions-file]
  (let [old-status (read-status old-id)]
    (when (:replaced-by old-status)
      (handoff-lib/die 2 (str "ALREADY_REPLACED: " old-id " -> " (:replaced-by old-status))))
    (when-not (contains? replaceable-states (:state old-status))
      (handoff-lib/die 2 (format "INVALID_TRANSITION: assignment '%s' in state %s cannot be replaced"
                                 old-id (name (:state old-status)))))
    (create! new-id template instructions-file old-id)
    (write-status! old-id (assoc old-status :replaced-by new-id))
    (squad-lib/log-event! old-id "replaced" (str "replaced-by=" new-id))
    (println (str "ASSIGNMENT_REPLACED: " old-id " -> " new-id))))

;; --- entry ----------------------------------------------------------------

(defn- usage-die []
  (handoff-lib/die 1 usage-text))

(defn -main [args]
  (let [[command & params] args
        params (vec params)]
    (case command
      "create" (if (= 3 (count params)) (apply create! params) (usage-die))
      "status" (if (= 1 (count params)) (status! (first params)) (usage-die))
      "spawn" (if (= 1 (count params)) (spawn! (first params)) (usage-die))
      "result" (if (= 2 (count params)) (apply result! params) (usage-die))
      "accept" (if (= 1 (count params)) (accept! (first params)) (usage-die))
      "reject" (if (<= 2 (count params)) (reject! (first params) (str/join " " (rest params))) (usage-die))
      "replace" (if (= 4 (count params)) (apply replace! params) (usage-die))
      "merge" (if (= 1 (count params)) (merge! (first params)) (usage-die))
      "merge-blocked" (if (<= 2 (count params))
                        (merge-blocked! (first params) (str/join " " (rest params)))
                        (usage-die))
      (usage-die))))

(handoff-lib/run-entry #(-main *command-line-args*))
