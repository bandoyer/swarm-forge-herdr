#!/usr/bin/env bb
;; squad_worker.bb — transient-worker bookkeeping for squad v2 (S2).
;;
;; File state only: .swarmforge/squad/workers/<name>.edn, no herdr calls —
;; the spawn driver consumes these records to create and close real agents.
;; Lifecycle: allocated -> active -> retired (retire is also allowed
;; straight from allocated, for workers that never spawn). Capacity:
;; allocated+active workers are capped by max_transient_agents in
;; swarmforge/squad.conf (default 10). Allocate is the single kind
;; resolution point: explicit [kind], then worker_kind, then claude.
;; Illegal transitions exit 2 with an INVALID_TRANSITION token; unknown
;; workers report NO_SUCH_WORKER.

(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "squad_lib.bb")))

(ns squad-worker
  (:require [babashka.fs :as fs]
            [clojure.string :as str]))

(def usage-text
  (str "Usage: squad_worker.sh <subcommand> ...\n\n"
       "  allocate <assignment-id> <template> [kind]\n"
       "  activate <worker-name>\n"
       "  retire <worker-name> [reason...]\n"
       "  list [--active]"))

;; --- worker records -------------------------------------------------------

(defn worker-file
  "Resolve a worker record path. Names are validated against herdr's
  agent-name shape before touching the filesystem, so a hostile name can
  never escape the workers directory (reviewer finding, worker-registry)."
  [worker-name]
  (when-not (re-matches #"[a-z][a-z0-9_-]{0,31}" (str worker-name))
    (handoff-lib/die 2 (str "INVALID_WORKER_NAME: '" worker-name
                            "' (expected lowercase name, max 32 chars)")))
  (fs/path (squad-lib/workers-dir) (str worker-name ".edn")))

;; --- naming ---------------------------------------------------------------

(defn worker-name
  "Deterministic herdr agent name for a worker; the launcher reuses this
  when it spawns the real agent, so keep the two in lockstep. Built as
  '<project>-<template>-<assignment-id>', lowercased, every char outside
  [a-z0-9_-] replaced with '-', trimmed from the LEFT to 32 chars so the
  distinctive assignment tail survives, then prefixed with 'w' (dropping
  one more leading char if already at 32) when it would not start with a
  letter."
  [project-name template assignment-id]
  (let [sanitized (-> (str project-name "-" template "-" assignment-id)
                      str/lower-case
                      (str/replace #"[^a-z0-9_-]" "-"))
        trimmed (if (> (count sanitized) 32)
                  (subs sanitized (- (count sanitized) 32))
                  sanitized)]
    (if (re-find #"^[a-z]" trimmed)
      trimmed
      (str "w" (subs trimmed (if (= 32 (count trimmed)) 1 0))))))

;; --- transitions ----------------------------------------------------------

(def allowed-transitions
  {:active  #{:allocated}
   :retired #{:allocated :active}})

(defn- transition! [worker-name new-state opts]
  (squad-lib/transition! (merge {:file (worker-file worker-name)
                                 :missing-token "NO_SUCH_WORKER"
                                 :announce-token "WORKER_STATE"
                                 :label "worker"
                                 :id worker-name
                                 :allowed (get allowed-transitions new-state #{})
                                 :new-state new-state}
                                opts)))

;; --- subcommands ----------------------------------------------------------

(defn allocate! [assignment-id template explicit-kind]
  (squad-lib/require-valid-agent-kind! explicit-kind)
  ;; Resolve once at allocation: explicit arg, then worker_kind, then claude.
  (let [agent-kind (or explicit-kind (squad-lib/configured-worker-kind))
        project-name (fs/file-name (handoff-lib/project-root))
        worker (worker-name project-name template assignment-id)
        file (worker-file worker)
        cap (squad-lib/max-transient-agents)]
    (when (fs/exists? file)
      (handoff-lib/die 2 (str "WORKER_EXISTS: " worker)))
    (when (>= (squad-lib/active-count) cap)
      (handoff-lib/die 2 (format "CAPACITY_EXHAUSTED: %d active workers, max_transient_agents %d"
                                 (squad-lib/active-count) cap)))
    (fs/create-dirs (squad-lib/workers-dir))
    (squad-lib/write-record! file {:name worker
                                   :template template
                                   :assignment assignment-id
                                   :agent-kind agent-kind
                                   :state :allocated
                                   :created-at (handoff-lib/iso-now)})
    (squad-lib/log-event! worker "allocated"
                          (str "template=" template " assignment=" assignment-id
                               " kind=" agent-kind))
    (println (str "WORKER_ALLOCATED: " worker))))

(defn activate! [worker-name]
  (transition! worker-name :active {}))

(defn retire! [worker-name reason]
  (transition! worker-name :retired
               (if (str/blank? reason)
                 {}
                 {:extra {:reason reason} :detail (str "reason=" reason)})))

(defn list! [active-only?]
  (let [workers (squad-lib/all-workers)
        active (filter #(squad-lib/active-states (:state %)) workers)
        shown (if active-only? active workers)]
    (doseq [{worker :name :keys [state template assignment]} shown]
      (println worker (name state) template assignment))
    (println (str "ACTIVE: " (count active) "/" (squad-lib/max-transient-agents)))))

;; --- entry ----------------------------------------------------------------

(defn- usage-die []
  (handoff-lib/die 1 usage-text))

(defn -main [args]
  (let [[command & params] args
        params (vec params)]
    (case command
      "allocate" (if (<= 2 (count params) 3)
                   (allocate! (nth params 0) (nth params 1) (nth params 2 nil))
                   (usage-die))
      "activate" (if (= 1 (count params)) (activate! (first params)) (usage-die))
      "retire" (if (<= 1 (count params))
                 (retire! (first params) (str/join " " (rest params)))
                 (usage-die))
      "list" (cond
               (= [] params) (list! false)
               (= ["--active"] params) (list! true)
               :else (usage-die))
      (usage-die))))

(handoff-lib/run-entry #(-main *command-line-args*))
