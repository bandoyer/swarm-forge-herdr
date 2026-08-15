;; handoff_lib.bb — shared library for the SwarmForge handoff protocol.
;;
;; Original implementation of the protocol documented in upstream
;; swarm-forge's handoff-protocol.md. File formats, output tokens, and exit
;; codes are protocol-compatible with upstream so that upstream role prompts
;; work unmodified. Loaded via load-file from the entry scripts; defines no
;; side effects at load time.

(ns handoff-lib
  (:require [babashka.fs :as fs]
            [babashka.process :as process]
            [clojure.edn :as edn]
            [clojure.string :as str]))

;; ---------------------------------------------------------------------------
;; Errors and exit discipline
;;
;; Entry scripts catch ExceptionInfo and exit with (:exit data). Exit 1 is
;; "cannot run here" (missing env, no current work); exit 2 is a protocol
;; violation or ambiguous queue state that needs outside repair.

(defn die [exit-code & message-lines]
  (throw (ex-info (str/join "\n" message-lines) {:exit exit-code})))

(defn run-entry
  "Run thunk with the protocol's error/exit conventions."
  [thunk]
  (try
    (thunk)
    (catch clojure.lang.ExceptionInfo e
      (binding [*out* *err*]
        (println (ex-message e)))
      (System/exit (:exit (ex-data e) 1)))))

;; ---------------------------------------------------------------------------
;; Environment: role, worktree state dir, project root

(defn current-role []
  (or (not-empty (System/getenv "SWARMFORGE_ROLE"))
      (die 1 "Set SWARMFORGE_ROLE.")))

(defn state-dir
  "Per-worktree handoff state. Agents always run inside their own worktree."
  []
  (fs/path (fs/cwd) ".swarmforge" "handoffs"))

(defn inbox-dir [] (fs/path (state-dir) "inbox"))

(defn- git-line [& args]
  (let [{:keys [exit out]} (apply process/sh {:continue true} args)]
    (when (zero? exit)
      (not-empty (str/trim out)))))

