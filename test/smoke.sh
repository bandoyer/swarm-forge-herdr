#!/usr/bin/env bash
# smoke.sh — end-to-end protocol test, no herdr required.
#
# Builds a throwaway project with a coder (task mode) and cleaner (batch
# mode), then drives a full handoff lifecycle both directions:
#   draft -> swarm_handoff -> handoffd --once -> ready_for_next ->
#   done_with_current, plus validation-failure and batch cases.
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export SWARMFORGE_WAKE_CMD=none

PASS=0
step() { echo "--- $1"; }
ok() { PASS=$((PASS + 1)); echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
expect() { # expect <label> <needle> <<< haystack
  local haystack; haystack="$(cat)"
  grep -qF "$2" <<<"$haystack" || { echo "$haystack"; fail "$1 (missing: $2)"; }
  ok "$1"
}

step "set up throwaway project"
PROJECT="$WORK/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -qb main
git -C "$PROJECT" -c user.email=smoke@test -c user.name=smoke \
  commit -q --allow-empty -m "initial"
COMMIT="$(git -C "$PROJECT" rev-parse --short=10 HEAD)"

CODER="$PROJECT"
CLEANER="$WORK/cleaner"
mkdir -p "$CLEANER"
mkdir -p "$PROJECT/.swarmforge"
printf 'coder\tmaster\t%s\tcoder\tcoder\tclaude\ttask\ncleaner\tcleaner\t%s\tcleaner\tcleaner\tclaude\tbatch\n' \
  "$CODER" "$CLEANER" > "$PROJECT/.swarmforge/roles.tsv"
# The cleaner "worktree" needs to resolve the project root and the commit.
ln -s "$PROJECT/.git" "$CLEANER/.git"
ln -s "$PROJECT/.swarmforge" "$CLEANER/.swarmforge" 2>/dev/null || true
rm -f "$CLEANER/.swarmforge"; mkdir -p "$CLEANER/.swarmforge"
cp "$PROJECT/.swarmforge/roles.tsv" "$CLEANER/.swarmforge/roles.tsv"
for wt in "$CODER" "$CLEANER"; do
  mkdir -p "$wt/swarmforge"
  cp -r "$TOOL_ROOT/swarmforge/scripts" "$wt/swarmforge/scripts"
done
SCRIPTS="swarmforge/scripts"

step "reject an invalid draft"
cd "$CODER"
printf 'type: git_handoff\nto: nobody\npriority: high\ncommit: xyz\n' > draft.txt
set +e
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/swarm_handoff.sh" draft.txt 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "invalid draft should exit 2, got $STATUS"
expect "invalid draft: bad priority reported" "must be two digits" <<<"$OUT"
expect "invalid draft: unknown recipient reported" "Unknown recipient role 'nobody'" <<<"$OUT"
expect "invalid draft: missing task reported" "Missing required header 'task'" <<<"$OUT"
rm draft.txt

step "queue a valid git_handoff (coder -> cleaner)"
printf 'type: git_handoff\nto: cleaner\npriority: 50\ntask: smoke-task\ncommit: %s\n' "$COMMIT" > draft.txt
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/swarm_handoff.sh" draft.txt)"
expect "handoff queued" "HANDOFF QUEUED:" <<<"$OUT"
[ ! -e draft.txt ] || fail "draft should be deleted after queuing"
ok "draft removed"

step "deliver via handoffd --once"
bb "$SCRIPTS/handoffd.bb" "$PROJECT" --once
[ -n "$(ls "$CLEANER/.swarmforge/handoffs/inbox/new/" 2>/dev/null)" ] || fail "no inbox delivery"
[ -n "$(ls "$CODER/.swarmforge/handoffs/sent/" 2>/dev/null)" ] || fail "original not archived to sent/"
ok "delivered to cleaner inbox, archived to coder sent/"
INBOX_FILE="$(ls "$CLEANER"/.swarmforge/handoffs/inbox/new/*.handoff)"
grep -q '^recipient: cleaner$' "$INBOX_FILE" || fail "recipient header missing"
grep -q '^enqueued_at: ' "$INBOX_FILE" || fail "enqueued_at header missing"
ok "delivery headers stamped"

step "queue a second handoff at the same priority (for batching)"
printf 'type: note\nto: cleaner\npriority: 50\nmessage: smoke note\n' > draft.txt
SWARMFORGE_ROLE=coder "$SCRIPTS/swarm_handoff.sh" draft.txt > /dev/null
bb "$SCRIPTS/handoffd.bb" "$PROJECT" --once

step "cleaner accepts both as one batch"
cd "$CLEANER"
OUT="$(SWARMFORGE_ROLE=cleaner "$SCRIPTS/ready_for_next.sh")"
expect "batch accepted" "BATCH:" <<<"$OUT"
expect "batch has two items" "COUNT: 2" <<<"$OUT"
expect "batch carries payload" "merge_and_process coder" <<<"$OUT"
expect "batch carries note" "smoke note" <<<"$OUT"

step "ready_for_next resumes the same batch"
OUT="$(SWARMFORGE_ROLE=cleaner "$SCRIPTS/ready_for_next.sh")"
expect "batch resumed" "COUNT: 2" <<<"$OUT"

step "cleaner completes the batch and returns a handoff"
OUT="$(SWARMFORGE_ROLE=cleaner "$SCRIPTS/done_with_current.sh")"
expect "batch completed" "COMPLETED_BATCH:" <<<"$OUT"
expect "queue drained" "NO_TASK" <<<"$OUT"
printf 'type: git_handoff\nto: coder\npriority: 50\ntask: smoke-task\ncommit: %s\n' "$COMMIT" > return.txt
SWARMFORGE_ROLE=cleaner "$SCRIPTS/swarm_handoff.sh" return.txt > /dev/null
bb "$SCRIPTS/handoffd.bb" "$PROJECT" --once

step "coder accepts and completes the return handoff (task mode)"
cd "$CODER"
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/ready_for_next.sh")"
expect "task accepted" "TASK:" <<<"$OUT"
expect "task named" "TASK_NAME: smoke-task" <<<"$OUT"
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/done_with_current.sh")"
expect "task completed" "COMPLETED:" <<<"$OUT"
expect "coder queue drained" "NO_TASK" <<<"$OUT"

step "contract enforcement: violations hard-block, compliance passes"
mkdir -p "$CODER/swarmforge/contracts"
cat > "$CODER/swarmforge/contracts/coder.contract.edn" <<'EDN'
{:role "coder"
 :artifact-roots ["src/"]
 :required-evidence [{:name "tests-green" :pattern "(?i)tests? passed"}]}
EDN
mkdir -p src && echo x > src/ok.txt && echo y > forbidden.txt
git add src forbidden.txt
git -c user.email=smoke@test -c user.name=smoke commit -qm "bad commit, no evidence"
BAD="$(git rev-parse --short=10 HEAD)"
printf 'type: git_handoff\nto: cleaner\npriority: 50\ntask: contract-check\ncommit: %s\n' "$BAD" > draft.txt
set +e
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/swarm_handoff.sh" draft.txt 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "contract violation should exit 2, got $STATUS"
expect "contract: out-of-root path rejected" "outside role coder's artifact roots" <<<"$OUT"
expect "contract: missing evidence rejected" "required evidence 'tests-green'" <<<"$OUT"
echo z >> src/ok.txt && git add src
git -c user.email=smoke@test -c user.name=smoke commit -qm "good commit

All 5 tests passed."
GOOD="$(git rev-parse --short=10 HEAD)"
printf 'type: git_handoff\nto: cleaner\npriority: 50\ntask: contract-check\ncommit: %s\n' "$GOOD" > draft.txt
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/swarm_handoff.sh" draft.txt)"
expect "contract: compliant commit queues" "HANDOFF QUEUED:" <<<"$OUT"
rm -f draft.txt
rm -rf "$CODER/swarmforge/contracts"

step "squad: hostile worker names are rejected before path resolution"
set +e
OUT="$("$SCRIPTS/squad_worker.sh" retire '../assignments/a1/status' 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "traversal name should exit 2, got $STATUS"
expect "traversal worker name rejected" "INVALID_WORKER_NAME" <<<"$OUT"

step "done with nothing in process fails cleanly"
set +e
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/done_with_current.sh" 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "empty done should exit 1, got $STATUS"
expect "empty done reports NO_CURRENT_TASK" "NO_CURRENT_TASK" <<<"$OUT"

step "squad: create/status/result/accept lifecycle"
cd "$CODER"
echo "Implement the thing." > instructions.md
OUT="$("$SCRIPTS/squad_assign.sh" create a1 implementer instructions.md)"
expect "assignment created" "ASSIGNMENT_CREATED: a1" <<<"$OUT"
[ -f .swarmforge/squad/assignments/a1/assignment.md ] || fail "assignment.md not written"
ok "assignment.md written"
OUT="$("$SCRIPTS/squad_assign.sh" status a1)"
expect "status reports created" "STATE: created" <<<"$OUT"
echo "worker output" > worker.handoff
OUT="$("$SCRIPTS/squad_assign.sh" result a1 worker.handoff)"
expect "result transition" "ASSIGNMENT_STATE: a1 created -> result" <<<"$OUT"
[ -f .swarmforge/squad/assignments/a1/result.handoff ] || fail "result handoff not stored"
ok "result handoff stored"
OUT="$("$SCRIPTS/squad_assign.sh" accept a1)"
expect "accept transition" "ASSIGNMENT_STATE: a1 result -> accepted" <<<"$OUT"

step "squad: reject records the reason"
"$SCRIPTS/squad_assign.sh" create a2 implementer instructions.md > /dev/null
"$SCRIPTS/squad_assign.sh" result a2 worker.handoff > /dev/null
OUT="$("$SCRIPTS/squad_assign.sh" reject a2 missing unit tests)"
expect "reject transition" "ASSIGNMENT_STATE: a2 result -> rejected" <<<"$OUT"
OUT="$("$SCRIPTS/squad_assign.sh" status a2)"
expect "status reports rejected" "STATE: rejected" <<<"$OUT"
expect "status carries reason" "REASON: missing unit tests" <<<"$OUT"

step "squad: illegal transition exits 2 with INVALID_TRANSITION"
set +e
OUT="$("$SCRIPTS/squad_assign.sh" accept a1 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "illegal transition should exit 2, got $STATUS"
expect "illegal transition token" "INVALID_TRANSITION" <<<"$OUT"

step "squad: replace links old and new assignments"
OUT="$("$SCRIPTS/squad_assign.sh" replace a2 a3 implementer instructions.md)"
expect "replacement announced" "ASSIGNMENT_REPLACED: a2 -> a3" <<<"$OUT"
OUT="$("$SCRIPTS/squad_assign.sh" status a2)"
expect "old links forward" "REPLACED_BY: a3" <<<"$OUT"
OUT="$("$SCRIPTS/squad_assign.sh" status a3)"
expect "new links back" "REPLACES: a2" <<<"$OUT"
expect "new starts created" "STATE: created" <<<"$OUT"

step "squad: events.log holds one timestamped line per state change"
LOG="$CODER/.swarmforge/squad/events.log"
[ -f "$LOG" ] || fail "events.log missing"
[ "$(grep -c ' a1 ' "$LOG")" -eq 3 ] || { cat "$LOG"; fail "a1 should log 3 events (created/result/accepted)"; }
ok "a1 logged created/result/accepted"
[ "$(grep -c ' a2 ' "$LOG")" -eq 4 ] || { cat "$LOG"; fail "a2 should log 4 events (created/result/rejected/replaced)"; }
ok "a2 logged created/result/rejected/replaced"
[ -z "$(grep -Ev '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ' "$LOG")" ] || { cat "$LOG"; fail "events.log lines must be timestamped"; }
ok "all events.log lines timestamped"
grep -q ' a2 rejected reason=missing unit tests' "$LOG" || { cat "$LOG"; fail "reject reason not logged"; }
ok "reject reason logged"

step "squad: result retries cleanly after a crash-interrupted result"
# Simulate a prior `result` that copied the handoff but crashed before the
# status write: the file exists, the state still allows result. The retry
# must succeed — durable file state exists precisely so operations can be
# retried after a crash, and a raw stack trace is not an agent-legible error.
"$SCRIPTS/squad_assign.sh" create a4 implementer instructions.md > /dev/null
cp worker.handoff .swarmforge/squad/assignments/a4/result.handoff
set +e
OUT="$("$SCRIPTS/squad_assign.sh" result a4 worker.handoff 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 0 ] || { echo "$OUT"; fail "result retry after crashed copy should succeed, got $STATUS"; }
expect "result retry transition" "ASSIGNMENT_STATE: a4 created -> result" <<<"$OUT"
rm -f instructions.md worker.handoff

step "squad worker: allocate/activate/retire lifecycle"
OUT="$("$SCRIPTS/squad_worker.sh" allocate a1 implementer)"
expect "worker allocated" "WORKER_ALLOCATED: project-implementer-a1" <<<"$OUT"
[ -f .swarmforge/squad/workers/project-implementer-a1.edn ] || fail "worker record not written"
ok "worker record written"
OUT="$("$SCRIPTS/squad_worker.sh" activate project-implementer-a1)"
expect "worker activated" "WORKER_STATE: project-implementer-a1 allocated -> active" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" retire project-implementer-a1 assignment merged)"
expect "worker retired" "WORKER_STATE: project-implementer-a1 active -> retired" <<<"$OUT"

step "squad worker: list output and --active filter"
"$SCRIPTS/squad_worker.sh" allocate a2 implementer > /dev/null
"$SCRIPTS/squad_worker.sh" allocate a3 reviewer > /dev/null
"$SCRIPTS/squad_worker.sh" activate project-implementer-a2 > /dev/null
OUT="$("$SCRIPTS/squad_worker.sh" list)"
expect "list shows retired worker" "project-implementer-a1 retired implementer a1" <<<"$OUT"
expect "list shows active worker" "project-implementer-a2 active implementer a2" <<<"$OUT"
expect "list shows allocated worker" "project-reviewer-a3 allocated reviewer a3" <<<"$OUT"
expect "list reports active count and cap" "ACTIVE: 2/10" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" list --active)"
if grep -qF "project-implementer-a1" <<<"$OUT"; then fail "--active should hide retired workers"; fi
ok "--active hides retired workers"
expect "--active keeps allocated worker" "project-reviewer-a3 allocated reviewer a3" <<<"$OUT"

step "squad worker: capacity cap from squad.conf"
printf 'max_transient_agents 2\n' > swarmforge/squad.conf
set +e
OUT="$("$SCRIPTS/squad_worker.sh" allocate a4 implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "capacity exhaustion should exit 2, got $STATUS"
expect "capacity token" "CAPACITY_EXHAUSTED" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" list)"
expect "list reflects lowered cap" "ACTIVE: 2/2" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" retire project-reviewer-a3)"
expect "retire straight from allocated" "WORKER_STATE: project-reviewer-a3 allocated -> retired" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" allocate a4 implementer)"
expect "retired worker frees a capacity slot" "WORKER_ALLOCATED: project-implementer-a4" <<<"$OUT"
rm swarmforge/squad.conf

step "squad worker: name sanitization and left-trim"
OUT="$("$SCRIPTS/squad_worker.sh" allocate a4 'Q.A')"
expect "uppercase and dots sanitized" "WORKER_ALLOCATED: project-q-a-a4" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" allocate 12345678901234567890123456789012 implementer)"
expect "long name left-trimmed and letter-prefixed" "WORKER_ALLOCATED: w2345678901234567890123456789012" <<<"$OUT"

step "squad worker: duplicate allocate, illegal transition, unknown worker"
set +e
OUT="$("$SCRIPTS/squad_worker.sh" allocate a4 'Q.A' 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "duplicate allocate should exit 2, got $STATUS"
expect "duplicate allocate token" "WORKER_EXISTS: project-q-a-a4" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_worker.sh" activate project-implementer-a1 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "activating a retired worker should exit 2, got $STATUS"
expect "worker illegal transition token" "INVALID_TRANSITION: worker 'project-implementer-a1' cannot go retired -> active" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_worker.sh" activate no-such 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "unknown worker should exit 1, got $STATUS"
expect "unknown worker token" "NO_SUCH_WORKER: no-such" <<<"$OUT"

step "squad assign: spawn transition"
OUT="$("$SCRIPTS/squad_assign.sh" spawn a3)"
expect "spawn transition" "ASSIGNMENT_STATE: a3 created -> spawned" <<<"$OUT"

step "squad worker: events.log records worker state changes"
grep -q ' project-implementer-a1 allocated template=implementer assignment=a1' "$LOG" || { cat "$LOG"; fail "allocate not logged"; }
ok "allocate logged"
grep -q ' project-implementer-a1 active' "$LOG" || { cat "$LOG"; fail "activate not logged"; }
ok "activate logged"
grep -q ' project-implementer-a1 retired reason=assignment merged' "$LOG" || { cat "$LOG"; fail "retire reason not logged"; }
ok "retire reason logged"
grep -q ' a3 spawned' "$LOG" || { cat "$LOG"; fail "spawn not logged"; }
ok "spawn logged"
[ "$(grep -c ' project-implementer-a1 ' "$LOG")" -eq 3 ] || { cat "$LOG"; fail "worker should log exactly 3 events"; }
ok "one line per worker state change"
[ -z "$(grep -Ev '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ' "$LOG")" ] || { cat "$LOG"; fail "events.log lines must be timestamped"; }
ok "worker events.log lines timestamped"

echo
echo "SMOKE PASSED ($PASS checks)"
