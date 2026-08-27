;; squad_lib.bb — shared squad v2 state helpers (docs/squad-v2.md).
;;
;; Owns the durable .swarmforge/squad/ layout the squad entry scripts share:
;; EDN record files, the append-only events.log, squad.conf settings
;; (capacity, agent profiles, merger depth, approval gates), and the
;; validated state-transition step. Loads handoff_lib.bb itself, so
;; entries load only this file. Defines no side effects at load time.

(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "handoff_lib.bb")))

(ns squad-lib
  (:require [babashka.fs :as fs]
            [clojure.edn :as edn]
            [clojure.string :as str]))

(def ^:dynamic *project-root*
  "Launcher bootstrap override. Entry scripts normally resolve through the
  registered roles.tsv; `swarm squad up` binds its already-validated root
  before that registration exists."
  nil)

(defn project-root [] (or *project-root* (handoff-lib/project-root)))

(defn squad-dir [] (fs/path (project-root) ".swarmforge" "squad"))

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
  (let [file (fs/path (project-root) "swarmforge" "squad.conf")]
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

(def pinned-profile-kinds
  "Agent kinds whose model/effort CLI mapping SwarmForge owns. Kind-only
  profiles remain open to every safe Herdr kind for S6 compatibility."
  #{"claude" "codex" "grok"})

(defn valid-agent-model?
  "Model ids are argv/audit values, never paths. Permit provider-style
  separators while excluding whitespace and control characters."
  [model]
  (boolean (re-matches #"[A-Za-z0-9][A-Za-z0-9._:/-]*" (str model))))

(defn valid-agent-effort? [effort] (safe-token? effort))

(defn- invalid-profile! [detail]
  (handoff-lib/die 2 (str "INVALID_AGENT_PROFILE: " detail)))

(defn require-valid-agent-profile!
  "Validate and return a {:kind, optional :model/:effort} profile. A
  kind-only profile preserves S6's INVALID_KIND error and open kind set; a
  pinned profile is complete and limited to launch mappings owned here."
  [{:keys [kind model effort] :as profile}]
  (if (or model effort)
    (do
      (when-not (and model effort)
        (invalid-profile! "model and effort must be supplied together"))
      (when-not (valid-agent-kind? kind)
        (invalid-profile! (str "unsafe kind: " kind)))
      (when-not (pinned-profile-kinds kind)
        (invalid-profile! (str "pinned kind is unsupported: " kind)))
      (when-not (valid-agent-model? model)
        (invalid-profile! (str "unsafe model: " model)))
      (when-not (valid-agent-effort? effort)
        (invalid-profile! (str "unsafe effort: " effort))))
    (require-valid-agent-kind! kind))
  profile)

(defn explicit-agent-profile
  "Parse zero, one, or three CLI values into no override, a legacy kind-only
  profile, or a complete pinned profile. Callers normally gate arity for their
  own usage text; this function still fails closed when called directly."
  [values]
  (let [values (vec values)
        profile (case (count values)
                  0 nil
                  1 {:kind (nth values 0)}
                  3 {:kind (nth values 0)
                     :model (nth values 1)
                     :effort (nth values 2)}
                  (invalid-profile! "expected <kind> or <kind> <model> <effort>"))]
    (when profile (require-valid-agent-profile! profile))))

(defn agent-profile-fields
  "Durable EDN fields for a resolved profile. Kind is always present; model
  and effort are additive only for a pinned profile."
  [{:keys [kind model effort]}]
  (cond-> {:agent-kind kind}
    model (assoc :agent-model model :agent-effort effort)))

(defn agent-profile-detail
  "Stable event/status detail. Kind-only text remains byte-compatible with
  S6; pinned profiles append model and effort."
  [{:keys [kind model effort]}]
  (str "kind=" kind
       (when model (str " model=" model " effort=" effort))))

(defn agent-launch-args
  "Provider-native CLI arguments passed after Herdr's `--`."
  [{:keys [kind model effort] :as profile}]
  (require-valid-agent-profile! profile)
  (if-not model
    []
    (case kind
      "codex" ["--model" model "-c" (str "model_reasoning_effort=" effort)]
      "claude" ["--model" model "--effort" effort]
      "grok" ["--model" model "--reasoning-effort" effort]
      ;; require-valid-agent-profile! owns this invariant; retain an explicit
      ;; fail-closed branch if the supported set and mapping ever drift.
      (invalid-profile! (str "no launch mapping for pinned kind: " kind)))))

(defn- conf-setting-values
  "All token vectors following a named squad.conf setting. Blank/comment and
  unrelated lines are ignored; recognized malformed lines remain visible to
  strict profile readers."
  [setting]
  (vec
   (for [line (squad-conf-lines)
         :let [trimmed (str/trim line)]
         :when (and (not (str/blank? trimmed))
                    (not (str/starts-with? trimmed "#")))
         :let [tokens (str/split trimmed #"\s+")]
         :when (= setting (first tokens))]
     (vec (rest tokens)))))

(defn- one-profile-setting
  [setting]
  (let [matches (conf-setting-values setting)]
    (when (> (count matches) 1)
      (invalid-profile! (str "duplicate " setting)))
    (when-let [values (first matches)]
      (when-not (= 3 (count values))
        (invalid-profile! (str setting " requires <kind> <model> <effort>")))
      (explicit-agent-profile values))))

(defn- configured-template-profile [template]
  (let [rows (conf-setting-values "template_profile")]
    ;; Validate every recognized row so a typo cannot remain latent until one
    ;; particular template happens to spawn.
    (doseq [values rows]
      (when-not (= 4 (count values))
        (invalid-profile! "template_profile requires <template> <kind> <model> <effort>"))
      (when-not (safe-token? (first values))
        (invalid-profile! (str "unsafe template: " (first values))))
      (require-valid-agent-profile!
       {:kind (nth values 1) :model (nth values 2) :effort (nth values 3)}))
    (when-let [duplicate (->> rows
                              (map first)
                              frequencies
                              (some (fn [[candidate n]]
                                      (when (> n 1) candidate))))]
      (invalid-profile! (str "duplicate template_profile for " duplicate)))
    (let [matches (filter #(= template (first %)) rows)]
      (when-let [values (first matches)]
        {:kind (nth values 1) :model (nth values 2) :effort (nth values 3)}))))

(defn validate-agent-profile-config!
  "Strictly validate every recognized profile setting before any profile-
  sensitive record is written. Legacy worker_kind keeps its historical
  permissive fallback behavior."
  []
  (one-profile-setting "leader_profile")
  (one-profile-setting "worker_profile")
  ;; A nil lookup still validates every template row and every duplicate.
  (configured-template-profile nil)
  true)

(defn configured-leader-profile
  "Configured pinned leader profile, or the legacy kind-only Claude default."
  []
  (validate-agent-profile-config!)
  (or (one-profile-setting "leader_profile") {:kind "claude"}))

(declare configured-worker-kind)

(defn configured-worker-profile
  "Resolved configured profile for a template before any explicit assignment
  override: template profile, default worker profile, legacy worker_kind, then
  kind-only Claude."
  [template]
  (validate-agent-profile-config!)
  (or (configured-template-profile template)
      (one-profile-setting "worker_profile")
      {:kind (configured-worker-kind)}))

(defn resolve-worker-profile
  "Resolve exactly once at allocation. An explicit kind-only profile replaces
  the complete configured profile rather than borrowing incompatible pins."
  [template explicit-profile]
  (validate-agent-profile-config!)
  (or explicit-profile (configured-worker-profile template)))

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
