#!/usr/bin/env bb
;; squad_approval.bb — human approval gates (docs/squad-s4.md, S4 slice A).
;;
;; An approval record routes one human decision:
;; .swarmforge/squad/approvals/<approval-id>.edn holding
;; {:id :gate :target :state :title :reason :requested-at}, plus
;; :decided-at/:detail once decided. The leader `request`s one when the
;; advisor reports a gated action (S4 row 11); the human decides via
;; `approve`/`reject`; the advisor reads the record to release or hold the
;; gated action. Lifecycle: pending -> approved | rejected, one decision
;; only — deciding a decided approval exits 2 with INVALID_TRANSITION.

(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "squad_lib.bb")))

(ns squad-approval
  (:require [babashka.fs :as fs]
            [clojure.string :as str]))

(def usage-text
  (str "Usage: squad_approval.sh <subcommand> ...\n\n"
       "  request <approval-id> <gate> <target> <title> <reason...>\n"
       "  approve <approval-id> [detail...]\n"
       "  reject <approval-id> <reason...>\n"
       "  list\n"
       "  status <approval-id>"))

(defn approval-file
  "Resolve an approval path. Ids are validated against the assignment-id
  shape before touching the filesystem, so a hostile id can never escape
  the approvals directory."
  [approval-id]
  (when-not (re-matches #"[A-Za-z0-9][A-Za-z0-9_-]*" (str approval-id))
    (handoff-lib/die 2 (str "INVALID_APPROVAL_ID: " approval-id)))
  (fs/path (squad-lib/approvals-dir) (str approval-id ".edn")))

;; --- subcommands ----------------------------------------------------------

(defn request! [approval-id gate target title reason]
  (let [file (approval-file approval-id)]
    ;; Gate and target become advisor match keys and audit-log detail; gate
    ;; their shape like assignment ids so neither can forge log lines.
    (when-not (re-matches #"[A-Za-z0-9][A-Za-z0-9._-]*" (str gate))
      (handoff-lib/die 2 (str "INVALID_GATE: " gate)))
    (when-not (re-matches #"[A-Za-z0-9][A-Za-z0-9_-]*" (str target))
      (handoff-lib/die 2 (str "INVALID_TARGET: " target)))
    (when (fs/exists? file)
      (handoff-lib/die 2 (str "APPROVAL_EXISTS: " approval-id)))
    (fs/create-dirs (squad-lib/approvals-dir))
    (squad-lib/write-record! file {:id approval-id
                                   :gate gate
                                   :target target
                                   :state :pending
                                   :title title
                                   :reason reason
                                   :requested-at (handoff-lib/iso-now)})
    (squad-lib/log-event! approval-id "requested" (str "gate=" gate " target=" target))
    (println (str "APPROVAL_REQUESTED: " approval-id))))

(defn- decide!
  "Shared approve/reject step: :pending only, stamp :decided-at, keep the
  decision text under :detail (the request-time :reason is the leader's
  case for asking and must survive the decision)."
  [approval-id new-state detail detail-key]
  (squad-lib/transition!
   {:file (approval-file approval-id)
    :missing-token "NO_SUCH_APPROVAL"
    :announce-token "APPROVAL_STATE"
    :label "approval"
    :id approval-id
    :allowed #{:pending}
    :new-state new-state
    :extra (cond-> {:decided-at (handoff-lib/iso-now)}
             (not (str/blank? detail)) (assoc :detail detail))
    :detail (when-not (str/blank? detail) (str detail-key "=" detail))}))

(defn approve! [approval-id detail]
  (decide! approval-id :approved detail "detail"))

(defn reject! [approval-id reason]
  (decide! approval-id :rejected reason "reason"))

(defn list!
  "One approval per line, pending (still awaiting the user) first."
  []
  (doseq [{:keys [id state gate target title]}
          (sort-by (juxt #(if (= :pending (:state %)) 0 1) :id)
                   (squad-lib/all-approvals))]
    (println id (name state) gate target title)))

(defn status! [approval-id]
  (let [{:keys [state gate target title reason requested-at decided-at detail]}
        (squad-lib/read-record (approval-file approval-id) "NO_SUCH_APPROVAL" approval-id)]
    (println "APPROVAL:" approval-id)
    (println "STATE:" (name state))
    (println "GATE:" gate)
    (println "TARGET:" target)
    (println "TITLE:" title)
    (println "REASON:" reason)
    (println "REQUESTED_AT:" requested-at)
    (when decided-at (println "DECIDED_AT:" decided-at))
    (when detail (println "DETAIL:" detail))))

;; --- entry ----------------------------------------------------------------

(defn- usage-die []
  (handoff-lib/die 1 usage-text))

(defn -main [args]
  (let [[command & params] args
        params (vec params)]
    (case command
      "request" (if (<= 5 (count params))
                  (request! (params 0) (params 1) (params 2) (params 3)
                            (str/join " " (subvec params 4)))
                  (usage-die))
      "approve" (if (<= 1 (count params))
                  (approve! (first params) (str/join " " (rest params)))
                  (usage-die))
      "reject" (if (<= 2 (count params))
                 (reject! (first params) (str/join " " (rest params)))
                 (usage-die))
      "list" (if (= [] params) (list!) (usage-die))
      "status" (if (= 1 (count params)) (status! (first params)) (usage-die))
      (usage-die))))

(handoff-lib/run-entry #(-main *command-line-args*))
