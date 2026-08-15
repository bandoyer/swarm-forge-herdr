#!/usr/bin/env bb
;; squad_assign.bb — the squad v2 assignment lifecycle (docs/squad-v2.md, S2).
;;
;; Durable, file-based assignment records under .swarmforge/squad/:
;;   assignments/<id>/assignment.md   instructions handed to the worker
;;   assignments/<id>/status.edn      lifecycle state + metadata
;;   assignments/<id>/result.handoff  the worker's result, once recorded
;;   events.log                       append-only timestamped state changes
;;
;; Lifecycle: created -> spawned -> result -> accepted | rejected (-> merged).
;; This tool owns created/result/accepted/rejected and replacement links;
;; the spawner writes spawned and the daemon writes merged (S3). Illegal
;; transitions exit 2 with an INVALID_TRANSITION token.

(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "handoff_lib.bb")))

(ns squad-assign
  (:require [babashka.fs :as fs]
            [clojure.edn :as edn]
            [clojure.string :as str]))

(def usage-text
  (str "Usage: squad_assign.sh <subcommand> ...\n\n"
       "  create <id> <template> <instructions-file>\n"
       "  status <id>\n"
       "  result <id> <handoff-file>\n"
       "  accept <id>\n"
       "  reject <id> <reason...>\n"
       "  replace <old-id> <new-id> <template> <instructions-file>"))

;; --- squad state layout ---------------------------------------------------

(defn squad-dir [] (fs/path (handoff-lib/project-root) ".swarmforge" "squad"))
(defn assignment-dir [id] (fs/path (squad-dir) "assignments" id))
(defn status-file [id] (fs/path (assignment-dir id) "status.edn"))

(defn log-event!
  "Append one line to events.log: '<iso-timestamp> <id> <event> [detail]'.
  Every state change must pass through here — the log feeds `swarm logs`
  and is the durable record herdr's live-only states cannot provide."
  [id event detail]
  (fs/create-dirs (squad-dir))
  (spit (str (fs/path (squad-dir) "events.log"))
        (str (handoff-lib/iso-now) " " id " " event
             (when-not (str/blank? detail) (str " " detail))
             "\n")
        :append true))

(defn read-status [id]
  (let [file (status-file id)]
    (when-not (fs/exists? file)
      (handoff-lib/die 1 (str "NO_SUCH_ASSIGNMENT: " id)))
    (edn/read-string (slurp (str file)))))

(defn write-status! [id status]
  (spit (str (status-file id))
        (str (pr-str (assoc status :updated-at (handoff-lib/iso-now))) "\n")))

;; --- transitions ----------------------------------------------------------

(def allowed-transitions
  "Prior states each transition may leave from. result accepts :spawned
  (the normal path) and :created (leader-routed work before spawn exists);
  reject accepts :spawned so a worker that dies without a result can still
  be closed out."
  {:result   #{:created :spawned}
   :accepted #{:result}
   :rejected #{:result :spawned}})

(defn transition!
  "Validated state change: die 2 on an illegal move; otherwise run effect!
  (side effects belong after validation, before the write), persist the new
  state plus extra fields, log, and announce."
  [id new-state {:keys [extra detail effect!]}]
  (let [status (read-status id)
        old-state (:state status)]
    (when-not (contains? (get allowed-transitions new-state #{}) old-state)
      (handoff-lib/die 2 (format "INVALID_TRANSITION: assignment '%s' cannot go %s -> %s"
                                 id (name old-state) (name new-state))))
    (when effect! (effect!))
    (write-status! id (merge status extra {:state new-state}))
    (log-event! id (name new-state) detail)
    (println (str "ASSIGNMENT_STATE: " id " " (name old-state) " -> " (name new-state)))))

;; --- subcommands ----------------------------------------------------------

(defn create!
  ([id template instructions-file] (create! id template instructions-file nil))
  ([id template instructions-file replaces]
   (when-not (re-matches #"[A-Za-z0-9][A-Za-z0-9_-]*" id)
     (handoff-lib/die 2 (str "INVALID_ASSIGNMENT_ID: " id)))
   (when (fs/exists? (assignment-dir id))
     (handoff-lib/die 2 (str "ASSIGNMENT_EXISTS: " id)))
   (when-not (fs/regular-file? instructions-file)
     (handoff-lib/die 1 (str "Instructions file not found: " instructions-file)))
   (fs/create-dirs (assignment-dir id))
   (fs/copy instructions-file (fs/path (assignment-dir id) "assignment.md"))
   (write-status! id (cond-> {:id id
                              :template template
                              :state :created
                              :created-at (handoff-lib/iso-now)}
                       replaces (assoc :replaces replaces)))
   (log-event! id "created" (str "template=" template
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

(defn result! [id handoff-file]
  (when-not (fs/regular-file? handoff-file)
    (handoff-lib/die 1 (str "Handoff file not found: " handoff-file)))
  (let [stored (fs/path (assignment-dir id) "result.handoff")]
    (transition! id :result
                 ;; replace-existing: a crashed prior attempt may have copied
                 ;; the file before the status write; the retry must succeed.
                 {:effect! #(fs/copy handoff-file stored {:replace-existing true})
                  :extra {:result-file (str stored)}
                  :detail (str "handoff=" (fs/file-name (fs/path handoff-file)))})))

(defn accept! [id]
  (transition! id :accepted {}))

(defn reject! [id reason]
  (transition! id :rejected {:extra {:reason reason}
                             :detail (str "reason=" reason)}))

(def replaceable-states
  "An accepted (or merged) assignment is finished work; only unfinished
  ones can be replaced."
  #{:created :spawned :result :rejected})

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
    (log-event! old-id "replaced" (str "replaced-by=" new-id))
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
      "result" (if (= 2 (count params)) (apply result! params) (usage-die))
      "accept" (if (= 1 (count params)) (accept! (first params)) (usage-die))
      "reject" (if (<= 2 (count params)) (reject! (first params) (str/join " " (rest params))) (usage-die))
      "replace" (if (= 4 (count params)) (apply replace! params) (usage-die))
      (usage-die))))

(handoff-lib/run-entry #(-main *command-line-args*))
