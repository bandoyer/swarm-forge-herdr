;; squad_lib.bb — shared squad v2 state helpers (docs/squad-v2.md).
;;
;; Owns the durable .swarmforge/squad/ layout the squad entry scripts share:
;; EDN record files, the append-only events.log, the transient-worker cap
;; from squad.conf, and the validated state-transition step. Loads
;; handoff_lib.bb itself, so entries load only this file. Defines no side
;; effects at load time.

(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "handoff_lib.bb")))

(ns squad-lib
  (:require [babashka.fs :as fs]
            [clojure.edn :as edn]
            [clojure.string :as str]))

(defn squad-dir [] (fs/path (handoff-lib/project-root) ".swarmforge" "squad"))

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

(defn read-record
  "Record EDN from file, or die 1 '<missing-token>: <id>' when absent."
  [file missing-token id]
  (when-not (fs/exists? file)
    (handoff-lib/die 1 (str missing-token ": " id)))
  (edn/read-string (slurp (str file))))

(defn write-record!
  "Persist a record to its EDN file, stamping :updated-at."
  [file record]
  (spit (str file)
        (str (pr-str (assoc record :updated-at (handoff-lib/iso-now))) "\n")))

(defn max-transient-agents
  "Transient-worker capacity from swarmforge/squad.conf, upstream's format:
  a line 'max_transient_agents N'. 10 when the file or line is absent."
  []
  (let [file (fs/path (handoff-lib/project-root) "swarmforge" "squad.conf")]
    (or (when (fs/exists? file)
          (some (fn [line]
                  (when-let [[_ n] (re-matches #"\s*max_transient_agents\s+(\d+)\s*" line)]
                    (parse-long n)))
                (str/split-lines (slurp (str file)))))
        10)))

(defn transition!
  "Validated state change on a record file: die 2 INVALID_TRANSITION unless
  the record's current state is in allowed; otherwise run effect! (side
  effects belong after validation, before the write), persist extra fields
  plus the new state, log, and announce as '<announce-token>: <id> <old> ->
  <new>'."
  [{:keys [file missing-token announce-token label id allowed new-state
           extra detail effect!]}]
  (let [record (read-record file missing-token id)
        old-state (:state record)]
    (when-not (contains? allowed old-state)
      (handoff-lib/die 2 (format "INVALID_TRANSITION: %s '%s' cannot go %s -> %s"
                                 label id (name old-state) (name new-state))))
    (when effect! (effect!))
    (write-record! file (merge record extra {:state new-state}))
    (log-event! id (name new-state) detail)
    (println (str announce-token ": " id " " (name old-state) " -> " (name new-state)))))
