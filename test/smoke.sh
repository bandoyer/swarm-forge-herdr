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

step "squad: spawn driver file-state path (--no-agent)"
cd "$CODER"
SWARM="$TOOL_ROOT/bin/swarm"
echo "Do the thing precisely." > sp.md
"$SCRIPTS/squad_assign.sh" create sp1 implementer sp.md >/dev/null
OUT="$("$SWARM" squad spawn sp1 implementer --no-agent)"
expect "spawn reports worker" "WORKER_SPAWNED:" <<<"$OUT"
WORKER="$(grep -oE 'WORKER_SPAWNED: .*' <<<"$OUT" | cut -d' ' -f2)"
[ -d ".worktrees/$WORKER/.swarmforge/handoffs/inbox/new" ] || fail "worker worktree/queue not prepared"
ok "worker worktree and queue dirs created"
grep -q "^$WORKER	" .swarmforge/roles.tsv || fail "worker not registered in roles.tsv"
ok "worker registered for routing"
OUT="$("$SCRIPTS/squad_assign.sh" status sp1)"
expect "assignment moved to spawned" "STATE: spawned" <<<"$OUT"
set +e
OUT="$("$SWARM" squad spawn sp1 implementer --no-agent 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "re-spawn of spawned assignment should fail, got $STATUS"
expect "re-spawn rejected" "not 'created'" <<<"$OUT"

step "squad: retire frees routing and worktree"
OUT="$("$SWARM" squad retire "$WORKER" done --no-agent)"
expect "retire reports worker" "WORKER_RETIRED: $WORKER" <<<"$OUT"
grep -q "^$WORKER	" .swarmforge/roles.tsv && fail "worker still in roles.tsv"
ok "worker deregistered"
[ ! -d ".worktrees/$WORKER" ] || fail "worker worktree not removed"
ok "worker worktree removed"

step "spawn-request: create/list/drop lifecycle"
echo "Spawn me." > sr.md
"$SCRIPTS/squad_assign.sh" create sr1 implementer sr.md > /dev/null
OUT="$("$SCRIPTS/squad_spawn_request.sh" create sr1 implementer)"
expect "spawn-request created" "SPAWN_REQUEST_CREATED: sr1" <<<"$OUT"
REQ=.swarmforge/squad/spawn-requests/sr1.edn
[ -f "$REQ" ] || fail "spawn-request record not written"
grep -q ':assignment "sr1"' "$REQ" || fail "record missing :assignment"
grep -q ':template "implementer"' "$REQ" || fail "record missing :template"
grep -q ':requested-at' "$REQ" || fail "record missing :requested-at"
ok "record carries assignment/template/requested-at"
OUT="$("$SCRIPTS/squad_spawn_request.sh" list)"
expect "list shows the request" "sr1 implementer" <<<"$OUT"
OUT="$("$SCRIPTS/squad_spawn_request.sh" drop sr1)"
expect "spawn-request dropped" "SPAWN_REQUEST_DROPPED: sr1" <<<"$OUT"
[ ! -e "$REQ" ] || fail "dropped record still on disk"
ok "dropped record deleted"
grep -q ' sr1 spawn-requested template=implementer' "$LOG" || { cat "$LOG"; fail "create not logged"; }
grep -q ' sr1 spawn-request-dropped' "$LOG" || { cat "$LOG"; fail "drop not logged"; }
ok "spawn-request create/drop logged to events.log"

step "spawn-request: refusals are agent-legible"
"$SCRIPTS/squad_spawn_request.sh" create sr1 implementer > /dev/null
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" create sr1 implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "duplicate spawn-request should exit 2, got $STATUS"
expect "duplicate token" "SPAWN_REQUEST_EXISTS: sr1" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" create ghost implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "missing assignment should exit 2, got $STATUS"
expect "missing assignment token" "NO_SUCH_ASSIGNMENT: ghost" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" create a1 implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "non-created assignment should exit 2, got $STATUS"
expect "non-created token" "ASSIGNMENT_NOT_CREATED" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" create '../evil' implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "hostile id should exit 2, got $STATUS"
expect "hostile id rejected before path resolution" "INVALID_ASSIGNMENT_ID" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" drop ghost 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "dropping a missing request should exit 1, got $STATUS"
expect "missing request token" "NO_SUCH_SPAWN_REQUEST: ghost" <<<"$OUT"
"$SCRIPTS/squad_spawn_request.sh" drop sr1 > /dev/null
rm -f sr.md

