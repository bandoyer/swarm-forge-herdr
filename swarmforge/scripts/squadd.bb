#!/usr/bin/env bb
;; squadd.bb — the squad daemon, the swarm's only side-effect owner
;; (docs/squad-s3.md, S3 slice B).
;;
;; Each poll: shell the advisor (squad_next.bb --mechanical-only), apply its
;; blocks in table order — spawn / merge / drop-stale-spawn-request /
;; retire-worker; wait-capacity is informational and skipped — then shell
;; --residual-only and wake the squad-leader only when a residual target
;; appears that the previous poll did not have (the leader polls judgment,
;; not mechanics). The daemon is the sole owner of the project's main
;; branch: nothing else merges, and it merges only while that branch
;; ('main', or `main_branch <name>` in swarmforge/squad.conf) is checked
;; out in the project root — anything else is skipped and retried.
;;
;; Every applied action is logged to .swarmforge/squad/events.log; daemon
;; operations (start/stop, failures, wake-ups) go to squadd.log. All paths
;; are anchored on the <project-root> argument, never the daemon's cwd.
;;
;; Usage: squadd.bb <project-root> [--once]
;;   --once  run a single poll pass and exit (for tests)
;; Env: SWARM_BIN            launcher for spawn/retire (default: swarm)
;;      SWARMFORGE_NO_AGENT  when set, pass --no-agent to spawn/retire
;;      SWARMFORGE_WAKE_CMD  override the wake command (default: herdr);
;;                           set to "none" to disable wake-ups entirely.

(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "handoff_lib.bb")))

(ns squadd
  (:require [babashka.fs :as fs]
            [babashka.process :as process]
            [clojure.edn :as edn]
            [clojure.string :as str]))

(def poll-ms 1000)
(def wake-message
  (str "Squad update: new residual actions await your judgment. Run "
       "swarmforge/scripts/squad_next.sh --residual-only and act on each block."))