(defn project-root
  "The directory holding .swarmforge/roles.tsv: the current directory, the
  git toplevel, or — from inside a linked worktree — the parent of the git
  common dir."
  []
  (let [marker #(fs/exists? (fs/path % ".swarmforge" "roles.tsv"))
        candidates [(fs/cwd)
                    (some-> (git-line "git" "rev-parse" "--show-toplevel") fs/path)
                    (some-> (git-line "git" "rev-parse" "--git-common-dir")
                            fs/path fs/absolutize fs/parent)]]
    (or (some #(when (and % (marker %)) %) candidates)
        (die 1 "Cannot find SwarmForge project root"))))

;; ---------------------------------------------------------------------------
;; roles.tsv — written by the launcher, read by everything else.
;; Columns: role, worktree-name, worktree-path, agent-name (herdr),
;; display, agent-kind, receive-mode.

(defn roles []
  (for [line (str/split-lines (slurp (str (fs/path (project-root) ".swarmforge" "roles.tsv"))))
        :when (not (str/blank? line))
        :let [[role wt-name wt-path agent-name display kind mode]
              (str/split line #"\t" -1)]]
    {:role role
     :worktree-name wt-name
     :worktree-path wt-path
     :agent-name agent-name
     :display display
     :agent-kind kind
     :receive-mode (if (str/blank? mode) "task" mode)}))

(defn role-entry [role-name]
  (or (some #(when (= role-name (:role %)) %) (roles))
      (die 1 (str "Unknown role: " role-name))))

(defn role-known? [role-name]
  (boolean (some #(= role-name (:role %)) (roles))))

(defn assert-role-worktree!
  "Queue commands must run inside the role's registered worktree; a stale
  worktree from a previous pack silently strands handoffs otherwise."
  []
  (let [entry (role-entry (current-role))
        here (str (fs/canonicalize (fs/cwd)))
        registered (str (fs/canonicalize (:worktree-path entry)))]
    (when-not (= here registered)
      (die 2 (str "WRONG_WORKTREE: role '" (:role entry) "' is registered at")
           (str "  " registered)
           (str "but this command ran in")
           (str "  " here)
           "cd to the registered worktree and retry."))))

;; ---------------------------------------------------------------------------
;; Role contracts (squad v2, S1) — optional per-role law: which paths a
;; role may author and what evidence its commits must carry. Absent
;; contract = no enforcement, so adoption is progressive.

(defn role-contract
  "Contract for a role. Transient squad workers have generated names, so
  when no contract file matches the name directly, fall back to the
  worker's template contract — contracts bind the workforce too."
  [role-name]
  (let [contract-file #(fs/path (project-root) "swarmforge" "contracts"
                                (str % ".contract.edn"))
        direct (contract-file role-name)]
    (cond
      (fs/exists? direct)
      (edn/read-string (slurp (str direct)))

      :else
      (let [worker-record (fs/path (project-root) ".swarmforge" "squad"
                                   "workers" (str role-name ".edn"))]
        (when (fs/exists? worker-record)
          (let [template (:template (edn/read-string (slurp (str worker-record))))
                fallback (contract-file template)]
            (when (and template (fs/exists? fallback))
              (edn/read-string (slurp (str fallback))))))))))

(defn- git-lines [& args]
  (let [{:keys [exit out]} (apply process/sh {:continue true} args)]
    (when (zero? exit)
      (vec (remove str/blank? (str/split-lines out))))))

(defn contract-violations
  "Errors for a git_handoff commit under the sender's contract, or [] —
  checks authored paths against :artifact-roots and the commit message
  against :required-evidence patterns. Merge commits (>1 parent) are
  integration, not authorship, and are skipped."
  [role-name commit]
  (if-let [{:keys [artifact-roots required-evidence]} (role-contract role-name)]
    (let [parents (git-lines "git" "rev-list" "--parents" "-n" "1" commit)
          merge? (> (count (str/split (or (first parents) "") #" ")) 2)
          paths (when-not merge?
                  (git-lines "git" "diff-tree" "--no-commit-id" "--name-only" "-r" commit))
          message (str/join "\n" (or (git-lines "git" "log" "-1" "--format=%B" commit) []))
          allowed? (fn [path] (some #(or (= path %) (str/starts-with? path %)) artifact-roots))
          path-errors (for [path paths :when (not (allowed? path))]
                        (format "Contract: '%s' is outside role %s's artifact roots (%s)."
                                path role-name (str/join ", " artifact-roots)))
          evidence-errors (for [{:keys [name pattern]} required-evidence
                                :when (not (re-find (re-pattern pattern) message))]
                            (format "Contract: required evidence '%s' not found in the commit message (expected to match: %s). Run the tool and record the real result in the commit message."
                                    name pattern))]
      (vec (concat path-errors evidence-errors)))
    []))

;; ---------------------------------------------------------------------------
;; Timestamps

(defn iso-now []
  (.format java.time.format.DateTimeFormatter/ISO_INSTANT (java.time.Instant/now)))

(defn compact-now
  "UTC timestamp for ids and filenames: YYYYMMDDTHHMMSSZ."
  []
  (.format (java.time.format.DateTimeFormatter/ofPattern "yyyyMMdd'T'HHmmss'Z'")
           (.atZone (java.time.Instant/now) java.time.ZoneOffset/UTC)))

;; ---------------------------------------------------------------------------
;; Handoff files: "header: value" lines, a blank line, an opaque body.

(defn parse-handoff [file]
  (let [text (slurp (str file))
        [header-block body] (str/split text #"\n\n" 2)
        headers (into {}
                      (keep (fn [line]
                              (let [[k v] (str/split line #": " 2)]
                                (when (and k v) [k v])))
                            (str/split-lines header-block)))]
    {:headers headers :body (or body "")}))

(defn header-field
  ([file field] (header-field file field nil))
  ([file field default]
   (get (:headers (parse-handoff file)) field default)))

(def header-order
  ["id" "from" "to" "recipient" "priority" "type" "role" "commit" "message"
   "created_at" "enqueued_at" "dequeued_at" "completed_at"])

(defn render-handoff [{:keys [headers body]}]
  (let [extras (sort (remove (set header-order) (keys headers)))]
    (str (str/join "\n" (for [k (concat header-order extras)
                              :let [v (get headers k)]
                              :when v]
                          (str k ": " v)))
         "\n\n" body)))

(defn- atomic-write! [file content]
  (let [tmp (fs/create-temp-file {:dir (fs/parent file) :prefix ".handoff."})]
    (spit (str tmp) content)
    (fs/move tmp file {:replace-existing true})))

(defn set-header!
  "Set one header in place, preserving the original header text order (new
  headers append to the end of the header block)."
  [file field value]
  (let [text (slurp (str file))
        [header-block body] (str/split text #"\n\n" 2)
        prefix (str field ": ")
        lines (str/split-lines header-block)
        replaced (mapv #(if (str/starts-with? % prefix) (str prefix value) %) lines)
        lines (if (= lines replaced) (conj lines (str prefix value)) replaced)]
    (atomic-write! file (str (str/join "\n" lines) "\n\n" (or body "")))))

;; ---------------------------------------------------------------------------
;; Queue directories

(defn handoff-files [dir]
  (if (fs/exists? dir)
    (->> (fs/list-dir dir)
         (filter #(and (fs/regular-file? %) (str/ends-with? (fs/file-name %) ".handoff")))
         (sort-by fs/file-name)
         vec)
    []))

(defn batch-dirs [dir]
  (if (fs/exists? dir)
    (->> (fs/list-dir dir)
         (filter #(and (fs/directory? %) (str/starts-with? (fs/file-name %) "batch_")))
         (sort-by fs/file-name)
         vec)
    []))

(defn ensure-queue-dirs! [root-dir]
  (doseq [sub [["outbox" "tmp"] ["sent"] ["failed"]
               ["inbox" "new"] ["inbox" "in_process"] ["inbox" "completed"]]]
    (fs/create-dirs (apply fs/path root-dir sub))))

;; ---------------------------------------------------------------------------
;; Agent-facing output contract

(defn print-task [file]
  (let [{:keys [headers body]} (parse-handoff file)]
    (println "TASK:" (str file))
    (println "FROM:" (get headers "from" "unknown"))
    (println "TYPE:" (get headers "type" "unknown"))
    (println "PRIORITY:" (get headers "priority" "50"))
    (when-let [task-name (get headers "task")]
      (println "TASK_NAME:" task-name))
    (println "PAYLOAD:")
    (print body)
    (flush)))

(defn print-batch [batch-dir]
  (let [files (handoff-files batch-dir)]
    (when (empty? files)
      (die 2 (str "AMBIGUOUS_TASK_STATE: batch contains no tasks: " batch-dir)))
    (println "BATCH:" (str batch-dir))
    (println "COUNT:" (count files))
    (println "PRIORITY:" (header-field (first files) "priority" "50"))
    (doseq [[index file] (map-indexed vector files)]
      (println)
      (println "BATCH_ITEM:" (inc index))
      (print-task file))))

(defn- bullet-list [paths]
  (str/join "\n" (map #(str "- " %) paths)))

;; ---------------------------------------------------------------------------
;; Sequence counter, serialized per worktree with a lock directory

(defn next-sequence []
  (let [dir (state-dir)
        seq-file (fs/path dir "sequence")
        lock-dir (fs/path dir "sequence.lock")]
    (fs/create-dirs dir)
    (loop []
      (when-not (try (fs/create-dir lock-dir) true
                     (catch java.nio.file.FileAlreadyExistsException _ false))
        (Thread/sleep 50)
        (recur)))
    (try
      (let [current (or (when (fs/exists? seq-file)
                          (parse-long (str/trim (slurp (str seq-file)))))
                        0)
            value (format "%06d" (inc current))]
        (spit (str seq-file) (str value "\n"))
        value)
      (finally
        (fs/delete-tree lock-dir)))))

;; ---------------------------------------------------------------------------
;; Queue transitions — task mode

(defn ready-task!
  "Accept or resume the current task. Prints TASK/NO_TASK."
  []
  (assert-role-worktree!)
  (let [inbox (inbox-dir)
        new-dir (fs/path inbox "new")
        in-process (fs/path inbox "in_process")]
    (ensure-queue-dirs! (state-dir))
    (let [batches (batch-dirs in-process)
          current (handoff-files in-process)]
      (when (seq batches)
        (die 2 "TASK_IN_PROCESS_IS_BATCH: use ready_for_next.sh or done_with_current.sh."
             (bullet-list batches)))
      (when (> (count current) 1)
        (die 2 "AMBIGUOUS_TASK_STATE: multiple tasks are already in process."
             (bullet-list current)))
      (cond
        (= 1 (count current))
        (print-task (first current))

        :else
        (if-let [source (first (handoff-files new-dir))]
          (let [target (fs/path in-process (fs/file-name source))]
            (when (fs/exists? target)
              (die 2 (str "AMBIGUOUS_TASK_STATE: target in-process file already exists: " target)))
            (fs/move source target)
            (set-header! target "dequeued_at" (iso-now))
            (print-task target))
          (println "NO_TASK"))))))

(defn done-task!
  "Complete the current task, then chain into ready-task!."
  []
  (assert-role-worktree!)
  (let [inbox (inbox-dir)
        in-process (fs/path inbox "in_process")
        completed (fs/path inbox "completed")]
    (ensure-queue-dirs! (state-dir))
    (let [batches (batch-dirs in-process)
          current (handoff-files in-process)]
      (when (seq batches)
        (die 2 "CURRENT_WORK_IS_BATCH: use done_with_current.sh."
             (bullet-list batches)))
      (when (empty? current)
        (die 1 "NO_CURRENT_TASK"))
      (when (> (count current) 1)
        (die 2 "AMBIGUOUS_TASK_STATE: multiple tasks are in process."
             (bullet-list current)))
      (let [source (first current)
            target (fs/path completed (fs/file-name source))]
        (set-header! source "completed_at" (iso-now))
        (when (fs/exists? target)
          (die 2 (str "AMBIGUOUS_TASK_STATE: completed file already exists: " target)))
        (fs/move source target)
        (println "COMPLETED:" (str target))
        (ready-task!)))))

;; ---------------------------------------------------------------------------
;; Queue transitions — batch mode

(defn- new-batch-dir [in-process]
  (loop [suffix 1]
    (let [dir (fs/path in-process (format "batch_%s_%06d" (compact-now) suffix))]
      (if (fs/exists? dir) (recur (inc suffix)) dir))))

(defn ready-batch!
  "Accept or resume the current batch: every queued handoff sharing the
  first file's priority. Prints BATCH/NO_TASK."
  []
  (assert-role-worktree!)
  (let [inbox (inbox-dir)
        new-dir (fs/path inbox "new")
        in-process (fs/path inbox "in_process")]
    (ensure-queue-dirs! (state-dir))
    (let [batches (batch-dirs in-process)
          singles (handoff-files in-process)]
      (when (seq singles)
        (die 2 "TASK_IN_PROCESS_IS_SINGLE: use ready_for_next.sh or done_with_current.sh."
             (bullet-list singles)))
      (when (> (count batches) 1)
        (die 2 "AMBIGUOUS_TASK_STATE: multiple batches are already in process."
             (bullet-list batches)))
      (cond
        (= 1 (count batches))
        (print-batch (first batches))

        :else
        (let [queued (handoff-files new-dir)]
          (if (empty? queued)
            (println "NO_TASK")
            (let [priority (header-field (first queued) "priority" "50")
                  selected (filter #(= priority (header-field % "priority" "50")) queued)
                  batch-dir (new-batch-dir in-process)]
              (fs/create-dir batch-dir)
              (doseq [source selected
                      :let [target (fs/path batch-dir (fs/file-name source))]]
                (fs/move source target)
                (set-header! target "dequeued_at" (iso-now)))
              (print-batch batch-dir))))))))

(defn done-batch!
  "Complete the current batch, then chain into ready-batch!."
  []
  (assert-role-worktree!)
  (let [inbox (inbox-dir)
        in-process (fs/path inbox "in_process")
        completed (fs/path inbox "completed")]
    (ensure-queue-dirs! (state-dir))
    (let [batches (batch-dirs in-process)
          singles (handoff-files in-process)]
      (when (seq singles)
        (die 2 "CURRENT_WORK_IS_SINGLE: use done_with_current.sh."
             (bullet-list singles)))
      (when (empty? batches)
        (die 1 "NO_CURRENT_BATCH"))
      (when (> (count batches) 1)
        (die 2 "AMBIGUOUS_TASK_STATE: multiple batches are in process."
             (bullet-list batches)))
      (let [source-dir (first batches)
            files (handoff-files source-dir)
            target-dir (fs/path completed (fs/file-name source-dir))]
        (when (empty? files)
          (die 2 (str "AMBIGUOUS_TASK_STATE: batch contains no tasks: " source-dir)))
        (when (fs/exists? target-dir)
          (die 2 (str "AMBIGUOUS_TASK_STATE: completed batch already exists: " target-dir)))
        (fs/create-dirs target-dir)
        (doseq [source files
                :let [target (fs/path target-dir (fs/file-name source))]]
          (when (fs/exists? target)
            (die 2 (str "AMBIGUOUS_TASK_STATE: completed batch file already exists: " target)))
          (set-header! source "completed_at" (iso-now))
          (fs/move source target)
          (println "COMPLETED:" (str target)))
        (fs/delete source-dir)
        (println "COMPLETED_BATCH:" (str target-dir))
        (ready-batch!)))))

;; ---------------------------------------------------------------------------
;; Receive-mode dispatch

(defn receive-mode []
  (:receive-mode (role-entry (current-role))))

(defn dispatch-by-mode! [task-fn batch-fn]
  (let [mode (receive-mode)]
    (case mode
      "task" (task-fn)
      "batch" (batch-fn)
      (die 2 (str "INVALID_RECEIVE_MODE: " mode " for role " (current-role))))))