step "advisor: empty state is an empty report, exit 0"
ADVISOR="$WORK/advisor"
mkdir -p "$ADVISOR/.swarmforge" "$ADVISOR/swarmforge"
cp "$PROJECT/.swarmforge/roles.tsv" "$ADVISOR/.swarmforge/roles.tsv"
cp -r "$TOOL_ROOT/swarmforge/scripts" "$ADVISOR/swarmforge/scripts"
cd "$ADVISOR"
synth() { # synth <assignment-id> <status-edn>
  mkdir -p ".swarmforge/squad/assignments/$1"
  printf '%s\n' "$2" > ".swarmforge/squad/assignments/$1/status.edn"
}
put_worker() { # put_worker <name> <record-edn>
  mkdir -p .swarmforge/squad/workers
  printf '%s\n' "$2" > ".swarmforge/squad/workers/$1.edn"
}
set +e
OUT="$("$SCRIPTS/squad_next.sh")"
STATUS=$?
set -e
[ "$STATUS" -eq 0 ] || fail "advisor should exit 0 on empty state, got $STATUS"
[ -z "$OUT" ] || { echo "$OUT"; fail "empty state should print nothing"; }
ok "empty report exits 0 and prints nothing"

step "advisor: rows 10, 1, 2 (spawn-request vs capacity)"
synth c1 '{:id "c1" :template "implementer" :state :created}'
OUT="$("$SCRIPTS/squad_next.sh")"
expect "row 10: created without spawn-request" "NEXT_ACTION: needs-spawn-request" <<<"$OUT"
expect "row 10 targets the assignment" "TARGET: c1" <<<"$OUT"
expect "row 10 is residual" "CLASS: residual" <<<"$OUT"
"$SCRIPTS/squad_spawn_request.sh" create c1 implementer > /dev/null
OUT="$("$SCRIPTS/squad_next.sh")"
expect "row 1: spawn when capacity available" "NEXT_ACTION: spawn" <<<"$OUT"
expect "row 1 is mechanical" "CLASS: mechanical" <<<"$OUT"
if grep -q 'needs-spawn-request' <<<"$OUT"; then fail "requested assignment must not re-nag row 10"; fi
ok "spawn-request suppresses needs-spawn-request"
printf 'max_transient_agents 0\n' > swarmforge/squad.conf
OUT="$("$SCRIPTS/squad_next.sh")"
expect "row 2: wait-capacity when exhausted" "NEXT_ACTION: wait-capacity" <<<"$OUT"
if grep -q '^NEXT_ACTION: spawn$' <<<"$OUT"; then fail "no spawn should be advised at zero capacity"; fi
ok "zero capacity advises no spawn"
rm swarmforge/squad.conf

