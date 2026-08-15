#!/usr/bin/env bb
;; squad_next.bb — the squad advisor (docs/squad-s3.md, S3 slice A).
;;
;; A pure, deterministic, READ-ONLY function of file state: it inspects
;; spawn-requests, assignment statuses, worker records, and squad.conf, and
;; prints zero or more blocks
;;
;;   NEXT_ACTION: <action>
;;   CLASS: mechanical | residual
;;   TARGET: <assignment-id or worker-name>
;;   REASON: <one line>
;;
;; separated by blank lines, in the order of the action table: squad-s3.md's
;; rows 1-10 plus squad-s4.md's approval rows 11-13 and its amendment of
;; row 5 (the merge gate). The daemon applies the mechanical actions; the
;; leader acts on the residual ones. Exit 0 always — an empty report is a
;; valid report — and nothing on disk is ever created, written, or deleted.

(load-file (str (babashka.fs/path (babashka.fs/parent *file*) "squad_lib.bb")))

(ns squad-next
  (:require [clojure.string :as str]))

(def usage-text "Usage: squad_next.sh [--residual-only | --mechanical-only]")

(def merger-template
  "Template name of the conflict-resolution role (docs/squad-s3.md); the
  merger depth cap counts assignments carrying this template."
  "merger")

(defn merger-depth
  "Length of the consecutive run of merger-template assignments at the head
  of assignment's :replaces chain — how many merger attempts this line of
  work has already consumed. The original blocked assignment is depth 0;
  each merger routed for it adds 1. A cycle in :replaces (corrupt state)
  ends the walk rather than hanging the advisor."
  [by-id assignment]
  (loop [current assignment, seen #{}, depth 0]
    (if (and current
             (= merger-template (:template current))
             (not (seen (:id current))))
      (recur (get by-id (:replaces current)) (conj seen (:id current)) (inc depth))
      depth)))

(defn- block [action class target reason]
  {:action action :class class :target target :reason reason})

(defn- stale-reason [assignment]
  (cond
    (nil? assignment) "assignment record is missing"
    (:replaced-by assignment) (str "assignment was replaced by " (:replaced-by assignment))
    :else (str "assignment is " (name (:state assignment)) ", not created")))

(defn advice
  "All advisor blocks for one file-state snapshot: rows 1-10 of the
  squad-s3.md action table plus the squad-s4.md approval rows 11-13,
  emitted in table order and sorted by record id within a row. Replaced
  assignments (:replaced-by set) are retired records — squad_assign's
  replace! reissues their work under the new id — so they trigger no spawn
  or judgment rows; their pending spawn-requests surface as stale (row 3)
  and their still-active workers are still offered for retirement (rows
  6-7). With no require_approval line and no approval records the report
  is byte-identical to S3: row 5 is only amended when merge-gate? is set,
  and rows 11-13 fire only off the gate or off approval records."
  [{:keys [requests assignments workers approvals cap max-depth merge-gate?]}]
  (let [by-id (into {} (map (juxt :id identity)) assignments)
        live (remove :replaced-by assignments)
        ;; S4 approval gate: records are matched to an assignment by
        ;; :target; only gate-"merge" records govern the merge gate.
        approvals-for (fn [id] (filter #(and (= "merge" (:gate %))
                                             (= id (:target %)))
                                       approvals))
        approved-for (fn [id] (first (filter #(= :approved (:state %))
                                             (approvals-for id))))
        spawnable? (fn [{:keys [assignment]}]
                     (let [a (get by-id assignment)]
                       (and a (= :created (:state a)) (not (:replaced-by a)))))
        active (filter (comp squad-lib/active-states :state) workers)
        in-use (count active)
        ;; Rows 1/2: hand the remaining capacity out in request order, so
        ;; the daemon is never told to spawn more workers than can allocate.
        free (max 0 (- cap in-use))
        pending (filter spawnable? requests)
        capacity-note (format "(%d/%d slots in use)" in-use cap)
        active-for (fn [id] (filter #(= id (:assignment %)) active))
        requested? (set (map :assignment requests))
        blocked (filter #(= :merge-blocked (:state %)) live)]
    (concat
     ;; row 1
     (for [request (take free pending)]
       (block "spawn" "mechanical" (:assignment request)
              (str "spawn-request pending and capacity available " capacity-note)))
     ;; row 2
     (for [request (drop free pending)]
       (block "wait-capacity" "mechanical" (:assignment request)
              (str "spawn-request pending but capacity exhausted " capacity-note)))
     ;; row 3
     (for [request requests :when (not (spawnable? request))]
       (block "drop-stale-spawn-request" "mechanical" (:assignment request)
              (stale-reason (get by-id (:assignment request)))))
     ;; row 4
     (for [a live :when (= :result (:state a))]
       (block "review" "residual" (:id a)
              "result recorded; leader must accept or reject"))
     ;; row 5 (amended by S4: when the merge gate is set, only an :approved
     ;; approval record releases the merge)
     (for [a live :when (= :accepted (:state a))
           :let [approval (when merge-gate? (approved-for (:id a)))]
           :when (or (not merge-gate?) approval)]
       (block "merge" "mechanical" (:id a)
              (if approval
                (str "accepted and approval " (:id approval)
                     " approved; daemon merges the result commit into main")
                "accepted; daemon merges the result commit into main")))
     ;; row 6
     (for [a assignments :when (= :merged (:state a))
           worker (active-for (:id a))]
       (block "retire-worker" "mechanical" (:name worker)
              (str "assignment " (:id a) " merged but its worker is still "
                   (name (:state worker)))))
     ;; row 7
     (for [a assignments :when (= :rejected (:state a))
           worker (active-for (:id a))]
       (block "retire-worker" "mechanical" (:name worker)
              (str "assignment " (:id a) " rejected but its worker is still "
                   (name (:state worker)))))
     ;; row 8
     (for [a blocked :let [depth (merger-depth by-id a)] :when (< depth max-depth)]
       (block "route-merger" "residual" (:id a)
              (format "merge-blocked at merger depth %d of max %d; leader assigns a merger"
                      depth max-depth)))
     ;; row 9
     (for [a blocked :let [depth (merger-depth by-id a)] :when (>= depth max-depth)]
       (block "escalate-to-user" "residual" (:id a)
              (format "merge-blocked at merger depth %d; max_merger_depth %d reached"
                      depth max-depth)))
     ;; row 10
     (for [a live :when (and (= :created (:state a)) (not (requested? (:id a))))]
       (block "needs-spawn-request" "residual" (:id a)
              "created but no spawn-request; leader must request a spawn"))
     ;; row 11
     (when merge-gate?
       (for [a live :when (and (= :accepted (:state a))
                               (empty? (approvals-for (:id a))))]
         (block "request-approval" "residual" (:id a)
                "accepted but the merge gate is set and no approval record exists; leader requests approval")))
     ;; row 12 — informational: the user decides; nobody is waked for it,
     ;; so the target is the approval id the user's CLI acts on.
     (for [approval approvals :when (= :pending (:state approval))]
       (block "await-user-approval" "residual" (:id approval)
              (str (:gate approval) " approval for " (:target approval)
                   " awaits the user's decision")))
     ;; row 13
     (for [approval approvals
           :let [a (get by-id (:target approval))]
           :when (and (= :rejected (:state approval))
                      (some? a)
                      (= :accepted (:state a))
                      (not (:replaced-by a)))]
       (block "handle-approval-rejection" "residual" (:target approval)
              (str "approval " (:id approval)
                   " rejected; leader rejects or reworks the assignment"))))))

;; --- entry ----------------------------------------------------------------

(defn snapshot []
  {:requests (squad-lib/all-spawn-requests)
   :assignments (squad-lib/all-assignments)
   :workers (squad-lib/all-workers)
   :approvals (squad-lib/all-approvals)
   :cap (squad-lib/max-transient-agents)
   :max-depth (squad-lib/max-merger-depth)
   :merge-gate? (squad-lib/require-approval? "merge")})

(defn print-report! [blocks]
  (when (seq blocks)
    (println (str/join "\n\n"
                       (for [{:keys [action class target reason]} blocks]
                         (str "NEXT_ACTION: " action "\n"
                              "CLASS: " class "\n"
                              "TARGET: " target "\n"
                              "REASON: " reason))))))

(defn -main [args]
  (let [wanted (case (vec args)
                 [] nil
                 ["--residual-only"] "residual"
                 ["--mechanical-only"] "mechanical"
                 (handoff-lib/die 1 usage-text))]
    (print-report! (cond->> (advice (snapshot))
                     wanted (filter #(= wanted (:class %)))))))

(handoff-lib/run-entry #(-main *command-line-args*))
