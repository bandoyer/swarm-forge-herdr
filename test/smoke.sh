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

step "done with nothing in process fails cleanly"
set +e
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/done_with_current.sh" 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "empty done should exit 1, got $STATUS"
expect "empty done reports NO_CURRENT_TASK" "NO_CURRENT_TASK" <<<"$OUT"

echo
echo "SMOKE PASSED ($PASS checks)"