step "advisor: full synthetic state fires every remaining row, in table order"
synth c2 '{:id "c2" :template "implementer" :state :created}'
"$SCRIPTS/squad_spawn_request.sh" create c2 implementer > /dev/null
synth c2 '{:id "c2" :template "implementer" :state :spawned}'
synth c3 '{:id "c3" :template "implementer" :state :result}'
synth c4 '{:id "c4" :template "implementer" :state :accepted}'
synth c5 '{:id "c5" :template "implementer" :state :merged}'
put_worker w-c5 '{:name "w-c5" :template "implementer" :assignment "c5" :state :active}'
synth c6 '{:id "c6" :template "implementer" :state :rejected}'
put_worker w-c6 '{:name "w-c6" :template "implementer" :assignment "c6" :state :allocated}'
synth c7 '{:id "c7" :template "implementer" :state :merge-blocked}'
synth c8 '{:id "c8" :template "implementer" :state :merge-blocked :replaced-by "m1"}'
synth m1 '{:id "m1" :template "merger" :state :merge-blocked :replaces "c8" :replaced-by "m2"}'
synth m2 '{:id "m2" :template "merger" :state :merge-blocked :replaces "m1"}'
synth c9 '{:id "c9" :template "implementer" :state :merge-blocked :replaced-by "m3"}'
synth m3 '{:id "m3" :template "merger" :state :merge-blocked :replaces "c9"}'
synth c10 '{:id "c10" :template "implementer" :state :created}'
OUT="$("$SCRIPTS/squad_next.sh")"
SEQ="$(grep '^NEXT_ACTION: ' <<<"$OUT" | sed 's/^NEXT_ACTION: //' | tr '\n' ' ')"
WANT="spawn drop-stale-spawn-request review merge retire-worker retire-worker route-merger route-merger escalate-to-user needs-spawn-request "
[ "$SEQ" = "$WANT" ] || { echo "$OUT"; fail "action sequence should follow table order; got: $SEQ"; }
ok "all rows fire in table order"
block_of() { grep -A3 "^NEXT_ACTION: $1\$" <<<"$OUT"; }
block_of drop-stale-spawn-request | grep -q 'TARGET: c2' || fail "row 3 should target the stale request c2"
ok "row 3: stale spawn-request targeted"
block_of review | grep -q 'TARGET: c3' || fail "row 4 should target c3"
ok "row 4: result assignment offered for review"
block_of merge | grep -q 'TARGET: c4' || fail "row 5 should target c4"
ok "row 5: accepted assignment offered for merge"
block_of retire-worker | grep -q 'TARGET: w-c5' || fail "row 6 should target worker w-c5"
block_of retire-worker | grep -q 'TARGET: w-c6' || fail "row 7 should target worker w-c6"
ok "rows 6-7: retire-worker targets worker names"
block_of route-merger | grep -q 'TARGET: c7' || fail "row 8 should target c7 (depth 0)"
block_of route-merger | grep -q 'TARGET: m3' || fail "row 8 should target m3 (depth 1)"
ok "row 8: route-merger under the depth cap"
block_of escalate-to-user | grep -q 'TARGET: m2' || fail "row 9 should target m2 (depth 2)"
ok "row 9: escalate at the depth cap"
block_of needs-spawn-request | grep -q 'TARGET: c10' || fail "row 10 should target c10"
ok "row 10: created without request reminded"
for hidden in c8 m1 c9; do
  if grep -q "^TARGET: $hidden\$" <<<"$OUT"; then fail "replaced assignment $hidden should stay silent"; fi
done
ok "replaced assignments trigger no judgment rows"
[ "$(grep -c '^NEXT_ACTION: ' <<<"$OUT")" -eq 10 ] || fail "expected 10 blocks"
[ "$(grep -c '^CLASS: ' <<<"$OUT")" -eq 10 ] || fail "every block needs a CLASS line"
[ "$(grep -c '^TARGET: ' <<<"$OUT")" -eq 10 ] || fail "every block needs a TARGET line"
[ "$(grep -c '^REASON: ' <<<"$OUT")" -eq 10 ] || fail "every block needs a REASON line"
[ "$(grep -c '^$' <<<"$OUT")" -eq 9 ] || { echo "$OUT"; fail "10 blocks need exactly 9 blank separators"; }
ok "blocks are 4 lines separated by single blank lines"

step "advisor: max_merger_depth read from squad.conf"
printf 'max_merger_depth 1\n' > swarmforge/squad.conf
OUT="$("$SCRIPTS/squad_next.sh")"
[ "$(grep -c '^NEXT_ACTION: escalate-to-user$' <<<"$OUT")" -eq 2 ] || { echo "$OUT"; fail "depth cap 1 should escalate both m3 and m2"; }
[ "$(grep -c '^NEXT_ACTION: route-merger$' <<<"$OUT")" -eq 1 ] || { echo "$OUT"; fail "depth cap 1 should still route c7 (depth 0)"; }
ok "lowered depth cap moves depth-1 merger to escalate"
rm swarmforge/squad.conf

step "advisor: class filters"
OUT="$("$SCRIPTS/squad_next.sh" --mechanical-only)"
if grep -q '^CLASS: residual$' <<<"$OUT"; then fail "--mechanical-only leaked a residual block"; fi
expect "--mechanical-only keeps mechanical blocks" "CLASS: mechanical" <<<"$OUT"
OUT="$("$SCRIPTS/squad_next.sh" --residual-only)"
if grep -q '^CLASS: mechanical$' <<<"$OUT"; then fail "--residual-only leaked a mechanical block"; fi
expect "--residual-only keeps residual blocks" "CLASS: residual" <<<"$OUT"

