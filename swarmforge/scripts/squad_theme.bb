#!/usr/bin/env bb
;; squad_theme.bb — lightweight work themes (docs/squad-s4.md, S4 slice A).
;;
;; A theme groups related assignments for reporting:
;; .swarmforge/squad/themes/<theme-id>/theme.md is the human-written theme
;; description and status.edn records which assignments belong to it.
;; Themes carry no lifecycle of their own — `status` derives one by reading
;; each attached assignment's current state.

(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "squad_lib.bb")))

(ns squad-theme
  (:require [babashka.fs :as fs]
            [clojure.edn :as edn]))

(def usage-text
  (str "Usage: squad_theme.sh <subcommand> ...\n\n"
       "  create <theme-id> <theme-file>\n"
       "  attach <theme-id> <assignment-id>\n"
       "  status <theme-id>"))

(defn theme-dir
  "Resolve a theme directory. Ids are validated against the assignment-id
  shape before touching the filesystem, so a hostile id can never escape
  the themes directory."
  [theme-id]
  (when-not (re-matches #"[A-Za-z0-9][A-Za-z0-9_-]*" (str theme-id))
    (handoff-lib/die 2 (str "INVALID_THEME_ID: " theme-id)))
  (fs/path (squad-lib/themes-dir) (str theme-id)))

(defn- theme-status-file [theme-id]
  (fs/path (theme-dir theme-id) "status.edn"))

;; --- subcommands ----------------------------------------------------------

(defn create! [theme-id theme-file]
  (let [dir (theme-dir theme-id)]
    (when (fs/exists? dir)
      (handoff-lib/die 2 (str "THEME_EXISTS: " theme-id)))
    (when-not (fs/regular-file? theme-file)
      (handoff-lib/die 1 (str "Theme file not found: " theme-file)))
    (fs/create-dirs dir)
    (fs/copy theme-file (fs/path dir "theme.md"))
    (squad-lib/write-record! (theme-status-file theme-id)
                             {:id theme-id
                              :assignments []
                              :created-at (handoff-lib/iso-now)})
    (squad-lib/log-event! theme-id "theme-created" "")
    (println (str "THEME_CREATED: " theme-id))))

(defn attach! [theme-id assignment-id]
  (let [file (theme-status-file theme-id)]
    ;; Attach arguments name records the caller believes exist, so a missing
    ;; one is a protocol violation (exit 2), unlike the read-a-record status
    ;; lookups that exit 1.
    (when-not (fs/exists? file)
      (handoff-lib/die 2 (str "NO_SUCH_THEME: " theme-id)))
    (when-not (re-matches #"[A-Za-z0-9][A-Za-z0-9_-]*" (str assignment-id))
      (handoff-lib/die 2 (str "INVALID_ASSIGNMENT_ID: " assignment-id)))
    (when-not (fs/exists? (squad-lib/status-file assignment-id))
      (handoff-lib/die 2 (str "NO_SUCH_ASSIGNMENT: " assignment-id)))
    (let [record (edn/read-string (slurp (str file)))]
      (when (some #{assignment-id} (:assignments record))
        (handoff-lib/die 2 (str "ALREADY_ATTACHED: " theme-id " " assignment-id)))
      (squad-lib/write-record! file (update record :assignments conj assignment-id)))
    (squad-lib/log-event! theme-id "theme-attached" (str "assignment=" assignment-id))
    (println (str "THEME_ATTACHED: " theme-id " " assignment-id))))

(defn status! [theme-id]
  (let [{:keys [assignments]}
        (squad-lib/read-record (theme-status-file theme-id) "NO_SUCH_THEME" theme-id)]
    (println "THEME:" theme-id)
    (doseq [assignment-id assignments]
      (let [file (squad-lib/status-file assignment-id)]
        ;; A deleted assignment record leaves its attachment visible rather
        ;; than hiding it: the theme is a report, not a filter.
        (println assignment-id
                 (if (fs/exists? file)
                   (name (:state (edn/read-string (slurp (str file)))))
                   "missing"))))))

;; --- entry ----------------------------------------------------------------

(defn- usage-die []
  (handoff-lib/die 1 usage-text))

(defn -main [args]
  (let [[command & params] args
        params (vec params)]
    (case command
      "create" (if (= 2 (count params)) (apply create! params) (usage-die))
      "attach" (if (= 2 (count params)) (apply attach! params) (usage-die))
      "status" (if (= 1 (count params)) (status! (first params)) (usage-die))
      (usage-die))))

(handoff-lib/run-entry #(-main *command-line-args*))
