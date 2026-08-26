;; squad_lib.bb — shared squad v2 state helpers (docs/squad-v2.md).
;;
;; Owns the durable .swarmforge/squad/ layout the squad entry scripts share:
;; EDN record files, the append-only events.log, squad.conf settings
;; (capacity, worker kind, merger depth, approval gates), and the
;; validated state-transition step. Loads handoff_lib.bb itself, so
;; entries load only this file. Defines no side effects at load time.

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
  ;; One event = one line: fold newlines out of caller-supplied detail so a
  ;; hostile value (a reject reason, a template name) cannot forge extra
  ;; audit-log lines.
  (let [detail (some-> detail (str/replace #"[\r\n]+" " "))]
    (spit (str (fs/path (squad-dir) "events.log"))
          (str (handoff-lib/iso-now) " " id " " event
               (when-not (str/blank? detail) (str " " detail))
               "\n")
          :append true)))

(defn read-record
  "Record EDN from file, or die 1 '<missing-token>: <id>' when absent."
  [file missing-token id]
  (when-not (fs/exists? file)
    (handoff-lib/die 1 (str missing-token ": " id)))
  (edn/read-string (slurp (str file))))

(defn- read-edn [file] (edn/read-string (slurp (str file))))

(defn- edn-records
  "All .edn records in dir, sorted by file name; [] when dir is absent."
  [dir]
  (if (fs/exists? dir)
    (->> (fs/list-dir dir)
         (filter #(str/ends-with? (fs/file-name %) ".edn"))
         (sort-by fs/file-name)
         (mapv read-edn))
    []))

;; --- assignment records ---------------------------------------------------

(defn assignments-dir [] (fs/path (squad-dir) "assignments"))
(defn assignment-dir [id] (fs/path (assignments-dir) id))
(defn status-file [id] (fs/path (assignment-dir id) "status.edn"))

(defn all-assignments
  "Every assignment status record, sorted by assignment id. Directories
  without a status.edn (a create interrupted mid-write) are skipped."
  []
  (if (fs/exists? (assignments-dir))
    (->> (fs/list-dir (assignments-dir))
         (filter fs/directory?)
         (sort-by fs/file-name)
         (keep #(let [file (fs/path % "status.edn")]
                  (when (fs/exists? file) (read-edn file))))
         vec)
    []))

;; --- spawn-request records (S3) -------------------------------------------

(defn spawn-requests-dir [] (fs/path (squad-dir) "spawn-requests"))

(defn all-spawn-requests
  "Every pending spawn-request, sorted by assignment id."
  []
  (edn-records (spawn-requests-dir)))

;; --- approval records (S4) ------------------------------------------------

(defn approvals-dir [] (fs/path (squad-dir) "approvals"))

(defn all-approvals
  "Every approval record, sorted by approval id."
  []
  (edn-records (approvals-dir)))

;; --- theme records (S4) ---------------------------------------------------

(defn themes-dir [] (fs/path (squad-dir) "themes"))

;; --- worker records -------------------------------------------------------

(defn workers-dir [] (fs/path (squad-dir) "workers"))

(def active-states
  "Worker states that occupy a slot and count against the capacity cap."
  #{:allocated :active})

(defn all-workers
  "Every worker record, sorted by name."
  []
  (edn-records (workers-dir)))

(defn active-count [] (count (filter (comp active-states :state) (all-workers))))

(defn write-record!
  "Persist a record to its EDN file, stamping :updated-at."
  [file record]
  (spit (str file)
        (str (pr-str (assoc record :updated-at (handoff-lib/iso-now))) "\n")))

(defn- squad-conf-lines
  "Lines of swarmforge/squad.conf; empty when the file is absent."
  []
  (let [file (fs/path (handoff-lib/project-root) "swarmforge" "squad.conf")]
    (if (fs/exists? file)
      (str/split-lines (slurp (str file)))
      [])))

(defn- conf-int
  "Integer setting from swarmforge/squad.conf, upstream's format: a line
  '<setting> N'. default when the file or line is absent."
  [setting default]
  (let [line-re (re-pattern (str "\\s*" setting "\\s+(\\d+)\\s*"))]
    (or (some (fn [line]
                (when-let [[_ n] (re-matches line-re line)]
                  (parse-long n)))
              (squad-conf-lines))
        default)))

(defn max-transient-agents
  "Transient-worker capacity; 10 when unconfigured."
  []
  (conf-int "max_transient_agents" 10))

(defn safe-token?
  "True when s is safe as a herdr CLI argument, roles.tsv field, and
  event-log value. Agent kinds and templates share this shape."
  [s]
  (boolean (re-matches #"[A-Za-z0-9][A-Za-z0-9._-]*" (str s))))

(defn valid-agent-kind?
  "True when kind is safe as a herdr CLI argument, roles.tsv field, and
  event-log value."
  [kind]
  (safe-token? kind))

(defn require-valid-agent-kind!
  "Die 2 INVALID_KIND when kind is present and not a valid agent kind.
  Nil is ignored so two-argument callers can pass the absent override
  through."
  [kind]
  (when (and kind (not (valid-agent-kind? kind)))
    (handoff-lib/die 2 (str "INVALID_KIND: " kind))))

(defn configured-worker-kind
  "Configured transient-worker kind; claude when squad.conf has no valid
  worker_kind setting. Leader kind is intentionally unrelated."
  []
  (or (some (fn [line]
              (when-let [[_ kind] (re-matches #"\s*worker_kind\s+(\S+)\s*" line)]
                (when (valid-agent-kind? kind) kind)))
            (squad-conf-lines))
      "claude"))

(defn require-approval?
  "True when squad.conf carries a 'require_approval <gate>' line — the S4
  human gate: the daemon may not apply the gated action until an :approved
  approval record exists for its target. No file or no line = no gate =
  pre-S4 behavior (docs/squad-s4.md)."
  [gate]
  (let [line-re (re-pattern (str "\\s*require_approval\\s+"
                                 (java.util.regex.Pattern/quote (str gate))
                                 "\\s*"))]
    (boolean (some #(re-matches line-re %) (squad-conf-lines)))))

(defn max-merger-depth
  "How many merger attempts a merge-blocked line of work may consume before
  the advisor escalates to the user (docs/squad-s3.md); 2 when unconfigured."
  []
  (conf-int "max_merger_depth" 2))

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