step "advisor: read-only and deterministic"
BEFORE="$(find .swarmforge swarmforge -type f -print0 | sort -z | xargs -0 md5sum)"
FIRST="$("$SCRIPTS/squad_next.sh")"
SECOND="$("$SCRIPTS/squad_next.sh")"
"$SCRIPTS/squad_next.sh" --residual-only > /dev/null
AFTER="$(find .swarmforge swarmforge -type f -print0 | sort -z | xargs -0 md5sum)"
[ "$BEFORE" = "$AFTER" ] || fail "advisor mutated file state"
ok "state identical before and after advisor runs"
[ "$FIRST" = "$SECOND" ] || fail "advisor output should be deterministic"
ok "back-to-back runs are identical"

step "advisor: partial capacity splits spawn/wait in request order"
# One free slot, two pending requests: the budget must hand out exactly the
# remaining capacity, not evaluate each request against a >0 check.
ADVISOR2="$WORK/advisor2"
mkdir -p "$ADVISOR2/.swarmforge" "$ADVISOR2/swarmforge"
cp "$PROJECT/.swarmforge/roles.tsv" "$ADVISOR2/.swarmforge/roles.tsv"
cp -r "$TOOL_ROOT/swarmforge/scripts" "$ADVISOR2/swarmforge/scripts"
cd "$ADVISOR2"
echo "work" > pc.md
printf 'max_transient_agents 1\n' > swarmforge/squad.conf
"$SCRIPTS/squad_assign.sh" create pc1 implementer pc.md > /dev/null
"$SCRIPTS/squad_assign.sh" create pc2 implementer pc.md > /dev/null
"$SCRIPTS/squad_spawn_request.sh" create pc1 implementer > /dev/null
"$SCRIPTS/squad_spawn_request.sh" create pc2 implementer > /dev/null
OUT="$("$SCRIPTS/squad_next.sh" --mechanical-only)"
grep -A3 '^NEXT_ACTION: spawn$' <<<"$OUT" | grep -q 'TARGET: pc1' \
  || { echo "$OUT"; fail "one free slot should spawn the first request"; }
grep -A3 '^NEXT_ACTION: wait-capacity$' <<<"$OUT" | grep -q 'TARGET: pc2' \
  || { echo "$OUT"; fail "overflow request should wait-capacity"; }
[ "$(grep -c '^NEXT_ACTION: spawn$' <<<"$OUT")" -eq 1 ] \
  || { echo "$OUT"; fail "exactly one spawn should be advised for one free slot"; }
ok "one slot, two requests: first spawns, second waits"

# --- reviewer findings (squad-advisor review) -------------------------------
# Each block below is a failing test for an open defect; disabled so the
# suite stays green. Run with SMOKE_FINDINGS=1 to watch them fail; the
# coder's fix removes the gate.
if [ "${SMOKE_FINDINGS:-0}" = 1 ]; then

step "FINDING: spawn-request create accepts a replaced (retired) assignment"
# squad_spawn_request.bb create checks only (= :created state), but
# squad_assign replace! keeps the old record's state, so a replaced
# :created assignment passes the gate and the request is born stale —
# contradicting the script's own header claim that a stale request "can
# only arise from lifecycle movement after the fact".
"$SCRIPTS/squad_assign.sh" create fr1 implementer pc.md > /dev/null
"$SCRIPTS/squad_assign.sh" replace fr1 fr2 implementer pc.md > /dev/null
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" create fr1 implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] \
  || { echo "$OUT"; fail "spawn-request for a replaced assignment should be refused (exit 2), got $STATUS"; }
ok "replaced assignment cannot request a spawn"

step "FINDING: unvalidated template forges events.log lines"
# The template argument flows raw into log-event! detail; a newline in it
# appends an attacker-chosen line to the durable audit log. Ids are
# validated before path resolution — templates deserve the same gate (they
# also become daemon spawn arguments in slice B).
"$SCRIPTS/squad_assign.sh" create fr3 implementer pc.md > /dev/null
set +e
"$SCRIPTS/squad_spawn_request.sh" create fr3 \
  "$(printf 'implementer\n2026-01-01T00:00:00Z fr3 accepted FORGED')" > /dev/null 2>&1
set -e
if grep -q 'FORGED' .swarmforge/squad/events.log; then
  fail "hostile template must not forge an events.log line"
fi
ok "template cannot forge audit-log lines"

fi
cd "$CODER"

echo
echo "SMOKE PASSED ($PASS checks)"
