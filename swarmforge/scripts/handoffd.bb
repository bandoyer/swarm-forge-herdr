#!/usr/bin/env bb
;; handoffd.bb — the handoff router daemon, herdr edition.
;;
;; Polls every role's outbox, delivers finished handoffs into recipient
;; inboxes (adding recipient/enqueued_at headers), wakes recipients through
;; `herdr agent prompt`, and archives originals to sent/ (failed/ on error).
;;
;; Differences from upstream's tmux daemon, on purpose:
;;   - Wake-ups go through herdr's socket API instead of tmux send-keys.
;;   - A failed wake-up is logged but does not fail the delivery: wake-ups
;;     are lossy by design (agents also poll on task completion), so an
;;     undeliverable notification must not send a valid handoff to failed/.
;;
;; Usage: handoffd.bb <project-root> [--once]
;;   --once  run a single poll pass and exit (for tests)
;; Env: SWARMFORGE_WAKE_CMD  override the wake command (default: herdr);
;;                           set to "none" to disable wake-ups entirely.

(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "handoff_lib.bb")))

(ns handoffd
  (:require [babashka.fs :as fs]
            [babashka.process :as process]
            [clojure.string :as str]))

(def poll-ms 1000)
(def wake-message "You have new handoff mail. If idle, run ready_for_next.sh.")

(def args-set (set *command-line-args*))
(def project-root
  (or (first (remove #(str/starts-with? % "--") *command-line-args*))
      (do (binding [*out* *err*]
            (println "Usage: handoffd.bb <project-root> [--once]"))
          (System/exit 1))))

(def daemon-dir (fs/path project-root ".swarmforge" "daemon"))
(def roles-file (fs/path project-root ".swarmforge" "roles.tsv"))
(def pid-file (fs/path daemon-dir "handoffd.pid"))
(def stop-file (fs/path daemon-dir "stop"))
(def log-file (fs/path daemon-dir "handoffd.log"))
(def stopping (atom false))

(defn log! [& parts]
  (fs/create-dirs daemon-dir)
  (spit (str log-file)
        (str (handoff-lib/iso-now) " " (str/join " " parts) "\n")
        :append true))

(defn load-roles []
  (into {}
        (for [line (str/split-lines (slurp (str roles-file)))
              :when (not (str/blank? line))
              :let [[role _wt-name wt-path agent-name] (str/split line #"\t" -1)]]
          [role {:worktree-path wt-path :agent-name agent-name}])))

;; --- wake-ups -------------------------------------------------------------

(defn wake! [agent-name]
  (let [cmd (or (System/getenv "SWARMFORGE_WAKE_CMD") "herdr")]
    (when-not (= "none" cmd)
      (let [{:keys [exit err]} (try (process/sh {:continue true}
                                                cmd "agent" "prompt" agent-name wake-message)
                                    (catch Exception e {:exit 1 :err (ex-message e)}))]
        (if (zero? exit)
          (log! "waked" agent-name)
          (log! "wake-failed" agent-name (str/trim (or err ""))))))))

;; --- delivery -------------------------------------------------------------

(defn archive! [path target-dir]
  (fs/create-dirs target-dir)
  (let [target (fs/path target-dir (fs/file-name path))]
    (if (fs/exists? target)
      (fs/move path (fs/path target-dir (str (handoff-lib/iso-now) "_" (fs/file-name path))))
      (fs/move path target))))

(defn fail! [path reason]
  (log! "failed" (str path) reason)
  (spit (str path ".error") (str reason "\n"))
  (archive! path (fs/path (fs/parent (fs/parent path)) "failed")))

(defn commit-tree [worktree-path commit]
  (let [{:keys [exit out err]}
        (process/sh {:continue true}
                    "git" "-C" worktree-path "rev-parse"
                    (str commit "^{tree}"))]
    (when-not (zero? exit)
      (throw (ex-info (str "cannot resolve Git tree for " commit ": "
                           (str/trim (str out "\n" err))) {})))
    (str/trim out)))

(defn deliver! [roles sender-role path]
  (let [{:keys [headers body]} (handoff-lib/parse-handoff path)
        recipients (some-> (get headers "to") (str/split #",") seq)
        recipient-info (when recipients
                         (into {}
                               (for [recipient recipients]
                                 [recipient
                                  (or (get roles recipient)
                                      (throw (ex-info
                                              (str "unknown recipient " recipient)
                                              {})))])))
        git-handoff? (= "git_handoff" (get headers "type"))
        task (get headers "task")
        tree (when git-handoff?
               (commit-tree (get-in roles [sender-role :worktree-path])
                            (get headers "commit")))
        guard-reason (when git-handoff?
                       (handoff-lib/handoff-guard-block-reason
                        project-root task sender-role recipients tree))]
    (if-not recipients
      (fail! path "missing to header")
      (if guard-reason
        (let [reason (str "HANDOFF_CIRCUIT_OPEN: " guard-reason)]
          (handoff-lib/open-handoff-circuit! project-root task guard-reason)
          (log! "circuit-open" (str "task=" task) reason)
          (fail! path reason))
        (do
          (doseq [recipient recipients]
            (let [info (get recipient-info recipient)
                  target (fs/path (:worktree-path info)
                                  ".swarmforge" "handoffs" "inbox" "new" (fs/file-name path))]
              (fs/create-dirs (fs/parent target))
              ;; Retry-safe: an already-delivered copy is left untouched.
              (when-not (fs/exists? target)
                (spit (str target)
                      (str (handoff-lib/render-handoff
                            {:headers (assoc headers
                                             "recipient" recipient
                                             "enqueued_at" (handoff-lib/iso-now))
                             :body body})
                           "\n")))
              (wake! (:agent-name info))))
          (archive! path (fs/path (get-in roles [sender-role :worktree-path])
                                  ".swarmforge" "handoffs" "sent"))
          (when git-handoff?
            (handoff-lib/record-handoff-delivery!
             project-root task sender-role recipients tree))
          (log! "delivered" (str path)))))))

;; --- poll loop ------------------------------------------------------------

(defn should-stop? []
  (or @stopping (fs/exists? stop-file)))

(defn outbox-files [info]
  (handoff-lib/handoff-files
   (fs/path (:worktree-path info) ".swarmforge" "handoffs" "outbox")))

(defn poll-once! []
  (let [roles (load-roles)]
    (doseq [[role info] roles
            path (outbox-files info)
            :while (not (should-stop?))]
      (try
        (deliver! roles role path)
        (catch Exception e
          (log! "error" (str path) (ex-message e))
          (try
            (fail! path (ex-message e))
            (catch Exception nested
              (log! "failed-to-archive" (str path) (ex-message nested)))))))))

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