(def args-set (set *command-line-args*))
(def project-root
  (or (first (remove #(str/starts-with? % "--") *command-line-args*))
      (do (binding [*out* *err*]
            (println "Usage: squadd.bb <project-root> [--once]"))
          (System/exit 1))))

(def scripts-dir (str (fs/parent *file*)))
(def squad-dir (fs/path project-root ".swarmforge" "squad"))
(def daemon-dir (fs/path squad-dir "daemon"))
(def pid-file (fs/path daemon-dir "squadd.pid"))
(def stop-file (fs/path daemon-dir "stop"))
(def log-file (fs/path daemon-dir "squadd.log"))
(def stopping (atom false))
(def known-residuals
  "Residual [target action] pairs seen on the previous poll; only pairs
  beyond this set trigger a leader wake-up. Keyed on the pair, not the
  target alone, so a known target whose advised action changes (review ->
  route-merger) still wakes the leader (reviewer finding, squadd)."
  (atom #{}))

(def swarm-bin (or (not-empty (System/getenv "SWARM_BIN")) "swarm"))
(def no-agent-args (if (System/getenv "SWARMFORGE_NO_AGENT") ["--no-agent"] []))

(defn log! [& parts]
  (fs/create-dirs daemon-dir)
  (spit (str log-file)
        (str (handoff-lib/iso-now) " " (str/join " " parts) "\n")
        :append true))

(defn event!
  "Mirror of squad_lib's log-event!, anchored on this daemon's project-root
  argument instead of the cwd squad_lib resolves: applied actions land in
  the same durable events.log the CLI tools write."
  [id event detail]
  (fs/create-dirs squad-dir)
  (let [detail (some-> detail (str/replace #"[\r\n]+" " "))]
    (spit (str (fs/path squad-dir "events.log"))
          (str (handoff-lib/iso-now) " " id " " event
               (when-not (str/blank? detail) (str " " detail))
               "\n")
          :append true)))

;; --- shelling out ----------------------------------------------------------

(defn- sh
  "Run argv from the project root; return the result without dying."
  [& argv]
  (apply process/sh {:continue true :dir (str project-root)} argv))

(defn- bb-script [script & args]
  (apply sh "bb" (str (fs/path scripts-dir script)) args))

(defn- failure-text [{:keys [out err]}]
  (str/trim (str out "\n" err)))

(defn advisor-blocks
  "Shell the advisor and parse its NEXT_ACTION blocks, preserving the
  emitted (table) order."
  [flag]
  (let [{:keys [exit out] :as result} (bb-script "squad_next.bb" flag)]
    (if-not (zero? exit)
      (do (log! "advisor-failed" flag (failure-text result)) [])
      (vec (for [chunk (str/split (str out) #"\n\n")
                 :when (not (str/blank? chunk))
                 :let [fields (into {} (keep #(let [[k v] (str/split % #": " 2)]
                                                (when v [k v]))
                                             (str/split-lines chunk)))]]
             {:action (get fields "NEXT_ACTION")
              :target (get fields "TARGET")
              :reason (get fields "REASON")})))))

;; --- mechanical actions -----------------------------------------------------

(defn- summarize
  "One short line from a command's output, safe for CLI args and log lines."
  [s]
  (let [line (str/trim (str/replace (str s) #"\s+" " "))]
    (if (> (count line) 200) (subs line 0 200) line)))

(defn- mark-blocked! [target detail]
  (let [{:keys [exit] :as result} (bb-script "squad_assign.bb" "merge-blocked" target detail)]
    (if (zero? exit)
      (do (event! target "squadd-merge-blocked" detail)
          (log! "merge-blocked" target detail))
      (log! "merge-blocked-failed" target (failure-text result)))))

(defn spawn! [{:keys [target]}]
  (let [request-file (fs/path squad-dir "spawn-requests" (str target ".edn"))
        template (when (fs/exists? request-file)
                   (:template (edn/read-string (slurp (str request-file)))))]
    (if (str/blank? (str template))
      (log! "spawn-skipped" target "spawn-request record missing or has no template")
      (let [{:keys [exit] :as result}
            (apply sh swarm-bin "squad" "spawn" target template no-agent-args)]
        (if (zero? exit)
          (do (bb-script "squad_spawn_request.bb" "drop" target)
              (event! target "squadd-spawn" (str "template=" template))
              (log! "spawned" target template))
          ;; Leave the request in place: the next poll retries the spawn.
          (log! "spawn-failed" target (failure-text result)))))))

(defn- main-branch
  "The only branch the daemon merges into — the daemon is the sole owner
  of the project's main branch (squad-s3.md). 'main' unless a
  'main_branch <name>' line in swarmforge/squad.conf says otherwise."
  []
  (let [conf (fs/path project-root "swarmforge" "squad.conf")]
    (or (when (fs/exists? conf)
          (some #(second (re-matches #"\s*main_branch\s+(\S+)\s*" %))
                (str/split-lines (slurp (str conf)))))
        "main")))

(defn- checked-out-branch []
  (let [{:keys [exit out]} (sh "git" "symbolic-ref" "--short" "-q" "HEAD")]
    (when (zero? exit) (str/trim (str out)))))

(defn merge! [{:keys [target]}]
  (let [result-file (fs/path squad-dir "assignments" target "result.handoff")
        commit (when (fs/exists? result-file)
                 (handoff-lib/header-field result-file "commit"))
        branch (checked-out-branch)]
    (cond
      ;; A wrong checkout is an operator-side anomaly, not a conflict:
      ;; skip and retry next poll rather than mark blocked (reviewer
      ;; finding, squadd: merging into whatever was checked out silently
      ;; stranded the commit off main).
      (not= branch (main-branch))
      (log! "merge-skipped" target
            (str "HEAD is " (or branch "detached") ", not " (main-branch)
                 "; retrying next poll"))

      ;; The commit header is stored data, not the validated swarm_handoff
      ;; path — gate its shape before it becomes git argv.
      (not (and commit (re-matches #"[0-9a-fA-F]{7,40}" commit)))
      (mark-blocked! target (if commit
                              (str "invalid commit header: " (summarize commit))
                              "result.handoff missing or has no commit header"))

      :else
      (let [{:keys [exit] :as result} (sh "git" "merge" "--no-edit" commit)]
        (if (zero? exit)
          (do (bb-script "squad_assign.bb" "merge" target)
              (event! target "squadd-merge" (str "commit=" commit))
              (log! "merged" target commit))
          (do (sh "git" "merge" "--abort")
              (mark-blocked! target (summarize (failure-text result)))))))))

(defn drop-stale! [{:keys [target reason]}]
  (let [{:keys [exit] :as result} (bb-script "squad_spawn_request.bb" "drop" target)]
    (if (zero? exit)
      (do (event! target "squadd-drop-stale-spawn-request" reason)
          (log! "dropped-stale" target reason))
      (log! "drop-failed" target (failure-text result)))))

(defn retire! [{:keys [target reason]}]
  (let [{:keys [exit] :as result}
        (apply sh swarm-bin "squad" "retire" target "daemon" no-agent-args)]
    (if (zero? exit)
      (do (event! target "squadd-retire-worker" reason)
          (log! "retired" target))
      (log! "retire-failed" target (failure-text result)))))

(defn apply-block! [{:keys [action] :as block}]
  (case action
    "spawn" (spawn! block)
    "merge" (merge! block)
    "drop-stale-spawn-request" (drop-stale! block)
    "retire-worker" (retire! block)
    "wait-capacity" nil ; informational: the advisor reports, the daemon waits
    (log! "unknown-action" (str action) (str (:target block)))))

;; --- leader wake-ups --------------------------------------------------------

(defn leader-agent-name []
  (let [roles-file (fs/path project-root ".swarmforge" "roles.tsv")]
    (when (fs/exists? roles-file)
      (some (fn [line]
              (let [[role _wt-name _wt-path agent-name] (str/split line #"\t" -1)]
                (when (= "squad-leader" role) agent-name)))
            (remove str/blank? (str/split-lines (slurp (str roles-file))))))))

(defn wake-leader! []
  (let [cmd (or (System/getenv "SWARMFORGE_WAKE_CMD") "herdr")]
    (when-not (= "none" cmd)
      (if-let [agent (leader-agent-name)]
        (let [{:keys [exit err]} (process/sh {:continue true}
                                             cmd "agent" "prompt" agent wake-message)]
          (if (zero? exit)
            (log! "waked" agent)
            (log! "wake-failed" agent (str/trim (or err "")))))
        (log! "wake-skipped" "no squad-leader row in roles.tsv")))))

(defn check-residuals!
  "Wake the leader only on residual [target action] pairs the previous
  poll did not have; a pair that disappears and returns wakes again on
  return."
  []
  (let [pairs (set (map (juxt :target :action) (advisor-blocks "--residual-only")))
        fresh (sort (map (fn [[target action]] (str target ":" action))
                         (remove @known-residuals pairs)))]
    (reset! known-residuals pairs)
    (when (seq fresh)
      (log! "residual-new" (str/join " " fresh))
      (wake-leader!))))

;; --- user notification (S4): one buzz per newly-pending approval ----------

(def notified-file (fs/path daemon-dir "notified-approvals.edn"))

(defn notify-pending-approvals!
  "Fire `herdr notification show` exactly once per pending approval —
  the human's buzz, distinct from leader wakes. Durable dedup so daemon
  restarts don't re-buzz."
  []
  (let [approvals-dir (fs/path project-root ".swarmforge" "squad" "approvals")
        notified (if (fs/exists? notified-file)
                   (edn/read-string (slurp (str notified-file)))
                   #{})
        pending (when (fs/exists? approvals-dir)
                  (for [f (fs/list-dir approvals-dir)
                        :when (str/ends-with? (fs/file-name f) ".edn")
                        :let [record (edn/read-string (slurp (str f)))]
                        :when (and (= :pending (:state record))
                                   (not (contains? notified (:id record))))]
                    record))]
    (doseq [{:keys [id title reason]} pending]
      (let [cmd (or (System/getenv "SWARMFORGE_WAKE_CMD") "herdr")]
        (if (= "none" cmd)
          (log! "user-notify-skipped" id)
          (let [{:keys [exit err]} (process/sh {:continue true}
                                               cmd "notification" "show"
                                               (str "Approval needed: " title)
                                               "--body" (str reason "  ->  swarm squad approve " id))]
            (if (zero? exit)
              (log! "user-notified" id)
              (log! "user-notify-failed" id (str/trim (or err "")))))))
      (spit (str notified-file)
            (pr-str (conj (if (fs/exists? notified-file)
                            (edn/read-string (slurp (str notified-file)))
                            #{})
                          id))))))

;; --- poll loop --------------------------------------------------------------

(defn should-stop? []
  (or @stopping (fs/exists? stop-file)))

(defn poll-once! []
  (doseq [block (advisor-blocks "--mechanical-only")
          :while (not (should-stop?))]
    (try
      (apply-block! block)
      (catch Exception e
        (log! "error" (str (:action block)) (str (:target block)) (ex-message e)))))
  (notify-pending-approvals!)
  (check-residuals!))

(defn sleep-poll! [ms]
  (loop [remaining ms]
    (when (and (pos? remaining) (not (should-stop?)))
      (Thread/sleep (min remaining 100))
      (recur (- remaining 100)))))

(defn -main []
  (if (args-set "--once")
    (poll-once!)
    (do
      (fs/create-dirs daemon-dir)
      (fs/delete-if-exists stop-file)
      (spit (str pid-file) (str (.pid (java.lang.ProcessHandle/current)) "\n"))
      (.addShutdownHook (Runtime/getRuntime)
                        (Thread. (fn [] (reset! stopping true))))
      (log! "started")
      (try
        (while (not (should-stop?))
          (poll-once!)
          (sleep-poll! poll-ms))
        (finally
          (fs/delete-if-exists pid-file)
          (log! "stopped"))))))

(-main)
